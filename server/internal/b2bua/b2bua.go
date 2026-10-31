// Package b2bua is the light server's call controller and app-leg SIP
// element, built on sipgo + diago (Phase 0 engine decision, SPEC §6).
//
// Responsibilities:
//   - terminate the app leg over TLS (SPEC §4.4 rules 1-2);
//   - registrar for provisioned users, feeding the registry (diago handles
//     INVITE dialogs but not REGISTER, so this is ours);
//   - route inbound INVITEs: local + registered → bridge; local + not
//     registered → wake the device via the gateway, wait for it to register,
//     then bridge; unknown → 404; trunk → 503 until the PBX leg (Phase 2);
//   - bridge the two legs with media proxied through the server (rule 3).
package b2bua

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/rand"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/emiago/diago"
	"github.com/emiago/diago/media"
	"github.com/emiago/diago/media/sdp"
	"github.com/emiago/sipgo"
	"github.com/emiago/sipgo/sip"
	"github.com/pion/rtp"

	"dialpark/server/internal/pbx"
	"dialpark/server/internal/pbxline"
	"dialpark/server/internal/qos"
	"dialpark/server/internal/registry"
	"dialpark/server/internal/routing"
	"dialpark/server/internal/sipauth"
	"dialpark/server/internal/wire"
)

// CallIDHeader carries the wake call_id on the callee-leg INVITE so the app
// can match the SIP call to the CallKit entry (PROTOCOL.md §6).
const CallIDHeader = "X-Dialler-Call-ID"

// Waker is the gateway's wake surface (satisfied by *gateway.Gateway).
type Waker interface {
	Wake(deviceID string, w wire.Wake) int
	CancelWake(deviceID, callID string, reason wire.CancelReason)
	// ForgetWake drops a pending wake silently once its call is over.
	ForgetWake(deviceID, callID string)
}

// Config configures the B2BUA.
type Config struct {
	// OnTrunkState, if set, is told each time the trunk qualifier finds
	// the trunk up or down (for the event ring). OnCall is told when a
	// call is bridged and when it ends, with the parties' URIs and, on
	// the end, why: bye, peer_gone or failed.
	OnTrunkState func(up bool, err error)
	OnCall       func(callID string, started bool, a, b, reason string)

	BindHost     string      // default 0.0.0.0
	Port         int         // default 5061
	ExternalHost string      // advertised in Contact/SDP and in wakes; required
	TLS          *tls.Config // required: the app leg is TLS-only
	Domains      []string    // SIP domains we serve; REGISTER for others → 403
	// RTP port range for the media relay (both legs). A fixed range lets a
	// deployment publish/firewall exactly these UDP ports. 0 → ephemeral.
	RTPPortStart int
	RTPPortEnd   int
	// TrunkCodecs is what a PBX trunk is offered, in order of preference
	// (default DefaultTrunkCodecs: G.722, PCMU, PCMA). A PBX that must stay
	// narrowband gets "pcmu,pcma" via -trunk-codecs.
	TrunkCodecs []media.Codec
	// KeepAdvertisedContact disables the route rewrite below (registrations
	// are reached by dialling their advertised Contact). Only for proving
	// in the harness that the rewrite is what makes NAT'd phones reachable.
	KeepAdvertisedContact bool
	// NoSymmetricRTP stops the relay from re-targeting the app leg's media
	// at the source address of the first RTP packet it receives from the
	// phone (symmetric RTP / "comedia"). Needed on NAT'd phones (Phase 4b)
	// and harmless on a LAN, so the default (false) learns. Set it where
	// the phone's observed source is NOT a deliverable reply address —
	// Docker Desktop's UDP port proxy in the harness — or the phone goes
	// silent after its first packet.
	NoSymmetricRTP bool
	// PublicPort is the SIP port apps are told to reach us on (wakes) when
	// it differs from Port (container published on another host port).
	// 0 = Port.
	PublicPort int
	// TrunkSRTP is SDES on the PBX leg (SPEC §6 near-term item 3a):
	//
	//	off   plain RTP, and an encrypted offer from the PBX is answered
	//	      in the clear. The default: a PBX that does not do SDES
	//	      refuses an RTP/SAVP offer with 488, so this cannot be on
	//	      until the PBX is known to accept it.
	//	sdes  offer RTP/SAVP with a=crypto (RFC 4568), mirror what the PBX
	//	      offers us, and refuse a leg that did not actually end up
	//	      encrypted.
	//
	// There is deliberately no "best effort" mode. RFC 4568 puts crypto on
	// a secure m-line, and RFC 3264 §6 makes an answer keep the offer's
	// profile, so "offered SAVP, answered in the clear" is malformed rather
	// than a downgrade: a PBX that cannot do SDES sends 488 instead. A mode
	// that bridged such an answer anyway would encrypt to a far end unable
	// to decrypt — garbled audio in place of a clean failure. The industry
	// work-arounds for genuine best-effort are all non-standard and are
	// listed under §6 "Much later".
	//
	// Each leg keys its own media session; the relay copies encoded payload
	// between them, so the app leg stays encrypted whatever the trunk does.
	TrunkSRTP TrunkSRTPMode

	// TrunkTLS is the TLS configuration for the PBX leg when the trunk's
	// transport is "tls" (SPEC §6 near-term item 3b). Nil elsewhere.
	//
	// Separate from TLS above on purpose: that one is the app leg, which we
	// own both ends of and can pin to TLS 1.3, while a PBX we do not own
	// cannot be. It also carries the trust for verifying the PBX, which the
	// app leg has no use for — apps dial us, so we are never the client
	// there. See tlsutil.PeerConfig.
	TrunkTLS *tls.Config

	// Trunk is the PBX peer for non-local destinations (SPEC §4.4 rule 7);
	// nil = standalone (app↔app only). Trunk-originated calls arrive on a
	// second listener, TrunkBind ("0.0.0.0:5060"), over Trunk.Transport.
	Trunk     *pbx.Trunk
	TrunkBind string
	// TrunkExternalHost is the address the PBX reaches us at (trunk-leg
	// signalling Contact and media). Empty = this host's first address.
	TrunkExternalHost string
	RingTimeout       time.Duration
	// TrunkQualify is how often the trunk's pooled TCP/TLS connection is
	// probed with OPTIONS so one that has gone silently dead is dropped
	// before a call needs it (qualify.go). 0 = off. Ignored over UDP.
	TrunkQualify time.Duration
	// PeerTimeout ends a bridged call once a party has stopped answering
	// the in-dialog OPTIONS each leg is asked on an interval
	// (bridgedCall.qualifyLegs). A B2BUA cannot rely on a BYE to end a
	// call: a phone that crashes or goes out of range sends none, and its
	// dialog then has nothing to cancel it, so the call and its relay
	// outlive everyone on it. 0 = off.
	PeerTimeout time.Duration
	MinExpires  int
	MaxExpires  int
	Logger      *slog.Logger
	// Auth challenges every app-leg REGISTER and initial INVITE with SIP
	// Digest against the device enrolment store and refuses a SIP user
	// other than the device's enrolled one (SPEC §4.4 rule 2). nil = no
	// authentication (unit tests only).
	Auth *sipauth.Authenticator

	// Lines puts the server in "lines" mode: instead of presenting one
	// trunk identity to the PBX, each call to it carries the calling
	// device's own registered line (SPEC §6 item 3c). Nil — the default,
	// and every trunk-mode deployment — leaves the PBX leg exactly as it
	// was, which is what keeps this feature off the existing call path.
	// Set through SetLines, since the registrar needs the SIP stack this
	// server builds.
	Lines Lines
	// DefaultLine is the user whose line identifies a call to the PBX that
	// has no line of its own — a transfer target dialled on behalf of a
	// party that is itself on the PBX. Empty means such a call is refused
	// rather than sent under someone else's number.
	DefaultLine string
	// PBXDomain is the host part of the address of record in lines mode
	// (From towards the PBX). Empty = the trunk peer's host.
	PBXDomain string
	// LabPumpDelay (lab/audio-continuity only) holds the relay back for
	// this long after the caller's ACK before the pumps start, so the
	// callee's RTP queues in the socket and drains as a burst — the
	// start-of-call backlog a slow ACK produces in production (227–276 ms
	// on app→CUCM calls), reproduced on demand. Zero in every real build.
	LabPumpDelay time.Duration
	// LinePorts gives each line its own PBX-leg socket (lines mode only;
	// see PortRange). The trunk listener binds the range's first port and
	// every other port gets a listener of its own; a line then registers
	// from, is called on, and calls out of the one it holds. Zero = one
	// shared socket, as before.
	LinePorts pbxline.PortRange
	// TrunkPeers are further source hosts to trust as the PBX over TLS,
	// beyond the one in Trunk. A CUCM cluster sends calls from whichever
	// node handles them, not only the node we registered to, and a call
	// from an untrusted source is challenged like an app's and fails.
	TrunkPeers []string
	// RTPTraceDir, when set, makes every relay pump write one TSV line per
	// packet it reads into <dir>/<call id>-<from>-<to>.tsv (pump.run): a
	// lab aid for the audio-continuity investigation (2026-10-31), off by
	// default and never on the hot path when empty.
	RTPTraceDir string
}

// Lines is the registered-line registry the PBX leg consults in lines mode.
// Satisfied by *pbxline.Manager; nil in trunk mode.
type Lines interface {
	// Credentials answers a PBX challenge for a call placed on this
	// user's behalf.
	Credentials(user string) (digestUser, secret string, ok bool)
	// Number is the directory number a call from this user must present
	// as its calling party.
	Number(user string) (string, bool)
}

func (c Config) withDefaults() Config {
	if c.BindHost == "" {
		c.BindHost = "0.0.0.0"
	}
	if c.Port == 0 {
		c.Port = 5061
	}
	if c.RingTimeout <= 0 {
		c.RingTimeout = 30 * time.Second
	}
	if c.PeerTimeout == 0 {
		// Four asks across it (qualifyLegs), so a party has a minute of
		// missed OPTIONS before its call ends — long enough that a network
		// blip or a phone briefly off the CPU cannot end a conversation,
		// short enough that nothing is left relaying to nobody.
		c.PeerTimeout = 60 * time.Second
	}
	if c.MinExpires == 0 {
		c.MinExpires = 60
	}
	if c.MaxExpires == 0 {
		c.MaxExpires = 3600
	}
	if c.Logger == nil {
		c.Logger = slog.Default()
	}
	return c
}

// Server is the app-leg SIP element.
type Server struct {
	cfg    Config
	reg    *registry.Registry
	router *routing.Router
	waker  Waker
	log    *slog.Logger
	dg     *diago.Diago
	tl     *sip.TransportLayer

	// Calls waiting for a woken app to register, by call id, so a decline or
	// busy wake_ack can end the wait at once instead of at the ring timeout.
	waitMu  sync.Mutex
	waiting map[string]context.CancelCauseFunc

	// Read-only views for the admin API (status.go).
	live  liveCalls
	trunk trunkState
}

// Why a woken callee's wait ended early: the device answered the wake with
// a refusal. The caller is told 486 (decline) or rung through to the ring
// timeout (busy/Focus); see wakeAndWaitFrom and bridge.
var (
	errWakeDeclined = errors.New("callee declined")
	errWakeBusy     = errors.New("callee busy")
	// The pooled TCP/TLS connection to the trunk delivered nothing back for
	// the INVITE — not even 100 Trying — within trunkResponseTimeout: it is
	// defunct. bridge drops the INVITE and the connection; serveDialog
	// redials once on a fresh one.
	errTrunkUnresponsive = errors.New("trunk connection unresponsive")
)

// trunkResponseTimeout is how long an INVITE to the trunk over TCP/TLS may
// go with no response at all before its connection is judged dead. A live
// PBX answers with 100 Trying within milliseconds (RFC 3261 §8.2.6 asks for
// it within 200 ms); a LAN or campus link adds a few. Three seconds is well
// clear of that and a tenth of Timer B.
const trunkResponseTimeout = 3 * time.Second

// Note: the app callee's TLS connection dying while its INVITE is out (iOS
// suspends the app after a Focus/DND filter, and the socket goes with it)
// is deliberately NOT treated as a fast failure. It is indistinguishable
// from a phone that is momentarily unreachable, so — like any PBX with a
// registered-but-unreachable phone — the caller rings on to the ring
// timeout, then 480. A watcher that answered the caller 480 within ~2 s of
// the socket dying was removed (2026-09-19) for that consistency: a phone
// in DND must ring through, oblivious, not fast-fail the caller. If the app
// comes back on a new connection meanwhile it re-registers and the retarget
// watch (WaitRouteChange, below) sends a fresh INVITE, as before.

// HandleWakeAck is the gateway's wake_ack hook: a decline or busy from the
// woken device ends that call's wait immediately. will_answer is not an
// event here; the registration that follows it is what the wait is for.
func (s *Server) HandleWakeAck(_ string, ack wire.WakeAck) {
	var cause error
	switch ack.Action {
	case wire.WakeDecline:
		cause = errWakeDeclined
	case wire.WakeBusy:
		cause = errWakeBusy
	default:
		return
	}
	s.waitMu.Lock()
	cancel := s.waiting[ack.CallID]
	s.waitMu.Unlock()
	if cancel != nil {
		cancel(cause)
	}
}

