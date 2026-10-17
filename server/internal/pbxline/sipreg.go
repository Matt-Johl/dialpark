package pbxline

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/emiago/sipgo"
	"github.com/emiago/sipgo/sip"
	"github.com/icholy/digest"
)

// SIPRegistrar is the Registrar seam over a real SIP stack: it sends the
// REGISTER, answers the PBX's digest challenge and reads back the lifetime
// it granted.
//
// The REGISTER client is ours rather than diago's RegisterTransaction, which
// cannot set a per-line From/To/Contact user, mutates its origin request on
// unregister, and abandons the loop on a 401. Writing it here also keeps the
// part that actually varies between exchanges — the shape of the challenge —
// in a pure function this package can test against CUCM-shaped headers with
// no socket in sight (SPEC §6 item 3c).
type SIPRegistrar struct {
	cfg SIPConfig

	mu sync.Mutex
	// One request per line, kept between refreshes: RFC 3261 §10.2 wants a
	// re-registration to carry the same Call-ID with a higher CSeq, which
	// is how the PBX tells a refresh from a new binding.
	reqs map[string]*sip.Request
	// sendFn is the wire: r.send, or a fake in the tests that pin the
	// challenge sequences an exchange sends (sipreg_challenge_test.go).
	sendFn func(context.Context, *sip.Request) (*sip.Response, error)
}

// SIPConfig describes where the REGISTERs go and what they advertise.
type SIPConfig struct {
	// Client sends on the trunk-leg transport, so the source address the
	// PBX sees is the one it will send calls back to.
	Client *sipgo.Client
	// Registrar is the PBX: host, port and transport parameter.
	Registrar sip.Uri
	// Domain is the host part of the line's own address of record (To and
	// From). Usually the PBX's SIP domain; defaults to Registrar.Host.
	Domain string
	// Contact is where the PBX should send this server's calls — the
	// trunk-leg listener's externally reachable address.
	Contact sip.Uri
	// UserAgent, when set, is sent as the User-Agent header.
	UserAgent string
}

// NewSIPRegistrar builds the registrar. Client and Registrar are required.
func NewSIPRegistrar(cfg SIPConfig) (*SIPRegistrar, error) {
	if cfg.Client == nil {
		return nil, fmt.Errorf("pbxline: no SIP client for the PBX leg")
	}
	if cfg.Registrar.Host == "" {
		return nil, fmt.Errorf("pbxline: no registrar address")
	}
	if cfg.Domain == "" {
		cfg.Domain = cfg.Registrar.Host
	}
	r := &SIPRegistrar{cfg: cfg, reqs: map[string]*sip.Request{}}
	r.sendFn = r.send
	return r, nil
}

// maxChallengeAnswers bounds how many fresh challenges one registration
// answers before it is called refused (see register).
const maxChallengeAnswers = 3

// Register sends one REGISTER for the line, answering a digest challenge if
// the PBX makes one, and reports the lifetime it granted.
func (r *SIPRegistrar) Register(ctx context.Context, l Line, expiry time.Duration) (Registration, error) {
	return r.register(ctx, l, expiry)
}

// Unregister drops the line's binding (Expires: 0).
func (r *SIPRegistrar) Unregister(ctx context.Context, l Line) error {
	_, err := r.register(ctx, l, 0)
	r.mu.Lock()
	delete(r.reqs, l.User)
	r.mu.Unlock()
	return err
}

