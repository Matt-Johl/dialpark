package pbxline

import (
	"context"
	"testing"
	"time"
)

// A line that moves to another PBX-leg socket is unregistered from the old
// one first (the exchange holds the binding against that address) and then
// registered from the new; a write that keeps the port disturbs nothing.
func TestPutMovingALineToAnotherPortReregisters(t *testing.T) {
	reg := newFakeRegistrar(nil)
	m := testManager(t, reg)
	m.Put(Line{User: "201", DigestUser: "d", Secret: "s", Port: 5062})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	m.Start(ctx)
	waitFor(t, "the first registration", func() bool { return reg.count() >= 1 })
	if st, _ := m.Status("201"); st.Port != 5062 {
		t.Fatalf("status port = %d, want 5062", st.Port)
	}
	if p, ok := m.Port("201"); !ok || p != 5062 {
		t.Fatalf("Port(201) = %d, %v", p, ok)
	}
	if u, ok := m.UserAtPort(5062); !ok || u != "201" {
		t.Fatalf("UserAtPort(5062) = %q, %v", u, ok)
	}
	if _, ok := m.UserAtPort(0); ok {
		t.Fatal("port 0 is the shared socket and names no line")
	}

	// The same line again: no unregistration, the binding is left alone.
	m.Put(Line{User: "201", DigestUser: "d", Secret: "s", Port: 5062})
	time.Sleep(20 * time.Millisecond)
	if u := reg.unregistered(); len(u) != 0 {
		t.Fatalf("an unchanged write unregistered the line: %v", u)
	}

	// Moved: off the old socket, on with the new.
	m.Put(Line{User: "201", DigestUser: "d", Secret: "s", Port: 5063})
	waitFor(t, "the unregistration from the old port", func() bool {
		u := reg.unregistered()
		return len(u) == 1 && u[0].Port == 5062
	})
	waitFor(t, "a registration from the new port", func() bool {
		reg.mu.Lock()
		defer reg.mu.Unlock()
		return len(reg.calls) > 0 && reg.calls[len(reg.calls)-1].Port == 5063
	})
	if p, _ := m.Port("201"); p != 5063 {
		t.Errorf("Port(201) after the move = %d", p)
	}
	if u, ok := m.UserAtPort(5063); !ok || u != "201" {
		t.Errorf("UserAtPort(5063) = %q, %v", u, ok)
	}
	if _, ok := m.UserAtPort(5062); ok {
		t.Error("the old port still names the line")
	}
	if st, _ := m.Status("201"); st.Port != 5063 {
		t.Errorf("status port after the move = %d", st.Port)
	}
	// Nil-safe, like the other accessors.
	var none *Manager
	if _, ok := none.Port("201"); ok {
		t.Error("nil manager has a port")
	}
	if _, ok := none.UserAtPort(5063); ok {
		t.Error("nil manager has a line")
	}
	if none.Ports().Len() != 0 {
		t.Error("nil manager has a range")
	}
}
