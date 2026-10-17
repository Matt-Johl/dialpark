package pbxline

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/emiago/sipgo/sip"
	"github.com/icholy/digest"
)

// The challenge sequences a live CUCM sends a registering line (SPEC §6
// item 3c, "its realm and challenge shape"), pinned from the 2026-10-17
// bench: realm "ccmsipline", MD5, no qop — and one nonce handed to every
// line that registers in the same instant, so the second line to answer it
// is re-challenged with a new nonce and no stale flag. That used to latch
// the line "credential refused" with a correct password.

const cucmRealm = "ccmsipline"

func cucm401(nonce string) *sip.Response {
	res := sip.NewResponse(401, "Unauthorized")
	res.AppendHeader(sip.NewHeader("WWW-Authenticate",
		`Digest realm="`+cucmRealm+`", nonce="`+nonce+`", algorithm=MD5`))
	return res
}

func cucm200() *sip.Response {
	res := sip.NewResponse(200, "OK")
	res.AppendHeader(sip.NewHeader("Expires", "120"))
	return res
}

// fakeExchange answers each send with the next scripted response and keeps
// the Authorization header of every request it saw.
type fakeExchange struct {
	script []*sip.Response
	auths  []string
}

func (f *fakeExchange) send(_ context.Context, req *sip.Request) (*sip.Response, error) {
	if h := req.GetHeader("Authorization"); h != nil {
		f.auths = append(f.auths, h.Value())
	} else {
		f.auths = append(f.auths, "")
	}
	if len(f.script) == 0 {
		return nil, errors.New("exchange: no more scripted responses")
	}
	res := f.script[0]
	f.script = f.script[1:]
	return res, nil
}

func newScriptedRegistrar(t *testing.T, script ...*sip.Response) (*SIPRegistrar, *fakeExchange) {
	t.Helper()
	ex := &fakeExchange{script: script}
	r := &SIPRegistrar{
		cfg: SIPConfig{
			Registrar: sip.Uri{Scheme: "sip", Host: "10.7.160.11", Port: 5060, UriParams: sip.NewParams()},
			Domain:    "10.7.160.11",
			Contact:   sip.Uri{Scheme: "sip", Host: "10.7.141.25", Port: 5062, UriParams: sip.NewParams()},
		},
		reqs: map[string]*sip.Request{},
	}
	r.sendFn = ex.send
	return r, ex
}

var line10910 = Line{User: "10910", DN: "10910", DigestUser: "10910", Secret: "s3cret"}

func nonceOf(t *testing.T, auth string) string {
	t.Helper()
	cred, err := digest.ParseCredentials(auth)
	if err != nil {
		t.Fatalf("parse %q: %v", auth, err)
	}
	return cred.Nonce
}

// Shared nonce consumed by a sibling line: the new nonce is a new question.
func TestAFreshNonceAfterOurAnswerIsAnsweredNotRefused(t *testing.T) {
	r, ex := newScriptedRegistrar(t, cucm401("shared"), cucm401("fresh"), cucm200())
	reg, err := r.Register(context.Background(), line10910, time.Hour)
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	if reg.Realm != cucmRealm || reg.Expiry != 120*time.Second {
		t.Errorf("registration = %+v, want realm %s expiry 120s", reg, cucmRealm)
	}
	if len(ex.auths) != 3 || ex.auths[0] != "" {
		t.Fatalf("sends = %d (%q), want an unauthenticated REGISTER then two answers", len(ex.auths), ex.auths)
	}
	if got := nonceOf(t, ex.auths[1]); got != "shared" {
		t.Errorf("first answer used nonce %q, want shared", got)
	}
	if got := nonceOf(t, ex.auths[2]); got != "fresh" {
		t.Errorf("second answer used nonce %q, want fresh", got)
	}
}

// stale=true is the standard's own way of saying the same thing.
func TestAStaleChallengeIsAnswered(t *testing.T) {
	stale := sip.NewResponse(401, "Unauthorized")
	stale.AppendHeader(sip.NewHeader("WWW-Authenticate",
		`Digest realm="`+cucmRealm+`", nonce="shared", algorithm=MD5, stale=true`))
	r, ex := newScriptedRegistrar(t, cucm401("shared"), stale, cucm200())
	if _, err := r.Register(context.Background(), line10910, time.Hour); err != nil {
		t.Fatalf("register: %v", err)
	}
	if len(ex.auths) != 3 {
		t.Fatalf("sends = %d, want 3", len(ex.auths))
	}
}

// The same nonce back again is a wrong password, and is not retried.
func TestTheSameNonceAgainIsACredentialRefusal(t *testing.T) {
	r, ex := newScriptedRegistrar(t, cucm401("n1"), cucm401("n1"), cucm200())
	_, err := r.Register(context.Background(), line10910, time.Hour)
	var refused *Refused
	if !errors.As(err, &refused) || refused.Reason != "credential refused" {
		t.Fatalf("err = %v, want Refused credential refused", err)
	}
	if len(ex.auths) != 2 {
		t.Fatalf("sends = %d, want exactly one answer and no retry", len(ex.auths))
	}
}

// An exchange that rotates its nonce on every refusal is still a refusal,
// after a bounded number of answers rather than for ever.
func TestEndlessFreshNoncesAreBounded(t *testing.T) {
	r, ex := newScriptedRegistrar(t, cucm401("a"), cucm401("b"), cucm401("c"), cucm401("d"), cucm401("e"), cucm200())
	_, err := r.Register(context.Background(), line10910, time.Hour)
	var refused *Refused
	if !errors.As(err, &refused) || !strings.Contains(refused.Reason, "credential refused") {
		t.Fatalf("err = %v, want Refused", err)
	}
	if len(ex.auths) != 1+maxChallengeAnswers {
		t.Fatalf("sends = %d, want 1 + %d", len(ex.auths), maxChallengeAnswers)
	}
}

// The ordinary case is unchanged: one challenge, one answer, registered.
func TestOneChallengeOneAnswer(t *testing.T) {
	r, ex := newScriptedRegistrar(t, cucm401("only"), cucm200())
	if _, err := r.Register(context.Background(), line10910, time.Hour); err != nil {
		t.Fatalf("register: %v", err)
	}
	if len(ex.auths) != 2 {
		t.Fatalf("sends = %d, want 2", len(ex.auths))
	}
}
