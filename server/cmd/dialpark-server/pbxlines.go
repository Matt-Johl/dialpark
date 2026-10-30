package main

import (
	"fmt"
	"log/slog"
	"net"
	"strconv"
	"strings"

	"github.com/emiago/sipgo"
	"github.com/emiago/sipgo/sip"

	"dialpark/server/internal/b2bua"
	"dialpark/server/internal/enroll"
	"dialpark/server/internal/pbx"
	"dialpark/server/internal/pbxline"
)

// -pbx-mode: how this server presents itself to the PBX (SPEC §6 item 3c).
//
// The two modes are exclusive by design, not by omission. An exchange
// matches inbound SIP against its trunk devices by source address and port,
// so a trunk pointing at this server would swallow the calls our registered
// lines place and the registrations would count for nothing. Choosing one
// per deployment removes that whole class of fault; it also means a trunk
// deployment cannot be affected by any of this, because in trunk mode none
// of it is built.
func parsePBXMode(s string) (lines bool, err error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", "trunk":
		return false, nil
	case "lines":
		return true, nil
	default:
		return false, fmt.Errorf("want trunk or lines, got %q", s)
	}
}

// splitList reads a comma-separated flag, dropping blanks.
func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// registrarURI is where REGISTERs go: -pbx-registrar if given, otherwise the
// trunk peer itself, which is the usual case. The transport always follows
// the trunk — one leg, one listener, one transport.
func registrarURI(spec string, trunk *pbx.Trunk) (sip.Uri, error) {
	host, port := trunk.Host, trunk.Port
	if spec = strings.TrimSpace(spec); spec != "" {
		spec = strings.TrimPrefix(spec, "sip:")
		h, p, err := net.SplitHostPort(spec)
		if err != nil {
			host = strings.Trim(spec, "[]") // no port given
		} else {
			n, err := strconv.Atoi(p)
			if err != nil || n <= 0 || n > 65535 {
				return sip.Uri{}, fmt.Errorf("bad -pbx-registrar port in %q", spec)
			}
			host, port = h, n
		}
		if host == "" {
			return sip.Uri{}, fmt.Errorf("bad -pbx-registrar %q", spec)
		}
	}
	u := sip.Uri{Scheme: "sip", Host: host, Port: port, UriParams: sip.NewParams()}
	u.UriParams.Add("transport", strings.ToLower(trunk.Transport))
	return u, nil
}

// startPBXLines builds the line registrar and hands it to the call server.
//
// It must run before calls.Serve: the server reads the registry from the
// call path, and Serve is both what begins serving calls and what starts the
// registration loops (b2bua.startLines).
//
// The manager is returned so the caller can Stop it, which drops every
// binding on the way out rather than leaving the exchange ringing contacts
// this server has stopped listening on.
func startPBXLines(log *slog.Logger, o options, trunk *pbx.Trunk, calls *b2bua.Server, devices *enroll.Store, onState func(pbxline.Status)) (*pbxline.Manager, error) {
	if trunk == nil {
		return nil, fmt.Errorf("-pbx-mode=lines needs a PBX to register to: give -trunk")
	}
	client := calls.TrunkClient()
	if client == nil {
		return nil, fmt.Errorf("-pbx-mode=lines: no SIP client for the PBX leg")
	}
	contact, ok := calls.TrunkContact()
	if !ok {
		return nil, fmt.Errorf("-pbx-mode=lines: cannot work out the address the PBX should call us back on")
	}
	ports := calls.LinePorts()
	target, err := registrarURI(o.pbxRegistrar, trunk)
	if err != nil {
		return nil, err
	}
	domain := o.pbxDomain
	if domain == "" {
		domain = trunk.Host
	}
	registrar, err := pbxline.NewSIPRegistrar(pbxline.SIPConfig{
		Client:    client,
		Registrar: target,
		Domain:    domain,
		Contact:   contact,
		// With a socket per line, each line registers from its own
		// (b2bua.PortRange); without a range both return the trunk's.
		Transport: func(port int) (*sipgo.Client, sip.Uri, bool) {
			c := calls.LineClient(port)
			u, ok := calls.LineContact(port)
			return c, u, ok && c != nil
		},
		UserAgent: "dialpark",
	})
	if err != nil {
		return nil, err
	}

	mgr := pbxline.New(pbxline.Config{
		Registrar: registrar,
		Expiry:    o.pbxExpiry,
		Ports:     ports,
		Log:       log,
		OnState:   onState,
	})
	// Every line the device store holds, minus the revoked ones.
	creds, err := devices.PBXCredentials()
	if err != nil {
		// Not fatal: one unreadable record must not keep the other lines
		// off the exchange. The error names the device.
		log.Error("some PBX line credentials could not be read; those lines will not register", "err", err)
	}
	// Each line takes the socket its record names, or the lowest free one;
	// a line the range has no room for is left stored and said so.
	placed := creds[:0]
	for _, c := range creds {
		port, err := assignLinePort(devices, ports, c.DeviceID)
		if err != nil {
			log.Error("pbx line not registered: no socket for it", "device", c.DeviceID, "user", c.User, "err", err)
			continue
		}
		c.Port = port
		placed = append(placed, c)
	}
	mgr.Set(linesFrom(placed))
	calls.SetLines(mgr)

	log.Info("pbx mode: lines", "registrar", target.String(), "domain", domain,
		"contact", contact.String(), "lines", len(placed), "expiry", o.pbxExpiry,
		"default_line", o.pbxDefaultLine, "peers", o.pbxPeers, "line_ports", ports.String())
	if ports.Len() == 0 {
		log.Warn("-pbx-mode=lines with one shared socket: an exchange that binds a device to the address it registers from (CUCM) accepts one line at a time; give -pbx-line-ports first-last for a socket per line")
	}
	if len(creds) == 0 {
		log.Warn("-pbx-mode=lines but no device has a PBX line configured; no call will reach the exchange until one does (PUT /v1/admin/devices/{id}/pbx-line)")
	}
	return mgr, nil
}

