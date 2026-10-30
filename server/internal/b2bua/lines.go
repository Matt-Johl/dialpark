package b2bua

import (
	"context"
	"errors"
	"strconv"
	"strings"

	"github.com/emiago/sipgo"
	"github.com/emiago/sipgo/sip"

	"dialpark/server/internal/pbxline"
)

// linePortTransport names the diago transport bound on one line port. The
// first port of the range is the trunk transport itself (lineTransport).
func linePortTransport(port int) string { return "line:" + strconv.Itoa(port) }

// lineTransport names the PBX-leg transport a request on behalf of a line
// on port leaves from: the trunk transport when there is no range, or the
// port is 0 or the range's first, otherwise that port's own transport.
func (s *Server) lineTransport(port int) string {
	if port == 0 || port == s.cfg.LinePorts.First || !s.cfg.LinePorts.Contains(port) {
		return transportTrunk
	}
	return linePortTransport(port)
}

// LinePorts is the configured range, zero when every line shares the
// trunk socket.
func (s *Server) LinePorts() pbxline.PortRange { return s.cfg.LinePorts }

// Lines mode: the PBX knows each device as a registered line of its own
// rather than knowing this server as one trunk peer (SPEC §6 item 3c).
//
// Everything here is inert unless a deployment turned that mode on. The one
// rule the whole feature rests on is that a call towards the PBX must
// present the *calling device's* number and answer challenges with that
// line's credential — an exchange rejects a From that is not the registered
// line, and would attribute the call to the wrong user if it did not.

// SetLines attaches the line registry, putting the PBX leg in lines mode.
//
// It must be called before Start: the registry is read from the call path
// without a lock, and Start is what begins serving calls. It is a setter
// rather than a Config field because the registrar registers over the SIP
// stack this server builds, so the two cannot both be constructed first.
func (s *Server) SetLines(l Lines) { s.cfg.Lines = l }

// TrunkClient is the SIP client that sends out of the trunk-leg transport —
// what the line registrar's REGISTERs must travel on, so the source address
// the PBX records is the one it will send calls back to. Nil when no trunk
// peer is configured.
func (s *Server) TrunkClient() *sipgo.Client { return s.LineClient(0) }

// LineClient is the SIP client that sends out of the socket a line on port
// holds (TrunkClient for 0 or a port outside the range). Nil when no trunk
// peer is configured.
func (s *Server) LineClient(port int) *sipgo.Client {
	if s.cfg.Trunk == nil {
		return nil
	}
	return s.dg.Client(s.lineTransport(port))
}

// TrunkContact is the address a registration should ask the PBX to send
// calls to: this server's trunk-leg listener as the PBX reaches it. The user
// part is left empty for the registrar to fill with each line's number.
func (s *Server) TrunkContact() (sip.Uri, bool) { return s.LineContact(0) }

// LineContact is TrunkContact on the socket a line on port holds: the same
// address, that port. 0 or a port outside the range is the trunk socket.
func (s *Server) LineContact(port int) (sip.Uri, bool) {
	if s.cfg.Trunk == nil {
		return sip.Uri{}, false
	}
	_, bound, err := trunkBind(s.cfg.TrunkBind, s.cfg.Trunk)
	if err != nil {
		return sip.Uri{}, false
	}
	if s.cfg.LinePorts.Len() > 0 {
		bound = s.cfg.LinePorts.First
	}
	if s.cfg.LinePorts.Contains(port) {
		bound = port
	}
	host := s.cfg.TrunkExternalHost
	if host == "" {
		host = firstIPv4()
	}
	u := sip.Uri{Scheme: "sip", Host: host, Port: bound, UriParams: sip.NewParams()}
	// Explicit transport, as the trunk leg's Contact carries elsewhere: a
	// default would be read as UDP and an in-dialog request could fall back
	// to a port nothing is listening on.
	u.UriParams.Add("transport", strings.ToLower(s.cfg.Trunk.Transport))
	return u, true
}