// trackWait makes a call's wake-wait cancellable by HandleWakeAck; the
// returned func removes it and must be deferred by the waiter.
func (s *Server) trackWait(callID string, cancel context.CancelCauseFunc) func() {
	s.waitMu.Lock()
	if s.waiting == nil {
		s.waiting = map[string]context.CancelCauseFunc{}
	}
	s.waiting[callID] = cancel
	s.waitMu.Unlock()
	s.live.trackWaiting(callID, time.Now())
	return func() {
		s.untrackWait(callID)
		cancel(nil)
	}
}

// untrackWait forgets a call's cancel without cancelling anything.
func (s *Server) untrackWait(callID string) {
	s.waitMu.Lock()
	delete(s.waiting, callID)
	s.waitMu.Unlock()
	s.live.untrackWaiting(callID)
}

// New builds the server. waker may be nil (no wake path; unregistered users
// get 480 immediately).
func New(cfg Config, reg *registry.Registry, router *routing.Router, waker Waker) (*Server, error) {
	cfg = cfg.withDefaults()
	if cfg.TLS == nil {
		return nil, errors.New("b2bua: TLS config is required (app leg is TLS-only)")
	}
	if cfg.ExternalHost == "" {
		return nil, errors.New("b2bua: ExternalHost is required")
	}
	s := &Server{cfg: cfg, reg: reg, router: router, waker: waker, log: cfg.Logger}

	if cfg.RTPPortStart > 0 && cfg.RTPPortEnd > cfg.RTPPortStart {
		media.RTPPortStart = cfg.RTPPortStart
		media.RTPPortEnd = cfg.RTPPortEnd
	}
	// QoS (SPEC §4.4): media EF, signalling CS3, on every socket this
	// process opens — the relay's RTP and the SIP listeners (accepted TLS
	// connections inherit the listener's marking). Vendored ListenConfig
	// hooks; standard library only.
	media.ListenConfig.Control = qos.Control(qos.DSCPEF)
	sipgo.ListenConfig.Control = qos.Control(qos.DSCPCS3)

	uaOpts := []sipgo.UserAgentOption{sipgo.WithUserAgent("dialpark"), sipgo.WithUserAgentHostname(cfg.ExternalHost)}
	if cfg.TrunkTLS != nil {
		// What we use when WE dial over TLS — the trust for verifying the
		// PBX, and our certificate for its mutual TLS.
		//
		// sipgo takes one client config for the whole user agent rather
		// than per transport, which looks as though it could weaken the app
		// leg. It cannot: a client config governs outbound connections, and
		// the app leg is inbound — apps dial us and we are the TLS server
		// there, where client verification never runs. The server only
		// dials an app whose TLS connection is already pooled (see
		// flowAlive), so it reuses that connection rather than performing a
		// fresh handshake; the one path that would dial an app directly is
		// -rewrite-contact=false, which exists to demonstrate a broken NAT
		// configuration and whose target has no server certificate anyway.
		uaOpts = append(uaOpts, sipgo.WithUserAgenTLSConfig(cfg.TrunkTLS))
	}
	ua, err := sipgo.NewUA(uaOpts...)
	if err != nil {
		return nil, err
	}
	srv, err := sipgo.NewServer(ua, sipgo.WithServerLogger(cfg.Logger))
	if err != nil {
		return nil, err
	}
	srv.OnRegister(s.onRegister)
	s.tl = srv.TransportLayer()

	opts := []diago.DiagoOption{
		diago.WithServer(srv),
		diago.WithLogger(cfg.Logger),
		diago.WithServerRequestMiddleware(s.authMiddleware),
	}
	if cfg.LinePorts.Len() > 0 && cfg.Trunk == nil {
		return nil, errors.New("b2bua: line ports need a PBX to register to; give -trunk")
	}
	if cfg.Trunk != nil {
		host, port, err := trunkBind(cfg.TrunkBind, cfg.Trunk)
		if err != nil {
			return nil, err
		}
		sameHost := func(h string) bool { return h == cfg.BindHost || h == "0.0.0.0" || cfg.BindHost == "0.0.0.0" }
		// Both legs listening on one port is not a configuration we can
		// serve, and the failure it produces otherwise is an "address in
		// use" from inside diago with nothing naming which leg lost.
		if port == cfg.Port && sameHost(host) {
			return nil, fmt.Errorf("b2bua: trunk bind %s:%d collides with the app leg; give -trunk-addr another port", host, port)
		}
		if cfg.LinePorts.Len() > 0 {
			// The range is the whole PBX leg: its first port is the trunk
			// listener. A -trunk-addr naming another port would be a
			// socket no line ever uses, which reads like a mistake.
			if !strings.EqualFold(cfg.Trunk.Transport, "udp") {
				return nil, fmt.Errorf("b2bua: line ports need a UDP trunk; the PBX leg is %s", strings.ToLower(cfg.Trunk.Transport))
			}
			if cfg.TrunkBind != "" && port != cfg.LinePorts.First {
				return nil, fmt.Errorf("b2bua: -trunk-addr port %d is not the first line port %d; the line port range is the whole PBX leg", port, cfg.LinePorts.First)
			}
			if cfg.LinePorts.Contains(cfg.Port) && sameHost(host) {
				return nil, fmt.Errorf("b2bua: line ports %s include the app leg's port %d", cfg.LinePorts, cfg.Port)
			}
			port = cfg.LinePorts.First
		}
		ext := cfg.TrunkExternalHost
		if ext == "" {
			ext = firstIPv4()
		}
		// One listener per line port beyond the first (which is the trunk
		// transport below). Each is the trunk transport with its own port
		// and name, so a leg can be dialled out of it (lineTransport) and
		// a request read on it is attributed to it (inboundLine).
		for p := cfg.LinePorts.First + 1; cfg.LinePorts.Len() > 0 && p <= cfg.LinePorts.Last; p++ {
			opts = append(opts, diago.WithTransport(diago.Transport{
				ID:               linePortTransport(p),
				Transport:        cfg.Trunk.Transport,
				BindHost:         host,
				BindPort:         p,
				ExternalHost:     ext,
				ExternalPort:     p,
				MediaSRTP:        srtpOption(cfg.TrunkSRTP),
				TLSURINoSIPS:     true,
				SendFromListener: true,
			}))
		}
		opts = append(opts, diago.WithTransport(diago.Transport{
			ID:           transportTrunk,
			Transport:    cfg.Trunk.Transport,
			BindHost:     host,
			BindPort:     port,
			ExternalHost: ext,
			// diago fills ExternalPort from BindPort only when ExternalHost is
			// empty (diago.go). We always set ExternalHost, so set the port too
			// or the Contact in our responses carries port 0 and the PBX sends
			// its ACK for our 200 OK to the wrong port: over UDP (no reused
			// connection like TLS) the ACK never arrives and answering the
			// inbound leg blocks for 32 s (Timer H) then fails — silent call.
			ExternalPort: port,
			// SDES on the PBX leg when the deployment says the PBX can
			// take it. Off by default: an RTP/SAVP offer to a PBX without
			// encryption comes back 488 and the call simply fails.
			MediaSRTP: srtpOption(cfg.TrunkSRTP),
			// The certificate we present when the PBX calls us. Nil unless
			// the trunk's transport is tls, in which case diago listens
			// with it (diago.go: ListenAndServeTLS when TLSConf != nil or
			// the transport is tls — so a tls trunk without this would try
			// to listen with no certificate at all).
			TLSConf: cfg.TrunkTLS,
			// sip:…;transport=tls in our Contact, not sips:. Both Asterisk
			// and CUCM emit the former on a secure trunk and some stacks
			// route a sips: Contact poorly (the app leg sets this for
			// exactly that reason). It is also the more honest claim:
			// RFC 5630 §3.3 reads sips: as a promise that the whole
			// remaining path is TLS, and past a B2BUA nothing on this leg
			// can promise anything about the other one.
			TLSURINoSIPS: true,
			// With a socket per line, every request out of a PBX-leg
			// socket must leave from that socket (vendored diago: the
			// upstream client picks one by remote address, which with
			// several listeners is whichever heard from the PBX last).
			// Off without a range, where there is one socket to pick.
			SendFromListener: cfg.LinePorts.Len() > 0,
		}))
	}
	opts = append(opts, mediaOptions(cfg)...)
	s.dg = diago.NewDiago(ua, opts...)
	return s, nil
}

// The two listeners' diago transport IDs. Legs are dialled out of one by
// name because diago otherwise picks the first transport whose protocol
// matches, and with a TLS trunk (SPEC §6 item 3b) both of ours are "tls":
// an app callee would then be offered the trunk's media settings — plain
// RTP where the app leg requires SRTP — and refuse the call with 488.
const (
	transportApp   = "app"
	transportTrunk = "trunk"
)

// A leg is dialled out of one of them by calleeTransport (lines.go), which
// in lines mode with a socket per line picks the calling line's own.

// srtpOption is diago's per-transport setting: 0 none, 1 SDES.
func srtpOption(m TrunkSRTPMode) int {
	if m.offers() {
		return 1
	}
	return 0
}

// TrunkSRTPMode is how far SDES goes on the PBX leg.
type TrunkSRTPMode string

const (
	TrunkSRTPOff  TrunkSRTPMode = "off"
	TrunkSRTPSDES TrunkSRTPMode = "sdes"
)

// ParseTrunkSRTP reads the -trunk-srtp flag.
func ParseTrunkSRTP(s string) (TrunkSRTPMode, error) {
	switch m := TrunkSRTPMode(strings.ToLower(strings.TrimSpace(s))); m {
	case "", TrunkSRTPOff:
		return TrunkSRTPOff, nil
	case TrunkSRTPSDES:
		return m, nil
	default:
		return "", fmt.Errorf("want off or sdes; got %q", s)
	}
}

// offers reports whether this mode puts a=crypto on the trunk leg at all.
func (m TrunkSRTPMode) offers() bool { return m == TrunkSRTPSDES }

// mediaOptions is the app-leg transport (always present) and the codec set.
func mediaOptions(cfg Config) []diago.DiagoOption {
	// The port apps reach us on, in our Contact: diago fills ExternalPort
	// from BindPort only when ExternalHost is empty (see the trunk transport
	// above), and a Contact without a port sends in-dialog requests to the
	// default 5061 — wrong wherever the public port differs (a container
	// published on another host port: the harness beside a native server
	// lost every ACK to the wrong server, 2026-09-13).
	publicPort := cfg.PublicPort
	if publicPort == 0 {
		publicPort = cfg.Port
	}
	return []diago.DiagoOption{
		diago.WithTransport(diago.Transport{
			// Named so a leg can be dialled out of a chosen transport
			// rather than the first one with a matching protocol —
			// ambiguous the moment the trunk is TLS too (see legTransport).
			ID:           transportApp,
			Transport:    "tls",
			BindHost:     cfg.BindHost,
			BindPort:     cfg.Port,
			ExternalHost: cfg.ExternalHost,
			ExternalPort: publicPort,
			TLSConf:      cfg.TLS,
			// libre/baresip cannot route to a sips: Contact (closes with ENOSYS).
			TLSURINoSIPS:   true,
			RewriteContact: true,
			// SRTP (SDES, AES_CM_128_HMAC_SHA1_80) on every app-leg session
			// (SPEC §4.4 rule 4): offers carry RTP/SAVP + a=crypto, answers
			// mirror the app's. The trunk transport above stays plain RTP;
			// the relay copies encoded payload between the legs and each
			// leg's media session applies its own keys.
			MediaSRTP: 1,
		}),
		diago.WithMediaConfig(diago.MediaConfig{
			// The app leg's offer: Opus for app↔app, G.722 for wideband PBX
			// calls, G.711 as the fallback everything speaks — and
			// telephone-event (RFC 4733), so a digit pressed on either
			// side travels as an event the relay forwards, not as a tone
			// a codec mangles. Without it an exchange sees a device with
			// no DTMF at all (CUCM lines bench 2026-10-17).
			Codecs: []media.Codec{media.CodecAudioOpus, media.CodecAudioG722, media.CodecAudioUlaw, media.CodecAudioAlaw, media.CodecTelephoneEvent8000},
		}),
	}
}

// Serve listens on the app leg until ctx ends.
func (s *Server) Serve(ctx context.Context) error {
	trunk := "none"
	if s.cfg.Trunk != nil {
		trunk = s.cfg.Trunk.URI("*")
	}
	s.log.Info("b2bua listening", "bind", fmt.Sprintf("%s:%d", s.cfg.BindHost, s.cfg.Port), "external", s.cfg.ExternalHost, "domains", s.cfg.Domains,
		"app_leg_symmetric_rtp", !s.cfg.NoSymmetricRTP, "rewrite_contact", !s.cfg.KeepAdvertisedContact, "trunk", trunk,
		"trunk_srtp", s.cfg.TrunkSRTP, "trunk_tls", s.cfg.TrunkTLS != nil)
	// Immediately after the line that describes the trunk, not before the
	// startup banner: warnings emitted during construction scroll past above
	// the line everyone reads as the beginning, next to the self-signed-cert
	// warning people have learned to ignore, and this one was missed on a
	// real deployment (2026-09-17).
	//
	// SDES carries the media keys in the SDP, so over signalling that is not
	// itself encrypted anyone who can read the INVITE can read the keys.
	// Against an attacker who sees both planes — the usual case on one LAN —
	// the media encryption adds nothing; it still helps against one who can
	// see only the media path. RFC 4568 §7.1 requires a protected signalling
	// channel for exactly this reason.
	if s.cfg.Trunk != nil && s.cfg.TrunkSRTP.offers() && !strings.EqualFold(s.cfg.Trunk.Transport, "tls") {
		s.log.Warn("trunk SRTP over unencrypted signalling: the SDES keys travel in the SDP, so anyone who can read the INVITE can decrypt the media; use a TLS trunk",
			"trunk_transport", s.cfg.Trunk.Transport, "trunk_srtp", s.cfg.TrunkSRTP)
	}
	s.startTrunkQualify(ctx)
	s.startLines(ctx)
	err := s.dg.Serve(ctx, s.serveDialog)
	if ctx.Err() != nil {
		return nil
	}
	return err
}

