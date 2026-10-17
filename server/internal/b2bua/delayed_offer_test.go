package b2bua

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/emiago/sipgo"
	"github.com/emiago/sipgo/sip"

	"dialpark/server/internal/pbx"
	"dialpark/server/internal/registry"
	"dialpark/server/internal/routing"
	"dialpark/server/internal/tlsutil"
)

// Delayed offer on the PBX leg (SPEC §6 item 3c; CUCM lines bench
// 2026-10-17 09:17:39): CUCM's INVITE to a third-party SIP line carries no
// SDP. The server rang the app, the app answered, and answering the caller
// then failed with diago's "no sdp present in INVITE" — the call dropped
// the moment it was picked up. RFC 3261 §13.2.1: when the INVITE has no
// offer, the 200 OK makes it and the ACK answers it.
//
// These run a real B2BUA on loopback with a UDP trunk listener and act as
// the PBX against it, calling the echo destination so the whole thing
// needs no app leg: the server must answer a bodiless INVITE with an SDP
// offer, take the answer from the ACK, and relay media on the addresses
// that answer named. The early-offer twin proves the path every Asterisk
// gate uses is unchanged by the same patch.

type tWriter struct{ t *testing.T }

func (w tWriter) Write(p []byte) (int, error) {
	w.t.Log(strings.TrimRight(string(p), "\n"))
	return len(p), nil
}

// skipIfNoBind: a build sandbox that forbids binding sockets cannot run a
// live B2BUA. Only that error skips; anything else is a failure.
func skipIfNoBind(t *testing.T, err error) {
	t.Helper()
	if errors.Is(err, syscall.EPERM) {
		t.Skipf("cannot bind a loopback socket here (%v); run outside the sandbox or in a container", err)
	}
}

