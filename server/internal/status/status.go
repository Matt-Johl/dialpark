// Package status serves the admin API's read-only views of live state
// (ADMIN-API.md §5.6–§5.8): the fleet, the server and the calls. Every
// answer is built from one snapshot of what the gateway, registry, line
// manager and B2BUA hold in memory, cached for a second and shared by
// every concurrent caller, so a client polling at any rate costs the
// call path one copy a second (§4.7).
package status

import (
	"net/http"
	"runtime"
	"time"

	"dialpark/server/internal/admin"
	"dialpark/server/internal/b2bua"
	"dialpark/server/internal/enroll"
	"dialpark/server/internal/gateway"
	"dialpark/server/internal/licence"
	"dialpark/server/internal/pbxline"
	"dialpark/server/internal/registry"
	"dialpark/server/internal/wire"
)

// Deps are the live sources, as functions so each is one snapshot call
// and tests can fake them. Any may be nil: that part of the view is then
// empty.
type Deps struct {
	Devices       func() []enroll.Device
	Sessions      func() map[string][]gateway.SessionInfo
	Endpoints     func() []registry.Endpoint
	Lines         func() []pbxline.Status
	Calls         func() []b2bua.CallView
	Trunk         func() b2bua.TrunkStatus
	AdminStats    func() admin.StatsView
	EventsDropped func() int64
	// Licence is the product licence summary (SPEC §4.9); nil → omitted.
	Licence func() licence.Summary
	Now     func() time.Time
}

// Info is the server's identity and effective startup configuration
// (ADMIN-API.md §5.7), fixed at start. Never a secret.
type Info struct {
	Version        string     `json:"version"`
	Go             string     `json:"go"`
	StartedAt      time.Time  `json:"started_at"`
	Mode           string     `json:"mode"` // standalone, trunk, lines
	Listeners      Listeners  `json:"listeners"`
	PublicHost     string     `json:"public_host"`
	LocalDomain    string     `json:"local_domain"`
	PublicSIPPort  int        `json:"public_sip_port"`
	PublicHTTPPort int        `json:"public_http_port"`
	TLS            TLSInfo    `json:"tls"`
	Trunk          *TrunkInfo `json:"trunk,omitempty"`
	PBX            *PBXInfo   `json:"pbx,omitempty"`
	RingTimeout    int        `json:"ring_timeout_seconds"`
	PeerTimeout    int        `json:"peer_timeout_seconds"`
	RTP            RTPInfo    `json:"rtp"`
	DataDir        string     `json:"data_dir"`
	DiagRetain     int        `json:"diag_retain_seconds"`
	Log            LogStartup `json:"log"`
}

// Listeners are the effective bind addresses.
type Listeners struct {
	Signal string `json:"signal"`
	SIP    string `json:"sip"`
	HTTP   string `json:"http"`
	Admin  string `json:"admin"`
	Trunk  string `json:"trunk,omitempty"`
}

// TLSInfo describes the certificate every phone pins. not_after is the
// date an operator must watch (ADMIN-API.md §10.1).
type TLSInfo struct {
	SelfSigned        bool      `json:"self_signed"`
	Subject           string    `json:"subject"`
	NotBefore         time.Time `json:"not_before,omitzero"`
	NotAfter          time.Time `json:"not_after,omitzero"`
	FingerprintSHA256 string    `json:"fingerprint_sha256"`
}

// TrunkInfo is the PBX leg's static configuration.
type TrunkInfo struct {
	URI                    string       `json:"uri"`
	Transport              string       `json:"transport"`
	SRTP                   string       `json:"srtp"`
	Codecs                 []string     `json:"codecs"`
	QualifyIntervalSeconds int          `json:"qualify_interval_seconds"`
	TLS                    TrunkTLSInfo `json:"tls"`
}

// TrunkTLSInfo says what was configured, never the material.
type TrunkTLSInfo struct {
	CertSet    bool   `json:"cert_set"`
	CASet      bool   `json:"ca_set"`
	Insecure   bool   `json:"insecure"`
	MinVersion string `json:"min_version"`
}

// PBXInfo is the lines-mode configuration.
type PBXInfo struct {
	Registrar             string   `json:"registrar"`
	Domain                string   `json:"domain"`
	Peers                 []string `json:"peers"`
	RegisterExpirySeconds int      `json:"register_expiry_seconds"`
	DefaultLine           string   `json:"default_line"`
	// LinePorts is the PBX-leg port range when each line has its own
	// socket ("5062-5099"); empty on the shared socket.
	LinePorts string `json:"line_ports,omitempty"`
}

// RTPInfo is the relay's port range and NAT behaviour.
type RTPInfo struct {
	Min       int  `json:"min"`
	Max       int  `json:"max"`
	Symmetric bool `json:"symmetric"`
}