// ---- registrar --------------------------------------------------------------

func (s *Server) servesDomain(host string) bool {
	if len(s.cfg.Domains) == 0 || host == "" {
		return true
	}
	if i := strings.IndexByte(host, ':'); i >= 0 {
		host = host[:i]
	}
	for _, d := range s.cfg.Domains {
		if strings.EqualFold(d, host) {
			return true
		}
	}
	return strings.EqualFold(host, s.cfg.ExternalHost)
}

func (s *Server) onRegister(req *sip.Request, tx sip.ServerTransaction) {
	to := req.To()
	if to == nil || to.Address.User == "" {
		_ = tx.Respond(sip.NewResponseFromRequest(req, 400, "Bad Request", nil))
		return
	}
	user := to.Address.User
	if !s.servesDomain(to.Address.Host) {
		_ = tx.Respond(sip.NewResponseFromRequest(req, 403, "Forbidden", nil))
		return
	}
	if s.cfg.Auth != nil {
		enrolled, err := s.cfg.Auth.Verify(req)
		if !s.authorized(req, tx, enrolled, user, err) {
			return
		}
	}

	contact := req.Contact()
	if contact == nil {
		// Query: report the current binding.
		ep, ok := s.reg.Lookup(user)
		if !ok {
			_ = tx.Respond(sip.NewResponseFromRequest(req, 404, "Not Found", nil))
			return
		}
		res := sip.NewResponseFromRequest(req, 200, "OK", nil)
		if ep.Contact != "" {
			res.AppendHeader(sip.NewHeader("Contact", "<"+ep.Contact+">"))
		}
		_ = tx.Respond(res)
		return
	}

	expires := registerExpires(req, contact, s.cfg.MaxExpires)
	if contact.Address.Wildcard || expires == 0 {
		s.reg.Unregister(user)
		s.log.Info("sip unregister", "user", user)
		_ = tx.Respond(sip.NewResponseFromRequest(req, 200, "OK", nil))
		return
	}
	if expires < s.cfg.MinExpires {
		res := sip.NewResponseFromRequest(req, 423, "Interval Too Brief", nil)
		res.AppendHeader(sip.NewHeader("Min-Expires", strconv.Itoa(s.cfg.MinExpires)))
		_ = tx.Respond(res)
		return
	}
	if expires > s.cfg.MaxExpires {
		expires = s.cfg.MaxExpires
	}

	// Rewrite the binding to the connection the REGISTER arrived on
	// (RFC 5626 outbound semantics): phones sit behind NAT/firewalls and
	// their advertised Contact is unreachable, but the TLS connection they
	// opened to us is. sipgo pools accepted connections by remote address,
	// so an INVITE addressed to src reuses that connection instead of
	// dialling back.
	uri := contact.Address.String()
	stored := uri
	if !s.cfg.KeepAdvertisedContact {
		stored = rewriteContact(contact.Address, req.Source())
	}
	ep, err := s.reg.Register(user, stored, time.Duration(expires)*time.Second)
	if err != nil {
		_ = tx.Respond(sip.NewResponseFromRequest(req, 404, "Not Found", nil))
		return
	}
	s.log.Info("sip register", "user", user, "contact", uri, "route", ep.Contact, "expires", expires)
	res := sip.NewResponseFromRequest(req, 200, "OK", nil)
	res.AppendHeader(sip.NewHeader("Contact", fmt.Sprintf("<%s>;expires=%d", uri, expires)))
	res.AppendHeader(sip.NewHeader("Expires", strconv.Itoa(expires)))
	_ = tx.Respond(res)
}

// authorized applies the app-leg Digest verdict for a request whose SIP
// user is sipUser: a request with no or stale credentials is challenged
// (401), bad credentials or an unknown device are refused (403), and so is
// a SIP user other than the one the authenticated device is enrolled for —
// the check that stops one enrolled phone registering or calling as
// another. Returns true when the request may proceed.
func (s *Server) authorized(req *sip.Request, tx sip.ServerTransaction, enrolledUser, sipUser string, err error) bool {
	switch {
	case err == nil:
		if !strings.EqualFold(enrolledUser, sipUser) {
			s.log.Warn("app leg: device is not enrolled for this user", "method", req.Method, "enrolled_user", enrolledUser, "sip_user", sipUser, "src", req.Source())
			_ = tx.Respond(sip.NewResponseFromRequest(req, 403, "Forbidden", nil))
			return false
		}
		return true
	case errors.Is(err, sipauth.ErrNoCredentials), errors.Is(err, sipauth.ErrStale):
		_ = tx.Respond(s.cfg.Auth.Challenge(req, errors.Is(err, sipauth.ErrStale)))
		return false
	default:
		s.log.Warn("app leg: authentication refused", "method", req.Method, "sip_user", sipUser, "src", req.Source(), "err", err)
		_ = tx.Respond(sip.NewResponseFromRequest(req, 403, "Forbidden", nil))
		return false
	}
}

// authMiddleware gates initial INVITEs on the app leg with the same Digest
// check as REGISTER, requiring the From user to be the device's enrolled
// user (no caller-identity spoofing). In-dialog requests ride a dialog that
// was authenticated when it was set up, and trunk requests are trusted by
// address (SPEC §4.4 rule 7), so neither is challenged.
func (s *Server) authMiddleware(next sipgo.RequestHandler) sipgo.RequestHandler {
	return func(req *sip.Request, tx sip.ServerTransaction) {
		fromPBX := isTrunkSource(req.Transport(), req.Source(), s.cfg.Trunk, s.cfg.TrunkPeers)
		if fromPBX {
			// Anything the exchange sends — an OPTIONS poll, a NOTIFY, a
			// call — proves it is reachable: a line retrying its REGISTER
			// need not wait out its backoff (lines.go, registrarSeen).
			s.registrarSeen()
		}
		// The PBX's unsolicited NOTIFYs never belong to a dialog, and diago
		// would answer them 400 for exactly that reason (pbxNotify).
		if req.Method == sip.NOTIFY && !inDialog(req) && fromPBX {
			s.pbxNotify(req, tx)
			return
		}
		if s.cfg.Auth != nil && req.Method == sip.INVITE && !inDialog(req) &&
			!isTrunkSource(req.Transport(), req.Source(), s.cfg.Trunk, s.cfg.TrunkPeers) {
			sipUser := ""
			if from := req.From(); from != nil {
				sipUser = from.Address.User
			}
			enrolled, err := s.cfg.Auth.Verify(req)
			if !s.authorized(req, tx, enrolled, sipUser, err) {
				return
			}
		}
		next(req, tx)
	}
}

// inDialog: a To tag means the request belongs to an existing dialog
// (re-INVITE for hold, BYE, ...), not a new call.
func inDialog(req *sip.Request) bool {
	to := req.To()
	return to != nil && to.Params.Has("tag")
}

// delayedOffer: an INVITE with no body is a delayed offer (RFC 3261
// §13.2.1) — the caller wants our 200 OK to carry the SDP offer and will
// answer it in the ACK. CUCM sends these to every third-party SIP line, so
// lines mode cannot take an inbound call without this. An INVITE with an
// SDP offer is answered exactly as it always was; the test is the same one
// diago uses to pick its answer path, so the two cannot disagree.
func delayedOffer(req *sip.Request) bool {
	return len(req.Body()) == 0
}

// pbxNotify answers an out-of-dialog NOTIFY from the PBX. An exchange sends
// every registered line an unsolicited message-summary NOTIFY (RFC 3842):
// CUCM on each registration and whenever the mailbox changes, Asterisk the
// same, and both expect 200 OK. diago matches NOTIFY against its dialogs —
// REFER progress is the only NOTIFY it knows — and answered these with 400
// Bad Request, which an exchange logs against the line (CUCM lines bench,
// 2026-10-17). The mailbox state is logged and otherwise dropped: nothing
// shows it yet, since a message-waiting light needs a wire field and an
// app release (SPEC §6 "Much later"). Any other out-of-dialog NOTIFY has no
// subscription behind it and is answered 481 as RFC 6665 requires.
func (s *Server) pbxNotify(req *sip.Request, tx sip.ServerTransaction) {
	event := ""
	if h := req.GetHeader("Event"); h != nil {
		event = strings.TrimSpace(h.Value())
	}
	name := event
	if i := strings.IndexByte(name, ';'); i >= 0 {
		name = strings.TrimSpace(name[:i])
	}
	line := ""
	if to := req.To(); to != nil {
		line = to.Address.User
	}
	if user, ok := s.inboundLine(req); ok {
		line = user
	}
	log := s.log.With("line", line, "event", event, "source", req.Source())
	if !strings.EqualFold(name, "message-summary") {
		log.Info("pbx notify: no subscription for this event; answered 481")
		_ = tx.Respond(sip.NewResponseFromRequest(req, 481, "Subscription Does Not Exist", nil))
		return
	}
	waiting, voice := parseMessageSummary(req.Body())
	log.Info("pbx: message waiting", "waiting", waiting, "voice", voice)
	_ = tx.Respond(sip.NewResponseFromRequest(req, 200, "OK", nil))
}

// parseMessageSummary reads the two lines of an RFC 3842 body that matter:
// "Messages-Waiting: yes" and "Voice-Message: 2/0 (0/0)" (new/old, urgent
// in brackets). A body without them — CUCM's first NOTIFY after a REGISTER
// can be a bare "Messages-Waiting: no" — reads as nothing waiting.
func parseMessageSummary(body []byte) (waiting bool, voice string) {
	for _, l := range strings.Split(string(body), "\n") {
		k, v, ok := strings.Cut(l, ":")
		if !ok {
			continue
		}
		v = strings.TrimSpace(v)
		switch strings.ToLower(strings.TrimSpace(k)) {
		case "messages-waiting":
			waiting = strings.EqualFold(v, "yes")
		case "voice-message":
			voice = v
		}
	}
	return waiting, voice
}

// flowAlive reports whether the TLS connection a rewritten registration
// route points at is still in sipgo's pool. It never dials.
func (s *Server) flowAlive(route string) bool {
	var u sip.Uri
	if err := sip.ParseUri(route, &u); err != nil || u.Host == "" || u.Port == 0 {
		return false
	}
	_, err := s.tl.GetConnection("tls", net.JoinHostPort(u.Host, strconv.Itoa(u.Port)))
	return err == nil
}

// reliableTransport is whether SIP over `transport` keeps a connection that
// can go silently dead (TCP, TLS) — as opposed to UDP, which pools nothing.
func reliableTransport(transport string) bool {
	switch strings.ToLower(transport) {
	case "tcp", "tls":
		return true
	}
	return false
}

// dropTrunkConnection closes the pooled connection to the trunk, if there is
// one, so the next request to it dials afresh. sipgo keys the pool by the
// dialled IP:port, so a trunk configured by name is looked up under each
// address the name resolves to as well.
func (s *Server) dropTrunkConnection(log *slog.Logger) {
	t := s.cfg.Trunk
	if t == nil || !reliableTransport(t.Transport) {
		return
	}
	addrs := []string{t.Address()}
	if net.ParseIP(t.Host) == nil {
		if ips, err := net.LookupIP(t.Host); err == nil {
			for _, ip := range ips {
				addrs = append(addrs, net.JoinHostPort(ip.String(), strconv.Itoa(t.Port)))
			}
		}
	}
	for _, addr := range addrs {
		c, err := s.tl.GetConnection(t.Transport, addr)
		if err != nil {
			continue
		}
		log.Warn("trunk: dropping its pooled connection", "addr", addr)
		_ = c.Close() // hard close: the read loop then evicts it from the pool
	}
}

// rewriteContact returns the URI to route to for a registration: the
// Contact's user part at the request's source ip:port over TLS. If the
// source cannot be parsed the Contact is kept as advertised.
func rewriteContact(advertised sip.Uri, source string) string {
	host, port, err := net.SplitHostPort(source)
	if err != nil || host == "" {
		return advertised.String()
	}
	u := sip.Uri{User: advertised.User, Host: host}
	if p, err := strconv.Atoi(port); err == nil {
		u.Port = p
	}
	u.UriParams = sip.NewParams()
	u.UriParams.Add("transport", "tls")
	return u.String()
}

// registerExpires returns the requested binding lifetime: the Contact
// "expires" param wins, then the Expires header, then def.
func registerExpires(req *sip.Request, contact *sip.ContactHeader, def int) int {
	if v, ok := contact.Params.Get("expires"); ok {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			return n
		}
	}
	if h := req.GetHeader("Expires"); h != nil {
		if n, err := strconv.Atoi(strings.TrimSpace(h.Value())); err == nil && n >= 0 {
			return n
		}
	}
	return def
}

// ---- calls ------------------------------------------------------------------

