package b2bua

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/emiago/diago"
	"github.com/emiago/sipgo"
	"github.com/emiago/sipgo/sip"

	"dialpark/server/internal/pbx"
	"dialpark/server/internal/pbxline"
	"dialpark/server/internal/registry"
	"dialpark/server/internal/routing"
	"dialpark/server/internal/tlsutil"
)

// A socket per line (SPEC §6 item 3c): an exchange binds a third-party SIP
// device to the address and port it registers from, one device per
// address, so two lines on one socket can never both be registered (CUCM,
// 2026-10-29). With a port range each line registers from, is called on,
// and calls out of its own socket. The unit tests below pin the transport
// choice; the live ones prove the vendored sipgo/diago patches on real
// sockets, bound to 0.0.0.0 as in production (a loopback bind would take
// the pinned-address path that already worked).

// portLines is fakeLines with a socket per line.
type portLines struct {
	fakeLines
	ports map[string]int
}

func (p portLines) Port(user string) (int, bool) {
	port, ok := p.ports[user]
	return port, ok
}

func (p portLines) UserAtPort(port int) (string, bool) {
	for u, pp := range p.ports {
		if pp == port {
			return u, true
		}
	}
	return "", false
}

func udpTrunk(host string) *pbx.Trunk { return &pbx.Trunk{Host: host, Port: 5060, Transport: "udp"} }

func TestLineTransportsAndContacts(t *testing.T) {
	lines := portLines{fakeLines{"201": {"201", "s"}, "202": {"202", "s"}}, map[string]int{"201": 5062, "202": 5063}}
	s := &Server{cfg: Config{
		Trunk: udpTrunk("cucm.example"), TrunkBind: "0.0.0.0:5062", TrunkExternalHost: "10.0.0.1",
		Lines: lines, DefaultLine: "202", LinePorts: pbxline.PortRange{First: 5062, Last: 5065},
	}}
	for port, want := range map[int]string{0: transportTrunk, 5062: transportTrunk, 5063: "line:5063", 5065: "line:5065", 5070: transportTrunk} {
		if got := s.lineTransport(port); got != want {
			t.Errorf("lineTransport(%d) = %q, want %q", port, got, want)
		}
	}
	for _, tc := range []struct {
		trunk bool
		user  string
		want  string
	}{
		{false, "201", transportApp},
		{true, "201", transportTrunk}, // the first port is the trunk socket
		{true, "202", "line:5063"},
		{true, "nobody", "line:5063"}, // the default line's socket
	} {
		if got := s.calleeTransport(tc.trunk, tc.user); got != tc.want {
			t.Errorf("calleeTransport(%v, %q) = %q, want %q", tc.trunk, tc.user, got, tc.want)
		}
	}
	for port, want := range map[int]int{0: 5062, 5062: 5062, 5063: 5063, 5070: 5062} {
		u, ok := s.LineContact(port)
		if !ok || u.Port != want || u.Host != "10.0.0.1" {
			t.Errorf("LineContact(%d) = %s, %v; want port %d", port, u.String(), ok, want)
		}
	}
	for recv, want := range map[string]string{"[::]:5062": "201", "[::]:5063": "202", "0.0.0.0:5063": "202", "[::]:5064": "", "[::]:5070": "", "": ""} {
		req := sip.NewRequest(sip.INVITE, sip.Uri{Host: "x"})
		req.SetReceivedOn(recv)
		got, ok := s.inboundLine(req)
		if got != want || ok != (want != "") {
			t.Errorf("inboundLine(received on %q) = %q, %v; want %q", recv, got, ok, want)
		}
	}
	// No range: no transport choice and no attribution by port, whatever
	// the registry says.
	s.cfg.LinePorts = pbxline.PortRange{}
	if got := s.calleeTransport(true, "202"); got != transportTrunk {
		t.Errorf("without a range calleeTransport = %q", got)
	}
	req := sip.NewRequest(sip.INVITE, sip.Uri{Host: "x"})
	req.SetReceivedOn("[::]:5063")
	if _, ok := s.inboundLine(req); ok {
		t.Error("without a range a request was attributed by port")
	}
	// A registry without ports (trunk-mode tests, older registries): the
	// trunk socket.
	s.cfg.LinePorts = pbxline.PortRange{First: 5062, Last: 5065}
	s.cfg.Lines = fakeLines{"202": {"202", "s"}}
	if got := s.calleeTransport(true, "202"); got != transportTrunk {
		t.Errorf("registry without ports: calleeTransport = %q", got)
	}
	// Trunk mode: untouched.
	s.cfg.Lines = nil
	if got := s.calleeTransport(true, "202"); got != transportTrunk {
		t.Errorf("trunk mode: calleeTransport = %q", got)
	}
}