// LogStartup is the log configuration the server started with.
type LogStartup struct {
	Level    string `json:"level"`
	JSON     bool   `json:"json"`
	SIPTrace bool   `json:"sip_trace"`
}

// ServerView is GET /v1/admin/server.
type ServerView struct {
	Info
	UptimeSeconds int64            `json:"uptime_seconds"`
	Trunk         *TrunkView       `json:"trunk,omitempty"`
	Counts        Counts           `json:"counts"`
	Admin         adminView        `json:"admin"`
	Licence       *licence.Summary `json:"licence,omitempty"`
}

// TrunkView is TrunkInfo plus the qualify state.
type TrunkView struct {
	TrunkInfo
	Qualify          string    `json:"qualify,omitempty"`
	QualifySince     time.Time `json:"qualify_since,omitzero"`
	QualifyLastError string    `json:"qualify_last_error,omitempty"`
}

// Counts is the fleet at a glance.
type Counts struct {
	Devices         int `json:"devices"`
	Enrolled        int `json:"enrolled"`
	Revoked         int `json:"revoked"`
	AppOnline       int `json:"app_online"`
	ExtensionOnline int `json:"extension_online"`
	SIPRegistered   int `json:"sip_registered"`
	LinesRegistered int `json:"lines_registered"`
	LinesFailed     int `json:"lines_failed"`
	Calls           int `json:"calls"`
}

type adminView struct {
	admin.StatsView
	EventsDropped int64 `json:"events_dropped"`
}

// FleetView is GET /v1/admin/status.
type FleetView struct {
	At      time.Time         `json:"at"`
	Trunk   b2bua.TrunkStatus `json:"trunk"`
	Licence *licence.Summary  `json:"licence,omitempty"`
	Devices []DeviceStatus    `json:"devices"`
}

// DeviceStatus is one device's live state.
type DeviceStatus struct {
	DeviceID    string `json:"device_id"`
	User        string `json:"user"`
	Description string `json:"description,omitempty"`
	Revoked     bool   `json:"revoked"`
	Enrolled    bool   `json:"enrolled"`
	// Licensed is whether the device holds a licence seat (SPEC §4.9).
	Licensed bool                `json:"licensed"`
	Sessions map[string]*Session `json:"sessions"`
	SIP      *SIPStatus          `json:"sip,omitempty"`
	Line     *LineStatus         `json:"line,omitempty"`
	Call     *CallRef            `json:"call,omitempty"`
}

// Session is one live connection.
type Session struct {
	Online     bool      `json:"online"`
	Since      time.Time `json:"since"`
	Addr       string    `json:"addr"`
	AppVersion string    `json:"app_version,omitempty"`
}

// SIPStatus is a live registration.
type SIPStatus struct {
	Registered bool      `json:"registered"`
	Contact    string    `json:"contact"`
	ExpiresAt  time.Time `json:"expires_at"`
}

// LineStatus is pbxline.Status minus what the record already carries.
type LineStatus struct {
	State     string    `json:"state"`
	Since     time.Time `json:"since"`
	ExpiresAt time.Time `json:"expires_at,omitzero"`
	Realm     string    `json:"realm,omitempty"`
	Error     string    `json:"error,omitempty"`
	Attempts  int       `json:"attempts,omitempty"`
	// Port is the PBX-leg socket the line registers from when the server
	// runs one per line; 0 on the shared socket.
	Port int `json:"port,omitempty"`
}

// CallRef points at the call a device is on.
type CallRef struct {
	CallID string    `json:"call_id"`
	Since  time.Time `json:"since"`
}

// snapshot is everything the three views are built from, taken once.
type snapshot struct {
	at        time.Time
	devices   []enroll.Device
	sessions  map[string][]gateway.SessionInfo
	endpoints map[string]registry.Endpoint // by user
	lines     map[string]pbxline.Status    // by user
	calls     []b2bua.CallView
	trunk     b2bua.TrunkStatus
	licence   *licence.Summary
}

// Handler serves GET /v1/admin/status, /v1/admin/server and /v1/admin/calls.
type Handler struct {
	deps Deps
	info Info
	snap *admin.Snapshot[snapshot]
	mux  *http.ServeMux
}

// New builds the handler. info is fixed; deps are read per snapshot.
func New(info Info, deps Deps) *Handler {
	if deps.Now == nil {
		deps.Now = time.Now
	}
	info.Go = runtime.Version()
	h := &Handler{deps: deps, info: info}
	h.snap = admin.NewSnapshot(h.take)
	h.snap.Now = deps.Now
	h.mux = http.NewServeMux()
	h.mux.HandleFunc("GET /v1/admin/status", h.status)
	h.mux.HandleFunc("GET /v1/admin/server", h.server)
	h.mux.HandleFunc("GET /v1/admin/calls", h.calls)
	return h
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) { h.mux.ServeHTTP(w, r) }