func (r *SIPRegistrar) register(ctx context.Context, l Line, expiry time.Duration) (Registration, error) {
	req := r.request(l)
	clearAuth(req)
	setExpires(req, expiry)

	res, err := r.sendFn(ctx, req)
	if err != nil {
		return Registration{}, err
	}

	// 423: the binding we asked for is shorter than the PBX will keep. It
	// tells us its minimum; take it and say so once, rather than retrying
	// the same too-brief request for ever.
	if res.StatusCode == sip.StatusIntervalToBrief {
		min, ok := minExpires(res)
		if !ok {
			return Registration{}, &Refused{Status: res.StatusCode, Reason: "423 without a usable Min-Expires"}
		}
		setExpires(req, min)
		if res, err = r.sendFn(ctx, req); err != nil {
			return Registration{}, err
		}
	}

	// Answer the challenge — and, within a bound, a fresh one after it.
	//
	// A second challenge after we have answered is how a wrong password
	// looks, and that is the one failure that must not be retried: devices
	// retrying a bad password is how an exchange ends up locking an
	// account out. But it is also how CUCM looks when several lines
	// register at once: it hands concurrent REGISTERs the SAME nonce, and
	// once one line's answer has consumed it the others are re-challenged
	// with a new nonce, no stale=true, same 401 (bench 2026-10-17 11:54,
	// four lines in 300 ms, line 10910 latched "credential refused" with
	// a correct password). The two are told apart by the nonce: a new one
	// is a new question and is answered; the same one back again is the
	// exchange saying our answer was wrong. maxChallengeAnswers keeps an
	// exchange that rotates its nonce on every refusal from being asked
	// for ever.
	var realm, answered string
	for n := 0; isChallenge(res); n++ {
		chal, hdr, err := challenge(res)
		if err != nil {
			// An unparseable or unsupported challenge (MD5-sess, a
			// digest algorithm we have no hash for) is a provisioning
			// fault, not a blip: retrying sends the identical request.
			return Registration{}, &Refused{Status: res.StatusCode, Reason: err.Error()}
		}
		if n > 0 && !chal.Stale && chal.Nonce == answered {
			return Registration{}, &Refused{Status: res.StatusCode, Reason: "credential refused"}
		}
		if n >= maxChallengeAnswers {
			return Registration{}, &Refused{Status: res.StatusCode,
				Reason: fmt.Sprintf("credential refused (%d challenges, each with a new nonce)", n+1)}
		}
		realm = chal.Realm
		auth, err := authorization(chal, sip.REGISTER.String(), req.Recipient.String(), l.DigestUser, l.Secret)
		if err != nil {
			return Registration{}, &Refused{Status: res.StatusCode, Reason: err.Error()}
		}
		req.RemoveHeader(hdr)
		req.AppendHeader(sip.NewHeader(hdr, auth))
		answered = chal.Nonce

		if res, err = r.sendFn(ctx, req); err != nil {
			return Registration{}, err
		}
	}

	if res.StatusCode != sip.StatusOK {
		return Registration{}, responseError(res)
	}
	return Registration{Expiry: grantedExpiry(res, expiry), Realm: realm}, nil
}

// send transmits the request and waits for its final response. The Via is
// dropped first: sipgo only adds one when none is present, and a refresh
// reusing the previous hop's Via would be answered to the wrong place.
func (r *SIPRegistrar) send(ctx context.Context, req *sip.Request) (*sip.Response, error) {
	req.RemoveHeader("Via")
	res, err := r.cfg.Client.Do(ctx, req, sipgo.ClientRequestRegisterBuild)
	if err != nil {
		return nil, fmt.Errorf("register %s: %w", req.Recipient.String(), err)
	}
	return res, nil
}

// request returns the line's REGISTER, building it on first use.
func (r *SIPRegistrar) request(l Line) *sip.Request {
	r.mu.Lock()
	defer r.mu.Unlock()
	if req, ok := r.reqs[l.User]; ok {
		return req
	}

	// Request-URI is the registrar itself (no user part); To and From are
	// the line's own address of record, which for a third-party SIP device
	// is what the exchange matches the registration to.
	aor := sip.Uri{Scheme: "sip", User: l.DN, Host: r.cfg.Domain, UriParams: sip.NewParams()}
	req := sip.NewRequest(sip.REGISTER, r.cfg.Registrar)
	if t, ok := r.cfg.Registrar.UriParams.Get("transport"); ok && t != "" {
		req.SetTransport(sip.NetworkToUpper(t))
	}

	from := &sip.FromHeader{Address: aor, Params: sip.NewParams()}
	from.Params.Add("tag", sip.GenerateTagN(16))
	to := &sip.ToHeader{Address: aor, Params: sip.NewParams()}

	contact := r.cfg.Contact
	contact.User = l.DN
	req.AppendHeader(from)
	req.AppendHeader(to)
	req.AppendHeader(&sip.ContactHeader{Address: contact, Params: sip.NewParams()})
	if r.cfg.UserAgent != "" {
		req.AppendHeader(sip.NewHeader("User-Agent", r.cfg.UserAgent))
	}

	r.reqs[l.User] = req
	return req
}