func freePort(t *testing.T, network string) int {
	t.Helper()
	if network == "udp" {
		c, err := net.ListenPacket("udp", "127.0.0.1:0")
		if err != nil {
			skipIfNoBind(t, err)
			t.Fatal(err)
		}
		defer c.Close()
		return c.LocalAddr().(*net.UDPAddr).Port
	}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		skipIfNoBind(t, err)
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

// startTrunkServer serves a B2BUA on loopback: the app leg on a TLS port
// nothing dials, the trunk listener on UDP. Returns the trunk address.
func startTrunkServer(t *testing.T) string {
	t.Helper()
	tlsCfg, _, err := tlsutil.LoadOrKeep("", "", []string{"127.0.0.1"}, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	trunkPort := freePort(t, "udp")
	trunkAddr := fmt.Sprintf("127.0.0.1:%d", trunkPort)
	reg := registry.New(nil)
	cfg := Config{
		TLS: tlsCfg, BindHost: "127.0.0.1", Port: freePort(t, "tcp"), ExternalHost: "127.0.0.1",
		Domains:           []string{"dialpark"},
		Trunk:             &pbx.Trunk{Host: "127.0.0.1", Port: 5060, Transport: "udp"},
		TrunkBind:         trunkAddr,
		TrunkExternalHost: "127.0.0.1",
		RingTimeout:       5 * time.Second,
		Logger:            slog.New(slog.NewTextHandler(tWriter{t}, nil)),
	}
	s, err := New(cfg, reg, routing.New(reg, cfg.Domains, func() bool { return true }), nil)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go func() { _ = s.Serve(ctx) }()
	// Serve binds asynchronously: the trunk port is ours to take until it is.
	deadline := time.Now().Add(3 * time.Second)
	for {
		c, err := net.ListenPacket("udp", trunkAddr)
		if err != nil {
			break
		}
		c.Close()
		if time.Now().After(deadline) {
			t.Fatal("the trunk listener never came up")
		}
		time.Sleep(20 * time.Millisecond)
	}
	return trunkAddr
}

var (
	sdpConn  = regexp.MustCompile(`(?m)^c=IN IP4 (\S+)`)
	sdpAudio = regexp.MustCompile(`(?m)^m=audio (\d+) RTP/AVP ([0-9 ]+)`)
)

// mediaOf reads where an SDP wants audio sent and which payload types it names.
func mediaOf(t *testing.T, sdp []byte) (*net.UDPAddr, []string) {
	t.Helper()
	c := sdpConn.FindSubmatch(sdp)
	m := sdpAudio.FindSubmatch(sdp)
	if c == nil || m == nil {
		t.Fatalf("no c=/m=audio in SDP:\n%s", sdp)
	}
	port, _ := strconv.Atoi(string(m[1]))
	return &net.UDPAddr{IP: net.ParseIP(string(c[1])), Port: port}, strings.Fields(string(m[2]))
}

func pcmuSDP(port int) []byte {
	return []byte("v=0\r\no=pbx 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n" +
		fmt.Sprintf("m=audio %d RTP/AVP 0\r\n", port) + "a=rtpmap:0 PCMU/8000\r\na=sendrecv\r\n")
}

// pbxClient is the exchange's side of one call: a sipgo dialog over UDP,
// with a server on the same user agent so the B2BUA's own BYE is answered
// (and seen) rather than left to time out.
type pbxClient struct {
	ua   *sipgo.DialogUA
	dlg  *sipgo.DialogClientSession
	byes chan *sip.Request
}

func newPBXClient(t *testing.T) *pbxClient {
	t.Helper()
	ua, err := sipgo.NewUA()
	if err != nil {
		t.Fatal(err)
	}
	client, err := sipgo.NewClient(ua, sipgo.WithClientHostname("127.0.0.1"))
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
	// Listen on UDP so the B2BUA's in-dialog requests (its BYE) have
	// somewhere to land; sipgo sends our own requests from the same socket,
	// so this port is the one our Contact names.
	port := freePort(t, "udp")
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

// invite sends INVITE (with the body given, none for a delayed offer) to the
// echo user through the trunk listener and waits for the 200 OK.
func (c *pbxClient) invite(t *testing.T, ctx context.Context, trunkAddr string, body []byte) *sip.Response {
	t.Helper()
	host, portStr, _ := net.SplitHostPort(trunkAddr)
	port, _ := strconv.Atoi(portStr)
	params := sip.NewParams()
	params.Add("transport", "udp")
	to := sip.Uri{User: routing.EchoUser, Host: host, Port: port, UriParams: params}
	var hdrs []sip.Header
	if body != nil {
		hdrs = append(hdrs, sip.NewHeader("Content-Type", "application/sdp"))
	}
	dlg, err := c.ua.Invite(ctx, to, body, hdrs...)
	if err != nil {
		t.Fatalf("invite: %v", err)
	}
	if err := dlg.WaitAnswer(ctx, sipgo.AnswerOptions{}); err != nil {
		t.Fatalf("wait answer: %v", err)
	}
	c.dlg = dlg
	return dlg.InviteResponse
}

// ack sends the ACK for the 200 OK, with the SDP answer when this is the
// delayed-offer exchange (sipgo's own Ack carries no body).
func (c *pbxClient) ack(t *testing.T, ctx context.Context, body []byte) {
	t.Helper()
	inv, res := c.dlg.InviteRequest, c.dlg.InviteResponse
	recipient := inv.Recipient
	if ct := res.Contact(); ct != nil {
		recipient = ct.Address
	}
	ack := sip.NewRequest(sip.ACK, *recipient.Clone())
	for _, h := range []sip.Header{inv.From(), res.To(), inv.CallID(), inv.Contact()} {
		ack.AppendHeader(sip.HeaderClone(h))
	}
	cseq := *inv.CSeq()
	cseq.MethodName = sip.ACK
	ack.AppendHeader(&cseq)
	mf := sip.MaxForwardsHeader(70)
	ack.AppendHeader(&mf)
	if body != nil {
		ack.AppendHeader(sip.NewHeader("Content-Type", "application/sdp"))
		ack.SetBody(body)
	}
	ack.SetTransport(inv.Transport())
	if err := c.dlg.WriteAck(ctx, ack); err != nil {
		t.Fatalf("ack: %v", err)
	}
}

// echoRTP sends PCMU packets to the server's media address from our own
// socket and counts how many come back. The echo path relays what it
// reads straight back to where the ACK's (or INVITE's) SDP said.
func echoRTP(t *testing.T, sock *net.UDPConn, to *net.UDPAddr) int {
	t.Helper()
	pkt := make([]byte, 12+160)
	pkt[0] = 0x80 // V=2
	pkt[1] = 0    // PCMU
	binary.BigEndian.PutUint32(pkt[8:], 0x1234abcd)
	for i := range pkt[12:] {
		pkt[12+i] = 0xff
	}
	got := 0
	buf := make([]byte, 1500)
	for i := 0; i < 25; i++ {
		binary.BigEndian.PutUint16(pkt[2:], uint16(i+1))
		binary.BigEndian.PutUint32(pkt[4:], uint32(i*160))
		if _, err := sock.WriteToUDP(pkt, to); err != nil {
			t.Fatalf("rtp send: %v", err)
		}
		_ = sock.SetReadDeadline(time.Now().Add(20 * time.Millisecond))
		for {
			n, _, err := sock.ReadFromUDP(buf)
			if err != nil {
				break
			}
			if n >= 12 && buf[0]>>6 == 2 {
				got++
			}
		}
	}
	return got
}

func TestDelayedOfferInviteIsAnsweredWithAnOfferAndMediaFlows(t *testing.T) {
	trunkAddr := startTrunkServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pbx := newPBXClient(t)

	// INVITE with no SDP: the 200 OK must carry an offer.
	res := pbx.invite(t, ctx, trunkAddr, nil)
	if res.StatusCode != 200 {
		t.Fatalf("final = %d, want 200", res.StatusCode)
	}
	if ct := res.ContentType(); ct == nil || ct.Value() != "application/sdp" || len(res.Body()) == 0 {
		t.Fatalf("the 200 OK to a delayed offer carries no SDP offer: %v", res)
	}
	serverMedia, pts := mediaOf(t, res.Body())
	hasPCMU := false
	for _, pt := range pts {
		hasPCMU = hasPCMU || pt == "0"
	}
	if !hasPCMU {
		t.Fatalf("the offer names no PCMU: %v", pts)
	}

	// The answer goes in the ACK, naming our own media socket.
	sock, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer sock.Close()
	pbx.ack(t, ctx, pcmuSDP(sock.LocalAddr().(*net.UDPAddr).Port))

	// Media must flow on the addresses the ACK's answer established.
	if got := echoRTP(t, sock, serverMedia); got < 5 {
		t.Fatalf("echoed %d packets of 25, want the relay running on the ACK's media address", got)
	}
	if err := pbx.dlg.Bye(ctx); err != nil {
		t.Fatalf("bye: %v", err)
	}
}

// The same server, the same call, with the offer in the INVITE as Asterisk
// and every existing gate sends it: answered from the INVITE body as
// before, ACK without a body, media on the INVITE's address.
func TestEarlyOfferInviteStillAnsweredFromTheInvite(t *testing.T) {
	trunkAddr := startTrunkServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pbx := newPBXClient(t)

	sock, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer sock.Close()
	res := pbx.invite(t, ctx, trunkAddr, pcmuSDP(sock.LocalAddr().(*net.UDPAddr).Port))
	if res.StatusCode != 200 {
		t.Fatalf("final = %d, want 200", res.StatusCode)
	}
	serverMedia, pts := mediaOf(t, res.Body())
	if len(pts) == 0 || pts[0] != "0" {
		t.Fatalf("the answer to a PCMU offer is %v, want PCMU", pts)
	}
	pbx.ack(t, ctx, nil)
	if got := echoRTP(t, sock, serverMedia); got < 5 {
		t.Fatalf("echoed %d packets of 25", got)
	}
	if err := pbx.dlg.Bye(ctx); err != nil {
		t.Fatalf("bye: %v", err)
	}
}

// A delayed offer whose ACK brings no answer is a call with no media. It
// must fail at the answer, not become a confirmed dialog that carries
// nothing: the caller gets a BYE and the server logs why.
func TestDelayedOfferWithNoAnswerInTheAckIsEnded(t *testing.T) {
	trunkAddr := startTrunkServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pbx := newPBXClient(t)
	res := pbx.invite(t, ctx, trunkAddr, nil)
	if res.StatusCode != 200 {
		t.Fatalf("final = %d, want 200", res.StatusCode)
	}
	pbx.ack(t, ctx, nil)
	// The server must hang up: a BYE on this dialog, answered here.
	select {
	case bye := <-pbx.byes:
		if bye.CallID().Value() != pbx.dlg.InviteRequest.CallID().Value() {
			t.Fatalf("BYE for another call: %s", bye.CallID().Value())
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the server kept a late-offer call whose ACK had no SDP")
	}
}