func (s *Server) serveDialog(in *diago.DialogServerSession) {
	callee := in.ToUser()
	callID := in.InviteRequest.CallID().Value()
	log := s.log.With("call", callID, "from", in.FromUser(), "to", callee)
	// A call from the exchange belongs to the line whose socket it arrived
	// on; the To user is what identified the line before each had a
	// socket, and still does on the shared one.
	if s.isTrunkLeg(in) {
		if user, ok := s.inboundLine(in.InviteRequest); ok {
			if user != callee {
				log = log.With("line", user)
			}
			callee = user
		}
	}

	d := s.router.Resolve(callee)
	if d.Target == routing.Unknown {
		log.Info("invite: unknown destination")
		_ = in.Respond(404, "Not Found", nil)
		return
	}
	legs := legs{callerTrunk: s.isTrunkLeg(in)}
	if delayedOffer(in.InviteRequest) {
		// The callee is offered the PBX codec set (there is no caller SDP
		// to narrow it from) and the caller is then offered, in our 200
		// OK, the one codec the callee took.
		log.Info("invite: delayed offer (no SDP); the caller is offered the callee's codec in the 200 OK", "caller_trunk", legs.callerTrunk)
	}

	if d.Target == routing.Echo {
		s.echo(log, in, legs.callerTrunk)
		return
	}

	// 100 Trying only. 180 Ringing waits until something is actually
	// alerting — the callee's own 18x, or the wake reaching a device, which
	// is what makes the phone ring on the wake path. Sending it here, before
	// the INVITE has gone anywhere, told every caller "ringing" even when
	// the destination was unreachable: a call to a PBX extension that was
	// switched off rang for the full ring timeout and the caller never heard
	// why (2026-09-15). Now an unreachable destination goes 100 → 480, and
	// the app plays congestion at once (SPEC §4.4 rule 8a).
	_ = in.Trying()
	legs.ring = ringer(in)

	ctx, cancel := context.WithTimeout(in.Context(), s.cfg.RingTimeout)
	defer cancel()

	if d.Target == routing.Trunk {
		// Non-local destination: hand it to the PBX as a trunk peer. The
		// PBX does the ringing; we relay media between the two legs.
		if s.cfg.Trunk == nil {
			_ = in.Respond(503, "Service Unavailable", nil)
			return
		}
		var dst sip.Uri
		if err := sip.ParseUri(s.cfg.Trunk.URI(d.User), &dst); err != nil {
			log.Error("bad trunk uri", "err", err)
			_ = in.Respond(500, "Server Internal Error", nil)
			return
		}
		legs.calleeTrunk = true
		log.Info("invite: to trunk", "dst", dst.String(), "from_trunk", legs.callerTrunk)
		// One redial on a fresh connection when the pooled one turns out to
		// be dead (errTrunkUnresponsive: bridge dropped it). A second failure
		// is answered as unreachable.
		for attempt := 0; ; attempt++ {
			err := s.bridge(ctx, log, in, dst, callID, legs)
			if !errors.Is(err, errTrunkUnresponsive) {
				return
			}
			if attempt == 0 && ctx.Err() == nil {
				log.Warn("invite: trunk connection unresponsive; dropped it, redialling on a fresh one")
				continue
			}
			if in.Context().Err() == nil {
				_ = in.Respond(480, "Temporarily Unavailable", nil)
			}
			return
		}
	}

	ep := d.Endpoint
	if d.Registered && !s.cfg.KeepAdvertisedContact && !s.flowAlive(ep.Contact) {
		// The registration was bound to a connection that no longer exists
		// (phone backgrounded, network changed, app killed). Dialling its
		// NAT'd address can only time out; treat it as unregistered so the
		// wake path brings the phone back on a fresh connection.
		log.Info("invite: registration flow gone, treating as unregistered", "route", ep.Contact)
		s.reg.Unregister(ep.User)
		d.Registered = false
	}
	wakeable := ep.DeviceID != "" && s.waker != nil
	if !d.Registered {
		woken, err := s.wakeAndWait(ctx, log, in, callID, ep, legs.ring)
		if err != nil {
			return
		}
		ep = woken
	} else if wakeable {
		// Registered: the INVITE goes straight to the app's SIP stack, but
		// send the wake too — the app rings from whichever arrives first and
		// de-duplicates on call_id (PROTOCOL.md §6).
		s.waker.Wake(ep.DeviceID, s.wakeFor(callID, in, ep))
	}

	var err error
	for attempt := 0; ; attempt++ {
		var dst sip.Uri
		if err = sip.ParseUri(ep.Contact, &dst); err != nil {
			log.Error("bad registered contact", "contact", ep.Contact, "err", err)
			_ = in.Respond(500, "Server Internal Error", nil)
			return
		}
		legs.calleeUser, legs.calleeRoute = ep.User, ep.Contact
		err = s.bridge(ctx, log, in, dst, callID, legs)
		var moved *retargetError
		if errors.As(err, &moved) && attempt < maxRetargets && ctx.Err() == nil {
			ep = moved.ep // the callee moved mid-ring: dial where it is now
			continue
		}
		break
	}
	if err != nil && wakeable {
		// Never bridged: stop the app ringing. "caller_hangup" only when
		// the caller went away (its dialog context ended); otherwise the
		// ring timed out.
		reason := wire.CancelTimeout
		if in.Context().Err() != nil {
			reason = wire.CancelCallerHangup
		}
		s.waker.CancelWake(ep.DeviceID, callID, reason)
	} else if wakeable {
		// Answered and over. The wake is kept pending through the ring so a
		// client reconnecting mid-ring is rung again; from here a reconnect
		// must not replay a call that is finished (it rang the app for a
		// dead call, and the app's answer then armed it to take the next
		// INVITE unrung).
		s.waker.ForgetWake(ep.DeviceID, callID)
	}
}

// wakeFor builds the wake payload for an inbound call to ep.
func (s *Server) wakeFor(callID string, in *diago.DialogServerSession, ep registry.Endpoint) wire.Wake {
	return s.wakeForFrom(callID, in.InviteRequest.From(), ep)
}

func (s *Server) wakeForFrom(callID string, from *sip.FromHeader, ep registry.Endpoint) wire.Wake {
	party := wire.Party{}
	if from != nil {
		party = wire.Party{DisplayName: from.DisplayName, URI: from.Address.String()}
	}
	return wire.Wake{
		CallID:    callID,
		From:      party,
		To:        wire.Party{URI: fmt.Sprintf("sip:%s@%s", ep.User, s.primaryDomain())},
		SIP:       wire.SIPTarget{Host: s.cfg.ExternalHost, Port: s.publicPort(), Transport: "tls"},
		ExpiresAt: time.Now().Add(s.cfg.RingTimeout),
	}
}

// wakeAndWait sends a wake for the callee's device and blocks until it
// registers, the caller gives up, or the ring timeout passes. On failure it
// has already answered the caller and cancelled the wake.
func (s *Server) wakeAndWait(ctx context.Context, log *slog.Logger, in *diago.DialogServerSession, callID string, ep registry.Endpoint, ring func()) (registry.Endpoint, error) {
	return s.wakeAndWaitFrom(ctx, log, in, callID, in.InviteRequest.From(), ep, ring)
}

// wakeAndWaitFrom is wakeAndWait with the caller identity given explicitly
// (a transfer wakes the target on behalf of the remaining party). With a
// nil `in` no SIP response is sent; the caller reports the failure.
// `ring` tells the caller the device is being alerted; nil when there is no
// caller leg to tell (a transfer).
func (s *Server) wakeAndWaitFrom(ctx context.Context, log *slog.Logger, in *diago.DialogServerSession, callID string, from *sip.FromHeader, ep registry.Endpoint, ring func()) (registry.Endpoint, error) {
	respond := func(code int, reason string) {
		if in != nil {
			_ = in.Respond(code, reason, nil)
		}
	}
	if ep.DeviceID == "" || s.waker == nil {
		log.Info("invite: callee not registered and not wake-routable")
		respond(480, "Temporarily Unavailable")
		return ep, errors.New("no wake path")
	}

	delivered := s.waker.Wake(ep.DeviceID, s.wakeForFrom(callID, from, ep))
	if delivered == 0 {
		// Nobody to wake (no live connection; APNS is Phase 4b). Fail fast
		// rather than making the caller wait out the ring timeout.
		s.waker.CancelWake(ep.DeviceID, callID, wire.CancelTimeout)
		log.Info("invite: callee offline, wake undeliverable")
		respond(480, "Temporarily Unavailable")
		return ep, errors.New("wake undeliverable")
	}
	log.Info("invite: woke callee device", "device", ep.DeviceID, "connections", delivered)
	// The wake is what makes the phone ring (CallKit rings from it, before
	// the INVITE arrives), so the caller is told "ringing" now — this is the
	// one place on the wake path where it becomes true.
	if ring != nil {
		ring()
	}

	// The wait can be cut short by the device's own answer to the wake: a
	// decline or busy wake_ack (HandleWakeAck) cancels it with that cause.
	wctx, cancel := context.WithCancelCause(ctx)
	defer s.trackWait(callID, cancel)()

	woken, err := s.reg.WaitRegistered(wctx, ep.User)
	if err != nil {
		cause := context.Cause(wctx)
		if cause == errWakeDeclined {
			// The user actively declined. Tell the caller 486 so the PBX
			// applies its busy rule (busy tone / forward-on-busy), not 480,
			// which reads as "nobody there". The device stopped ringing
			// itself, so no wake_cancel is needed.
			log.Info("invite: callee declined the wake", "cause", cause)
			respond(486, "Busy Here")
			return ep, cause
		}
		if cause == errWakeBusy {
			// The device filtered the call itself (Focus / Sleep / DND): it
			// was alerted but the system suppressed the ring, so nobody will
			// answer. That is an unanswered call, not a rejection — with a
			// caller leg, keep it ringing to the ring timeout then 480, as
			// for any woken device that never answers (industry "DND rings
			// through"; only a user decline, above, fast-fails with 486).
			// With no caller leg (a transfer) there is nothing to ring, so
			// return at once. No wake_cancel either way — the device is idle.
			log.Info("invite: callee device filtered the wake (Focus/DND)", "cause", cause)
			if in != nil {
				<-ctx.Done() // the ring timeout, or the caller giving up
				if in.Context().Err() == nil {
					respond(480, "Temporarily Unavailable")
				}
			}
			return ep, cause
		}
		reason := wire.CancelTimeout
		if ctx.Err() != nil && (in == nil || in.Context().Err() != nil) {
			reason = wire.CancelCallerHangup
		}
		s.waker.CancelWake(ep.DeviceID, callID, reason)
		log.Info("invite: wake did not produce a registration", "reason", reason)
		if reason == wire.CancelTimeout {
			respond(480, "Temporarily Unavailable")
		}
		return ep, err
	}
	return woken, nil
}

// bridge answers the caller and dials the callee's contact, proxying media.
//
// Both legs run symmetric RTP (SPEC §4.4 rule 3, and a must for phones
// behind NAT): the relay learns each peer's real media address from the
// first packet it receives instead of trusting the SDP, whose address is
// often a private one.
// echo answers the caller and plays its own audio straight back: the
// end-to-end self-test for a phone (microphone → encoder → RTP → relay →
// RTP → decoder → speaker) with no second party. Same relay pump as a
// bridged call, source and sink on one leg.
func (s *Server) echo(log *slog.Logger, in *diago.DialogServerSession, trunk bool) {
	_ = in.Trying()
	if err := in.AnswerOptions(diago.AnswerOptions{RTPNAT: s.legNAT(trunk)}); err != nil {
		log.Error("echo: answer", "err", err)
		return
	}
	p, err := newPump(in, in)
	if err != nil {
		log.Error("echo: relay", "err", err)
		_ = in.Hangup(in.Context())
		return
	}
	codec := media.CodecAudioFromSession(in.Media().MediaSession())
	log.Info("echo: answered", "codec", codec.Name, "from_trunk", trunk, "srtp", srtpState(in.Media().MediaSession()))
	go p.run(in.Context(), log.With("dir", "echo"))
	<-in.Context().Done()
	log.Info("echo: ended", "relayed", p.String())
}

// legs says which side of a call is the PBX trunk (neither, for app↔app).
type legs struct {
	callerTrunk bool
	calleeTrunk bool
	// A registered local callee: its SIP user and the route being dialled,
	// so bridge can notice a re-registration from elsewhere mid-ring and
	// a decline wake_ack while the INVITE is in flight. Empty for a trunk
	// or echo callee.
	calleeUser  string
	calleeRoute string
	// Sends 180 Ringing to the caller, once, when the callee is genuinely
	// being alerted. Never nil for a bridged call.
	ring func()
}

// ringer returns a function that sends 180 Ringing to the caller the first
// time it is called and does nothing after. Several things can be the first
// sign that the callee is alerting — a 180 or 183 from its route, a wake
// delivered to a device, a retargeted second INVITE — and the caller must
// see exactly one 180 across all of them.
func ringer(in *diago.DialogServerSession) func() {
	var once sync.Once
	return func() { once.Do(func() { _ = in.Ringing() }) }
}

// retargetError ends a callee INVITE that was overtaken by a fresh
// registration: serveDialog dials the new route instead.
type retargetError struct{ ep registry.Endpoint }

func (e *retargetError) Error() string { return "callee re-registered at " + e.ep.Contact }

var errRetarget = errors.New("callee route changed")

// maxRetargets bounds how often one call follows a moving callee.
const maxRetargets = 3