// linesPorts is the part of the registry that knows which socket each line
// holds. Optional, as linesStarter is: a registry without it, or a server
// without a range, keeps every line on the trunk socket.
type linesPorts interface {
	Port(user string) (int, bool)
	UserAtPort(port int) (string, bool)
}

// lineUser is the user whose line a call on behalf of localUser goes out
// under: their own, or the configured default. ok is false when neither
// has a line.
func (s *Server) lineUser(localUser string) (string, bool) {
	if _, found := s.cfg.Lines.Number(localUser); found {
		return localUser, true
	}
	if s.cfg.DefaultLine != "" {
		if _, found := s.cfg.Lines.Number(s.cfg.DefaultLine); found {
			return s.cfg.DefaultLine, true
		}
	}
	return "", false
}

// calleeTransport names the PBX-leg transport a callee leg dialled on
// behalf of localUser leaves from: in lines mode with a range, the socket
// that user's line holds, so the exchange sees the call come from the
// device it registered; otherwise the trunk transport, as always.
func (s *Server) calleeTransport(calleeTrunk bool, localUser string) string {
	if !calleeTrunk {
		return transportApp
	}
	if s.cfg.Lines == nil || s.cfg.LinePorts.Len() == 0 {
		return transportTrunk
	}
	lp, ok := s.cfg.Lines.(linesPorts)
	if !ok {
		return transportTrunk
	}
	user, ok := s.lineUser(localUser)
	if !ok {
		return transportTrunk
	}
	port, _ := lp.Port(user)
	return s.lineTransport(port)
}

// inboundLine is the user whose line a request from the PBX arrived on, by
// the socket it was read on. ok is false outside lines mode, without a
// range, or when no line holds that port — the caller then falls back to
// the To user, which is what identified the line before sockets did and
// still does on the shared one.
func (s *Server) inboundLine(req *sip.Request) (string, bool) {
	if s.cfg.Lines == nil || s.cfg.LinePorts.Len() == 0 || req == nil {
		return "", false
	}
	lp, ok := s.cfg.Lines.(linesPorts)
	if !ok {
		return "", false
	}
	_, port, err := sip.ParseAddr(req.ReceivedOn())
	if err != nil || !s.cfg.LinePorts.Contains(port) {
		return "", false
	}
	return lp.UserAtPort(port)
}

// pbxDomain is the host part of a line's address of record.
func (s *Server) pbxDomain() string {
	if s.cfg.PBXDomain != "" {
		return s.cfg.PBXDomain
	}
	if s.cfg.Trunk != nil {
		return s.cfg.Trunk.Host
	}
	return s.cfg.ExternalHost
}

// trunkIdentity is the calling identity a call to the PBX must carry on
// behalf of localUser.
//
// In trunk mode it returns nothing and ok is true: the request is built
// exactly as it always has been, which is the point — no trunk deployment
// sees a header move because this feature exists.
//
// In lines mode ok is false when neither the caller nor the configured
// default has a line. That refuses the call, deliberately: sending it under
// another user's number would put the wrong name on someone's phone and the
// wrong entry in the exchange's records, and sending it under no line at all
// is rejected by the exchange anyway, several seconds later and with a worse
// explanation.
func (s *Server) trunkIdentity(localUser string) (from *sip.FromHeader, digestUser, secret string, ok bool) {
	if s.cfg.Lines == nil {
		return nil, "", "", true
	}
	user, found := s.lineUser(localUser)
	if !found {
		return nil, "", "", false
	}
	dn, _ := s.cfg.Lines.Number(user)
	digestUser, secret, _ = s.cfg.Lines.Credentials(user)
	// No tag: diago adds one to a From it did not build, and generating a
	// second here would be the only tag in the dialog that is not its.
	return &sip.FromHeader{
		Address: sip.Uri{Scheme: "sip", User: dn, Host: s.pbxDomain(), UriParams: sip.NewParams()},
		Params:  sip.NewParams(),
	}, digestUser, secret, true
}

