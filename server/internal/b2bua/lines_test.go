package b2bua

import (
	"errors"
	"github.com/emiago/sipgo"
	"testing"

	"github.com/emiago/sipgo/sip"

	"dialpark/server/internal/pbx"
)

// fakeLines is a line registry with no SIP behind it.
type fakeLines map[string][2]string // user → {dn, secret}

func (f fakeLines) Number(user string) (string, bool) {
	l, ok := f[user]
	if !ok {
		return "", false
	}
	return l[0], true
}

func (f fakeLines) Credentials(user string) (string, string, bool) {
	l, ok := f[user]
	if !ok {
		return "", "", false
	}
	return "du-" + user, l[1], true
}

func linesServer(t *testing.T, lines Lines, defaultLine string) *Server {
	t.Helper()
	return &Server{cfg: Config{
		ExternalHost: "dialpark.example",
		Trunk:        &pbx.Trunk{Host: "cucm.example", Port: 5060, Transport: "tcp"},
		Lines:        lines,
		DefaultLine:  defaultLine,
	}}
}

// The guard for every trunk deployment: with no line registry, a callee
// leg's INVITE carries exactly what it always has — the wake's call-id
// header and nothing else, and no credentials — so diago builds the request
// unchanged (with an Originator, that means the caller's own From).
//
// If this test has to be updated, a working PBX trunk has just changed
// behaviour, and the harness trunk suite is the thing to run.
func TestTrunkModeSendsTheSameInviteItAlwaysHas(t *testing.T) {
	s := linesServer(t, nil, "")
	for _, calleeTrunk := range []bool{true, false} {
		headers, digestUser, secret, ok := s.calleeInvite("call-1", calleeTrunk, "201")
		if !ok {
			t.Fatalf("trunk mode must never refuse a call for want of a line (calleeTrunk=%v)", calleeTrunk)
		}
		if len(headers) != 1 {
			t.Fatalf("headers = %d, want exactly the call-id header: %v", len(headers), headers)
		}
		if headers[0].Name() != CallIDHeader || headers[0].Value() != "call-1" {
			t.Errorf("header = %s: %s", headers[0].Name(), headers[0].Value())
		}
		if digestUser != "" || secret != "" {
			t.Errorf("trunk mode must send no credentials, got %q/%q", digestUser, secret)
		}
	}
	if s.linesMode() {
		t.Error("a server with no registry is not in lines mode")
	}
}

func TestLinesModeSendsTheCallingLine(t *testing.T) {
	s := linesServer(t, fakeLines{"201": {"7001", "s1"}, "202": {"202", "s2"}}, "")

	headers, digestUser, secret, ok := s.calleeInvite("call-1", true, "201")
	if !ok {
		t.Fatal("a caller with a line should be identified")
	}
	if len(headers) != 2 {
		t.Fatalf("headers = %v, want the call-id header and a From", headers)
	}
	from, isFrom := headers[1].(*sip.FromHeader)
	if !isFrom {
		t.Fatalf("second header is %T, want a From", headers[1])
	}
	// The exchange matches the call to the line by this user part; its own
	// extension here (201) would be rejected or mis-attributed.
	if from.Address.User != "7001" {
		t.Errorf("From user = %q, want the line's DN 7001", from.Address.User)
	}
	if from.Address.Host != "cucm.example" {
		t.Errorf("From host = %q, want the PBX domain", from.Address.Host)
	}
	// diago adds the tag to a From it did not build; a second one here
	// would be the only tag in the dialog that is not its.
	if from.Params.Has("tag") {
		t.Error("the From should carry no tag of ours")
	}
	if digestUser != "du-201" || secret != "s1" {
		t.Errorf("credentials = %q/%q, want the calling line's", digestUser, secret)
	}

	// A local callee is not the PBX: no identity, no credential.
	headers, digestUser, _, ok = s.calleeInvite("call-2", false, "201")
	if !ok || len(headers) != 1 || digestUser != "" {
		t.Errorf("a local leg should be untouched: %v %q", headers, digestUser)
	}
}

func TestLinesModeRefusesACallItCannotIdentify(t *testing.T) {
	s := linesServer(t, fakeLines{"201": {"7001", "s1"}}, "")
	if _, _, _, ok := s.calleeInvite("call-1", true, "299"); ok {
		t.Fatal("a caller with no line must be refused, not sent under someone else's number")
	}

	// Unless a default is configured: a transfer target dialled on behalf
	// of a party that is itself on the PBX has no line of its own.
	s = linesServer(t, fakeLines{"201": {"7001", "s1"}}, "201")
	_, digestUser, secret, ok := s.calleeInvite("call-1", true, "299")
	if !ok || digestUser != "du-201" || secret != "s1" {
		t.Fatalf("the default line should stand in: %v %q/%q", ok, digestUser, secret)
	}

	// A default naming a line that does not exist is still a refusal, not
	// a call sent with no identity at all.
	s = linesServer(t, fakeLines{"201": {"7001", "s1"}}, "nobody")
	if _, _, _, ok := s.calleeInvite("call-1", true, "299"); ok {
		t.Fatal("a default line that does not exist must not let the call through")
	}
}

func TestPBXDomainFallsBackToTheTrunkPeer(t *testing.T) {
	s := linesServer(t, fakeLines{"201": {"7001", "s"}}, "")
	if got := s.pbxDomain(); got != "cucm.example" {
		t.Errorf("pbxDomain = %q, want the trunk peer's host", got)
	}
	s.cfg.PBXDomain = "cluster.example.com"
	if got := s.pbxDomain(); got != "cluster.example.com" {
		t.Errorf("pbxDomain = %q, want the configured domain", got)
	}
	// No trunk at all (standalone): the server's own host, so nothing
	// produces an empty domain.
	s = &Server{cfg: Config{ExternalHost: "dialpark.example"}}
	if got := s.pbxDomain(); got != "dialpark.example" {
		t.Errorf("pbxDomain with no trunk = %q", got)
	}
}

func TestUriUser(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"sip:201@dialpark.example", "201"},
		{"sip:201@dialpark.example;transport=tls", "201"},
		{`"Matt" <sip:201@dialpark.example>`, "201"},
		{"", ""},
	} {
		if got := uriUser(tc.in); got != tc.want {
			t.Errorf("uriUser(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// CUCM's way of saying the calling line is not registered: 503 with Warning
// 399 "Unable to find a device handler …" (bench 2026-10-22 09:33). Any
// other failure is the call's own business.
func TestExchangeSaysUnregistered(t *testing.T) {
	res := func(code int, warning string) error {
		r := sip.NewResponse(code, "x")
		if warning != "" {
			r.AppendHeader(sip.NewHeader("Warning", warning))
		}
		return sipgo.ErrDialogResponse{Res: r}
	}
	if !exchangeSaysUnregistered(res(503, `399 13756-cucm001 "Unable to find a device handler for the request received on port 5062 from 10.7.141.25"`)) {
		t.Error("CUCM's device-handler 503 must read as unregistered")
	}
	if exchangeSaysUnregistered(res(503, "")) {
		t.Error("a bare 503 is not a verdict on the line")
	}
	if exchangeSaysUnregistered(res(486, "")) || exchangeSaysUnregistered(errors.New("timeout")) {
		t.Error("busy and a timeout are not verdicts on the line")
	}
}