// DefaultTrunkCodecs is what a PBX trunk gets offered unless configured:
// G.722 wideband first (what enterprise handsets speak to their PBX), then
// G.711. Apps get the full set (Opus first). Because the relay copies
// encoded audio between the legs, the caller is always answered with the
// codec the callee took, so a call that touches the trunk is G.722 or
// G.711 end to end and never transcoded (SPEC §4.4 rule 4).
var DefaultTrunkCodecs = []media.Codec{media.CodecAudioG722, media.CodecAudioUlaw, media.CodecAudioAlaw}

// trunkCodecs is the configured trunk offer, or the default.
func (c Config) trunkCodecs() []media.Codec {
	set := DefaultTrunkCodecs
	if len(c.TrunkCodecs) > 0 {
		set = c.TrunkCodecs
	}
	return withTelephoneEvent(set)
}

// withTelephoneEvent adds RFC 4733 telephone-event to a codec set that
// lacks it. -trunk-codecs names audio codecs; DTMF is not a choice. An
// INVITE to the PBX without it told CUCM the device had no DTMF (bench
// 2026-10-17), and digits from the app would have been forwarded as audio
// payload under the audio codec's payload type.
func withTelephoneEvent(set []media.Codec) []media.Codec {
	for _, c := range set {
		if c.Name == "telephone-event" {
			return set
		}
	}
	out := make([]media.Codec, 0, len(set)+1)
	out = append(out, set...)
	return append(out, media.CodecTelephoneEvent8000)
}

// telephoneEventOffered reads the telephone-event format out of an SDP
// offer, with the offerer's payload type: a dynamic type is theirs to
// choose and the answer must echo it (CUCM and Asterisk use 101, which is
// convention, not a rule).
func telephoneEventOffered(body []byte) (media.Codec, bool) {
	if len(body) == 0 {
		return media.Codec{}, false
	}
	sd := sdp.SessionDescription{}
	if err := sdp.Unmarshal(body, &sd); err != nil {
		return media.Codec{}, false
	}
	md, err := sd.MediaDescription("audio")
	if err != nil {
		return media.Codec{}, false
	}
	codecs := make([]media.Codec, len(md.Formats))
	n, _ := media.CodecsFromSDPRead(md.Formats, sd.Values("a"), codecs)
	for _, c := range codecs[:n] {
		if c.Name == "telephone-event" {
			return c, true
		}
	}
	return media.Codec{}, false
}

// ParseCodecs turns a flag value like "g722,pcmu,pcma" into codecs, in that
// order of preference. Names are case-insensitive; PCMU/PCMA/G722/opus.
func ParseCodecs(list string) ([]media.Codec, error) {
	var out []media.Codec
	for _, name := range strings.Split(list, ",") {
		switch strings.ToLower(strings.TrimSpace(name)) {
		case "":
			continue
		case "g722":
			out = append(out, media.CodecAudioG722)
		case "pcmu", "ulaw", "g711u":
			out = append(out, media.CodecAudioUlaw)
		case "pcma", "alaw", "g711a":
			out = append(out, media.CodecAudioAlaw)
		case "opus":
			out = append(out, media.CodecAudioOpus)
		default:
			return nil, fmt.Errorf("unknown codec %q (want g722, pcmu, pcma or opus)", strings.TrimSpace(name))
		}
	}
	if len(out) == 0 {
		return nil, errors.New("no codecs")
	}
	return out, nil
}

// lateOfferCodecs is what a delayed-offer caller is offered in our 200 OK:
// the callee's codec first, then the rest of the PBX set as fallbacks.
func lateOfferCodecs(first media.Codec, set []media.Codec) []media.Codec {
	out := []media.Codec{first}
	for _, c := range set {
		if !sameCodec(c, first) {
			out = append(out, c)
		}
	}
	return out
}

// callTouchesTrunk reports whether either leg is the PBX trunk. When it is,
// the callee is offered G.711 only so the negotiated codec is one both legs
// share (the relay does not transcode); app↔app keeps the full set.
func callTouchesTrunk(l legs) bool { return l.callerTrunk || l.calleeTrunk }

// requireTrunkSRTP enforces -trunk-srtp=sdes on a trunk leg: nil unless
// this is the PBX leg, encryption was asked for, and the session did not
// actually get it. Only the trunk leg is checked — the app leg is unconditionally
// SRTP (rule 4) and has no mode.
func (s *Server) requireTrunkSRTP(trunk bool, ms *media.MediaSession) error {
	if !trunk || s.cfg.TrunkSRTP != TrunkSRTPSDES {
		return nil
	}
	if ms != nil && ms.SecureRTPActive() {
		return nil
	}
	return errTrunkNotSecure
}

var errTrunkNotSecure = errors.New("trunk leg is not SRTP and -trunk-srtp=sdes")

// srtpState is the per-leg log value: "on" when both directions of the
// leg's media are SRTP-protected, "off" otherwise (the trunk, always).
func srtpState(ms *media.MediaSession) string {
	if ms != nil && ms.SecureRTPActive() {
		return "on"
	}
	return "off"
}

// callerStatus is the final response the caller gets when the callee leg
// fails. A deliberate refusal by the callee — 486 Busy Here (what baresip
// and desk phones send on reject), 600 Busy Everywhere, 603 Decline — is
// relayed unchanged so the PBX applies its busy rule. Anything else (no
// answer, timeout, transport failure, cancelled wait) is 480 Temporarily
// Unavailable: nobody could be reached. diago surfaces the callee's final
// response as sipgo.ErrDialogResponse, by value or by pointer depending on
// the path, so both are checked.
func callerStatus(err error) (int, string) {
	var res *sip.Response
	var byVal sipgo.ErrDialogResponse
	var byPtr *sipgo.ErrDialogResponse
	if errors.As(err, &byVal) {
		res = byVal.Res
	} else if errors.As(err, &byPtr) && byPtr != nil {
		res = byPtr.Res
	}
	if res != nil {
		switch res.StatusCode {
		case 486, 600, 603:
			return int(res.StatusCode), res.Reason
		}
	}
	return 480, "Temporarily Unavailable"
}

// legNAT is the symmetric-RTP setting for a leg: the trunk always learns
// (a PBX behind NAT is normal); app legs follow the deployment flag.
func (s *Server) legNAT(trunk bool) int {
	if trunk || !s.cfg.NoSymmetricRTP {
		return media.RTPNATSymetric
	}
	return media.RTPNATDisabled
}

// isTrunkLeg reports whether an incoming call came from the PBX trunk
// rather than an app: the app leg is TLS-only, so any other transport is
// the trunk listener; a TLS trunk is told apart by source address.
func (s *Server) isTrunkLeg(in *diago.DialogServerSession) bool {
	if s.cfg.Trunk == nil {
		return false
	}
	return isTrunkSource(in.InviteRequest.Transport(), in.InviteRequest.Source(), s.cfg.Trunk, s.cfg.TrunkPeers)
}

func isTrunkSource(transport, source string, t *pbx.Trunk, peers []string) bool {
	if t == nil {
		return false
	}
	if !strings.EqualFold(transport, "tls") {
		return true
	}
	host, _, err := net.SplitHostPort(source)
	if err != nil {
		host = source
	}
	if strings.EqualFold(host, t.Host) {
		return true
	}
	// A cluster answers and originates from whichever node handles the
	// call, not only the one we registered to or send to. A call from an
	// untrusted source is challenged like an app's, which a PBX cannot
	// answer, so every node of the exchange has to be named here
	// (-pbx-peers) or its calls simply fail.
	for _, p := range peers {
		if p != "" && strings.EqualFold(host, p) {
			return true
		}
	}
	return false
}

// trunkBind parses the trunk listener address; an empty host is 0.0.0.0 and
// an empty address is port 5060 (5061 for a TLS trunk).
func trunkBind(addr string, t *pbx.Trunk) (string, int, error) {
	if addr == "" {
		port := 5060
		if strings.EqualFold(t.Transport, "tls") {
			// Not 5061, the conventional SIP/TLS port: that is the app
			// leg's, and the two transports would fight over the same
			// socket on any default configuration.
			port = 5062
		}
		return "0.0.0.0", port, nil
	}
	host, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		return "", 0, fmt.Errorf("b2bua: bad trunk bind %q: %w", addr, err)
	}
	if host == "" {
		host = "0.0.0.0"
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port <= 0 || port > 65535 {
		return "", 0, fmt.Errorf("b2bua: bad trunk bind port %q", portStr)
	}
	return host, port, nil
}

// firstIPv4 is this host's first non-loopback IPv4 address, the address a
// PBX on the same network reaches us at.
func firstIPv4() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return "127.0.0.1"
	}
	for _, a := range addrs {
		if ipn, ok := a.(*net.IPNet); ok && !ipn.IP.IsLoopback() && ipn.IP.To4() != nil {
			return ipn.IP.String()
		}
	}
	return "127.0.0.1"
}

