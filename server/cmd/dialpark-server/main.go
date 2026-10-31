// Command dialpark-server is the on-prem light server: signal gateway (wire
// protocol over TLS), SIP registrar on the app leg, media relay, directory
// and enrolment APIs. See SPEC.md §4.
package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"dialpark/server/internal/admin"
	"dialpark/server/internal/b2bua"
	"dialpark/server/internal/diag"
	"dialpark/server/internal/directory"
	"dialpark/server/internal/enroll"
	"dialpark/server/internal/events"
	"dialpark/server/internal/gateway"
	"dialpark/server/internal/licence"
	"dialpark/server/internal/loglevel"
	"dialpark/server/internal/pbx"
	"dialpark/server/internal/pbxline"
	"dialpark/server/internal/qos"
	"dialpark/server/internal/registry"
	"dialpark/server/internal/routing"
	"dialpark/server/internal/secrets"
	"dialpark/server/internal/sipauth"
	"dialpark/server/internal/status"
	"dialpark/server/internal/tlsutil"
	"dialpark/server/internal/wire"

	"github.com/emiago/diago/media"
	"github.com/emiago/sipgo/sip"
)

func main() {
	var (
		signalAddr   = flag.String("signal-addr", ":7443", "wire-protocol TLS listen address")
		sipAddr      = flag.String("sip-addr", ":5061", "app-leg SIP/TLS listen address")
		httpAddr     = flag.String("http-addr", "127.0.0.1:8080", "device API listen address (directory, diag, enrol); phones reach it, so a deployment binds it on the LAN")
		adminAddr    = flag.String("admin-addr", "127.0.0.1:8081", "admin API listen address (/v1/admin/); loopback by default because dialpark-admin runs on this host. Bind it wider only for testing across machines — the token over TLS protects it either way")
		adminTokFile = flag.String("admin-token-file", "", "file holding the admin bearer token (whitespace trimmed); the production form of -admin-token, which is visible to every local user in ps")
		certFile     = flag.String("tls-cert", "", "TLS certificate PEM (empty → self-signed dev cert)")
		keyFile      = flag.String("tls-key", "", "TLS private key PEM")
		publicHost   = flag.String("public-host", "", "hostname/IP advertised to apps in wakes and certs (default: first non-loopback IPv4)")
		localDomain  = flag.String("local-domain", "", "SIP domain this server owns (default: public-host)")
		dataDir      = flag.String("data-dir", "./data", "directory for devices.json and directory.json")
		adminToken   = flag.String("admin-token", "", "bearer token for admin APIs (empty → generated and printed)")
		ringTimeout  = flag.Duration("ring-timeout", 30*time.Second, "how long a callee may ring (and a woken app may take to register)")
		trunkQualify = flag.Duration("trunk-qualify", 10*time.Second, "how often the trunk's TCP/TLS connection is probed with OPTIONS so one that has gone silently dead (a network blip on either side) is dropped before a call needs it; 0 = off; no effect over UDP")
		peerTimeout  = flag.Duration("peer-timeout", 60*time.Second, "end a bridged call when a party stops answering the in-dialog OPTIONS each leg is asked; the backstop for a phone that vanished without a BYE (crash, out of range, suspended). 0 = off")
		rtpMin       = flag.Int("rtp-min", 20000, "first UDP port for relayed media (0 = ephemeral)")
		rtpMax       = flag.Int("rtp-max", 20100, "last UDP port for relayed media")
		rewrite      = flag.Bool("rewrite-contact", true, "route to a registration's source address over its own TLS connection (required for phones behind NAT); false only for harness negative tests")
		logJSON      = flag.Bool("log-json", false, "log as JSON")
		sipTrace     = flag.Bool("sip-trace", false, "log every SIP message sent and received (harness debugging)")
		logLevel     = flag.String("log-level", "info", "debug|info|warn|error (debug includes the media relay's RTP source learning)")
		rtpSym       = flag.Bool("rtp-symmetric", true, "re-target a phone's media at the source of its first RTP packet (needed behind NAT); false where that source is not a deliverable reply address (Docker Desktop harness)")
		pubSIPPort   = flag.Int("public-sip-port", 0, "SIP port advertised to apps (welcome, wakes) when it differs from -sip-addr, e.g. a container published on another host port; 0 = same as -sip-addr")
		pubHTTPPort  = flag.Int("public-http-port", 0, "HTTPS port written into enrolment QR links when it differs from -http-addr (a container published on another host port); 0 = same as -http-addr")
		trunk        = flag.String("trunk", "", "PBX SIP peer for non-local destinations, e.g. sip:asterisk:5060;transport=tcp (empty: standalone, app↔app only)")
		trunkAddr    = flag.String("trunk-addr", "", "listen address for trunk-originated calls (default :5060, :5062 for a TLS trunk — not 5061, which is the app leg's); transport follows -trunk")
		trunkExt     = flag.String("trunk-external-host", "", "address the PBX reaches this server at, used in trunk-leg Contact and SDP (default: this host's first address)")
		trunkSRTP    = flag.String("trunk-srtp", "off", "SDES (RFC 4568) on the PBX leg: off (plain RTP) or sdes (offer RTP/SAVP, mirror the PBX's, and refuse a leg that did not end up encrypted). Default off: a PBX without encryption refuses an SAVP offer with 488. Use a TLS trunk with it — SDES keys travel in the SDP")
		trunkCodecs  = flag.String("trunk-codecs", "g722,pcmu,pcma", "codecs offered to the PBX in order of preference (g722, pcmu, pcma, opus); the app leg is answered with whichever the PBX takes, never transcoded")
		trunkCert    = flag.String("trunk-tls-cert", "", "certificate PEM presented on the PBX leg, in both directions (CUCM's secure trunks do mutual TLS); needed when -trunk uses transport=tls")
		trunkKey     = flag.String("trunk-tls-key", "", "private key PEM for -trunk-tls-cert")
		trunkCA      = flag.String("trunk-tls-ca", "", "CA PEM the PBX's certificate is verified against (empty: the system roots, which reject the private CA most PBX deployments use)")
		trunkNoVer   = flag.Bool("trunk-tls-insecure", false, "accept any certificate from the PBX: a dev convenience against a self-signed PBX, and an open door to anyone who can intercept the trunk")
		trunkTLSMin  = flag.String("trunk-tls-min-version", "1.2", "lowest TLS version accepted on the PBX leg: 1.2 or 1.3. The app leg always pins 1.3; CUCM's secure trunks generally speak 1.2, so raising this may leave the exchange unreachable")
		pbxMode      = flag.String("pbx-mode", "trunk", "how this server presents itself to the PBX named by -trunk: trunk (an IP-trusted peer, the default and unchanged) or lines (one registered third-party SIP device per configured device, SPEC §6 item 3c). Never both — a PBX matches inbound SIP against its trunks by source address, so a trunk pointing at us would bypass the registrations")
		pbxRegistrar = flag.String("pbx-registrar", "", "where REGISTERs go in -pbx-mode=lines, if not the -trunk peer itself (host[:port]); the transport follows -trunk")
		pbxDomain    = flag.String("pbx-domain", "", "SIP domain in a line's address of record, i.e. the host part of From and To towards the PBX (default: the -trunk peer's host)")
		pbxPeers     = flag.String("pbx-peers", "", "further PBX addresses to trust as a call source over a TLS trunk, comma-separated: a cluster originates from whichever node handles the call, and a call from an unnamed node is challenged like an app's and fails")
		pbxExpiry    = flag.Duration("pbx-register-expiry", time.Hour, "registration lifetime asked for in -pbx-mode=lines; the refresh follows what the PBX grants, not this")
		pbxDefLine   = flag.String("pbx-default-line", "", "the user whose line identifies a call to the PBX that has no line of its own (a transfer target dialled for a party that is itself on the PBX). Empty refuses such a call rather than sending it under someone else's number")
		pbxLinePorts = flag.String("pbx-line-ports", "", "in -pbx-mode=lines, a UDP port range (first-last, e.g. 5062-5099) with one PBX-leg socket per port and one line per socket: each line registers from, is called on and calls out of its own port. An exchange binds a third-party SIP device to the address and port it registers from, so lines sharing one socket cannot all be registered at once (CUCM). The first port is the trunk listener; -trunk-addr may name it or be left out. Empty: every line shares the one trunk socket")
		rtpTrace     = flag.String("rtp-trace", "", "lab only: directory for a per-packet TSV of every relayed RTP stream (<call id>-<from>-<to>.tsv; t_us seq ts len skew_ms marker); empty = off")
		diagRetain   = flag.Duration("diag-retain", 30*24*time.Hour, "how long a device's uploaded diagnostics are kept under <data-dir>/diag; 0 keeps them forever")
		showVersion  = flag.Bool("version", false, "print the build version and exit")
	)
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}
	trunkTLSMinVer, err := tlsutil.MinTLSVersion(*trunkTLSMin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "bad -trunk-tls-min-version:", err)
		os.Exit(2)
	}
	trunkSRTPMode, err := b2bua.ParseTrunkSRTP(*trunkSRTP)
	if err != nil {
		fmt.Fprintln(os.Stderr, "bad -trunk-srtp:", err)
		os.Exit(2)
	}
	trunkCodecList, err := b2bua.ParseCodecs(*trunkCodecs)
	if err != nil {
		fmt.Fprintln(os.Stderr, "bad -trunk-codecs:", err)
		os.Exit(2)
	}
	pbxLines, err := parsePBXMode(*pbxMode)
	if err != nil {
		fmt.Fprintln(os.Stderr, "bad -pbx-mode:", err)
		os.Exit(2)
	}
	linePorts, err := pbxline.ParsePortRange(*pbxLinePorts)
	if err != nil {
		fmt.Fprintln(os.Stderr, "bad -pbx-line-ports:", err)
		os.Exit(2)
	}
	if linePorts.Len() > 0 && !pbxLines {
		fmt.Fprintln(os.Stderr, "-pbx-line-ports needs -pbx-mode=lines")
		os.Exit(2)
	}
	sip.SIPDebug = *sipTrace
	adminTok, err := resolveAdminToken(*adminToken, *adminTokFile, os.ReadFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	var level slog.Level
	if err := level.UnmarshalText([]byte(*logLevel)); err != nil {
		fmt.Fprintln(os.Stderr, "bad -log-level:", err)
		os.Exit(2)
	}
	// The level is a variable so PUT /v1/admin/log can move it at runtime
	// (ADMIN-API.md §5.10); every handler in the process reads it.
	var levelVar slog.LevelVar
	levelVar.Set(level)
	hopts := &slog.HandlerOptions{Level: &levelVar}
	var handler slog.Handler = slog.NewTextHandler(os.Stderr, hopts)
	if *logJSON {
		handler = slog.NewJSONHandler(os.Stderr, hopts)
	}
	log := slog.New(handler)
	slog.SetDefault(log)
	media.SetDefaultLogger(log)

	if err := run(context.Background(), log, options{
		signalAddr: *signalAddr, sipAddr: *sipAddr, httpAddr: *httpAddr, adminAddr: *adminAddr,
		certFile: *certFile, keyFile: *keyFile,
		publicHost: *publicHost, localDomain: *localDomain,
		dataDir: *dataDir, adminToken: adminTok,
		diagRetain: *diagRetain,
		levelVar:   &levelVar, logLevel: level, logJSON: *logJSON, sipTrace: *sipTrace,
		ringTimeout: *ringTimeout, rtpMin: *rtpMin, rtpMax: *rtpMax,
		keepAdvertisedContact: !*rewrite,
		noSymmetricRTP:        !*rtpSym,
		publicSIPPort:         *pubSIPPort,
		publicHTTPPort:        *pubHTTPPort,
		trunk:                 *trunk,
		trunkAddr:             *trunkAddr,
		trunkExternalHost:     *trunkExt,
		trunkCodecs:           trunkCodecList,
		trunkSRTP:             trunkSRTPMode,
		trunkQualify:          *trunkQualify,
		peerTimeout:           *peerTimeout,
		trunkCert:             *trunkCert,
		trunkKey:              *trunkKey,
		trunkCA:               *trunkCA,
		trunkTLSInsecure:      *trunkNoVer,
		trunkTLSMin:           trunkTLSMinVer,
		pbxLines:              pbxLines,
		pbxRegistrar:          *pbxRegistrar,
		pbxDomain:             *pbxDomain,
		pbxPeers:              splitList(*pbxPeers),
		pbxExpiry:             *pbxExpiry,
		pbxDefaultLine:        *pbxDefLine,
		pbxLinePorts:          linePorts,
		rtpTraceDir:           *rtpTrace,
	}); err != nil {
		log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

// certFingerprint is the base64url SHA-256 of the server certificate's DER,
// what the app pins after enrolment (SPEC §4.8). Empty if there is none.
func certFingerprint(cfg *tls.Config) string {
	if cfg == nil || len(cfg.Certificates) == 0 || len(cfg.Certificates[0].Certificate) == 0 {
		return ""
	}
	sum := sha256.Sum256(cfg.Certificates[0].Certificate[0])
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

// resolveAdminToken picks the admin bearer token from the two flags: the
// file wins when given (trimmed; empty is an error), the literal is the
// harness's, and both at once is a mistake worth refusing. Empty means
// "generate one", which run does.
func resolveAdminToken(literal, file string, readFile func(string) ([]byte, error)) (string, error) {
	if file == "" {
		return literal, nil
	}
	if literal != "" {
		return "", errors.New("give -admin-token or -admin-token-file, not both")
	}
	b, err := readFile(file)
	if err != nil {
		return "", fmt.Errorf("-admin-token-file: %w", err)
	}
	tok := strings.TrimSpace(string(b))
	if tok == "" {
		return "", fmt.Errorf("-admin-token-file %s is empty", file)
	}
	return tok, nil
}

// version is stamped by the Makefile (-X main.version=…); "dev" otherwise.
var version = "dev"

type options struct {
	signalAddr, sipAddr, httpAddr string
	adminAddr                     string
	diagRetain                    time.Duration
	// The log configuration the process started with, and the variable
	// the admin API moves.
	levelVar                     *slog.LevelVar
	logLevel                     slog.Level
	logJSON                      bool
	sipTrace                     bool
	certFile, keyFile            string
	publicHost, localDomain      string
	dataDir, adminToken          string
	ringTimeout                  time.Duration
	rtpMin, rtpMax               int
	keepAdvertisedContact        bool
	noSymmetricRTP               bool
	publicSIPPort                int
	publicHTTPPort               int
	trunk, trunkAddr             string
	trunkExternalHost            string
	trunkCodecs                  []media.Codec
	trunkSRTP                    b2bua.TrunkSRTPMode
	trunkQualify                 time.Duration
	peerTimeout                  time.Duration
	trunkCert, trunkKey, trunkCA string
	trunkTLSInsecure             bool
	trunkTLSMin                  uint16
	// How the PBX leg presents itself (SPEC §6 item 3c). pbxLines false is
	// the IP-trusted trunk peer this server has always been, and none of
	// the rest applies.
	pbxLines       bool
	pbxRegistrar   string
	rtpTraceDir    string
	pbxDomain      string
	pbxPeers       []string
	pbxExpiry      time.Duration
	pbxDefaultLine string
	// pbxLinePorts gives each line its own PBX-leg socket; zero is the one
	// shared trunk socket.
	pbxLinePorts pbxline.PortRange
}

func run(ctx context.Context, log *slog.Logger, o options) error {
	ctx, stop := signal.NotifyContext(ctx, syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if o.publicHost == "" {
		o.publicHost = firstIPv4()
	}
	if err := checkPublicHost(o.publicHost, net.InterfaceAddrs); err != nil {
		// Not fatal: behind port forwarding (the Docker harness advertising
		// the Mac's address) the advertised host is never a local one.
		log.Warn("public host check", "err", err)
	}
	if o.localDomain == "" {
		o.localDomain = o.publicHost
	}
	if o.adminToken == "" {
		var b [16]byte
		_, _ = rand.Read(b[:])
		o.adminToken = hex.EncodeToString(b[:])
		log.Warn("no -admin-token given; generated one for this run", "admin_token", o.adminToken)
	}

	// The dev certificate is kept under <data-dir>/tls so a restart presents
	// the same one: enrolled apps pin its fingerprint (SPEC §4.8).
	tlsCfg, selfSigned, err := tlsutil.LoadOrKeep(o.certFile, o.keyFile, []string{o.publicHost, "localhost", "127.0.0.1"}, filepath.Join(o.dataDir, "tls"))
	if err != nil {
		return err
	}
	if selfSigned {
		log.Warn("using a self-signed TLS certificate, kept in <data-dir>/tls; enrolled apps pin it, other clients must disable verification in dev", "fingerprint_sha256", certFingerprint(tlsCfg))
	}

	// Stores.
	devices, err := enroll.Open(filepath.Join(o.dataDir, "devices.json"))
	if err != nil {
		return err
	}
	// Credentials issued from now on also carry their SIP Digest form for
	// this realm (the app leg's registrar verifies against it).
	devices.Realm = o.localDomain
	// The key that seals PBX line credentials (SPEC §6 item 3c). Opened in
	// either mode: an operator may provision lines against a server that is
	// still trunking, ready for the switch.
	if devices.Secrets, err = secrets.OpenKey(filepath.Join(o.dataDir, "pbx.key")); err != nil {
		return err
	}
	// The product licence (SPEC §4.9): the install id this server is bound
	// by, and the seats in force, set before anything registers or listens.
	_, lic, err := startLicence(log, o.dataDir)
	if err != nil {
		return err
	}
	devices.SetSeats(lic.Seats())
	// One directory per device (SPEC §6 item 7): <data-dir>/directories/
	// <device>.json. A pre-item-7 global directory.json is folded into
	// every enrolled device's directory once, then renamed.
	dir, err := directory.Open(filepath.Join(o.dataDir, "directories"))
	if err != nil {
		return err
	}
	var enrolled []string
	for _, d := range devices.Devices() {
		if !d.Revoked {
			enrolled = append(enrolled, d.DeviceID)
		}
	}
	if n, m, err := dir.Migrate(filepath.Join(o.dataDir, "directory.json"), enrolled); err != nil {
		return fmt.Errorf("directory migration: %w", err)
	} else if m > 0 {
		log.Info("migrated the global directory into per-device directories", "contacts", n, "devices", m)
	}

	// Core.
	started := time.Now()
	// The event ring (ADMIN-API.md §5.9): what the server did, for the
	// admin API to read instead of grepping the log. Never who asked.
	ring := events.New(events.Default)
	reg := registry.New(nil)
	for _, d := range devices.Devices() {
		if !d.Revoked {
			reg.Provision(d.User, d.DeviceID)
		}
	}
	reg.OnChange(func(ep registry.Endpoint, registered bool) {
		kind := events.KindSIPUnregister
		detail := map[string]any{}
		if registered {
			kind = events.KindSIPRegister
			detail["contact"], detail["expires_at"] = ep.Contact, ep.Expires
		}
		ring.Emit(kind, ep.DeviceID, ep.User, detail)
	})
	var adapter pbx.Adapter = pbx.None{}
	var trunkCfg *pbx.Trunk
	var trunkTLS *tls.Config
	if o.trunk != "" {
		t, err := pbx.ParseTrunk(o.trunk)
		if err != nil {
			return fmt.Errorf("bad -trunk %q: %w", o.trunk, err)
		}
		trunkCfg = &t
		adapter = pbx.NewSIPTrunk(t)
		if strings.EqualFold(t.Transport, "tls") {
			trunkTLS, err = tlsutil.PeerConfig(o.trunkCert, o.trunkKey, o.trunkCA, o.trunkTLSMin, o.trunkTLSInsecure)
			if err != nil {
				return err
			}
			// A TLS trunk with no certificate listens with none: the PBX's
			// inbound calls fail the handshake, so only our outbound
			// direction would work. Better to say so at startup than to
			// have half the calls quietly stop arriving.
			if o.trunkCert == "" {
				log.Warn("-trunk uses transport=tls but no -trunk-tls-cert was given; calls the PBX places to us cannot complete a handshake")
			}
			if o.trunkTLSInsecure {
				log.Warn("-trunk-tls-insecure: the PBX's certificate is not verified, so a machine that can intercept the trunk can impersonate the PBX and read every call")
			}
		} else if o.trunkCert != "" || o.trunkCA != "" || o.trunkTLSInsecure {
			log.Warn("trunk TLS flags ignored: -trunk is not transport=tls", "trunk_transport", t.Transport)
		}
	}
	router := routing.New(reg, []string{o.localDomain, o.publicHost}, func() bool { _, ok := adapter.Trunk(); return ok })

	sipHost, sipPortStr, err := net.SplitHostPort(o.sipAddr)
	if err != nil {
		return fmt.Errorf("bad -sip-addr %q: %w", o.sipAddr, err)
	}
	sipPort, err := strconv.Atoi(sipPortStr)
	if err != nil {
		return fmt.Errorf("bad -sip-addr port %q: %w", sipPortStr, err)
	}
	publicSIPPort := o.publicSIPPort
	if publicSIPPort == 0 {
		publicSIPPort = sipPort
	}

	gw := gateway.New(gateway.Config{
		Logger:           log,
		DirectoryVersion: dir.Version,
		// Tell each connecting app which SIP user to register, so it is
		// reachable directly while running (SPEC §2 foreground path).
		SIPAccountFor: func(deviceID string) *wire.SIPAccount {
			ep, ok := reg.LookupDevice(deviceID)
			if !ok {
				return nil
			}
			return &wire.SIPAccount{User: ep.User, Domain: o.localDomain, Host: o.publicHost, Port: publicSIPPort, Transport: "tls"}
		},
		// Server-managed settings (SPEC §6 item 8b), absent until set.
		DeviceConfigFor: func(deviceID string) *wire.DeviceConfig {
			c := devices.Config(deviceID)
			if c == nil {
				return nil
			}
			return &wire.DeviceConfig{Version: c.Version, SSIDs: c.SSIDs}
		},
		// The licence gate (SPEC §4.9), after the credential check: a holder
		// beyond the seats, or any device once the licence has lapsed, is
		// told why on the one error code every app decodes.
		Licensed:   licenceGate(devices, lic),
		LicenceFor: lic.Token,
	}, devices)
	dir.OnChange(gw.NotifyDirectory)
	dir.OnWrite(func(deviceID string, version int64, by string) {
		ring.Emit(events.KindDirectoryChanged, deviceID, "", map[string]any{"version": version, "by": by})
	})
	gw.OnPresence(func(ev gateway.PresenceEvent) {
		log.Info("presence", "device", ev.DeviceID, "kind", ev.Kind, "online", ev.Online)
		ring.Emit(events.KindPresence, ev.DeviceID, "", map[string]any{"client": string(ev.Kind), "online": ev.Online})
	})
	gw.OnWake(func(deviceID, callID string, delivered int) {
		ring.Emit(events.KindWakeSent, deviceID, "", map[string]any{"call_id": callID, "delivered": delivered})
	})
	// App-leg SIP element: registrar + call controller + media bridge (diago).
	calls, err := b2bua.New(b2bua.Config{
		OnTrunkState: func(up bool, err error) {
			detail := map[string]any{"qualify": "down"}
			if up {
				detail["qualify"] = "up"
			}
			if err != nil {
				detail["error"] = err.Error()
			}
			ring.Emit(events.KindTrunkState, "", "", detail)
		},
		OnCall: func(callID string, started bool, a, b, reason string) {
			kind, detail := events.KindCallEnd, map[string]any{"call_id": callID, "a": a, "b": b, "reason": reason}
			if started {
				kind = events.KindCallStart
				delete(detail, "reason")
			}
			ring.Emit(kind, "", "", detail)
		},
		BindHost:              sipHost,
		Port:                  sipPort,
		PublicPort:            publicSIPPort,
		ExternalHost:          o.publicHost,
		TLS:                   tlsCfg,
		Domains:               []string{o.localDomain, o.publicHost},
		RTPPortStart:          o.rtpMin,
		RTPPortEnd:            o.rtpMax,
		KeepAdvertisedContact: o.keepAdvertisedContact,
		NoSymmetricRTP:        o.noSymmetricRTP,
		Trunk:                 trunkCfg,
		TrunkBind:             o.trunkAddr,
		TrunkExternalHost:     o.trunkExternalHost,
		TrunkCodecs:           o.trunkCodecs,
		TrunkSRTP:             o.trunkSRTP,
		TrunkQualify:          o.trunkQualify,
		PeerTimeout:           o.peerTimeout,
		TrunkTLS:              trunkTLS,
		TrunkPeers:            o.pbxPeers,
		PBXDomain:             o.pbxDomain,
		DefaultLine:           o.pbxDefaultLine,
		LinePorts:             o.pbxLinePorts,
		RTPTraceDir:           o.rtpTraceDir,
		RingTimeout:           o.ringTimeout,
		Auth:                  sipauth.New(o.localDomain, devices),
		Logger:                log,
	}, reg, router, gw)
	if err != nil {
		return err
	}
	// Lines mode (SPEC §6 item 3c): this server holds one registration per
	// configured device instead of being an IP-trusted trunk peer. Built
	// before Serve, which is what starts the registration loops, and
	// nothing at all in trunk mode.
	var lines *pbxline.Manager
	if o.pbxLines {
		lines, err = startPBXLines(log, o, trunkCfg, calls, devices, func(st pbxline.Status) {
			ring.Emit(events.KindLineState, "", st.User, map[string]any{"state": string(st.State), "error": st.Error, "realm": st.Realm})
		})
		if err != nil {
			return err
		}
		defer lines.Stop()
	} else if o.pbxRegistrar != "" || o.pbxDomain != "" || len(o.pbxPeers) > 0 || o.pbxDefaultLine != "" {
		log.Warn("-pbx-* flags ignored: -pbx-mode is trunk")
	}
	// Seats move when the licence changes or a device is enrolled, revoked
	// or purged: the devices that crossed the line are cut off or let back
	// in, one by one, and nothing else is touched (SPEC §4.9).
	devices.OnSeats(seatHooks(log, ring, reg, gw, lines, devices))
	lic.OnChange(func(seats int) {
		ring.Emit(events.KindLicenceChanged, "", "", map[string]any{"seats": seats, "state": string(lic.State())})
		devices.SetSeats(seats)
	})
	go lic.Run(ctx)

	// A wake_ack of decline/busy ends that call's wait for a registration at
	// once (the caller gets 486) instead of at the ring timeout.
	gw.OnWakeAck(func(deviceID string, ack wire.WakeAck) {
		log.Info("wake_ack", "device", deviceID, "call", ack.CallID, "action", ack.Action)
		ring.Emit(events.KindWakeAck, deviceID, "", map[string]any{"call_id": ack.CallID, "action": string(ack.Action)})
		calls.HandleWakeAck(deviceID, ack)
	})

	// HTTP, two listeners (ADMIN-API.md §4.1): the device API on -http-addr,
	// which phones reach, and the admin API on -admin-addr, loopback by
	// default. /v1/admin/ is not served on the device listener at all.
	mux := http.NewServeMux()
	adminAPI := http.NewServeMux()
	dirH := directory.NewHandler(dir, devices.DeviceAuth)
	mux.Handle("/v1/directory", dirH)
	mux.Handle("/v1/directory/", dirH)
	// The operator's per-device directory routes sit under /v1/admin/ but
	// are more specific than the enrolment handler's prefix, so they win.
	knownDevice := devices.Exists
	dirAdmin := directory.NewAdminHandler(dir, o.adminToken, knownDevice)
	adminAPI.Handle("/v1/admin/devices/{id}/directory", dirAdmin)
	adminAPI.Handle("/v1/admin/devices/{id}/directory/{cid}", dirAdmin)
	adminAPI.Handle("GET /v1/admin/whoami", admin.Whoami())
	// Device diagnostics land in <data-dir>/diag/<device>/ (app + extension
	// logs, MetricKit crash/CPU reports): readable on this machine without
	// touching the phone. See ios/README.md "When the app dies or freezes".
	// The admin reads and prunes them (ADMIN-API.md §5.11); a sweeper
	// applies -diag-retain hourly.
	diagDir := filepath.Join(o.dataDir, "diag")
	mux.Handle("/v1/diag", diag.Handler(diagDir, devices.DeviceAuth, log))
	diagAdmin := diag.AdminHandler(diagDir, knownDevice)
	adminAPI.Handle("/v1/admin/devices/{id}/diag", diagAdmin)
	adminAPI.Handle("/v1/admin/devices/{id}/diag/{name}", diagAdmin)
	go diag.RunSweeper(ctx, diagDir, o.diagRetain, time.Hour, log)
	// Events, the log level, and the live views (ADMIN-API.md §5.6–§5.10).
	adminAPI.Handle("GET /v1/admin/events", ring.Handler())
	logCtl := loglevel.New(o.levelVar, func(on bool) { sip.SIPDebug = on }, o.logLevel, o.sipTrace)
	logH := logEvents(ring, logCtl, logCtl.Handler())
	adminAPI.Handle("GET /v1/admin/log", logH)
	adminAPI.Handle("PUT /v1/admin/log", logH)
	var adminStats admin.Stats
	live := status.New(serverInfo(o, tlsCfg, trunkCfg, started), status.Deps{
		Devices:       devices.Devices,
		Sessions:      gw.Sessions,
		Endpoints:     reg.Endpoints,
		Lines:         func() []pbxline.Status { return lines.Statuses() },
		Calls:         calls.Calls,
		Trunk:         calls.TrunkStatus,
		AdminStats:    adminStats.View,
		EventsDropped: ring.Dropped,
		Licence: func() licence.Summary {
			used, _ := devices.Seats()
			return lic.Summary(used)
		},
	})
	adminAPI.Handle("GET /v1/admin/status", live)
	// The product licence (SPEC §4.9): read, and installed by paste.
	licenceAPI := licence.NewHandler(lic, o.adminToken, func() int { used, _ := devices.Seats(); return used })
	adminAPI.Handle("GET /v1/admin/licence", licenceAPI)
	adminAPI.Handle("PUT /v1/admin/licence", licenceAPI)
	adminAPI.Handle("POST /v1/admin/licence", licenceAPI)
	adminAPI.Handle("GET /v1/admin/server", live)
	adminAPI.Handle("GET /v1/admin/calls", live)
	// Enrolment (SPEC §4.8): the admin mints a code, the phone claims it
	// for a credential. The QR link and the claim reply carry the server's
	// certificate fingerprint so the app can pin it from the first
	// connection.
	certSHA256 := certFingerprint(tlsCfg)
	_, httpPortStr, err := net.SplitHostPort(o.httpAddr)
	if err != nil {
		return fmt.Errorf("bad -http-addr %q: %w", o.httpAddr, err)
	}
	httpPort, _ := strconv.Atoi(httpPortStr)
	if o.publicHTTPPort != 0 {
		httpPort = o.publicHTTPPort
	}
	_, signalPortStr, _ := net.SplitHostPort(o.signalAddr)
	signalPort, _ := strconv.Atoi(signalPortStr)
	hooks := adminHooks(log, ring, reg, gw, lines, devices, dir, diagDir)
	adminAPI.Handle("/v1/admin/", enroll.NewAdminHandler(devices, o.adminToken,
		enroll.Link{Host: o.publicHost, HTTPSPort: httpPort, CertSHA256: certSHA256}, hooks))
	mux.Handle("POST /v1/enrol", enroll.NewEnrolHandler(devices,
		enroll.EnrolInfo{SignalPort: signalPort, SIPDomain: o.localDomain, CertSHA256: certSHA256}, hooks))
	mux.Handle("GET /healthz", admin.Healthz())
	// The admin front door (ADMIN-API.md §4.7): rate limit, bearer guard and
	// in-flight cap ahead of every admin route; healthz outside it.
	adminRoot := http.NewServeMux()
	adminRoot.Handle("GET /healthz", admin.Healthz())
	adminRoot.Handle("/v1/admin/", admin.Chain(o.adminToken, admin.NewRateLimiter(), &adminStats, adminAPI))

	// Listeners.
	// The wire-protocol listener carries call signalling (wakes): CS3, like
	// the SIP listener. Accepted connections inherit the marking.
	signalLc := net.ListenConfig{Control: qos.Control(qos.DSCPCS3)}
	signalRaw, err := signalLc.Listen(ctx, "tcp", o.signalAddr)
	if err != nil {
		return fmt.Errorf("signal listen: %w", err)
	}
	signalLn := tls.NewListener(signalRaw, tlsCfg)
	// The directory/admin API carries device and admin tokens, so it is TLS
	// on the same certificate as the other listeners.
	httpLn, err := tls.Listen("tcp", o.httpAddr, tlsCfg)
	if err != nil {
		return fmt.Errorf("http listen: %w", err)
	}
	httpSrv := &http.Server{Handler: mux}
	admin.ConfigureServer(httpSrv)
	// The admin listener accepts a bounded number of connections; the TLS
	// layer sits on top so a closed TLS conn frees its slot.
	adminRaw, err := net.Listen("tcp", o.adminAddr)
	if err != nil {
		return fmt.Errorf("admin listen: %w", err)
	}
	adminLn := tls.NewListener(admin.LimitListener(adminRaw, admin.MaxConnections), tlsCfg)
	adminSrv := &http.Server{Handler: adminRoot}
	admin.ConfigureServer(adminSrv)

	log.Info("dialpark-server starting",
		"signal", signalLn.Addr(), "sip", o.sipAddr, "https", httpLn.Addr(), "admin", adminLn.Addr(),
		"public_host", o.publicHost, "local_domain", o.localDomain,
		"ring_timeout", o.ringTimeout, "rtp_range", fmt.Sprintf("%d-%d", o.rtpMin, o.rtpMax), "data_dir", o.dataDir)

	errc := make(chan error, 4)
	go func() { errc <- gw.Serve(ctx, signalLn) }()
	go func() { errc <- calls.Serve(ctx) }()
	serveHTTP := func(srv *http.Server, ln net.Listener) {
		err := srv.Serve(ln)
		if errors.Is(err, http.ErrServerClosed) {
			err = nil
		}
		errc <- err
	}
	go serveHTTP(httpSrv, httpLn)
	go serveHTTP(adminSrv, adminLn)

	select {
	case <-ctx.Done():
		log.Info("shutting down")
	case err := <-errc:
		if err != nil {
			stop()
			return err
		}
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = httpSrv.Shutdown(shutdownCtx)
	_ = adminSrv.Shutdown(shutdownCtx)
	return nil
}

// serverInfo is GET /v1/admin/server's fixed half (ADMIN-API.md §5.7): the
// effective startup configuration and the certificate every phone pins.
// Never a secret: no token, no key material, no key paths.
func serverInfo(o options, tlsCfg *tls.Config, trunk *pbx.Trunk, started time.Time) status.Info {
	info := status.Info{
		Version: version, StartedAt: started, Mode: "standalone",
		Listeners:  status.Listeners{Signal: o.signalAddr, SIP: o.sipAddr, HTTP: o.httpAddr, Admin: o.adminAddr},
		PublicHost: o.publicHost, LocalDomain: o.localDomain,
		PublicSIPPort: o.publicSIPPort, PublicHTTPPort: o.publicHTTPPort,
		RingTimeout: int(o.ringTimeout.Seconds()), PeerTimeout: int(o.peerTimeout.Seconds()),
		RTP:     status.RTPInfo{Min: o.rtpMin, Max: o.rtpMax, Symmetric: !o.noSymmetricRTP},
		DataDir: o.dataDir, DiagRetain: int(o.diagRetain.Seconds()),
		Log: status.LogStartup{Level: strings.ToLower(o.logLevel.String()), JSON: o.logJSON, SIPTrace: o.sipTrace},
	}
	info.TLS.SelfSigned = o.certFile == ""
	info.TLS.FingerprintSHA256 = certFingerprint(tlsCfg)
	if tlsCfg != nil && len(tlsCfg.Certificates) > 0 && len(tlsCfg.Certificates[0].Certificate) > 0 {
		if leaf, err := x509.ParseCertificate(tlsCfg.Certificates[0].Certificate[0]); err == nil {
			info.TLS.Subject, info.TLS.NotBefore, info.TLS.NotAfter = leaf.Subject.String(), leaf.NotBefore, leaf.NotAfter
		}
	}
	if trunk != nil {
		info.Mode = "trunk"
		codecs := make([]string, 0, len(o.trunkCodecs))
		for _, c := range o.trunkCodecs {
			codecs = append(codecs, c.Name)
		}
		info.Trunk = &status.TrunkInfo{
			URI: o.trunk, Transport: strings.ToLower(trunk.Transport), SRTP: string(o.trunkSRTP), Codecs: codecs,
			QualifyIntervalSeconds: int(o.trunkQualify.Seconds()),
			TLS:                    status.TrunkTLSInfo{CertSet: o.trunkCert != "", CASet: o.trunkCA != "", Insecure: o.trunkTLSInsecure, MinVersion: tlsVersionName(o.trunkTLSMin)},
		}
		info.Listeners.Trunk = o.trunkAddr
	}
	if o.pbxLines {
		info.Mode = "lines"
		info.PBX = &status.PBXInfo{Registrar: o.pbxRegistrar, Domain: o.pbxDomain, Peers: o.pbxPeers, RegisterExpirySeconds: int(o.pbxExpiry.Seconds()), DefaultLine: o.pbxDefaultLine, LinePorts: o.pbxLinePorts.String()}
	}
	return info
}

func tlsVersionName(v uint16) string {
	switch v {
	case tls.VersionTLS13:
		return "1.3"
	case tls.VersionTLS12:
		return "1.2"
	}
	return fmt.Sprintf("0x%04x", v)
}

// logEvents records a successful PUT /v1/admin/log in the event ring.
func logEvents(ring *events.Ring, ctl *loglevel.Controller, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPut {
			next.ServeHTTP(w, r)
			return
		}
		sw := &statusWriter{ResponseWriter: w}
		next.ServeHTTP(sw, r)
		if sw.status == http.StatusOK {
			v := ctl.View()
			ring.Emit(events.KindLogLevel, "", "", map[string]any{"level": v.Level, "sip_trace": v.SIPTrace, "until": v.Until})
		}
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

// adminHooks is what the admin API's writes do to the live server: the
// registry, the gateway, the line manager (nil in trunk mode), the
// directory, the diagnostics directory and the event ring. Kept out of
// run so it can be tested without listeners.
func adminHooks(log *slog.Logger, ring *events.Ring, reg *registry.Registry, gw *gateway.Gateway, lines *pbxline.Manager, devices *enroll.Store, dir *directory.Store, diagDir string) enroll.Hooks {
	return enroll.Hooks{
		OnIssue: func(deviceID, user string) { reg.Provision(user, deviceID) },
		OnEvent: func(kind, deviceID string, detail map[string]any) { ring.Emit(kind, deviceID, "", detail) },
		OnRevoke: func(deviceID string) {
			if ep, ok := reg.LookupDevice(deviceID); ok {
				reg.Deprovision(ep.User)
				// Its phone can no longer connect, so its line must not
				// stay registered: the exchange would go on ringing a
				// number nobody can answer for the whole ring timeout.
				if lines != nil {
					lines.Delete(ep.User)
				}
			}
			gw.Disconnect(deviceID)
			ring.Emit(events.KindDeviceRevoked, deviceID, "", nil)
		},
		// Purge (ADMIN-API.md §5.1): everything a revoke does, then the
		// device's directory and diagnostics go with its record. One
		// device's entries and files; nothing else is touched.
		OnPurge: func(deviceID string) {
			if ep, ok := reg.LookupDevice(deviceID); ok {
				reg.Deprovision(ep.User)
				if lines != nil {
					lines.Delete(ep.User)
				}
			}
			gw.Disconnect(deviceID)
			if err := dir.Purge(deviceID); err != nil {
				log.Error("purge: directory", "device", deviceID, "err", err)
			}
			if err := diag.Purge(diagDir, deviceID); err != nil {
				log.Error("purge: diagnostics", "device", deviceID, "err", err)
			}
			log.Info("device purged", "device", deviceID)
			ring.Emit(events.KindDevicePurged, deviceID, "", nil)
		},
		// A claim rotates the credential: whatever is connected with the
		// old one is dropped (it reconnects with the new one, or it was a
		// phone this device id no longer belongs to). One device only.
		OnClaim: func(deviceID, user string) {
			log.Info("enrolment code claimed", "device", deviceID, "user", user)
			ring.Emit(events.KindCodeClaimed, deviceID, user, nil)
			reg.Provision(user, deviceID)
			gw.Disconnect(deviceID)
			// A claim un-revokes, so a line that was dropped on revocation
			// comes back with the replacement phone (if it holds a seat).
			registerLine(log, lines, devices, deviceID)
		},
		// Settings changed: that device's live sessions get them now; a
		// device not connected gets them in its next welcome.
		OnConfig: func(deviceID string, cfg enroll.DeviceConfig) {
			log.Info("device settings changed", "device", deviceID, "version", cfg.Version, "ssids", cfg.SSIDs)
			ring.Emit(events.KindConfigChanged, deviceID, "", map[string]any{"version": cfg.Version})
			gw.NotifyConfig(deviceID, wire.DeviceConfig{Version: cfg.Version, SSIDs: cfg.SSIDs})
		},
		// A PBX line written or removed: that one line re-registers, and
		// nothing else on the server is touched.
		OnPBXLine: func(deviceID string, line *enroll.PBXCredential) {
			if line == nil {
				ring.Emit(events.KindLineRemoved, deviceID, "", nil)
			} else {
				ring.Emit(events.KindLineChanged, deviceID, line.User, nil)
			}
			// Trunk mode has no registrar to tell (the hook is nil): the
			// line is stored for a later switch and that is all.
			if hook := pbxLineHook(log, lines, devices); hook != nil {
				hook(deviceID, line)
			}
		},
	}
}

// checkPublicHost reports a -public-host that is an IP literal this machine
// does not hold. Apps register their SIP leg to the host the welcome
// advertises; an address that is not ours can only time out on the phone
// ("engine: registration failed: Operation timed out") while the gateway,
// reached by the address in the app's settings, looks fine. That is what a
// stale `ipconfig getifaddr` in `make dev-server` produced on 2026-09-13
// (advertised 10.18.0.168 on a Mac that was 10.18.0.212). A hostname is
// left to DNS. The caller decides whether it is fatal.
func checkPublicHost(host string, interfaceAddrs func() ([]net.Addr, error)) error {
	ip := net.ParseIP(host)
	if ip == nil {
		return nil
	}
	addrs, err := interfaceAddrs()
	if err != nil {
		return nil // cannot tell; do not block startup on it
	}
	for _, a := range addrs {
		if ipn, ok := a.(*net.IPNet); ok && ipn.IP.Equal(ip) {
			return nil
		}
	}
	return fmt.Errorf("-public-host %s is not an address of this machine; apps would register to it and time out (use the LAN address of the interface phones reach, or a hostname)", host)
}

func firstIPv4() string {
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if ipn, ok := a.(*net.IPNet); ok && !ipn.IP.IsLoopback() && ipn.IP.To4() != nil {
			return ipn.IP.String()
		}
	}
	return "127.0.0.1"
}