func (h *Handler) take() snapshot {
	s := snapshot{at: h.deps.Now(), endpoints: map[string]registry.Endpoint{}, lines: map[string]pbxline.Status{}}
	if h.deps.Devices != nil {
		s.devices = h.deps.Devices()
	}
	if h.deps.Sessions != nil {
		s.sessions = h.deps.Sessions()
	}
	if h.deps.Endpoints != nil {
		for _, ep := range h.deps.Endpoints() {
			s.endpoints[ep.User] = ep
		}
	}
	if h.deps.Lines != nil {
		for _, l := range h.deps.Lines() {
			s.lines[l.User] = l
		}
	}
	if h.deps.Calls != nil {
		s.calls = h.deps.Calls()
	}
	if h.deps.Trunk != nil {
		s.trunk = h.deps.Trunk()
	}
	if h.deps.Licence != nil {
		l := h.deps.Licence()
		s.licence = &l
	}
	return s
}

func (h *Handler) status(w http.ResponseWriter, r *http.Request) {
	s := h.snap.Get()
	// A device is on a call when one of the call's app legs is its user.
	onCall := map[string]CallRef{}
	for _, c := range s.calls {
		for _, leg := range []*b2bua.LegView{c.A, c.B} {
			if leg != nil && leg.Leg == "app" && leg.User != "" {
				onCall[leg.User] = CallRef{CallID: c.CallID, Since: c.Since}
			}
		}
	}
	view := FleetView{At: s.at, Trunk: s.trunk, Licence: s.licence, Devices: make([]DeviceStatus, 0, len(s.devices))}
	for _, d := range s.devices {
		ds := DeviceStatus{
			DeviceID: d.DeviceID, User: d.User, Description: d.Description,
			Revoked: d.Revoked, Enrolled: d.Enrolled, Licensed: d.Licensed, Sessions: map[string]*Session{},
		}
		for _, si := range s.sessions[d.DeviceID] {
			ds.Sessions[string(si.Kind)] = &Session{Online: true, Since: si.Since, Addr: si.Addr, AppVersion: si.AppVersion}
		}
		if ep, ok := s.endpoints[d.User]; ok && ep.Contact != "" {
			ds.SIP = &SIPStatus{Registered: true, Contact: ep.Contact, ExpiresAt: ep.Expires}
		}
		if l, ok := s.lines[d.User]; ok {
			ds.Line = &LineStatus{State: string(l.State), Since: l.Since, ExpiresAt: l.ExpiresAt, Realm: l.Realm, Error: l.Error, Attempts: l.Attempts, Port: l.Port}
		}
		if c, ok := onCall[d.User]; ok {
			cc := c
			ds.Call = &cc
		}
		view.Devices = append(view.Devices, ds)
	}
	admin.WriteJSON(w, http.StatusOK, view)
}

func (h *Handler) server(w http.ResponseWriter, r *http.Request) {
	s := h.snap.Get()
	view := ServerView{Info: h.info, UptimeSeconds: int64(s.at.Sub(h.info.StartedAt).Seconds()), Licence: s.licence}
	if h.info.Trunk != nil {
		view.Trunk = &TrunkView{TrunkInfo: *h.info.Trunk, Qualify: s.trunk.Qualify, QualifySince: s.trunk.Since, QualifyLastError: s.trunk.LastError}
	}
	view.Info.Trunk = nil // carried by view.Trunk with the live state
	for _, d := range s.devices {
		view.Counts.Devices++
		if d.Enrolled {
			view.Counts.Enrolled++
		}
		if d.Revoked {
			view.Counts.Revoked++
		}
		for _, si := range s.sessions[d.DeviceID] {
			switch si.Kind {
			case wire.ClientApp:
				view.Counts.AppOnline++
			case wire.ClientExtension:
				view.Counts.ExtensionOnline++
			}
		}
		if ep, ok := s.endpoints[d.User]; ok && ep.Contact != "" {
			view.Counts.SIPRegistered++
		}
	}
	for _, l := range s.lines {
		switch l.State {
		case pbxline.StateRegistered:
			view.Counts.LinesRegistered++
		case pbxline.StateRefused, pbxline.StateRetrying:
			view.Counts.LinesFailed++
		}
	}
	view.Counts.Calls = len(s.calls)
	if h.deps.AdminStats != nil {
		view.Admin.StatsView = h.deps.AdminStats()
	}
	if h.deps.EventsDropped != nil {
		view.Admin.EventsDropped = h.deps.EventsDropped()
	}
	admin.WriteJSON(w, http.StatusOK, view)
}

func (h *Handler) calls(w http.ResponseWriter, r *http.Request) {
	s := h.snap.Get()
	calls := s.calls
	if calls == nil {
		calls = []b2bua.CallView{}
	}
	admin.WriteJSON(w, http.StatusOK, calls)
}