func (s *Server) bridge(ctx context.Context, log *slog.Logger, in *diago.DialogServerSession, dst sip.Uri, callID string, l legs) error {
	// Order matters: the caller keeps ringing (180 already sent) until the
	// phone answers, and is answered (200) only then. Answering the caller
	// first — as diago's own bridge helper does — starts the caller's media
	// while the phone is still ringing; a few seconds of it are gone before
	// anyone hears it, and a human caller is "connected" to silence.
	//
	// The callee leg is offered the caller's codecs (Originator reads the
	// caller's INVITE SDP, which does not require it to be answered) and
	// symmetric RTP where the deployment wants it.
	out, err := s.dg.NewDialog(dst, diago.NewDialogOptions{TransportID: s.calleeTransport(l.calleeTrunk, in.FromUser())})
	if err != nil {
		log.Error("new callee dialog", "dst", dst.String(), "err", err)
		_ = in.Respond(500, "Server Internal Error", nil)
		return err
	}
	calleeNAT := s.legNAT(l.calleeTrunk)
	// The relay copies encoded audio between the legs without transcoding, so
	// both legs must settle on the same codec. A PBX trunk speaks G.722 and
	// G.711. Constrain the callee's offer to the trunk set whenever EITHER
	// leg is the trunk, not just when the callee is: an app callee reached
	// from a trunk caller, left with its full set, negotiates Opus, which the
	// trunk caller then cannot be answered with — silence in both directions.
	// A call that touches the trunk is therefore G.722 (or G.711) end to end
	// (app↔app, neither trunk, keeps the full set with Opus first). The
	// Originator below intersects this set with the caller's offer, keeping
	// every common codec so the far end can still fall back (vendored patch).
	if callTouchesTrunk(l) {
		out.SetCodecs(s.cfg.trunkCodecs())
	}
	from := in.InviteRequest.From()
	legA := &callLeg{name: "caller", trunk: l.callerTrunk, sess: in, party: wire.Party{DisplayName: from.DisplayName, URI: from.Address.String()}}
	legB := &callLeg{name: "callee", trunk: l.calleeTrunk, sess: out, party: wire.Party{URI: dst.String()}}
	call := newBridgedCall(s, log, callID, legA, legB)
	s.live.trackBridged(call)
	defer s.live.untrackBridged(callID)
	// Hold has no message of its own: a party holds by re-INVITEing its own
	// leg to sendonly, and all we ever see is the direction we settled on.
	// Watch both legs for it, so hold music follows whichever party pressed
	// hold (SPEC §4.4 rule 8b).
	onMedia := func(leg *callLeg) func(*diago.DialogMedia) {
		return func(m *diago.DialogMedia) {
			if ms := m.MediaSession(); ms != nil {
				call.setHeld(leg, heldMode(ms.NegotiatedMode()))
			}
		}
	}

	// Abandoning a registered callee's INVITE early. Three things end it
	// before the callee answers: the caller hangs up (ctx), the callee moves
	// — a phone changing Wi-Fi network registers again from its new address
	// within a second, and the INVITE sent to the old route can only run
	// into Timer B — and a decline wake_ack (the app refused the call on its
	// wake before the INVITE reached it). sipgo will not CANCEL an INVITE
	// that has had no response: it waits for the transaction to time out
	// (32 s) first. Over TLS a live phone answers within milliseconds, so a
	// route with no response is dead and the wait only delays the
	// wake_cancel — on 2026-09-13 the app rang for callers who had hung up
	// 20–30 s earlier. So with no response yet the INVITE is abandoned at
	// once (sipgo's forced cancel); with one, the normal CANCEL/487
	// exchange runs and returns quickly.
	inviteCtx := ctx
	inviteDone := make(chan struct{}) // closed once out.Invite has returned
	retargeted := make(chan registry.Endpoint, 1)
	var (
		answered  atomic.Bool // any response from the callee's route
		abandonMu sync.Mutex
		abandoned error // why we gave up, if we did
	)
	// Installed for every callee, trunk included: an 18x from the callee is
	// what makes the caller's 180 true, and a call that fails before one
	// must reach the caller as a failure and nothing else, so the app plays
	// congestion instead of ring-back (SPEC §4.4 rule 8a). 183 is forwarded
	// as 180: we cannot pass early media through without answering the
	// caller, so the caller generates its own ring-back either way.
	onResp := func(res *sip.Response) error {
		answered.Store(true)
		// The callee's answer: how long its RTP may have been queuing
		// before the pumps start (pump answer_to_pump_ms).
		if res != nil && res.StatusCode >= 200 && res.StatusCode < 300 && legB.answeredAt.IsZero() {
			legB.answeredAt = time.Now()
		}
		if l.calleeTrunk {
			// Any response from the exchange, 100 Trying included, is the
			// exchange being reachable (lines.go, registrarSeen).
			s.registrarSeen()
		}
		if res != nil && res.StatusCode >= 180 && res.StatusCode < 200 && l.ring != nil {
			l.ring()
		}
		return nil
	}
	if l.calleeTrunk && reliableTransport(s.cfg.Trunk.Transport) {
		// A pooled TCP/TLS connection to the PBX can be dead without
		// anything having said so: after a network interruption on either
		// side the socket stays open here while its packets go nowhere, and
		// TCP takes a minute or two to notice. Every outbound trunk call in
		// that window sat on it until Timer B (32 s), and the INVITE,
		// delivered a minute late, rang the PBX phone after the caller had
		// gone (2026-09-19 13:09). A live PBX answers an INVITE with 100
		// Trying within milliseconds, so no response at all for
		// trunkResponseTimeout is proof the connection is defunct: the
		// INVITE is dropped outright (a CANCEL would go the same way) and
		// the connection closed, which also discards the unsent INVITE;
		// serveDialog then redials once on a fresh connection. UDP pools
		// nothing and has its own retransmissions, so it is left to Timer B.
		ictx, cancelInvite := context.WithCancelCause(ctx)
		inviteCtx = ictx
		go func() {
			select {
			case <-inviteDone:
			case <-ictx.Done():
			case <-time.After(trunkResponseTimeout):
				if answered.Load() {
					return
				}
				abandonMu.Lock()
				if abandoned == nil {
					abandoned = errTrunkUnresponsive
				}
				abandonMu.Unlock()
				cancelInvite(sipgo.WaitAnswerForceCancelErr)
			}
		}()
	}
	if l.calleeUser != "" {
		ictx, cancelInvite := context.WithCancelCause(context.Background())
		inviteCtx = ictx
		abandon := func(reason error) {
			abandonMu.Lock()
			if abandoned == nil {
				abandoned = reason
			}
			abandonMu.Unlock()
			if answered.Load() {
				cancelInvite(reason)
			} else {
				cancelInvite(sipgo.WaitAnswerForceCancelErr)
			}
		}
		stopParent := context.AfterFunc(ctx, func() { abandon(context.Cause(ctx)) })
		s.trackWait(callID, func(cause error) {
			if cause == nil {
				return
			}
			if cause == errWakeDeclined || cause == errWakeBusy {
				// The app answers on both channels in the same breath: this
				// ack on the gateway, and its own final on the INVITE (486 for
				// a decline; the hang-up it does on a Focus/DND filter). A
				// CANCEL sent now would cross that final — the app answers the
				// CANCEL 481 — so hold it: let the final land, and force the
				// CANCEL only if it never comes (the app died after the ack).
				//
				// For a system busy, also record the cause now so the caller's
				// response is decided by errWakeBusy (ring through to 480 at
				// the timeout), not by the app's simultaneous 486 relayed as a
				// fast rejection. A decline leaves the cause unset, so the
				// app's own 486 reaches the caller unchanged (callerStatus).
				if cause == errWakeBusy {
					abandonMu.Lock()
					if abandoned == nil {
						abandoned = cause
					}
					abandonMu.Unlock()
				}
				go func() {
					select {
					case <-inviteDone:
					case <-time.After(declineGrace):
						abandon(cause)
					}
				}()
				return
			}
			abandon(cause)
		})
		// If the callee's connection dies while its INVITE is out (the app
		// suspended after a Focus/DND filter, say), the caller is NOT failed
		// fast: it rings on to the ring timeout like any unreachable phone
		// (see the note by errWakeBusy). The one way the call still completes
		// is the app coming back on a NEW connection — that arrives as a
		// fresh REGISTER, which this watch turns into a new INVITE.
		wctx, stopWatch := context.WithCancel(ictx)
		go func() {
			if ep, err := s.reg.WaitRouteChange(wctx, l.calleeUser, l.calleeRoute); err == nil {
				retargeted <- ep
				abandon(errRetarget)
			}
		}()
		defer func() {
			stopParent()
			stopWatch()
			s.untrackWait(callID)
		}()
	}
	// Lines mode sends this call out as the calling device's own registered
	// line; trunk mode adds nothing and the INVITE is built as it always
	// has been.
	headers, digestUser, digestSecret, identified := s.calleeInvite(callID, l.calleeTrunk, in.FromUser())
	if !identified {
		log.Warn("invite: no PBX line for the caller and no default line; refusing", "caller", in.FromUser())
		_ = in.Respond(403, "Forbidden", nil)
		out.Close()
		return errors.New("no pbx line for the caller")
	}
	err = out.Invite(inviteCtx, diago.InviteClientOptions{
		Originator: in,
		Headers:    headers,
		Username:   digestUser,
		Password:   digestSecret,
		OnResponse: onResp,
		OnMediaUpdate: func(m *diago.DialogMedia) {
			m.MediaSession().RTPNAT = calleeNAT
			onMedia(legB)(m)
		},
		OnRefer: call.onRefer(legB),
	})
	close(inviteDone)
	if err != nil {
		abandonMu.Lock()
		why := abandoned
		abandonMu.Unlock()
		switch why {
		case errRetarget:
			ep := <-retargeted
			log.Info("invite callee: callee re-registered while ringing; re-targeting", "old", dst.String(), "new", ep.Contact)
			_ = out.Hangup(out.Context())
			out.Close()
			return &retargetError{ep: ep}
		case errWakeDeclined:
			// The user actively declined while the INVITE was out. 486 so
			// the PBX applies its busy rule.
			log.Info("invite callee: user declined on the wake before the INVITE was answered", "cause", why)
			_ = out.Hangup(out.Context())
			out.Close()
			if in.Context().Err() == nil {
				_ = in.Respond(486, "Busy Here", nil)
			}
			return why
		case errWakeBusy:
			// The device filtered the call itself (Focus / Sleep / DND): it
			// was alerted but the system suppressed the ring, so nobody will
			// answer. Not a rejection — the caller keeps the ringback it
			// already has until the ring timeout (or it gives up), then 480,
			// exactly as when any woken device never answers. Industry "DND
			// rings through"; a user decline (above) is the only fast 486.
			log.Info("invite callee: device filtered the call (Focus/DND); ringing to the timeout", "cause", why)
			_ = out.Hangup(out.Context())
			out.Close()
			<-ctx.Done() // the ring timeout, or the caller giving up
			if in.Context().Err() == nil {
				_ = in.Respond(480, "Temporarily Unavailable", nil)
			}
			return why
		case errTrunkUnresponsive:
			// Nothing to CANCEL: the transaction was terminated by the
			// forced cancel, and a CANCEL would go down the same dead
			// connection. Drop that connection so the redial (serveDialog)
			// opens a fresh one; the caller is answered there, not here.
			log.Warn("invite callee: no response from the trunk; its connection is dead", "dst", dst.String(), "after", trunkResponseTimeout)
			out.Close()
			s.dropTrunkConnection(log)
			return why
		}
		log.Error("invite callee", "dst", dst.String(), "offered", codecNames(out.Media().MediaSession()), "err", err)
		if l.calleeTrunk && exchangeSaysUnregistered(err) {
			// CUCM's "Unable to find a device handler": the line this call
			// went out on is not registered there, whatever we believe.
			s.lineUnregistered(in.FromUser())
		}
		_ = out.Hangup(out.Context())
		out.Close()
		if in.Context().Err() == nil {
			// The caller is still ringing, so tell it what happened: a
			// refusal by the callee (486/600/603) is relayed as-is so the
			// PBX applies its busy rule; anything else is 480. A cancelled
			// caller is already answered (487) by the stack.
			code, reason := callerStatus(err)
			_ = in.Respond(code, reason, nil)
		}
		return err
	}
	// The callee answered: answer the caller now with the codec the callee
	// took (the relay copies encoded audio, so the legs must match), then
	// complete the callee.
	negotiated := media.CodecAudioFromSession(out.Media().MediaSession())
	log.Info("callee answered", "codec", negotiated.Name, "callee_trunk", l.calleeTrunk, "caller_trunk", l.callerTrunk,
		"callee_srtp", srtpState(out.Media().MediaSession()))
	// A PBX that answered our RTP/SAVP offer without usable crypto would
	// carry this call unencrypted — or, worse, be unable to decrypt what we
	// send. Fail it rather than bridge it.
	if err := s.requireTrunkSRTP(l.calleeTrunk, out.Media().MediaSession()); err != nil {
		log.Error("callee leg would not secure the media", "err", err)
		_ = out.Hangup(out.Context())
		out.Close()
		if in.Context().Err() == nil {
			_ = in.Respond(488, "Not Acceptable Here", nil)
		}
		return err
	}
	legA.codec, legB.codec = negotiated, negotiated
	// With an early offer the caller is answered with the callee's codec
	// alone: it is one the caller offered, so it cannot refuse. With a
	// delayed offer the caller answers OUR offer in its ACK, and an offer
	// of that one codec is too narrow for an exchange: CUCM, asked for
	// G.722 alone, answered with an ACK carrying no SDP and a BYE a few
	// milliseconds later (lines bench 2026-10-17 10:53), while the same
	// cluster takes PCMU from a G.722-first list. So the late offer is the
	// whole PBX set with the callee's codec first; if the exchange picks
	// another, the callee is moved onto it by re-INVITE below — the same
	// move a transfer makes (renegotiateCodec) — so the relay still never
	// transcodes.
	delayed := delayedOffer(in.InviteRequest)
	answerCodecs := []media.Codec{negotiated}
	if delayed {
		// The PBX set already ends in telephone-event.
		answerCodecs = lateOfferCodecs(negotiated, s.cfg.trunkCodecs())
	} else if ev, ok := telephoneEventOffered(in.InviteRequest.Body()); ok {
		// An early offer is answered with the callee's codec and, when the
		// caller offered one, its telephone-event at the caller's payload
		// type, so digits from this leg arrive as events.
		answerCodecs = append(answerCodecs, ev)
	}
	legA.answeredAt = time.Now() // our 200 OK goes out now; AnswerOptions returns on its ACK
	if err := in.AnswerOptions(diago.AnswerOptions{RTPNAT: s.legNAT(l.callerTrunk), Codecs: answerCodecs,
		OnRefer: call.onRefer(legA), OnMediaUpdate: onMedia(legA)}); err != nil {
		log.Error("answer caller", "err", err)
		_ = out.Hangup(out.Context())
		out.Close()
		return err
	}
	// Same rule the other way round, and only now: a leg's session is not
	// secure until BOTH crypto contexts exist, and ours is created when we
	// answer — so asking at INVITE time calls every inbound call insecure,
	// encrypted ones included (2026-09-16).
	if err := s.requireTrunkSRTP(l.callerTrunk, in.Media().MediaSession()); err != nil {
		log.Error("caller leg would not secure the media", "err", err)
		out.Close()
		_ = in.Hangup(in.Context())
		return err
	}
	if err := out.Ack(ctx); err != nil {
		log.Error("ack callee", "err", err)
		out.Close()
		_ = in.Hangup(in.Context())
		return err
	}
	defer out.Close()
	// The late offer's answer: if the exchange took a codec other than the
	// callee's, move the callee onto it now that its dialog is confirmed.
	// A callee that will not move leaves two legs on different codecs,
	// which the copy-relay cannot bridge, so that ends the call.
	if delayed {
		if got := media.CodecAudioFromSession(in.Media().MediaSession()); !sameCodec(got, negotiated) {
			log.Info("late offer: the caller took another codec; moving the callee to it", "callee_had", negotiated.Name, "caller_took", got.Name)
			if err := renegotiateCodec(ctx, legB, got); err != nil {
				log.Error("late offer: the callee would not move to the caller's codec; no audio is possible", "codec", got.Name, "err", err)
				_ = out.Hangup(out.Context())
				_ = in.Hangup(in.Context())
				return fmt.Errorf("late offer answered with %s and the callee would not move: %w", got.Name, err)
			}
			legA.codec, legB.codec = got, got
		}
	}
	if s.cfg.LabPumpDelay > 0 {
		log.Warn("lab: holding the pumps back after the ACK", "delay", s.cfg.LabPumpDelay)
		time.Sleep(s.cfg.LabPumpDelay)
	}
	log.Info("bridged", "dst", dst.String(), "codec", legA.codec.Name, "caller_srtp", srtpState(in.Media().MediaSession()), "callee_srtp", srtpState(out.Media().MediaSession()))

	// Media relay: our own pumps rather than diago's Bridge, so every leg
	// reports what it read and wrote — a phone that receives nothing while
	// "phone<-caller" keeps writing is the network eating packets, not us.
	// The bridged call also handles REFER (transfer) by swapping a leg.
	if err := call.start(); err != nil {
		log.Error("relay", "err", err)
		_ = out.Hangup(out.Context())
		_ = in.Hangup(in.Context())
		s.callEvent(call, false, "failed")
		return err
	}
	s.callEvent(call, true, "")
	call.wait()
	reason := "bye"
	select {
	case <-call.gone:
		reason = "peer_gone"
	default:
	}
	s.callEvent(call, false, reason)
	return nil
}

// callEvent tells Config.OnCall, if set, that a call was bridged or ended.
func (s *Server) callEvent(c *bridgedCall, started bool, reason string) {
	if s.cfg.OnCall == nil {
		return
	}
	c.mu.Lock()
	var a, b string
	if c.a != nil {
		a = c.a.party.URI
	}
	if c.b != nil {
		b = c.b.party.URI
	}
	c.mu.Unlock()
	s.cfg.OnCall(c.callID, started, a, b, reason)
}

