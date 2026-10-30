package enroll

import (
	"path/filepath"
	"testing"
)

// The PBX-leg socket a line registers from (SPEC §6 item 3c, a socket per
// line) is the server's to set, survives a credential change and a restart,
// and goes with the line when the line goes.
func TestPBXLinePortIsKeptWithTheLine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "devices.json")
	s := testStore(t, path)
	s.Create("dev-a", "201", "")
	s.Create("dev-b", "202", "")
	if _, err := s.SetPBXLine("dev-a", "", "line201", "s"); err != nil {
		t.Fatal(err)
	}
	if l, _ := s.PBXLine("dev-a"); l.Port != 0 {
		t.Fatalf("a new line has port %d; the server assigns one, a write never does", l.Port)
	}
	// No line, no port: not an error, nothing stored.
	if err := s.SetPBXLinePort("dev-b", 5063); err != nil {
		t.Fatal(err)
	}
	if len(s.PBXLinePorts()) != 0 {
		t.Fatal("a port was recorded for a device with no line")
	}
	if err := s.SetPBXLinePort("dev-a", 5063); err != nil {
		t.Fatal(err)
	}
	if l, _ := s.PBXLine("dev-a"); l.Port != 5063 {
		t.Fatalf("port = %d, want 5063", l.Port)
	}
	c, _, _ := s.PBXCredential("dev-a")
	if c.Port != 5063 {
		t.Errorf("the registrar's credential carries port %d, want 5063", c.Port)
	}
	// A credential change keeps the socket: the exchange knows the device by it.
	if _, err := s.SetPBXLine("dev-a", "", "line201", "new-secret"); err != nil {
		t.Fatal(err)
	}
	if l, _ := s.PBXLine("dev-a"); l.Port != 5063 {
		t.Fatalf("port after a credential change = %d, want 5063 kept", l.Port)
	}
	// And a restart.
	again := testStore(t, path)
	again.Secrets = s.Secrets
	if got := again.PBXLinePorts(); got["dev-a"] != 5063 || len(got) != 1 {
		t.Fatalf("ports after reload = %v, want dev-a on 5063 only", got)
	}
	// Deleting the line frees the port by there being no record to hold it.
	if _, err := s.DeletePBXLine("dev-a"); err != nil {
		t.Fatal(err)
	}
	if len(s.PBXLinePorts()) != 0 {
		t.Fatal("a deleted line still holds a port")
	}
}
