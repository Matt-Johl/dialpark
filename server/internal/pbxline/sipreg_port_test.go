package pbxline

import (
	"context"
	"testing"
	"time"

	"github.com/emiago/sipgo"
	"github.com/emiago/sipgo/sip"
)

// A socket per line (b2bua.PortRange): the REGISTER advertises the line's
// own port in Contact and is sent by that port's client, and a line that
// moves port starts a new registration rather than refreshing the old.
func TestRegisterAdvertisesTheLinesOwnPort(t *testing.T) {
	ua, err := sipgo.NewUA()
	if err != nil {
		t.Fatal(err)
	}
	defer ua.Close()
	clients := map[int]*sipgo.Client{}
	for _, p := range []int{5062, 5063} {
		c, err := sipgo.NewClient(ua)
		if err != nil {
			t.Fatal(err)
		}
		clients[p] = c
	}
	r, ex := newScriptedRegistrar(t, cucm200(), cucm200(), cucm200())
	r.cfg.Transport = func(port int) (*sipgo.Client, sip.Uri, bool) {
		c, ok := clients[port]
		return c, sip.Uri{Scheme: "sip", Host: "10.7.141.25", Port: port, UriParams: sip.NewParams()}, ok
	}
	var sent []*sip.Request
	r.sendFn = func(ctx context.Context, req *sip.Request) (*sip.Response, error) {
		sent = append(sent, req)
		return ex.send(ctx, req)
	}

	line := Line{User: "10911", DN: "10911", DigestUser: "10911", Secret: "s", Port: 5063}
	if _, err := r.Register(context.Background(), line, time.Minute); err != nil {
		t.Fatal(err)
	}
	if got := sent[0].Contact().Address.Port; got != 5063 {
		t.Fatalf("Contact port = %d, want the line's 5063", got)
	}
	if c, _ := r.transport(5063); c != clients[5063] {
		t.Error("the REGISTER is not sent by the line's own client")
	}
	// A refresh reuses the request (same Call-ID on the wire): the
	// exchange sees one binding renewed.
	if _, err := r.Register(context.Background(), line, time.Minute); err != nil {
		t.Fatal(err)
	}
	if sent[1] != sent[0] {
		t.Error("a refresh on the same port built a new request")
	}
	// A move to another port is a new binding from a new address: a new
	// request, the new port in Contact.
	line.Port = 5062
	if _, err := r.Register(context.Background(), line, time.Minute); err != nil {
		t.Fatal(err)
	}
	if got := sent[2].Contact().Address.Port; got != 5062 {
		t.Fatalf("Contact port after the move = %d, want 5062", got)
	}
	if sent[2] == sent[0] {
		t.Error("a line that moved port reused the old binding's request")
	}
	// A port the server has no socket for falls back to the shared one.
	if c, u := r.transport(9999); c != r.cfg.Client || u.Port != r.cfg.Contact.Port {
		t.Errorf("unknown port fell back to %v/%d, want the shared client and contact", c, u.Port)
	}
}
