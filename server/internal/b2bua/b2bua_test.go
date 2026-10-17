package b2bua

import (
	"crypto/tls"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/emiago/sipgo/sip"

	"dialpark/server/internal/registry"
	"dialpark/server/internal/routing"
)

// The SIP/media paths need real sockets and are exercised by the docker
// harness (make harness-call). These tests cover the socket-free logic.

func TestRegisterExpires(t *testing.T) {
	mk := func(contact, expiresHdr string) (*sip.Request, *sip.ContactHeader) {
		req := sip.NewRequest(sip.REGISTER, sip.Uri{Host: "dialpark"})
		var c sip.ContactHeader
		if _, err := sip.ParseAddressValue(contact, &c.Address, &c.Params); err != nil {
			t.Fatal(err)
		}
		if expiresHdr != "" {
			req.AppendHeader(sip.NewHeader("Expires", expiresHdr))
		}
		return req, &c
	}
	req, c := mk("<sip:201@10.0.0.5:5061;transport=tls>;expires=300", "7200")
	if got := registerExpires(req, c, 60); got != 300 {
		t.Fatalf("contact param should win: %d", got)
	}
	req, c = mk("<sip:201@10.0.0.5:5061;transport=tls>", "7200")
	if got := registerExpires(req, c, 60); got != 7200 {
		t.Fatalf("Expires header: %d", got)
	}
	req, c = mk("<sip:201@10.0.0.5:5061;transport=tls>", "")
	if got := registerExpires(req, c, 60); got != 60 {
		t.Fatalf("default: %d", got)
	}
}

func TestRewriteContactRoutesToSourceOverTLS(t *testing.T) {
	var adv sip.Uri
	if err := sip.ParseUri("sip:201-0x1010e11f0@10.18.0.212:50615;transport=tls", &adv); err != nil {
		t.Fatal(err)
	}
	// The phone advertised its own listener; we route to where the TLS
	// connection actually came from (NAT source port), always over TLS.
	got := rewriteContact(adv, "203.0.113.9:61234")
	want := "sip:201-0x1010e11f0@203.0.113.9:61234;transport=tls"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	var back sip.Uri
	if err := sip.ParseUri(got, &back); err != nil {
		t.Fatal(err)
	}
	if tr, _ := back.UriParams.Get("transport"); tr != "tls" || back.Port != 61234 {
		t.Fatalf("round trip lost routing: %+v", back)
	}
	// Unparseable source keeps the advertised contact.
	if got := rewriteContact(adv, "garbage"); got != adv.String() {
		t.Fatalf("fallback: %q", got)
	}
}

func TestServesDomain(t *testing.T) {
	s := &Server{cfg: Config{Domains: []string{"dialpark.example.local"}, ExternalHost: "10.0.0.1"}}
	cases := map[string]bool{
		"dialpark.example.local":      true,
		"DIALPARK.example.local:5061": true,
		"10.0.0.1":                    true,
		"evil.example":                false,
		"":                            true,
	}
	for host, want := range cases {
		if got := s.servesDomain(host); got != want {
			t.Errorf("servesDomain(%q) = %v want %v", host, got, want)
		}
	}
	open := &Server{cfg: Config{ExternalHost: "10.0.0.1"}}
	if !open.servesDomain("anything.example") {
		t.Fatal("no Domains configured should serve any host")
	}
}

func TestFlowAliveFalseWithoutConnection(t *testing.T) {
	reg := registry.New(nil)
	r := routing.New(reg, nil, nil)
	s, err := New(Config{TLS: &tls.Config{}, ExternalHost: "h", Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}, reg, r, nil)
	if err != nil {
		t.Fatal(err)
	}
	// No connection was ever accepted from this address: the route is dead
	// and must not be dialled. (A live flow is exercised by the harness.)
	if s.flowAlive("sip:201@192.168.65.1:63199;transport=tls") {
		t.Fatal("flowAlive reported a connection that does not exist")
	}
	if s.flowAlive("not a uri") {
		t.Fatal("unparseable route must be dead")
	}
}

func TestNewRequiresTLSAndHost(t *testing.T) {
	reg := registry.New(nil)
	r := routing.New(reg, nil, nil)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	if _, err := New(Config{ExternalHost: "h", Logger: log}, reg, r, nil); err == nil {
		t.Fatal("missing TLS accepted")
	}
	if _, err := New(Config{TLS: &tls.Config{}, Logger: log}, reg, r, nil); err == nil {
		t.Fatal("missing ExternalHost accepted")
	}
	s, err := New(Config{TLS: &tls.Config{}, ExternalHost: "h", Logger: log}, reg, r, nil)
	if err != nil {
		t.Fatal(err)
	}
	if s.cfg.Port != 5061 || s.cfg.RingTimeout == 0 || s.cfg.MinExpires != 60 {
		t.Fatalf("defaults not applied: %+v", s.cfg)
	}
}

// -peer-timeout 0 means off. The config's zero means "the default", so
// main maps the flag's zero to a negative value, which withDefaults must
// leave alone and startLocked must read as "no watchdog".
func TestANegativePeerTimeoutStaysOffThroughDefaults(t *testing.T) {
	if got := (Config{PeerTimeout: -1}).withDefaults().PeerTimeout; got >= 0 {
		t.Fatalf("withDefaults turned the off value into %v", got)
	}
	if got := (Config{}).withDefaults().PeerTimeout; got != 60*time.Second {
		t.Fatalf("zero must still take the default, got %v", got)
	}
}