// pump moves encoded audio one way between two legs and counts it.
// pumpTimelineBreak is how far a source's timestamps may part from its
// packets' arrival, between one packet and the next, before the relay
// rebases them (pump.forward). Normal skew here is tens of ms, a burst
// after a stall a few hundred; a hold/resume that breaks the timeline is
// seconds. Two seconds is also the longest network stall worth carrying
// as delay rather than restarting the far end's buffer over.
const pumpTimelineBreak = 2 * time.Second

// pumpFrozenBreak is how much timeline a source may fail to produce while
// its packets keep arriving on time before the relay stops copying its
// timestamps and paces them itself (pump.forward). A step of 20 ms per
// packet is under any per-packet limit, so a clock that freezes or slows
// is invisible to pumpTimelineBreak: the PBX sent 94 packets on one
// timestamp after a desk phone's resume (2026-09-27 08:02), the app's
// playout buffer, which counts frames by timestamp, never had one to play,
// and dropped the lot. Ten frames is far beyond jitter and well short of
// what a listener notices.
const pumpFrozenBreak = 200 * time.Millisecond

// declineGrace is how long a decline or busy wake_ack waits for the app's
// own 486 on the INVITE before the server CANCELs it itself (bridge). The
// 486 normally lands within a few ms of the ack, on another connection.
const declineGrace = 500 * time.Millisecond

type pump struct {
	r          io.Reader
	w          io.Writer
	read       atomic.Int64 // frames read from the source leg
	written    atomic.Int64 // frames written to the destination leg
	writeErrs  atomic.Int64
	lastReadAt atomic.Int64 // unix ms of the last successful read

	// Packet path (nil = byte copy through io.Writer); see forward.
	rr    *media.RTPPacketReader
	rw    *media.RTPPacketWriter
	codec media.Codec // destination: payload type and RTP clock
	// RFC 4733 telephone-event (DTMF) on each leg, as negotiated: the
	// payload type a digit arrives under from the source and the one the
	// destination expects. A digit is an event packet, not audio: it is
	// forwarded under the destination's event type and kept out of the
	// audio timeline heuristics below (its packets repeat one timestamp
	// for the length of the key press, which the frozen-clock detector
	// would read as a stall). With no event type on the destination the
	// digit is dropped rather than sent as audio under the audio type,
	// which is what happened before 2026-10-17: a burst of noise.
	srcEvent, dstEvent       uint8
	hasSrcEvent, hasDstEvent bool
	events                   atomic.Int64 // event packets forwarded
	eventsDropped            atomic.Int64 // event packets with nowhere to go
	// Guards the outbound timeline below. The relay goroutine had it to
	// itself until hold music arrived (rule 8b): that plays from a ticker
	// on another goroutine and must continue the same sequence numbers and
	// timestamps, so the two share a lock. Uncontended in practice — a leg
	// that is holding sends nothing to relay.
	mu sync.Mutex
	// Source timeline → ours.
	haveSrc  bool
	srcSSRC  uint32
	tsOffset uint32
	wroteAny bool
	lastOut  uint32
	t0       time.Time
	ts0      uint32
	// Sequence numbers are rebased like timestamps (source seq + offset),
	// never regenerated: a packet the source lost stays missing on the
	// way out, so the far end's jitter buffer and concealment see the loss
	// instead of a seamless stream with a hole in the timeline.
	seqOffset uint16
	lastSeq   uint16
	// Audio of our own went out on this stream (hold music), so the
	// relayed source's offsets no longer describe where we are: the next
	// relayed packet has to be rebased onto the numbering the music left
	// behind. See forward.
	localWrote bool
	// Set while our own audio owns this stream (hold music). Relayed
	// packets are dropped rather than forwarded for as long as it is: two
	// sources interleaved on one stream is noise, and during a transfer the
	// party being replaced is still sending.
	localOnly atomic.Bool
	// How far the source's timestamps may part from its packets' arrival,
	// between one packet and the next, before the relay stops trusting its
	// timeline and starts a fresh one (see forward). Zero = pumpTimelineBreak.
	timelineBreak time.Duration
	breaks        atomic.Int64 // timeline breaks rebased so far
	lastBreakMs   atomic.Int64 // size of the last one, signed
	// Timeline the source has failed to produce while its packets kept
	// arriving on time — a clock that froze or slowed. Reset as soon as
	// the timestamps keep up again. Beyond frozenBreak (zero =
	// pumpFrozenBreak) the relay paces the packets itself, one frame each,
	// until the source's clock moves again; `frozen` marks that episode
	// so it is counted once. See forward.
	lag         time.Duration
	frozen      bool
	frozenBreak time.Duration
	// Arrival skew of the source against its own timeline, for the log.
	skewMs     atomic.Int64
	earlyMaxMs atomic.Int64
	lateMaxMs  atomic.Int64
	// Loss, reordering and interarrival jitter as seen from the source's
	// sequence numbers and timing (RFC 3550 §6.4.1), so a lossy leg can be
	// placed without RTCP. Written by the relay goroutine only.
	expectSeq   uint16
	lost        atomic.Int64
	reordered   atomic.Int64
	jitter      float64 // RTP ticks, running estimate
	jitterMs100 atomic.Int64
	lastArrival time.Time
	lastTs      uint32
	// Arrival continuity of the source — backlog at start, bursts and gaps
	// per window — and the optional per-packet trace (pump_continuity.go).
	cont       continuity
	answeredAt time.Time // when the source leg was answered; zero = unknown
	traceDir   string    // Config.RTPTraceDir; empty = no trace
	traceName  string    // file stem under traceDir
	trace      *pumpTrace
}

type mediaEnd interface {
	AudioReader(...diago.AudioReaderOption) (io.Reader, error)
	AudioWriter(...diago.AudioWriterOption) (io.Writer, error)
	MediaSession() *media.MediaSession
}

func newPump(from, to mediaEnd) (*pump, error) {
	r, err := from.AudioReader()
	if err != nil {
		return nil, err
	}
	w, err := to.AudioWriter()
	if err != nil {
		return nil, err
	}
	p := &pump{r: r, w: w}
	// Packet-level forwarding needs the RTP reader and writer themselves
	// (for the headers) and the destination's codec; anything else falls
	// back to the byte copy through io.Writer.
	rr, okR := r.(*media.RTPPacketReader)
	rw, okW := w.(*media.RTPPacketWriter)
	if okR && okW {
		if ms := to.MediaSession(); ms != nil {
			p.setPacketPath(rr, rw, media.CodecAudioFromSession(ms))
			p.dstEvent, p.hasDstEvent = telephoneEventPT(ms)
		}
		p.srcEvent, p.hasSrcEvent = telephoneEventPT(from.MediaSession())
	}
	return p, nil
}

// telephoneEventPT is the payload type a leg negotiated for RFC 4733
// telephone-event, if it negotiated one.
func telephoneEventPT(ms *media.MediaSession) (uint8, bool) {
	if ms == nil {
		return 0, false
	}
	list := ms.CommonCodecs()
	if len(list) == 0 {
		list = ms.Codecs
	}
	for _, c := range list {
		if c.Name == "telephone-event" {
			return c.PayloadType, true
		}
	}
	return 0, false
}

func (p *pump) setPacketPath(rr *media.RTPPacketReader, rw *media.RTPPacketWriter, dst media.Codec) {
	p.rr, p.rw, p.codec = rr, rw, dst
}

func (p *pump) String() string {
	s := fmt.Sprintf("read=%d written=%d write_errs=%d lost=%d reordered=%d jitter_ms=%.1f early_max_ms=%d late_max_ms=%d",
		p.read.Load(), p.written.Load(), p.writeErrs.Load(), p.lost.Load(), p.reordered.Load(), p.jitterMs(),
		p.earlyMaxMs.Load(), p.lateMaxMs.Load())
	if ev, dropped := p.events.Load(), p.eventsDropped.Load(); ev > 0 || dropped > 0 {
		s += fmt.Sprintf(" events=%d events_dropped=%d", ev, dropped)
	}
	return s + " " + p.cont.summary()
}

func (p *pump) jitterMs() float64 { return float64(p.jitterMs100.Load()) / 100 }