func TestLinePortsConfigIsRefusedWhenItCannotWork(t *testing.T) {
	tlsCfg, _, err := tlsutil.LoadOrKeep("", "", []string{"127.0.0.1"}, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	base := func() Config {
		return Config{
			TLS: tlsCfg, BindHost: "127.0.0.1", Port: 5061, ExternalHost: "127.0.0.1", Domains: []string{"dialpark"},
			Trunk: udpTrunk("127.0.0.1"), TrunkExternalHost: "127.0.0.1", LinePorts: pbxline.PortRange{First: 5062, Last: 5065},
			Logger: slog.New(slog.NewTextHandler(tWriter{t}, nil)),
		}
	}
	for name, tc := range map[string]struct {
		change func(*Config)
		want   string
	}{
		"no trunk":                      {func(c *Config) { c.Trunk = nil }, "-trunk"},
		"tcp trunk":                     {func(c *Config) { c.Trunk.Transport = "tcp" }, "UDP"},
		"trunk-addr not the first port": {func(c *Config) { c.TrunkBind = "0.0.0.0:5070" }, "first line port"},
		"app port inside":               {func(c *Config) { c.LinePorts = pbxline.PortRange{First: 5060, Last: 5065} }, "app leg"},
	} {
		cfg := base()
		tc.change(&cfg)
		reg := registry.New(nil)
		_, err := New(cfg, reg, routing.New(reg, cfg.Domains, func() bool { return true }), nil)
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: err = %v, want one mentioning %q", name, err, tc.want)
		}
	}
	// And the shapes that work: the first port as -trunk-addr, or none.
	for _, bind := range []string{"", "0.0.0.0:5062", ":5062"} {
		cfg := base()
		cfg.TrunkBind = bind
		reg := registry.New(nil)
		if _, err := New(cfg, reg, routing.New(reg, cfg.Domains, func() bool { return true }), nil); err != nil {
			t.Errorf("trunk bind %q: %v", bind, err)
		}
	}
}

// ---- live: real sockets, the vendored transport patches ---------------------

// freePortRange finds n consecutive UDP ports free on every address.
func freePortRange(t *testing.T, n int) []int {
	t.Helper()
	for attempt := 0; attempt < 50; attempt++ {
		c, err := net.ListenPacket("udp", "0.0.0.0:0")
		if err != nil {
			skipIfNoBind(t, err)
			t.Fatal(err)
		}
		base := c.LocalAddr().(*net.UDPAddr).Port
		c.Close()
		if base+n-1 > 65535 {
			continue
		}
		ok := true
		for p := base; p < base+n; p++ {
			l, err := net.ListenPacket("udp", fmt.Sprintf("0.0.0.0:%d", p))
			if err != nil {
				ok = false
				break
			}
			l.Close()
		}
		if ok {
			ports := make([]int, n)
			for i := range ports {
				ports[i] = base + i
			}
			return ports
		}
	}
	t.Fatal("no free run of UDP ports")
	return nil
}

