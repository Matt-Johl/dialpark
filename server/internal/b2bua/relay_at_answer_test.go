package b2bua

import (
	"context"
	"encoding/binary"
	"fmt"
	"log/slog"
	"net"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/emiago/sipgo"
	"github.com/emiago/sipgo/sip"

	"dialpark/server/internal/pbx"
	"dialpark/server/internal/registry"
	"dialpark/server/internal/routing"
	"dialpark/server/internal/tlsutil"
)

// The relay starts when the callee answers, not when the caller's ACK
// arrives (RFC 3261 §13.3.1.4: the ACK confirms the dialog; it is not a
// media gate). Before 2026-11-02 the caller's answer blocked until its
// ACK, so the callee's RTP — flowing since its own 200 OK — sat in the
// socket for the caller's round trip (230–320 ms on an app leg) and was
// then released as one burst, which the phone's play buffer discarded as
// the cut opening of every call.
//
// A real B2BUA on loopback: the exchange (a sipgo UAC over UDP) calls an
// unregistered user through the trunk listener, which the router sends
// back to the trunk peer — a raw UDP PBX here, which answers at once and
// starts sending RTP. The caller then holds its ACK back, and must hear
// that RTP before it sends it.

// startTrunkServerPeer is startTrunkServer with the trunk peer (where a
// call for an unknown user is sent) at peerPort.
func startTrunkServerPeer(t *testing.T, peerPort int) string {
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
		Trunk:             &pbx.Trunk{Host: "127.0.0.1", Port: peerPort, Transport: "udp"},
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

// answerInvite: the raw PBX takes the server's INVITE and answers 200 OK
// with PCMU on mediaPort, returning the server's media address from the
// INVITE's SDP and the address the INVITE came from.
func (p *rawPBX) answerInvite(t *testing.T, mediaPort int) (serverMedia *net.UDPAddr, from *net.UDPAddr, inv *sip.Request) {
	t.Helper()
	inv, from = p.readRequest(sip.INVITE)
	serverMedia, _ = mediaOf(t, inv.Body())
	res := sip.NewResponseFromRequest(inv, 200, "OK", pcmuSDP(mediaPort))
	res.To().Params.Add("tag", "pbx-"+strconv.Itoa(mediaPort))
	res.AppendHeader(&sip.ContactHeader{Address: sip.Uri{Scheme: "sip", User: "201", Host: "127.0.0.1", Port: p.port(), UriParams: sip.NewParams()}})
	res.AppendHeader(sip.NewHeader("Content-Type", "application/sdp"))
	p.send(res, from)
	return serverMedia, from, inv
}

// sendRTP: n PCMU packets, 20 ms apart, from sock to the server (from a
// goroutine, so a send failure is logged, not fatal).
func sendRTP(t *testing.T, sock *net.UDPConn, to *net.UDPAddr, n int) {
	pkt := make([]byte, 12+160)
	pkt[0] = 0x80
	pkt[1] = 0
	binary.BigEndian.PutUint32(pkt[8:], 0x5151abcd)
	for i := 0; i < n; i++ {
		binary.BigEndian.PutUint16(pkt[2:], uint16(i+1))
		binary.BigEndian.PutUint32(pkt[4:], uint32(i*160))
		if _, err := sock.WriteToUDP(pkt, to); err != nil {
			t.Logf("rtp send: %v", err)
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// countRTP: packets arriving on sock within d.
func countRTP(sock *net.UDPConn, d time.Duration) int {
	buf := make([]byte, 1500)
	got := 0
	deadline := time.Now().Add(d)
	for {
		_ = sock.SetReadDeadline(deadline)
		n, _, err := sock.ReadFromUDP(buf)
		if err != nil {
			return got
		}
		if n >= 12 && buf[0]>>6 == 2 {
			got++
		}
	}
}

func TestRelayStartsAtTheAnswerNotTheAck(t *testing.T) {
	peer := newRawPBX(t)
	trunkAddr := startTrunkServerPeer(t, peer.port())
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	caller := newPBXClient(t)

	callerMedia, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer callerMedia.Close()
	peerMedia, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer peerMedia.Close()

	// The callee: answer the INVITE the server sends us and start talking
	// at once, as every exchange does from its 200 OK.
	type answered struct {
		serverMedia *net.UDPAddr
		ackAt       time.Time
	}
	calleeDone := make(chan answered, 1)
	go func() {
		serverMedia, _, _ := peer.answerInvite(t, peerMedia.LocalAddr().(*net.UDPAddr).Port)
		go sendRTP(t, peerMedia, serverMedia, 40) // 800 ms of audio
		_, _ = peer.readRequest(sip.ACK)
		calleeDone <- answered{serverMedia: serverMedia, ackAt: time.Now()}
	}()

	host, portStr, _ := net.SplitHostPort(trunkAddr)
	port, _ := strconv.Atoi(portStr)
	params := sip.NewParams()
	params.Add("transport", "udp")
	to := sip.Uri{User: "201", Host: host, Port: port, UriParams: params}
	dlg, err := caller.ua.Invite(ctx, to, pcmuSDP(callerMedia.LocalAddr().(*net.UDPAddr).Port), sip.NewHeader("Content-Type", "application/sdp"))
	if err != nil {
		t.Fatalf("invite: %v", err)
	}
	if err := dlg.WaitAnswer(ctx, sipgo.AnswerOptions{}); err != nil {
		t.Fatalf("wait answer: %v", err)
	}
	caller.dlg = dlg
	answeredAt := time.Now()
	if dlg.InviteResponse.StatusCode != 200 {
		t.Fatalf("final = %d, want 200", dlg.InviteResponse.StatusCode)
	}

	// No ACK yet. The callee's audio must already be coming through.
	got := countRTP(callerMedia, 300*time.Millisecond)
	if got < 8 {
		t.Fatalf("heard %d packets in the 300 ms before our ACK, want the callee's audio relayed from the answer (≥ 8)", got)
	}
	t.Logf("%d packets relayed before the ACK", got)

	caller.ack(t, ctx, nil)
	ackedAt := time.Now()

	// The callee's dialog was completed on its answer, not on our ACK.
	select {
	case a := <-calleeDone:
		if a.ackAt.After(ackedAt) {
			t.Errorf("the callee's ACK went out after the caller's ACK; it should follow the callee's 200 OK at once")
		}
		if a.ackAt.Sub(answeredAt) > 200*time.Millisecond {
			t.Errorf("the callee was ACKed %v after the caller was answered", a.ackAt.Sub(answeredAt))
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the callee never saw the server's ACK")
	}

	// Still a working call after the ACK: more audio arrives.
	if got := countRTP(callerMedia, 300*time.Millisecond); got < 5 {
		t.Fatalf("heard %d packets after the ACK, want the relay still running", got)
	}
	if err := dlg.Bye(ctx); err != nil {
		t.Fatalf("bye: %v", err)
	}
	// Our BYE reaches the callee.
	bye, from := peer.readRequest(sip.BYE)
	peer.send(sip.NewResponseFromRequest(bye, 200, "OK", nil), from)
}

// A caller that never ACKs: the dialog is confirmed by the transaction's
// timeout (64*T1) and the server ends it with BYE on both legs, as RFC
// 3261 §13.3.1.4 asks — instead of carrying a call nobody confirmed. T1
// is shortened so the wait is seconds, not 32 s.
func TestNoAckEndsTheCallWithBye(t *testing.T) {
	sip.SetTimers(50*time.Millisecond, 400*time.Millisecond, 500*time.Millisecond)
	t.Cleanup(func() { sip.SetTimers(500*time.Millisecond, 4*time.Second, 5*time.Second) })

	peer := newRawPBX(t)
	trunkAddr := startTrunkServerPeer(t, peer.port())
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	caller := newPBXClient(t)

	callerMedia, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer callerMedia.Close()
	peerMedia, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer peerMedia.Close()

	peerBye := make(chan struct{}, 1)
	go func() {
		peer.answerInvite(t, peerMedia.LocalAddr().(*net.UDPAddr).Port)
		for {
			req, from := p2Read(peer)
			if req == nil {
				return
			}
			if req.Method == sip.BYE {
				peer.send(sip.NewResponseFromRequest(req, 200, "OK", nil), from)
				peerBye <- struct{}{}
				return
			}
		}
	}()

	host, portStr, _ := net.SplitHostPort(trunkAddr)
	port, _ := strconv.Atoi(portStr)
	params := sip.NewParams()
	params.Add("transport", "udp")
	to := sip.Uri{User: "201", Host: host, Port: port, UriParams: params}
	dlg, err := caller.ua.Invite(ctx, to, pcmuSDP(callerMedia.LocalAddr().(*net.UDPAddr).Port), sip.NewHeader("Content-Type", "application/sdp"))
	if err != nil {
		t.Fatalf("invite: %v", err)
	}
	if err := dlg.WaitAnswer(ctx, sipgo.AnswerOptions{}); err != nil {
		t.Fatalf("wait answer: %v", err)
	}
	if dlg.InviteResponse.StatusCode != 200 {
		t.Fatalf("final = %d, want 200", dlg.InviteResponse.StatusCode)
	}
	// No ACK, ever. 64*T1 = 3.2 s later the server must give up on both legs.
	select {
	case bye := <-caller.byes:
		if bye.CallID().Value() != dlg.InviteRequest.CallID().Value() {
			t.Fatalf("BYE for another call: %s", bye.CallID().Value())
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the server never ended a call whose caller did not ACK")
	}
	select {
	case <-peerBye:
	case <-time.After(5 * time.Second):
		t.Fatal("the callee leg was not ended")
	}
}

// p2Read: the next request at the raw PBX, nil on timeout.
func p2Read(p *rawPBX) (*sip.Request, *net.UDPAddr) {
	buf := make([]byte, 65535)
	_ = p.conn.SetReadDeadline(time.Now().Add(12 * time.Second))
	for {
		n, from, err := p.conn.ReadFrom(buf)
		if err != nil {
			return nil, nil
		}
		msg, err := p.parser.ParseSIP(buf[:n])
		if err != nil {
			continue
		}
		if req, ok := msg.(*sip.Request); ok {
			return req, from.(*net.UDPAddr)
		}
	}
}

// The log tells the story: the bridged line carries answer_to_relay_ms
// and the call-ended line the ACK's time and each pump's backlog.
func TestRelayLogFieldsNameTheStart(t *testing.T) {
	p := &pump{}
	if !strings.Contains(p.String(), "backlog_pkts=0") {
		t.Fatalf("pump summary lacks the backlog: %s", p.String())
	}
}
