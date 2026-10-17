package b2bua

import (
	"crypto/tls"
	"io"
	"log/slog"
	"strconv"
	"strings"
	"testing"

	"github.com/emiago/sipgo/sip"

	"dialpark/server/internal/pbx"
	"dialpark/server/internal/registry"
	"dialpark/server/internal/routing"
)

// The PBX's unsolicited NOTIFYs (SPEC §6 item 3c, CUCM lines bench
// 2026-10-17 09:12:20): CUCM sends every registered third-party line a
// message-summary NOTIFY on registration and on each mailbox change, with
// no subscription behind it and so no To tag. diago matched it against its
// dialogs (REFER progress is the only NOTIFY it knows), failed on the
// missing tag, and answered 400 Bad Request. The exchange expects 200 OK.

// fakeTx records the one response a handler sends.
type fakeTx struct{ res *sip.Response }

func (f *fakeTx) Terminate()                         {}
func (f *fakeTx) OnTerminate(sip.FnTxTerminate) bool { return false }
func (f *fakeTx) Done() <-chan struct{}              { return nil }
func (f *fakeTx) Err() error                         { return nil }
func (f *fakeTx) Respond(r *sip.Response) error      { f.res = r; return nil }
func (f *fakeTx) Acks() <-chan *sip.Request          { return nil }
func (f *fakeTx) OnCancel(sip.FnTxCancel) bool       { return false }

// cucmMWI is the shape CUCM 14 sends a third-party SIP line, taken from
// the 2026-10-17 bench (host, line and tags as logged; body per RFC 3842).
const cucmMWI = "NOTIFY sip:10910@10.7.141.25:5062 SIP/2.0\r\n" +
	"Via: SIP/2.0/UDP 10.7.160.11:5060;branch=z9hG4bK1a2b3c\r\n" +
	"From: <sip:10910@10.7.160.11>;tag=1361230528\r\n" +
	"To: <sip:10910@10.7.141.25>\r\n" +
	"Call-ID: 7c0e5c80-1f21e7f5-a4fff-ba0070a@10.7.160.11\r\n" +
	"CSeq: 101 NOTIFY\r\n" +
	"Max-Forwards: 70\r\n" +
	"Event: message-summary\r\n" +
	"Subscription-State: active\r\n" +
	"Content-Type: application/simple-message-summary\r\n" +
	"Content-Length: %d\r\n\r\n%s"

func notifyFrom(t *testing.T, raw, transport, source string) *sip.Request {
	t.Helper()
	msg, err := sip.ParseMessage([]byte(raw))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	req := msg.(*sip.Request)
	req.SetTransport(transport)
	req.SetSource(source)
	return req
}

func withBody(body string) string {
	return strings.Replace(strings.Replace(cucmMWI, "%d", strconv.Itoa(len(body)), 1), "%s", body, 1)
}