func linesFrom(creds []enroll.PBXCredential) []pbxline.Line {
	out := make([]pbxline.Line, 0, len(creds))
	for _, c := range creds {
		out = append(out, pbxline.Line{User: c.User, DN: c.DN, DigestUser: c.DigestUser, Secret: c.Secret, Port: c.Port})
	}
	return out
}

// assignLinePort is the PBX-leg socket deviceID's line registers from: the
// one its record already names when that is in the range, else the lowest
// port of the range no other device's line holds, which is then written to
// the record so the line keeps it across restarts (an exchange binds the
// device to it). 0 without a range. There is no pool to keep in step: a
// line deleted or purged frees its port by no longer being stored.
func assignLinePort(devices *enroll.Store, r pbxline.PortRange, deviceID string) (int, error) {
	if r.Len() == 0 {
		return 0, nil
	}
	line, ok := devices.PBXLine(deviceID)
	if !ok {
		return 0, fmt.Errorf("no line stored for %s", deviceID)
	}
	if r.Contains(line.Port) {
		return line.Port, nil
	}
	used := map[int]bool{}
	for id, p := range devices.PBXLinePorts() {
		if id != deviceID {
			used[p] = true
		}
	}
	for p := r.First; p <= r.Last; p++ {
		if used[p] {
			continue
		}
		if err := devices.SetPBXLinePort(deviceID, p); err != nil {
			return 0, err
		}
		return p, nil
	}
	return 0, fmt.Errorf("every port of %s is held by another line; widen -pbx-line-ports", r)
}

// pbxLineHook keeps the registrar in step with the admin API: a line written
// registers now and a line removed drops its binding, one device at a time
// and with nothing reloaded (SPEC §4.8).
func pbxLineHook(log *slog.Logger, mgr *pbxline.Manager, devices *enroll.Store) func(string, *enroll.PBXCredential) {
	if mgr == nil {
		// Trunk mode: an administrator may still provision lines against a
		// server that is not using them, ready for a later switch.
		return nil
	}
	return func(deviceID string, cred *enroll.PBXCredential) {
		if cred == nil {
			if user, ok := devices.UserFor(deviceID); ok {
				log.Info("pbx line removed", "device", deviceID, "user", user)
				mgr.Delete(user)
			}
			return
		}
		log.Info("pbx line set", "device", deviceID, "user", cred.User, "dn", cred.DN, "digest_user", cred.DigestUser)
		registerLine(log, mgr, devices, deviceID)
	}
}

// registerLine puts deviceID's stored line on the exchange, unless the
// device is enrolled and holds no licence seat (SPEC §4.9): the exchange
// must not ring a phone the server refuses everywhere else. A device that
// has not enrolled yet is registered as it always was, so its line answers
// the moment the phone is in someone's hand. Nothing to do with no line
// stored or, in trunk mode, no manager.
func registerLine(log *slog.Logger, mgr *pbxline.Manager, devices *enroll.Store, deviceID string) {
	if mgr == nil {
		return
	}
	cred, ok, err := devices.PBXCredential(deviceID)
	if err != nil {
		log.Error("pbx line could not be read", "device", deviceID, "err", err)
		return
	}
	if !ok {
		return
	}
	if devices.SeatState(deviceID) == enroll.SeatUnlicensed {
		log.Info("pbx line stored but not registered: the device holds no licence seat", "device", deviceID, "user", cred.User)
		return
	}
	port, err := assignLinePort(devices, mgr.Ports(), deviceID)
	if err != nil {
		log.Error("pbx line stored but not registered: no socket for it", "device", deviceID, "user", cred.User, "err", err)
		return
	}
	mgr.Put(pbxline.Line{User: cred.User, DN: cred.DN, DigestUser: cred.DigestUser, Secret: cred.Secret, Port: port})
}