// forward sends one payload to the destination leg at once, carrying the
// source packet's own timing.
//
// The library's io.Writer path stamps packets with its own clock and then
// BLOCKS for one packet time (20 ms) per write: it is a player's pacer, and
// a relay built on it can never forward faster than the nominal rate. Any
// packets that queue behind it — the ones that arrived before the relay
// started, or a burst after a network stall — are forwarded at exactly the
// rate new ones arrive, so the queue never drains and every burst becomes
// permanent delay for the rest of the call (the "audio 0–2 s late, varying
// per call" symptom on the app). WriteSamples has no clock; we write
// immediately and force each timestamp to the source's, rebased onto our
// stream, so silence gaps stay gaps and the far end's jitter buffer deals
// with the bursts, as it is designed to.
func (p *pump) forward(payload []byte) error {
	if p.rr == nil {
		_, err := p.w.Write(payload)
		return err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	hdr := p.rr.PacketHeader
	now := time.Now()
	if p.hasSrcEvent && hdr.PayloadType == p.srcEvent {
		return p.forwardEvent(hdr, payload, now)
	}
	// A source we have already seen still needs rebasing if hold music has
	// been on this stream since: `writeLocal` moved our sequence numbers
	// and timestamps forward and the source knows nothing about it, so
	// continuing on its old offsets sends the far end BACKWARDS by the
	// length of the music — every packet then arrives stale and its jitter
	// buffer drops the lot. On a device that was the caller's microphone
	// vanishing after resume, with the relay counters still rising
	// (2026-09-15).
	newStream := !p.haveSrc || hdr.SSRC != p.srcSSRC || p.localWrote
	// A source whose timeline has parted from real time is also a new
	// stream. Within one SSRC the timestamps are trusted only while they
	// advance with the packets' arrival; when the two disagree by more than
	// timelineBreak between one packet and the next — a timestamp jumping
	// ahead or BACK, or freezing while packets keep coming — the far end
	// must not see it. A desk phone's hold/resume on the PBX did exactly
	// that (2026-09-18 08:45: 31 s backwards in one step, same SSRC,
	// packets every 20 ms throughout); forwarded verbatim, the app's
	// playout buffer, which orders by timestamp, dropped every later frame
	// as old and the call was silent to its end. An honest gap — no packets
	// for a while, timestamps that then account for it — keeps arrival and
	// timeline together and passes untouched.
	if !newStream {
		// The source's clock is taken to be the destination codec's: the
		// relay forwards payloads verbatim, so both legs share a codec. A
		// transcoding path would have to measure tsGap in the SOURCE clock.
		arrivalGap := now.Sub(p.lastArrival)
		tsTicks := int32(hdr.Timestamp - p.lastTs)
		tsGap := time.Duration(tsTicks) * time.Second / time.Duration(p.codec.SampleRate)
		limit := p.timelineBreak
		if limit == 0 {
			limit = pumpTimelineBreak
		}
		diff := tsGap - arrivalGap
		// Forward or frozen: only beyond the limit, to stay clear of bursts
		// and stalls. Backwards while the sequence number went forwards:
		// never legitimate within one SSRC (a reordered packet moves both
		// back together), and even a small step back costs the far end the
		// same drop for its length — so any step back of more than a
		// frame's slack rebases, however short.
		// (expectSeq is one past the highest sequence number seen, so this
		// is "beyond everything so far", which a reordered packet is not.)
		back := tsTicks < -int32(p.codec.SampleTimestamp()) && int16(hdr.SequenceNumber+1-p.expectSeq) > 0
		if diff > limit || diff < -limit || back {
			newStream = true
			p.breaks.Add(1)
			p.lastBreakMs.Store(diff.Milliseconds())
		} else {
			// A clock that freezes or slows loses ground by less than a
			// frame per packet, under any per-packet limit, and the far
			// end's playout buffer counts frames by timestamp: 94 packets
			// on one timestamp were 94 packets it never played
			// (2026-09-27 08:02, the PBX after a desk phone's resume).
			// Ground lost while packets arrive on time adds up; a stall
			// (judged by diff above) does not count, and a timestamp that
			// keeps up again clears it. Past pumpFrozenBreak the relay
			// paces each packet one frame after the last it sent — no
			// marker, one break per episode — until the source's clock
			// moves again, from where our timeline then carries on.
			frame := time.Duration(p.codec.SampleTimestamp()) * time.Second / time.Duration(p.codec.SampleRate)
			switch {
			case arrivalGap >= 2*frame:
			case diff < -frame/4:
				p.lag -= diff
			default:
				p.lag = 0
			}
			flimit := p.frozenBreak
			if flimit == 0 {
				flimit = pumpFrozenBreak
			}
			if p.lag > flimit {
				if !p.frozen {
					p.frozen = true
					p.breaks.Add(1)
					p.lastBreakMs.Store(-p.lag.Milliseconds())
				}
				p.tsOffset = p.lastOut + p.codec.SampleTimestamp() - hdr.Timestamp
			} else {
				p.frozen = false
			}
		}
	}
	if newStream {
		p.startStream(hdr, now)
	} else {
		// Arrival skew against the source's own timeline since its first
		// packet: negative = early (a burst / backlog draining), positive =
		// late (a stall). Both are what the far end's jitter buffer absorbs.
		elapsed := now.Sub(p.t0)
		expected := time.Duration(hdr.Timestamp-p.ts0) * time.Second / time.Duration(p.codec.SampleRate)
		skew := (elapsed - expected).Milliseconds()
		p.skewMs.Store(skew)
		if -skew > p.earlyMaxMs.Load() {
			p.earlyMaxMs.Store(-skew)
		}
		if skew > p.lateMaxMs.Load() {
			p.lateMaxMs.Store(skew)
		}
		p.accountSeq(hdr.SequenceNumber)
		// Interarrival jitter (RFC 3550 §6.4.1): the running mean of how far
		// the arrival spacing strays from the timestamp spacing, in RTP ticks.
		arrival := now.Sub(p.lastArrival).Seconds() * float64(p.codec.SampleRate)
		d := arrival - float64(int32(hdr.Timestamp-p.lastTs))
		if d < 0 {
			d = -d
		}
		p.jitter += (d - p.jitter) / 16
		p.jitterMs100.Store(int64(p.jitter * 100000 / float64(p.codec.SampleRate)))
		p.lastArrival, p.lastTs = now, hdr.Timestamp
	}
	// The writer's next timestamp is where it left off (we never let it
	// advance on its own); move it to where this packet belongs.
	want := hdr.Timestamp + p.tsOffset
	cur := p.rw.InitTimestamp()
	if p.wroteAny {
		cur = p.lastOut
	}
	p.rw.DelayTimestamp(want - cur)
	seq := hdr.SequenceNumber + p.seqOffset
	_, err := p.rw.WriteSamplesSeq(payload, 0, hdr.Marker || newStream, p.codec.PayloadType, seq)
	if err == nil {
		// Highest so far, wraparound-safe: a reordered packet must not
		// pull the continuation point backwards.
		if !p.wroteAny || int16(seq-p.lastSeq) > 0 {
			p.lastSeq = seq
		}
		p.lastOut, p.wroteAny = want, true
	}
	return err
}

// startStream rebases a source's timeline onto ours, continuing right after
// what we last sent so the far end sees one monotonic stream. "What we last
// sent" is what matters, not whether THIS pump has seen a source: a pump
// that replaced another on the same leg (transfer) inherited its
// predecessor's numbering and must carry it on, or the far end sees the
// stream jump.
func (p *pump) startStream(hdr rtp.Header, now time.Time) {
	start := p.rw.InitTimestamp()
	if p.wroteAny {
		start = p.lastOut + p.codec.SampleTimestamp()
	}
	p.tsOffset = start - hdr.Timestamp
	p.rebaseSeq(hdr.SequenceNumber)
	p.srcSSRC, p.haveSrc, p.localWrote = hdr.SSRC, true, false
	p.t0, p.ts0 = now, hdr.Timestamp
	p.expectSeq = hdr.SequenceNumber + 1
	p.lastArrival, p.lastTs = now, hdr.Timestamp
	p.lag, p.frozen = 0, false
}

// accountSeq keeps the loss and reordering counters (wraparound-safe): a
// jump forward is loss, a small step back is a reordered packet that was
// counted lost a moment ago, a large one is the source renumbering its
// stream.
func (p *pump) accountSeq(seq uint16) {
	switch diff := int16(seq - p.expectSeq); {
	case diff == 0:
		p.expectSeq++
	case diff > 0:
		p.lost.Add(int64(diff))
		p.expectSeq = seq + 1
	case diff > -64:
		p.reordered.Add(1)
		if p.lost.Load() > 0 {
			p.lost.Add(-1)
		}
	default:
		// The source renumbered its stream (a phone restarting its
		// sender): continue ours from where it was.
		p.expectSeq = seq + 1
		p.rebaseSeq(seq)
	}
}

// forwardEvent relays one RFC 4733 telephone-event packet — a DTMF digit,
// or the end of one — under the destination's event payload type. It is in
// the source's RTP sequence and timeline and is rebased exactly as audio
// is, but it does not feed the audio clock heuristics: every packet of a
// key press carries the timestamp the press started at, which is a
// frozen clock to the detector in forward and must not be rebased away.
// A digit with no event type on the far leg has nowhere to go and is
// dropped; it is not sent as audio.
func (p *pump) forwardEvent(hdr rtp.Header, payload []byte, now time.Time) error {
	if !p.hasDstEvent {
		p.eventsDropped.Add(1)
		return nil
	}
	if !p.haveSrc || hdr.SSRC != p.srcSSRC || p.localWrote {
		p.startStream(hdr, now)
	} else {
		p.accountSeq(hdr.SequenceNumber)
	}
	want := hdr.Timestamp + p.tsOffset
	cur := p.rw.InitTimestamp()
	if p.wroteAny {
		cur = p.lastOut
	}
	p.rw.DelayTimestamp(want - cur)
	seq := hdr.SequenceNumber + p.seqOffset
	_, err := p.rw.WriteSamplesSeq(payload, 0, hdr.Marker, p.dstEvent, seq)
	if err == nil {
		p.events.Add(1)
		if !p.wroteAny || int16(seq-p.lastSeq) > 0 {
			p.lastSeq = seq
		}
		// The writer now stands at this timestamp; the next packet, audio
		// or event, moves it from here.
		p.lastOut, p.wroteAny = want, true
	}
	return err
}

// writeLocal puts one frame of our own audio on this pump's stream, in
// place of a relayed packet (hold music, rule 8b). Everything the far end
// uses to recognise the stream is unchanged — SSRC, payload type and the
// leg's SRTP context all belong to the writer — and the sequence number and
// timestamp continue from the last packet we sent, so its jitter buffer
// sees the audio simply carry on rather than a new stream starting.
func (p *pump) writeLocal(payload []byte, marker bool) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	want, cur, seq := p.rw.InitTimestamp(), p.rw.InitTimestamp(), uint16(rand.Uint32())
	if p.wroteAny {
		want = p.lastOut + p.codec.SampleTimestamp()
		cur = p.lastOut
		seq = p.lastSeq + 1
	}
	p.rw.DelayTimestamp(want - cur)
	if _, err := p.rw.WriteSamplesSeq(payload, 0, marker, p.codec.PayloadType, seq); err != nil {
		return err
	}
	p.lastSeq, p.lastOut, p.wroteAny, p.localWrote = seq, want, true, true
	return nil
}

// inheritTimeline continues this pump's outbound numbering from prev, a
// pump that wrote to the same leg before it and has been stopped. A
// transfer replaces every pump, but the leg that stays keeps its RTP
// stream — same SSRC, same SRTP context at the far end — and a new pump
// starting at a random sequence number (rebaseSeq, a stream's first
// packet) made that stream jump. Plain RTP shrugs; SRTP does not: a jump
// backwards is a replay to libsrtp, a large one a wrong rollover counter,
// and every packet is dropped unheard — the PBX's echo test went silent
// both ways after a transfer on the LAN, on an SRTP trunk only, on
// whichever side of the coin the random start fell (2026-09-17 18:25).
func (p *pump) inheritTimeline(prev *pump) {
	if prev == nil || prev == p || p.rw == nil || prev.rw != p.rw {
		return
	}
	prev.mu.Lock()
	lastSeq, lastOut, wrote := prev.lastSeq, prev.lastOut, prev.wroteAny
	prev.mu.Unlock()
	if !wrote {
		return
	}
	p.mu.Lock()
	p.lastSeq, p.lastOut, p.wroteAny = lastSeq, lastOut, true
	p.mu.Unlock()
}

// playHold loops frames onto this pump's destination leg until ctx ends.
//
// The cadence is ours now: with the other party holding, nothing arrives to
// pace us, so frames go out on a ticker against a monotonic deadline rather
// than "20 ms after the last one" — the latter drifts, and a drifting
// sender is what a jitter buffer reports as jitter.
func (p *pump) playHold(ctx context.Context, frames [][]byte, log *slog.Logger) {
	const frameDur = 20 * time.Millisecond
	p.localOnly.Store(true)
	defer p.localOnly.Store(false)
	t := time.NewTicker(frameDur)
	defer t.Stop()
	start, sent, errs := time.Now(), 0, 0
	// Marker on the first frame: it tells the far end this is a new talk
	// spurt after a gap, which is exactly what it is.
	marker := true
	for {
		select {
		case <-ctx.Done():
			log.Info("stopped playing", "frames", sent, "seconds", time.Since(start).Seconds())
			return
		case <-t.C:
			if err := p.writeLocal(frames[sent%len(frames)], marker); err != nil {
				if errs++; errs <= 3 {
					log.Warn("hold music write failed", "err", err)
				}
			}
			marker = false
			sent++
		}
	}
}

// heldMode reports whether a leg's negotiated direction means the party on
// it has put the call on hold. They offer sendonly (or inactive) and we
// settle on its mirror, so what we see is that we may no longer send to
// them — and the party on the other leg is now hearing nothing.
func heldMode(mode string) bool {
	return mode == sdp.ModeRecvonly || mode == sdp.ModeInactive
}

// rebaseSeq maps a source stream starting at srcSeq onto our numbering:
// right after the last number we sent, or anywhere for the first packet.
func (p *pump) rebaseSeq(srcSeq uint16) {
	start := p.lastSeq + 1
	if !p.wroteAny {
		start = uint16(rand.Uint32())
	}
	p.seqOffset = start - srcSeq
}

// run relays until the source leg's reader ends (its session closed) or
// ctx is done, logging a counter line every 2 s so a silent leg can be
// placed: reads flat = nothing arriving from that leg; writes flat with
// reads rising = we stopped forwarding; both rising while the far end
// hears nothing = the packets leave us and are lost on the way.
func (p *pump) run(ctx context.Context, log *slog.Logger) {
	buf := make([]byte, media.RTPBufSize)
	var lastRead, lastWritten int64
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	p.cont.start(time.Now(), p.answeredAt)
	p.openTrace(log)
	done := make(chan struct{})
	go func() {
		defer close(done)
		// Closed here, not in run: run may return on ctx while this
		// goroutine is still in Read, and the last packet must not write
		// to a closed file.
		defer p.closeTrace()
		for {
			n, err := p.r.Read(buf)
			if ctx.Err() != nil {
				return // pumps replaced (transfer) or call over
			}
			if n > 0 {
				now := time.Now()
				p.read.Add(1)
				p.lastReadAt.Store(now.UnixMilli())
				var hdr *rtp.Header
				if p.rr != nil {
					hdr = &p.rr.PacketHeader
				}
				p.cont.noteRead(now, hdr, p.codec)
				if p.localOnly.Load() {
					// Hold music has this stream; what arrives is not
					// forwarded. Counted as read, not written — which is
					// what the 2 s line calls "we stopped forwarding".
					p.traceRead(now, hdr, n)
					continue
				}
				breaks := p.breaks.Load()
				if werr := p.forward(buf[:n]); werr != nil {
					if errors.Is(werr, net.ErrClosed) {
						// The destination leg's socket is gone: the call is
						// ending and this packet crossed the teardown. Not
						// an error, and nothing more can go this way.
						log.Info("relay destination closed", "after", p.String())
						return
					}
					if p.writeErrs.Add(1) <= 3 {
						log.Warn("relay write failed", "err", werr, "after", p.String())
					}
				} else {
					p.written.Add(1)
				}
				// After forward, so the line carries this packet's skew.
				p.traceRead(now, hdr, n)
				if p.breaks.Load() != breaks {
					log.Info("relay: source timeline broke within one SSRC; rebased onto ours",
						"jump_ms", p.lastBreakMs.Load(), "breaks", p.breaks.Load(), "after", p.String())
				}
			}
			if err != nil {
				if ne, ok := err.(net.Error); ok && ne.Timeout() {
					continue
				}
				if errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) {
					log.Info("relay source closed", "after", p.String())
				} else {
					// Any other error ends the relay for this direction: the
					// far end goes silent. Say so loudly.
					log.Error("RELAY STOPPED on read error", "err", err, "after", p.String())
				}
				return
			}
		}
	}()
	for {
		select {
		case <-done:
			return
		case <-ctx.Done():
			return
		case <-ticker.C:
			r, w := p.read.Load(), p.written.Load()
			win := p.cont.window()
			log.Info("relay", "read", r, "written", w, "write_errs", p.writeErrs.Load(),
				"read_2s", r-lastRead, "written_2s", w-lastWritten,
				"lost", p.lost.Load(), "reordered", p.reordered.Load(), "jitter_ms", p.jitterMs(),
				"skew_ms", p.skewMs.Load(), "early_max_ms", p.earlyMaxMs.Load(), "late_max_ms", p.lateMaxMs.Load(),
				"backlog_pkts", win.backlogPkts, "backlog_ms", win.backlogMs, "first_rtp_ms", win.firstRTPMs,
				"answer_to_pump_ms", win.answerToPumpMs,
				"max_gap_ms", win.maxGapMs, "max_burst", win.maxBurst, "burst_ms", win.burstMs)
			lastRead, lastWritten = r, w
		}
	}
}

func (s *Server) publicPort() int {
	if s.cfg.PublicPort > 0 {
		return s.cfg.PublicPort
	}
	return s.cfg.Port
}

func (s *Server) primaryDomain() string {
	if len(s.cfg.Domains) > 0 {
		return s.cfg.Domains[0]
	}
	return s.cfg.ExternalHost
}

// codecNames lists a session's offered codecs for logs ("-" before any
// media session exists).
func codecNames(ms *media.MediaSession) string {
	if ms == nil {
		return "-"
	}
	names := make([]string, 0, len(ms.Codecs))
	for _, c := range ms.Codecs {
		names = append(names, c.Name)
	}
	return strings.Join(names, ",")
}