func newTrunkServer(t *testing.T, transport string) *Server {
	t.Helper()
	reg := registry.New(nil)
	s, err := New(Config{TLS: &tls.Config{}, ExternalHost: "10.7.141.25",
		Trunk:  &pbx.Trunk{Host: "10.7.160.11", Port: 5060, Transport: transport},
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}, reg, routing.New(reg, nil, nil), nil)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestPBXMessageWaitingNotifyIsAnswered200(t *testing.T) {
	s := newTrunkServer(t, "udp")
	body := "Messages-Waiting: yes\r\nMessage-Account: sip:10910@10.7.160.11\r\nVoice-Message: 2/0 (1/0)\r\n"
	req := notifyFrom(t, withBody(body), "UDP", "10.7.160.11:5060")
	tx := &fakeTx{}
	passed := false
	s.authMiddleware(func(*sip.Request, sip.ServerTransaction) { passed = true })(req, tx)
	if passed {
		t.Fatal("the NOTIFY reached diago, which answers it 400")
	}
	if tx.res == nil || tx.res.StatusCode != 200 {
		t.Fatalf("response = %v, want 200 OK", tx.res)
	}
}

// CUCM's first NOTIFY after a REGISTER can be the bare "no" with no
// Voice-Message line; it still wants its 200.
func TestPBXMessageWaitingNoIsAnswered200(t *testing.T) {
	s := newTrunkServer(t, "udp")
	req := notifyFrom(t, withBody("Messages-Waiting: no\r\n"), "UDP", "10.7.160.11:5060")
	tx := &fakeTx{}
	s.authMiddleware(func(*sip.Request, sip.ServerTransaction) { t.Fatal("reached diago") })(req, tx)
	if tx.res == nil || tx.res.StatusCode != 200 {
		t.Fatalf("response = %v, want 200 OK", tx.res)
	}
}

// Any other unsolicited NOTIFY has no subscription behind it: 481, as
// RFC 6665 requires, not diago's 400.
func TestPBXUnknownNotifyIsAnswered481(t *testing.T) {
	s := newTrunkServer(t, "udp")
	raw := strings.Replace(withBody(""), "Event: message-summary", "Event: check-sync", 1)
	req := notifyFrom(t, raw, "UDP", "10.7.160.11:5060")
	tx := &fakeTx{}
	s.authMiddleware(func(*sip.Request, sip.ServerTransaction) { t.Fatal("reached diago") })(req, tx)
	if tx.res == nil || tx.res.StatusCode != 481 {
		t.Fatalf("response = %v, want 481", tx.res)
	}
}

// A NOTIFY with a To tag is REFER progress inside a dialog — diago's, as
// before. This is the transfer path and must not be touched.
func TestInDialogNotifyStillReachesDiago(t *testing.T) {
	s := newTrunkServer(t, "udp")
	raw := strings.Replace(withBody(""), "To: <sip:10910@10.7.141.25>", "To: <sip:10910@10.7.141.25>;tag=abc", 1)
	req := notifyFrom(t, raw, "UDP", "10.7.160.11:5060")
	tx := &fakeTx{}
	passed := false
	s.authMiddleware(func(*sip.Request, sip.ServerTransaction) { passed = true })(req, tx)
	if !passed || tx.res != nil {
		t.Fatalf("in-dialog NOTIFY: passed=%v res=%v, want passed through unanswered", passed, tx.res)
	}
}

// On a TLS trunk only the PBX's own address is the PBX; a NOTIFY from
// anywhere else is whatever it was before (an app's would be refused by
// diago as it always has been).
func TestNotifyFromANonTrunkSourceIsNotAnsweredAsThePBX(t *testing.T) {
	s := newTrunkServer(t, "tls")
	req := notifyFrom(t, withBody("Messages-Waiting: no\r\n"), "TLS", "10.7.141.99:50123")
	tx := &fakeTx{}
	passed := false
	s.authMiddleware(func(*sip.Request, sip.ServerTransaction) { passed = true })(req, tx)
	if !passed || tx.res != nil {
		t.Fatalf("passed=%v res=%v, want passed through", passed, tx.res)
	}
	// And from the PBX itself over TLS it is ours.
	req = notifyFrom(t, withBody("Messages-Waiting: no\r\n"), "TLS", "10.7.160.11:5061")
	tx = &fakeTx{}
	s.authMiddleware(func(*sip.Request, sip.ServerTransaction) { t.Fatal("reached diago") })(req, tx)
	if tx.res == nil || tx.res.StatusCode != 200 {
		t.Fatalf("response = %v, want 200 OK", tx.res)
	}
}

func TestParseMessageSummary(t *testing.T) {
	cases := []struct {
		body    string
		waiting bool
		voice   string
	}{
		{"Messages-Waiting: yes\r\nMessage-Account: sip:10910@10.7.160.11\r\nVoice-Message: 2/0 (1/0)\r\n", true, "2/0 (1/0)"},
		{"Messages-Waiting: no\r\n", false, ""},
		{"messages-waiting: YES\nvoice-message: 1/3 (0/0)\n", true, "1/3 (0/0)"},
		{"", false, ""},
	}
	for _, c := range cases {
		w, v := parseMessageSummary([]byte(c.body))
		if w != c.waiting || v != c.voice {
			t.Errorf("%q → waiting=%v voice=%q, want %v %q", c.body, w, v, c.waiting, c.voice)
		}
	}
}

// The test diago uses to choose its answer path and the one the B2BUA
// uses to log and check a late offer must be the same test.
func TestDelayedOfferIsAnInviteWithNoBody(t *testing.T) {
	req := sip.NewRequest(sip.INVITE, sip.Uri{User: "10910", Host: "10.7.141.25"})
	if !delayedOffer(req) {
		t.Error("an INVITE with no body is a delayed offer")
	}
	req.SetBody([]byte("v=0\r\n"))
	if delayedOffer(req) {
		t.Error("an INVITE with a body is an early offer")
	}
}