// ---- response reading -------------------------------------------------------

// clearAuth drops the credential left on the request by the previous
// registration, so every one starts from a fresh challenge.
//
// Replaying the old header is wrong twice over. The exchange may accept an
// Authorization computed with a password that has since been changed — for
// as long as it still honours that nonce — so a corrected or revoked
// credential goes on working and nobody finds out until the refresh after
// that. And repeating one nonce, nonce-count and cnonce is a replay, which a
// stricter exchange rejects outright.
//
// Found on the Asterisk bench, and not by reasoning: a line whose password
// had just been replaced with a wrong one carried on registering happily,
// while the INVITEs it sent — which are challenged separately — were
// refused (2026-09-22). The cost of the fix is one extra round trip per
// refresh, which for a line is once an hour.
func clearAuth(req *sip.Request) {
	req.RemoveHeader("Authorization")
	req.RemoveHeader("Proxy-Authorization")
}

func setExpires(req *sip.Request, d time.Duration) {
	req.RemoveHeader("Expires")
	req.AppendHeader(sip.NewHeader("Expires", strconv.Itoa(int(d.Seconds()))))
}

func isChallenge(res *sip.Response) bool {
	return res.StatusCode == sip.StatusUnauthorized || res.StatusCode == sip.StatusProxyAuthRequired
}

// challenge parses a 401/407 and names the header the answer belongs in.
func challenge(res *sip.Response) (*digest.Challenge, string, error) {
	name, answer := "WWW-Authenticate", "Authorization"
	if res.StatusCode == sip.StatusProxyAuthRequired {
		name, answer = "Proxy-Authenticate", "Proxy-Authorization"
	}
	h := res.GetHeader(name)
	if h == nil {
		return nil, "", fmt.Errorf("%d without a %s header", res.StatusCode, name)
	}
	chal, err := digest.ParseChallenge(h.Value())
	if err != nil {
		return nil, "", fmt.Errorf("unparseable %s: %w", name, err)
	}
	if !digest.CanDigest(chal) {
		return nil, "", fmt.Errorf("unsupported challenge: algorithm %q qop %q",
			chal.Algorithm, strings.Join(chal.QOP, ","))
	}
	return chal, answer, nil
}

// authorization computes the credential header value for a challenge. Pure,
// so the challenge shapes an exchange might send can be tested directly.
func authorization(chal *digest.Challenge, method, uri, username, password string) (string, error) {
	cred, err := digest.Digest(chal, digest.Options{
		Method:   method,
		URI:      uri,
		Username: username,
		Password: password,
		Count:    1,
	})
	if err != nil {
		return "", err
	}
	return cred.String(), nil
}

// grantedExpiry reads the lifetime the PBX gave us: the Expires header, or
// the expires parameter on the Contact it echoed, or what we asked for.
func grantedExpiry(res *sip.Response, asked time.Duration) time.Duration {
	if h := res.GetHeader("Expires"); h != nil {
		if n, err := strconv.Atoi(strings.TrimSpace(h.Value())); err == nil && n > 0 {
			return time.Duration(n) * time.Second
		}
	}
	if c := res.Contact(); c != nil {
		if v, ok := c.Params.Get("expires"); ok {
			if n, err := strconv.Atoi(v); err == nil && n > 0 {
				return time.Duration(n) * time.Second
			}
		}
	}
	return asked
}

func minExpires(res *sip.Response) (time.Duration, bool) {
	h := res.GetHeader("Min-Expires")
	if h == nil {
		return 0, false
	}
	n, err := strconv.Atoi(strings.TrimSpace(h.Value()))
	if err != nil || n <= 0 {
		return 0, false
	}
	return time.Duration(n) * time.Second, true
}

// responseError classifies a non-200. Anything that says "this request is
// wrong" is refused — retrying sends the identical request — while a timeout
// or a server-side failure is transient and worth another go.
func responseError(res *sip.Response) error {
	switch code := res.StatusCode; {
	case code == sip.StatusRequestTimeout,
		code == sip.StatusTemporarilyUnavailable,
		code == sip.StatusServiceUnavailable,
		code >= 500:
		return fmt.Errorf("pbx answered %d %s", code, res.Reason)
	default:
		return &Refused{Status: code, Reason: res.Reason}
	}
}