// startLinesServer serves a B2BUA with a socket per line on loopback, the
// PBX leg bound to 0.0.0.0 on the ports given (the first is the trunk
// listener), with lines as its registry.
func startLinesServer(t *testing.T, lines Lines, ports []int) *Server {
	t.Helper()
	tlsCfg, _, err := tlsutil.LoadOrKeep("", "", []string{"127.0.0.1"}, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	reg := registry.New(nil)
	cfg := Config{
		TLS: tlsCfg, BindHost: "127.0.0.1", Port: freePort(t, "tcp"), ExternalHost: "127.0.0.1",
		Domains:           []string{"dialpark"},
		Trunk:             udpTrunk("127.0.0.1"),
		TrunkBind:         fmt.Sprintf("0.0.0.0:%d", ports[0]),
		TrunkExternalHost: "127.0.0.1",
		LinePorts:         pbxline.PortRange{First: ports[0], Last: ports[len(ports)-1]},
		RingTimeout:       5 * time.Second,
		Logger:            slog.New(slog.NewTextHandler(tWriter{t}, nil)),
	}
	s, err := New(cfg, reg, routing.New(reg, cfg.Domains, func() bool { return true }), nil)
	if err != nil {
		t.Fatal(err)
	}
	s.SetLines(lines)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go func() { _ = s.Serve(ctx) }()
	deadline := time.Now().Add(3 * time.Second)
	for _, p := range ports {
		for {
			c, err := net.ListenPacket("udp", fmt.Sprintf("0.0.0.0:%d", p))
			if err != nil {
				break
			}
			c.Close()
			if time.Now().After(deadline) {
				t.Fatalf("the listener on %d never came up", p)
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
	return s
}

// rawPBX is the exchange as one UDP socket and a parser: it sees exactly
// which of the server's sockets each request or response came from.
type rawPBX struct {
	t      *testing.T
	conn   net.PacketConn
	parser *sip.Parser
	seq    int
}

func newRawPBX(t *testing.T) *rawPBX {
	t.Helper()
	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		skipIfNoBind(t, err)
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return &rawPBX{t: t, conn: conn, parser: sip.NewParser()}
}

func (p *rawPBX) port() int { return p.conn.LocalAddr().(*net.UDPAddr).Port }

func (p *rawPBX) send(msg sip.Message, to *net.UDPAddr) {
	p.t.Helper()
	if _, err := p.conn.WriteTo([]byte(msg.String()), to); err != nil {
		p.t.Fatal(err)
	}
}

// read returns the next SIP message and the server socket it came from.
func (p *rawPBX) read() (sip.Message, *net.UDPAddr) {
	p.t.Helper()
	buf := make([]byte, 65535)
	_ = p.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	n, from, err := p.conn.ReadFrom(buf)
	if err != nil {
		p.t.Fatalf("read: %v", err)
	}
	msg, err := p.parser.ParseSIP(buf[:n])
	if err != nil {
		p.t.Fatalf("parse: %v\n%s", err, buf[:n])
	}
	return msg, from.(*net.UDPAddr)
}

func (p *rawPBX) readRequest(method sip.RequestMethod) (*sip.Request, *net.UDPAddr) {
	p.t.Helper()
	for {
		msg, from := p.read()
		req, ok := msg.(*sip.Request)
		if !ok {
			continue
		}
		if req.Method == method {
			return req, from
		}
	}
}

// options sends an OPTIONS to the server socket on port and waits for its
// 200. Each one leaves the pool entry for this address naming that socket,
// which is how the exchange's traffic looks after two lines have spoken.
func (p *rawPBX) options(port int) {
	p.t.Helper()
	p.seq++
	params := sip.NewParams()
	params.Add("transport", "udp")
	req := sip.NewRequest(sip.OPTIONS, sip.Uri{Scheme: "sip", Host: "127.0.0.1", Port: port, UriParams: params})
	via := sip.NewParams()
	via.Add("branch", sip.GenerateBranch())
	req.AppendHeader(&sip.ViaHeader{ProtocolName: "SIP", ProtocolVersion: "2.0", Transport: "UDP", Host: "127.0.0.1", Port: p.port(), Params: via})
	fromParams := sip.NewParams()
	fromParams.Add("tag", sip.GenerateTagN(8))
	req.AppendHeader(&sip.FromHeader{Address: sip.Uri{Scheme: "sip", User: "pbx", Host: "127.0.0.1", UriParams: sip.NewParams()}, Params: fromParams})
	req.AppendHeader(&sip.ToHeader{Address: sip.Uri{Scheme: "sip", Host: "127.0.0.1", Port: port, UriParams: sip.NewParams()}, Params: sip.NewParams()})
	callID := sip.CallIDHeader(fmt.Sprintf("opt-%d-%d", port, p.seq))
	req.AppendHeader(&callID)
	req.AppendHeader(&sip.CSeqHeader{SeqNo: uint32(p.seq), MethodName: sip.OPTIONS})
	mf := sip.MaxForwardsHeader(70)
	req.AppendHeader(&mf)
	req.SetBody(nil)
	p.send(req, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port})
	for {
		msg, from := p.read()
		if res, ok := msg.(*sip.Response); ok && res.CSeq().MethodName == sip.OPTIONS {
			if from.Port != port {
				p.t.Fatalf("the 200 to an OPTIONS sent to %d came from %d", port, from.Port)
			}
			return
		}
	}
}

func portOf(t *testing.T, addr string) int {
	t.Helper()
	_, port, err := sip.ParseAddr(addr)
	if err != nil {
		t.Fatalf("bad address %q: %v", addr, err)
	}
	return port
}

func liveLines(ports []int) portLines {
	return portLines{
		fakeLines{"201": {"201", "s"}, "202": {"202", "s"}},
		map[string]int{"201": ports[0], "202": ports[1]},
	}
}

// A request on behalf of a line before its listener is up fails and takes
// nothing: the line loops start before the listeners are bound, and a
// client socket on the line's port would leave the listener with "address
// already in use" (lines bench 2026-10-29, one run in three). The
// registrar retries on its backoff.
func TestLineRequestBeforeTheListenerIsUpTakesNoPort(t *testing.T) {
	ports := freePortRange(t, 2)
	tlsCfg, _, err := tlsutil.LoadOrKeep("", "", []string{"127.0.0.1"}, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	reg := registry.New(nil)
	cfg := Config{
		TLS: tlsCfg, BindHost: "127.0.0.1", Port: freePort(t, "tcp"), ExternalHost: "127.0.0.1",
		Domains: []string{"dialpark"}, Trunk: udpTrunk("127.0.0.1"),
		TrunkBind: fmt.Sprintf("0.0.0.0:%d", ports[0]), TrunkExternalHost: "127.0.0.1",
		LinePorts: pbxline.PortRange{First: ports[0], Last: ports[1]},
		Logger:    slog.New(slog.NewTextHandler(tWriter{t}, nil)),
	}
	s, err := New(cfg, reg, routing.New(reg, cfg.Domains, func() bool { return true }), nil)
	if err != nil {
		t.Fatal(err)
	}
	// Not served: no listener holds any line port.
	pbx := newRawPBX(t)
	params := sip.NewParams()
	params.Add("transport", "udp")
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_, err = s.LineClient(ports[1]).Do(ctx, sip.NewRequest(sip.OPTIONS, sip.Uri{Scheme: "sip", Host: "127.0.0.1", Port: pbx.port(), UriParams: params}))
	if err == nil || !strings.Contains(err.Error(), "no udp listener") {
		t.Fatalf("a request before the listener is up: err = %v, want a refusal naming the missing listener", err)
	}
	// The port is still free for the listener.
	l, err := net.ListenPacket("udp", fmt.Sprintf("0.0.0.0:%d", ports[1]))
	if err != nil {
		t.Fatalf("the line port was taken by the request: %v", err)
	}
	l.Close()
}

// A line's REGISTER leaves from the line's own socket and names its port,
// even after the exchange has spoken to another socket last (the
// remote-keyed pool then names that one).
func TestLineRegisterLeavesFromItsOwnSocket(t *testing.T) {
	ports := freePortRange(t, 2)
	s := startLinesServer(t, liveLines(ports), ports)
	pbx := newRawPBX(t)
	pbx.options(ports[1])
	pbx.options(ports[0])

	regParams := sip.NewParams()
	regParams.Add("transport", "udp")
	reg, err := pbxline.NewSIPRegistrar(pbxline.SIPConfig{
		Registrar: sip.Uri{Scheme: "sip", Host: "127.0.0.1", Port: pbx.port(), UriParams: regParams},
		Domain:    "pbx.example",
		Transport: func(port int) (*sipgo.Client, sip.Uri, bool) {
			c := s.LineClient(port)
			u, ok := s.LineContact(port)
			return c, u, ok && c != nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := reg.Register(ctx, pbxline.Line{User: "202", DN: "202", DigestUser: "202", Secret: "s", Port: ports[1]}, time.Minute)
		done <- err
	}()
	req, from := pbx.readRequest(sip.REGISTER)
	if from.Port != ports[1] {
		t.Errorf("the REGISTER left from port %d, want the line's %d", from.Port, ports[1])
	}
	if req.Via().Port != ports[1] {
		t.Errorf("Via port = %d, want %d", req.Via().Port, ports[1])
	}
	if c := req.Contact(); c == nil || c.Address.Port != ports[1] || c.Address.User != "202" {
		t.Errorf("Contact = %v, want 202 at port %d", c, ports[1])
	}
	res := sip.NewResponseFromRequest(req, 200, "OK", nil)
	res.AppendHeader(sip.NewHeader("Expires", "60"))
	pbx.send(res, from)
	if err := <-done; err != nil {
		t.Fatalf("register: %v", err)
	}
}

// pinnedPBXClient is pbxClient with every request leaving from its listener,
// so the server sees one exchange address throughout.
func pinnedPBXClient(t *testing.T) *pbxClient {
	t.Helper()
	ua, err := sipgo.NewUA()
	if err != nil {
		t.Fatal(err)
	}
	port := freePort(t, "udp")
	client, err := sipgo.NewClient(ua, sipgo.WithClientHostname("127.0.0.1"), sipgo.WithClientPort(port),
		sipgo.WithClientConnectionAddr(fmt.Sprintf("127.0.0.1:%d", port)))
	if err != nil {
		t.Fatal(err)
	}
	srv, err := sipgo.NewServer(ua)
	if err != nil {
		t.Fatal(err)
	}
	c := &pbxClient{byes: make(chan *sip.Request, 4)}
	srv.OnBye(func(req *sip.Request, tx sip.ServerTransaction) {
		_ = tx.Respond(sip.NewResponseFromRequest(req, 200, "OK", nil))
		c.byes <- req
	})
	ctx, cancel := context.WithCancel(context.Background())
	go func() { _ = srv.ListenAndServe(ctx, "udp", fmt.Sprintf("127.0.0.1:%d", port)) }()
	t.Cleanup(func() { cancel(); client.Close(); ua.Close() })
	deadline := time.Now().Add(3 * time.Second)
	for {
		l, err := net.ListenPacket("udp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			break
		}
		l.Close()
		if time.Now().After(deadline) {
			t.Fatal("the PBX client's listener never came up")
		}
		time.Sleep(20 * time.Millisecond)
	}
	c.ua = &sipgo.DialogUA{Client: client,
		ContactHDR: sip.ContactHeader{Address: sip.Uri{User: "pbx", Host: "127.0.0.1", Port: port, UriParams: sip.NewParams()}}}
	return c
}

func (c *pbxClient) optionsTo(t *testing.T, ctx context.Context, port int) {
	t.Helper()
	params := sip.NewParams()
	params.Add("transport", "udp")
	res, err := c.ua.Client.Do(ctx, sip.NewRequest(sip.OPTIONS, sip.Uri{Scheme: "sip", Host: "127.0.0.1", Port: port, UriParams: params}))
	if err != nil {
		t.Fatalf("options to %d: %v", port, err)
	}
	if got := portOf(t, res.Source()); got != port {
		t.Fatalf("the 200 to an OPTIONS sent to %d came from %d", port, got)
	}
}

// inviteTo is pbxClient.invite with the To user chosen, to the server
// socket on port. Any final response is returned; a failure is nil.
func (c *pbxClient) inviteTo(t *testing.T, ctx context.Context, port int, user string, body []byte) (*sip.Response, error) {
	t.Helper()
	params := sip.NewParams()
	params.Add("transport", "udp")
	to := sip.Uri{User: user, Host: "127.0.0.1", Port: port, UriParams: params}
	var hdrs []sip.Header
	if body != nil {
		hdrs = append(hdrs, sip.NewHeader("Content-Type", "application/sdp"))
	}
	dlg, err := c.ua.Invite(ctx, to, body, hdrs...)
	if err != nil {
		return nil, err
	}
	c.dlg = dlg
	if err := dlg.WaitAnswer(ctx, sipgo.AnswerOptions{}); err != nil {
		return dlg.InviteResponse, err
	}
	return dlg.InviteResponse, nil
}

// A call from the exchange to a line's socket is answered from that socket,
// with that socket's port in Contact, and belongs to that line whatever the
// To user says — while the same INVITE to another line's socket is that
// other line's.
func TestInboundInviteAnsweredFromTheSocketItArrivedOn(t *testing.T) {
	ports := freePortRange(t, 2)
	// The echo user is the line on the second socket; "201" the first.
	lines := portLines{
		fakeLines{"201": {"201", "s"}, routing.EchoUser: {"900", "s"}},
		map[string]int{"201": ports[0], routing.EchoUser: ports[1]},
	}
	startLinesServer(t, lines, ports)
	pbx := pinnedPBXClient(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	// Two lines have spoken; the pool entry for our address names the
	// first socket.
	pbx.optionsTo(t, ctx, ports[1])
	pbx.optionsTo(t, ctx, ports[0])

	media, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer media.Close()
	mediaPort := media.LocalAddr().(*net.UDPAddr).Port

	// To names the first line; the socket says the echo line. The socket
	// wins and the call is answered (echo), from that socket.
	res, err := pbx.inviteTo(t, ctx, ports[1], "201", pcmuSDP(mediaPort))
	if err != nil {
		t.Fatalf("invite to the echo line's socket: %v", err)
	}
	if got := portOf(t, res.Source()); got != ports[1] {
		t.Errorf("the 200 OK came from port %d, want the socket the INVITE went to, %d", got, ports[1])
	}
	if c := res.Contact(); c == nil || c.Address.Port != ports[1] {
		t.Errorf("Contact = %v, want port %d", c, ports[1])
	}
	pbx.ack(t, ctx, nil)
	if err := pbx.dlg.Bye(ctx); err != nil {
		t.Fatalf("bye: %v", err)
	}

	// The same INVITE to the first line's socket is for 201, which has no
	// phone registered, so it is not answered by the echo: the router
	// sends an unregistered user back to the PBX, and that leg is refused
	// for want of a line of the caller's (403). Whatever the code, it is
	// a refusal, and it comes from the first socket.
	res, err = pbx.inviteTo(t, ctx, ports[0], "201", pcmuSDP(mediaPort))
	if err == nil || res == nil || res.StatusCode < 400 {
		t.Fatalf("invite to the first socket: res %v err %v, want a refusal", res, err)
	}
	if got := portOf(t, res.Source()); got != ports[0] {
		t.Errorf("the 404 came from port %d, want %d", got, ports[0])
	}
}

// A call the server places on a line's behalf — INVITE, ACK and BYE —
// leaves from that line's socket with its port in Via and Contact, after
// the exchange has spoken to another socket last.
func TestOutboundLineDialogStaysOnItsSocket(t *testing.T) {
	ports := freePortRange(t, 2)
	s := startLinesServer(t, liveLines(ports), ports)
	pbx := newRawPBX(t)
	pbx.options(ports[1])
	pbx.options(ports[0])

	media, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer media.Close()
	mediaPort := media.LocalAddr().(*net.UDPAddr).Port

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	params := sip.NewParams()
	params.Add("transport", "udp")
	dst := sip.Uri{Scheme: "sip", User: "100", Host: "127.0.0.1", Port: pbx.port(), UriParams: params}
	d, err := s.dg.NewDialog(dst, diago.NewDialogOptions{TransportID: s.calleeTransport(true, "202")})
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	done := make(chan error, 1)
	go func() { done <- d.Invite(ctx, diago.InviteClientOptions{}) }()

	inv, from := pbx.readRequest(sip.INVITE)
	if from.Port != ports[1] {
		t.Errorf("the INVITE left from port %d, want the line's %d", from.Port, ports[1])
	}
	if inv.Via().Port != ports[1] {
		t.Errorf("Via port = %d, want %d", inv.Via().Port, ports[1])
	}
	if c := inv.Contact(); c == nil || c.Address.Port != ports[1] {
		t.Errorf("Contact = %v, want port %d", c, ports[1])
	}
	res := sip.NewResponseFromRequest(inv, 200, "OK", pcmuSDP(mediaPort))
	res.To().Params.Add("tag", "pbx-"+strconv.Itoa(ports[1]))
	res.AppendHeader(&sip.ContactHeader{Address: sip.Uri{Scheme: "sip", User: "100", Host: "127.0.0.1", Port: pbx.port(), UriParams: sip.NewParams()}})
	res.AppendHeader(sip.NewHeader("Content-Type", "application/sdp"))
	pbx.send(res, from)
	if err := <-done; err != nil {
		t.Fatalf("invite: %v", err)
	}
	if err := d.Ack(ctx); err != nil {
		t.Fatalf("ack: %v", err)
	}
	if _, from := pbx.readRequest(sip.ACK); from.Port != ports[1] {
		t.Errorf("the ACK left from port %d, want %d", from.Port, ports[1])
	}

	go func() { done <- d.Hangup(ctx) }()
	bye, from := pbx.readRequest(sip.BYE)
	if from.Port != ports[1] {
		t.Errorf("the BYE left from port %d, want the line's %d", from.Port, ports[1])
	}
	pbx.send(sip.NewResponseFromRequest(bye, 200, "OK", nil), from)
	if err := <-done; err != nil {
		t.Fatalf("hangup: %v", err)
	}
}