// calleeInvite is what a callee leg's INVITE carries beyond its SDP: the
// wake's call-id header always, and — only when the callee is the PBX and
// only in lines mode — the calling line's From and digest credential.
//
// In trunk mode the result is exactly what this server has always sent: the
// one header, and no credentials, so diago builds the request as before
// (with an Originator, that means the caller's own From). Both callers go
// through here so there is one place to read, and one place a test can pin.
//
// ok is false only in lines mode, when neither the calling party nor the
// configured default has a line — see trunkIdentity for why that refuses the
// call rather than improvising one.
func (s *Server) calleeInvite(callID string, calleeTrunk bool, onBehalfOf string) (headers []sip.Header, digestUser, secret string, ok bool) {
	headers = []sip.Header{sip.NewHeader(CallIDHeader, callID)}
	if !calleeTrunk {
		return headers, "", "", true
	}
	from, du, sec, ok := s.trunkIdentity(onBehalfOf)
	if !ok {
		return nil, "", "", false
	}
	if from != nil {
		headers = append(headers, from)
	}
	return headers, du, sec, true
}

// linesMode reports whether the PBX leg presents registered lines.
func (s *Server) linesMode() bool { return s.cfg.Lines != nil }

// linesStarter is the part of the registry that runs its own registration
// loops. Optional: a test's stand-in registry implements Lines and nothing
// else, and never registers anything.
type linesStarter interface{ Start(ctx context.Context) }

// startLines begins the registrations, from Serve and alongside the trunk
// qualifier, so the loops share the server's lifetime.
//
// It runs before the listeners are actually up, as the qualifier does. That
// needs no synchronising: a REGISTER sent a moment too early fails like any
// other, and the loop retries it on its ordinary backoff — the same path
// that covers the far more common case of a PBX which is not up yet when
// this server boots.
func (s *Server) startLines(ctx context.Context) {
	st, ok := s.cfg.Lines.(linesStarter)
	if !ok {
		return
	}
	st.Start(ctx)
}

// linesRegistrarWatcher is the part of the registry that wants to hear when
// the exchange is reachable, and when it has disowned a line. Optional, as
// linesStarter is. See pbxline.Manager.RegistrarSeen and Unregistered.
type linesRegistrarWatcher interface {
	RegistrarSeen()
	Unregistered(user string)
}

// registrarSeen tells the registry the exchange has just been heard from:
// any request from it, any response to one of ours.
func (s *Server) registrarSeen() {
	if w, ok := s.cfg.Lines.(linesRegistrarWatcher); ok {
		w.RegistrarSeen()
	}
}

// lineUnregistered tells the registry the exchange has disowned user's
// line, so it is re-registered now.
func (s *Server) lineUnregistered(user string) {
	if w, ok := s.cfg.Lines.(linesRegistrarWatcher); ok {
		w.Unregistered(user)
	}
}

// exchangeSaysUnregistered reads a failed callee INVITE for CUCM's way of
// saying the calling line is not registered: 503 with Warning 399 "Unable
// to find a device handler for the request received on port …". Any other
// failure is the call's own business.
func exchangeSaysUnregistered(err error) bool {
	var res *sip.Response
	var byVal sipgo.ErrDialogResponse
	var byPtr *sipgo.ErrDialogResponse
	if errors.As(err, &byVal) {
		res = byVal.Res
	} else if errors.As(err, &byPtr) && byPtr != nil {
		res = byPtr.Res
	}
	if res == nil || res.StatusCode != 503 {
		return false
	}
	for _, h := range res.GetHeaders("Warning") {
		if strings.Contains(strings.ToLower(h.Value()), "device handler") {
			return true
		}
	}
	return false
}

// uriUser is the user part of a SIP URI, empty if it will not parse. A
// name-addr ("Matt" <sip:201@…>) is unwrapped first: the parser takes bare
// URIs only, and the difference between the two decides whether a call finds
// its line or is refused.
func uriUser(uri string) string {
	if i := strings.IndexByte(uri, '<'); i >= 0 {
		if j := strings.IndexByte(uri[i:], '>'); j > 0 {
			uri = uri[i+1 : i+j]
		}
	}
	var u sip.Uri
	if err := sip.ParseUri(uri, &u); err != nil {
		return ""
	}
	return u.User
}
