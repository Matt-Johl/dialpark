package main

import (
	"log/slog"
	"path/filepath"
	"strings"
	"testing"

	"dialpark/server/internal/enroll"
	"dialpark/server/internal/pbxline"
	"dialpark/server/internal/secrets"
)

func portStore(t *testing.T) *enroll.Store {
	t.Helper()
	devices, _ := enroll.Open("")
	devices.Realm = "dialpark"
	box, _ := secrets.OpenKey(filepath.Join(t.TempDir(), "pbx.key"))
	devices.Secrets = box
	return devices
}

// Each line takes the lowest port of the range no other line holds, keeps
// it once it has one, and is refused when the range is full.
func TestAssignLinePort(t *testing.T) {
	devices := portStore(t)
	r := pbxline.PortRange{First: 5062, Last: 5064}
	for _, d := range [][2]string{{"dev-a", "201"}, {"dev-b", "202"}, {"dev-c", "203"}, {"dev-d", "204"}} {
		devices.Create(d[0], d[1], "")
		if _, err := devices.SetPBXLine(d[0], "", "line-"+d[1], "s"); err != nil {
			t.Fatal(err)
		}
	}
	// No range: everything on the shared socket, nothing written.
	if p, err := assignLinePort(devices, pbxline.PortRange{}, "dev-a"); p != 0 || err != nil {
		t.Fatalf("no range: port %d err %v", p, err)
	}
	if p, _ := assignLinePort(devices, r, "dev-b"); p != 5062 {
		t.Fatalf("first allocation = %d, want the range's first port", p)
	}
	if p, _ := assignLinePort(devices, r, "dev-a"); p != 5063 {
		t.Fatalf("second allocation = %d, want the next free port", p)
	}
	if p, _ := assignLinePort(devices, r, "dev-b"); p != 5062 {
		t.Fatalf("dev-b asked again got %d; a line keeps its port", p)
	}
	if p, _ := assignLinePort(devices, r, "dev-c"); p != 5064 {
		t.Fatalf("third allocation = %d", p)
	}
	if _, err := assignLinePort(devices, r, "dev-d"); err == nil || !strings.Contains(err.Error(), "widen") {
		t.Fatalf("a full range must refuse and say so, got %v", err)
	}
	// A stored port outside the range (the range moved) is reassigned.
	if _, err := devices.DeletePBXLine("dev-c"); err != nil {
		t.Fatal(err)
	}
	if err := devices.SetPBXLinePort("dev-b", 6000); err != nil {
		t.Fatal(err)
	}
	if p, _ := assignLinePort(devices, r, "dev-b"); p != 5062 {
		t.Fatalf("a port outside the range was kept: %d", p)
	}
	if p, _ := assignLinePort(devices, r, "dev-d"); p != 5064 {
		t.Fatalf("the deleted line's port was not freed: dev-d got %d", p)
	}
	if _, err := assignLinePort(devices, r, "dev-none"); err == nil {
		t.Fatal("a device with no line cannot take a port")
	}
}

// registerLine puts the line on the exchange from its own socket when the
// manager runs with a range, and on the shared one otherwise.
func TestRegisterLineTakesASocket(t *testing.T) {
	log := slog.Default()
	devices := portStore(t)
	devices.SetSeats(2)
	devices.Create("dev-a", "201", "")
	devices.Create("dev-b", "202", "")
	for _, id := range []string{"dev-a", "dev-b"} {
		if _, err := devices.SetPBXLine(id, "", "line-"+id, "s"); err != nil {
			t.Fatal(err)
		}
	}
	mgr := pbxline.New(pbxline.Config{Registrar: okRegistrar{}, Log: log, Ports: pbxline.PortRange{First: 5062, Last: 5063}})
	registerLine(log, mgr, devices, "dev-a")
	registerLine(log, mgr, devices, "dev-b")
	if p, _ := mgr.Port("201"); p != 5062 {
		t.Errorf("201 on port %d, want 5062", p)
	}
	if p, _ := mgr.Port("202"); p != 5063 {
		t.Errorf("202 on port %d, want 5063", p)
	}
	if u, ok := mgr.UserAtPort(5063); !ok || u != "202" {
		t.Errorf("UserAtPort(5063) = %q, %v", u, ok)
	}
	if got := devices.PBXLinePorts(); got["dev-a"] != 5062 || got["dev-b"] != 5063 {
		t.Errorf("stored ports = %v", got)
	}
	// A third line has no socket: stored, logged, not registered.
	devices.Create("dev-c", "203", "")
	if _, err := devices.SetPBXLine("dev-c", "", "line-dev-c", "s"); err != nil {
		t.Fatal(err)
	}
	registerLine(log, mgr, devices, "dev-c")
	if _, ok := mgr.Port("203"); ok {
		t.Error("a line the range has no room for was registered anyway")
	}
	// Without a range every line is on the shared socket.
	shared := pbxline.New(pbxline.Config{Registrar: okRegistrar{}, Log: log})
	registerLine(log, shared, devices, "dev-a")
	if p, ok := shared.Port("201"); !ok || p != 0 {
		t.Errorf("shared socket: port %d, %v", p, ok)
	}
}
