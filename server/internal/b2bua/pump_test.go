package b2bua

import (
	"context"
	"io"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/emiago/diago/media"
	"github.com/pion/rtp"
)

// The relay must forward packets the moment they arrive, carrying the
// source's timing. The library's paced io.Writer could only emit one packet
// per 20 ms, so a burst of N packets — a startup backlog, a stall on the
// network — was smoothed into N×20 ms of permanent delay on the far end.
// These tests drive the real RTP reader/writer with a fake source and sink.

const ulawFrame = 160 // samples per 20 ms G.711 packet, RTP clock 8 kHz

// fakeSource hands out prepared packets; delayBefore[i] stalls before the
// i-th packet to emulate a network hiccup followed by a burst.
type fakeSource struct {
	pkts        []rtp.Packet
	delayBefore map[int]time.Duration
	i           int
}

func (f *fakeSource) ReadRTP(buf []byte, p *rtp.Packet) (int, error) {
	if f.i >= len(f.pkts) {
		return 0, io.EOF
	}
	if d, ok := f.delayBefore[f.i]; ok {
		time.Sleep(d)
	}
	b, err := f.pkts[f.i].Marshal()
	if err != nil {
		return 0, err
	}
	f.i++
	n := copy(buf, b)
	if err := p.Unmarshal(buf[:n]); err != nil {
		return 0, err
	}
	return n, nil
}

type sinkPacket struct {
	hdr rtp.Header
	at  time.Time
}

type fakeSink struct {
	mu   sync.Mutex
	pkts []sinkPacket
}

func (s *fakeSink) WriteRTP(p *rtp.Packet) error {
	s.mu.Lock()
	s.pkts = append(s.pkts, sinkPacket{hdr: p.Header, at: time.Now()})
	s.mu.Unlock()
	return nil
}

func (s *fakeSink) all() []sinkPacket {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]sinkPacket(nil), s.pkts...)
}

func packet(seq uint16, ts, ssrc uint32, marker bool) rtp.Packet {
	return rtp.Packet{
		Header:  rtp.Header{Version: 2, PayloadType: 0, SequenceNumber: seq, Timestamp: ts, SSRC: ssrc, Marker: marker},
		Payload: make([]byte, ulawFrame),
	}
}

// runPump relays everything the source has and returns the sink and the
// wall time it took.
func runPump(t *testing.T, src *fakeSource) (*fakeSink, time.Duration) {
	t.Helper()
	sink := &fakeSink{}
	rr := media.NewRTPPacketReader(src, media.CodecAudioUlaw)
	rw := media.NewRTPPacketWriter(sink, media.CodecAudioUlaw)
	p := &pump{r: rr, w: rw}
	p.setPacketPath(rr, rw, media.CodecAudioUlaw)
	start := time.Now()
	done := make(chan struct{})
	go func() {
		p.run(context.Background(), slog.New(slog.NewTextHandler(io.Discard, nil)))
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("relay did not finish")
	}
	if got, want := int(p.written.Load()), len(src.pkts); got != want {
		t.Fatalf("forwarded %d of %d packets", got, want)
	}
	return sink, time.Since(start)
}

func TestRelayForwardsABurstAtOnce(t *testing.T) {
	src := &fakeSource{}
	for i := 0; i < 50; i++ {
		src.pkts = append(src.pkts, packet(uint16(i), 1000+uint32(i)*ulawFrame, 0xabc, i == 0))
	}
	sink, took := runPump(t, src)
	// The paced writer took 1.0 s for exactly this (measured); a relay must
	// not add anything like a packet time per packet.
	if took > 250*time.Millisecond {
		t.Fatalf("50-packet burst took %v to forward; the relay is pacing", took)
	}
	out := sink.all()
	if !out[0].hdr.Marker {
		t.Fatal("first packet of the stream must carry the marker")
	}
	for i := 1; i < len(out); i++ {
		if d := out[i].hdr.Timestamp - out[i-1].hdr.Timestamp; d != ulawFrame {
			t.Fatalf("packet %d: timestamp step %d, want %d (source timing not carried)", i, d, ulawFrame)
		}
		if out[i].hdr.SequenceNumber != out[i-1].hdr.SequenceNumber+1 {
			t.Fatalf("packet %d: sequence not contiguous", i)
		}
	}
}

func TestRelayPreservesSilenceGapsAndRebasesNewStreams(t *testing.T) {
	src := &fakeSource{}
	ts := uint32(5000)
	for i := 0; i < 40; i++ {
		if i == 10 {
			ts += 25 * ulawFrame // half a second of silence: no packets sent
		}
		ssrc := uint32(0x111)
		if i >= 30 {
			ssrc = 0x222 // the source restarted its stream (new SSRC, new timeline)
			if i == 30 {
				ts = 9_000_000
			}
		}
		seq := uint16(i)
		if i >= 30 {
			seq = 40000 + uint16(i) // the restarted stream numbers itself afresh
		}
		src.pkts = append(src.pkts, packet(seq, ts, ssrc, false))
		ts += ulawFrame
	}
	sink, _ := runPump(t, src)
	out := sink.all()
	// Sequence numbers continue across the restart too: the far end sees
	// one stream, not a 40000-packet loss.
	if out[30].hdr.SequenceNumber != out[29].hdr.SequenceNumber+1 {
		t.Fatalf("new stream did not continue our sequence: %d after %d", out[30].hdr.SequenceNumber, out[29].hdr.SequenceNumber)
	}
	if d := out[10].hdr.Timestamp - out[9].hdr.Timestamp; d != 26*ulawFrame {
		t.Fatalf("silence gap not preserved: step %d, want %d", d, 26*ulawFrame)
	}
	// A new source stream continues our timeline one frame on, marked.
	if d := out[30].hdr.Timestamp - out[29].hdr.Timestamp; d != ulawFrame {
		t.Fatalf("new stream did not continue our timeline: step %d", d)
	}
	if !out[30].hdr.Marker {
		t.Fatal("first packet of a new source stream must carry the marker")
	}
	if out[29].hdr.Marker || out[31].hdr.Marker {
		t.Fatal("marker set on a packet that does not start a stream")
	}
	if d := out[31].hdr.Timestamp - out[30].hdr.Timestamp; d != ulawFrame {
		t.Fatalf("timing after the new stream: step %d", d)
	}
}

// The relay counts what the source's own sequence numbers and timing say —
// loss, reordering, interarrival jitter — so a lossy leg can be placed from
// the server log without RTCP (audio-quality gates, SPEC §7.2).
func TestRelayCountsLossReorderingAndJitter(t *testing.T) {
	src := &fakeSource{delayBefore: map[int]time.Duration{15: 80 * time.Millisecond}}
	order := []int{0, 1, 2, 3, 4, 5, 6, 8, 9, 10, 12, 11, 13, 14, 15, 16, 17, 18, 19} // 7 lost; 11 late
	for _, i := range order {
		src.pkts = append(src.pkts, packet(uint16(i), uint32(i)*ulawFrame, 0x999, false))
	}
	sink := &fakeSink{}
	rr := media.NewRTPPacketReader(src, media.CodecAudioUlaw)
	rw := media.NewRTPPacketWriter(sink, media.CodecAudioUlaw)
	p := &pump{r: rr, w: rw}
	p.setPacketPath(rr, rw, media.CodecAudioUlaw)
	p.run(context.Background(), slog.New(slog.NewTextHandler(io.Discard, nil)))
	if got := p.lost.Load(); got != 1 {
		t.Fatalf("lost = %d, want 1 (packet 7; the late 11 must not count)", got)
	}
	if got := p.reordered.Load(); got != 1 {
		t.Fatalf("reordered = %d, want 1 (packet 11 after 12)", got)
	}
	// Packets arrive back to back (far faster than their 20 ms spacing) with
	// one 80 ms stall: the jitter estimate must be clearly non-zero.
	if j := p.jitterMs(); j <= 1 {
		t.Fatalf("jitter_ms = %.2f; a burst with a stall should register", j)
	}
	if !strings.Contains(p.String(), "lost=1 reordered=1") {
		t.Fatalf("summary lacks the counters: %s", p.String())
	}
}

// A packet the source lost stays lost on the way out, and a reordered one
// keeps its place: the relay rebases sequence numbers like timestamps
// instead of renumbering, so the receiver's jitter buffer and concealment
// see the loss (plan Phase D).
func TestRelayCarriesSequenceGapsAndOrder(t *testing.T) {
	src := &fakeSource{}
	order := []int{0, 1, 2, 3, 4, 5, 6, 8, 9, 10, 12, 11, 13, 14, 15} // 7 lost; 11 late
	for _, i := range order {
		src.pkts = append(src.pkts, packet(uint16(100+i), uint32(i)*ulawFrame, 0x777, false))
	}
	sink, _ := runPump(t, src)
	out := sink.all()
	base := out[0].hdr.SequenceNumber - 100
	for k, i := range order {
		if want := uint16(100+i) + base; out[k].hdr.SequenceNumber != want {
			t.Fatalf("packet %d (source seq %d): out seq %d, want %d — gaps/order not carried", k, 100+i, out[k].hdr.SequenceNumber, want)
		}
	}
	if out[7].hdr.SequenceNumber != out[6].hdr.SequenceNumber+2 {
		t.Fatal("the lost packet's number was not left missing")
	}
	if out[11].hdr.SequenceNumber != out[10].hdr.SequenceNumber-1 {
		t.Fatal("the late packet was renumbered instead of keeping its place")
	}
}

func TestRelayReportsArrivalSkew(t *testing.T) {
	// Ten packets at once, a 300 ms stall, then twenty at once: what a
	// network hiccup looks like. The stalled packet is late against the
	// source's timeline; the burst after it is early.
	src := &fakeSource{delayBefore: map[int]time.Duration{10: 300 * time.Millisecond}}
	for i := 0; i < 31; i++ {
		src.pkts = append(src.pkts, packet(uint16(i), uint32(i)*ulawFrame, 0x777, false))
	}
	sink := &fakeSink{}
	rr := media.NewRTPPacketReader(src, media.CodecAudioUlaw)
	rw := media.NewRTPPacketWriter(sink, media.CodecAudioUlaw)
	p := &pump{r: rr, w: rw}
	p.setPacketPath(rr, rw, media.CodecAudioUlaw)
	start := time.Now()
	p.run(context.Background(), slog.New(slog.NewTextHandler(io.Discard, nil)))
	took := time.Since(start)
	if took > 600*time.Millisecond {
		t.Fatalf("31 packets with one 300 ms stall took %v; the burst after the stall was paced", took)
	}
	if late := p.lateMaxMs.Load(); late < 50 {
		t.Fatalf("late_max_ms = %d; the stalled packet should read as late", late)
	}
	if early := p.earlyMaxMs.Load(); early < 200 {
		t.Fatalf("early_max_ms = %d; the burst after the stall should read as early", early)
	}
	// And the burst went out as one: the last packet left within a few ms
	// of the stalled one, not 400 ms later.
	out := sink.all()
	if spread := out[len(out)-1].at.Sub(out[10].at); spread > 100*time.Millisecond {
		t.Fatalf("burst spread over %v on the way out", spread)
	}
}

// drive relays exactly n packets from the source, the way run() does.
func drive(t *testing.T, p *pump, n int) {
	t.Helper()
	buf := make([]byte, media.RTPBufSize)
	for i := 0; i < n; i++ {
		read, err := p.r.Read(buf)
		if err != nil || read == 0 {
			t.Fatalf("source packet %d: read %d, err %v", i, read, err)
		}
		if err := p.forward(buf[:read]); err != nil {
			t.Fatalf("source packet %d: forward: %v", i, err)
		}
	}
}

// Hold music goes out on the same stream as the relayed audio, so it moves
// our sequence numbers and timestamps on — and the party that is holding
// knows nothing about that. When it resumes, its packets carry on from
// where THEY left off, same SSRC and same numbering, and the relay has to
// rebase them onto what the music left behind.
//
// Without that the outbound stream jumps BACKWARDS by the length of the
// music and the far end drops every packet as stale. On a device that was
// the caller's microphone gone for good after a resume, while the relay
// counters kept rising and nothing logged an error (2026-09-15).
// A transfer replaces the pumps, but the leg that stays keeps its stream.
// The pump that takes over writing to it must carry on the numbering the
// old one left — after the hold music and ring-back the old one wrote — or
// the far end sees the stream jump: harmless on plain RTP, a replay or a
// wrong rollover counter to libsrtp, which then drops everything (the LAN
// PBX's echo test silent both ways after a transfer, 2026-09-17 18:25).
func TestReplacementPumpContinuesTheLegsNumbering(t *testing.T) {
	const held = 50
	sink := &fakeSink{}
	rw := media.NewRTPPacketWriter(sink, media.CodecAudioUlaw)

	// The pump that carried the call until the transfer: relayed audio,
	// then the transfer clips written locally.
	src1 := &fakeSource{}
	for i := 0; i < 10; i++ {
		src1.pkts = append(src1.pkts, packet(uint16(i), 1000+uint32(i)*ulawFrame, 0xaaa, i == 0))
	}
	rr1 := media.NewRTPPacketReader(src1, media.CodecAudioUlaw)
	old := &pump{r: rr1, w: rw}
	old.setPacketPath(rr1, rw, media.CodecAudioUlaw)
	drive(t, old, 10)
	for i := 0; i < held; i++ {
		if err := old.writeLocal(make([]byte, ulawFrame), i == 0); err != nil {
			t.Fatalf("clip frame %d: %v", i, err)
		}
	}

	// The replacement: a different source (the transfer target), another
	// SSRC and sequence space, writing to the same leg.
	src2 := &fakeSource{}
	for i := 0; i < 10; i++ {
		src2.pkts = append(src2.pkts, packet(40000+uint16(i), 777000+uint32(i)*ulawFrame, 0xbbb, i == 0))
	}
	rr2 := media.NewRTPPacketReader(src2, media.CodecAudioUlaw)
	next := &pump{r: rr2, w: rw}
	next.setPacketPath(rr2, rw, media.CodecAudioUlaw)
	next.inheritTimeline(old)
	drive(t, next, 10)

	out := sink.all()
	if len(out) != 10+held+10 {
		t.Fatalf("sink has %d packets, want %d", len(out), 10+held+10)
	}
	for i := 1; i < len(out); i++ {
		if d := int16(out[i].hdr.SequenceNumber - out[i-1].hdr.SequenceNumber); d <= 0 {
			t.Fatalf("packet %d: sequence went %d (from %d to %d)", i, d, out[i-1].hdr.SequenceNumber, out[i].hdr.SequenceNumber)
		}
		if d := int32(out[i].hdr.Timestamp - out[i-1].hdr.Timestamp); d <= 0 {
			t.Fatalf("packet %d: timestamp went backwards by %d", i, -d)
		}
	}
	// And it follows on immediately: one frame after the last clip frame.
	first, prev := out[10+held], out[10+held-1]
	if d := first.hdr.SequenceNumber - prev.hdr.SequenceNumber; d != 1 {
		t.Errorf("replacement pump left a sequence gap of %d", d)
	}
	if d := first.hdr.Timestamp - prev.hdr.Timestamp; d != ulawFrame {
		t.Errorf("replacement pump left a timestamp gap of %d, want %d", d, ulawFrame)
	}

	// A pump for a different leg inherits nothing.
	other := &pump{r: rr2, w: media.NewRTPPacketWriter(&fakeSink{}, media.CodecAudioUlaw)}
	other.setPacketPath(rr2, other.w.(*media.RTPPacketWriter), media.CodecAudioUlaw)
	other.inheritTimeline(old)
	if other.wroteAny {
		t.Error("a pump writing to another leg must not inherit this one's numbering")
	}
}

func TestResumeAfterHoldMusicNeverGoesBackwards(t *testing.T) {
	const ssrc = 0xabc
	const held = 50 // frames of hold music: one second
	src := &fakeSource{}
	for i := 0; i < 20; i++ {
		src.pkts = append(src.pkts, packet(uint16(i), 1000+uint32(i)*ulawFrame, ssrc, i == 0))
	}
	sink := &fakeSink{}
	rr := media.NewRTPPacketReader(src, media.CodecAudioUlaw)
	rw := media.NewRTPPacketWriter(sink, media.CodecAudioUlaw)
	p := &pump{r: rr, w: rw}
	p.setPacketPath(rr, rw, media.CodecAudioUlaw)

	drive(t, p, 10) // talking
	for i := 0; i < held; i++ {
		if err := p.writeLocal(make([]byte, ulawFrame), i == 0); err != nil {
			t.Fatalf("hold music frame %d: %v", i, err)
		}
	}
	drive(t, p, 10) // resumed: the phone picks up its own numbering again

	out := sink.all()
	if len(out) != 20+held {
		t.Fatalf("sink has %d packets, want %d", len(out), 20+held)
	}
	for i := 1; i < len(out); i++ {
		if d := int16(out[i].hdr.SequenceNumber - out[i-1].hdr.SequenceNumber); d <= 0 {
			t.Fatalf("packet %d: sequence went %d (from %d to %d) — the far end drops this as stale",
				i, d, out[i-1].hdr.SequenceNumber, out[i].hdr.SequenceNumber)
		}
		if d := int32(out[i].hdr.Timestamp - out[i-1].hdr.Timestamp); d <= 0 {
			t.Fatalf("packet %d: timestamp went backwards by %d", i, -d)
		}
	}
	// The resumed audio must also follow the music immediately, not leave a
	// gap the far end conceals: one frame on from the last music frame.
	first := out[20+held-10]
	prev := out[20+held-11]
	if d := first.hdr.SequenceNumber - prev.hdr.SequenceNumber; d != 1 {
		t.Errorf("resume left a sequence gap of %d", d)
	}
	if d := first.hdr.Timestamp - prev.hdr.Timestamp; d != ulawFrame {
		t.Errorf("resume left a timestamp gap of %d, want %d", d, ulawFrame)
	}
}

// A source whose timestamps part from real time within one SSRC gets a
// fresh timeline from the relay, whichever way they part. The desk phone's
// hold/resume on the PBX sent the app's stream 31 s BACKWARDS in one step,
// same SSRC, packets every 20 ms throughout (2026-09-18 08:45); forwarded
// as-is, the app's playout buffer (ordered by timestamp) dropped every
// later frame as old and the call was silent to its end. A timestamp that
// jumps ahead, or freezes while packets keep arriving, is the same fault
// in another shape. An honest gap — no packets, then timestamps that
// account for the time — is not a fault and passes untouched.
func TestRelayRebasesATimelineThatBreaksWithinOneSSRC(t *testing.T) {
	const frameDur = 20 * time.Millisecond
	type shape struct {
		name    string
		tsShift int32         // applied to the source's timestamp at packet 20
		delay   time.Duration // the relay waits this long before packet 20
		breaks  bool
	}
	shapes := []shape{
		{"backwards 31s", -31 * 50 * ulawFrame, 0, true},
		// Under the arrival-vs-timeline limit, yet never legitimate: the
		// sequence number went on while the timestamp went back.
		{"backwards 60ms", -3 * ulawFrame, 0, true},
		{"ahead 31s", 31 * 50 * ulawFrame, 0, true},
		{"frozen while packets arrive", -ulawFrame, 150 * time.Millisecond, true},
		{"honest gap", 8 * ulawFrame, 8 * frameDur, false},
	}
	for _, sh := range shapes {
		t.Run(sh.name, func(t *testing.T) {
			src := &fakeSource{delayBefore: map[int]time.Duration{}}
			if sh.delay > 0 {
				src.delayBefore[20] = sh.delay
			}
			ts := uint32(5000)
			for i := 0; i < 40; i++ {
				if i == 20 {
					ts = uint32(int32(ts) + sh.tsShift)
				}
				src.pkts = append(src.pkts, packet(uint16(i), ts, 0x111, false))
				ts += ulawFrame
			}
			sink := &fakeSink{}
			rr := media.NewRTPPacketReader(src, media.CodecAudioUlaw)
			rw := media.NewRTPPacketWriter(sink, media.CodecAudioUlaw)
			p := &pump{r: rr, w: rw, timelineBreak: 100 * time.Millisecond}
			p.setPacketPath(rr, rw, media.CodecAudioUlaw)
			drive(t, p, 40)
			out := sink.all()
			if got := p.breaks.Load() > 0; got != sh.breaks {
				t.Fatalf("timeline break detected=%v, want %v (jump_ms=%d)", got, sh.breaks, p.lastBreakMs.Load())
			}
			step := int32(out[20].hdr.Timestamp - out[19].hdr.Timestamp)
			if sh.breaks {
				// Rebased: our timeline carries on one frame after what we
				// last sent, marked as a new talk spurt.
				if step != ulawFrame {
					t.Fatalf("rebased stream stepped %d, want %d", step, ulawFrame)
				}
				if !out[20].hdr.Marker {
					t.Fatal("first packet after the break must carry the marker")
				}
			} else {
				if step != int32(sh.tsShift)+ulawFrame {
					t.Fatalf("honest gap not preserved: step %d, want %d", step, int32(sh.tsShift)+ulawFrame)
				}
				if out[20].hdr.Marker {
					t.Fatal("an honest gap is not a new stream")
				}
			}
			// Either way the stream never goes backwards and continues
			// normally afterwards, sequence numbers untouched.
			for i := 1; i < len(out); i++ {
				if d := int32(out[i].hdr.Timestamp - out[i-1].hdr.Timestamp); d <= 0 {
					t.Fatalf("packet %d: timestamp went backwards by %d", i, -d)
				}
				if d := out[i].hdr.SequenceNumber - out[i-1].hdr.SequenceNumber; d != 1 {
					t.Fatalf("packet %d: sequence stepped %d", i, d)
				}
			}
			if d := out[21].hdr.Timestamp - out[20].hdr.Timestamp; d != ulawFrame {
				t.Fatalf("timing after the break: step %d", d)
			}
			if out[19].hdr.Marker || out[21].hdr.Marker {
				t.Fatal("marker on a packet that does not start a stream")
			}
		})
	}
}

// A clock that freezes or slows while packets keep arriving loses less
// than a frame per packet, under any per-packet limit, and the far end's
// playout buffer counts frames by timestamp: it never has one to play. The
// PBX did that for 94 packets after a desk phone's resume (2026-09-27
// 08:02). Past pumpFrozenBreak the relay paces the packets itself, one
// frame each and no marker, counted as one break; when the source's clock
// moves again our timeline carries on from there, an honest gap and all.
func TestRelayPacesAFrozenOrSlowedClock(t *testing.T) {
	const frameDur = 20 * time.Millisecond
	shapes := []struct {
		name string
		step uint32 // the source's timestamp advance per packet, packets 20–39
	}{
		{"frozen", 0},
		{"half speed", ulawFrame / 2},
	}
	for _, sh := range shapes {
		t.Run(sh.name, func(t *testing.T) {
			src := &fakeSource{delayBefore: map[int]time.Duration{}}
			const base = uint32(5000)
			for i := 0; i < 60; i++ {
				ts := base + uint32(i)*ulawFrame // the honest timeline
				if i >= 20 && i < 40 {
					ts = base + 20*ulawFrame + uint32(i-20)*sh.step
					src.delayBefore[i+1] = frameDur // packets keep arriving on time
				}
				src.pkts = append(src.pkts, packet(uint16(i), ts, 0x111, false))
			}
			sink := &fakeSink{}
			rr := media.NewRTPPacketReader(src, media.CodecAudioUlaw)
			rw := media.NewRTPPacketWriter(sink, media.CodecAudioUlaw)
			p := &pump{r: rr, w: rw, frozenBreak: 100 * time.Millisecond}
			p.setPacketPath(rr, rw, media.CodecAudioUlaw)
			drive(t, p, 60)
			out := sink.all()
			if got := p.breaks.Load(); got != 1 {
				t.Fatalf("breaks=%d, want 1 (the episode counted once)", got)
			}
			// Detection: the first packet of the stretch we paced ourselves.
			detected := 0
			for i := 21; i < 40; i++ {
				if out[i].hdr.Timestamp-out[i-1].hdr.Timestamp == ulawFrame {
					detected = i
					break
				}
			}
			if detected == 0 || detected > 34 {
				t.Fatalf("paced from packet %d, want within the stretch and early enough to matter", detected)
			}
			for i := detected; i < 40; i++ {
				if d := out[i].hdr.Timestamp - out[i-1].hdr.Timestamp; d != ulawFrame {
					t.Fatalf("packet %d: paced step %d, want %d", i, d, ulawFrame)
				}
			}
			// The clock moves again: the time it skipped is an honest gap
			// from where we were, and the stream then runs on normally.
			if d := out[40].hdr.Timestamp - out[39].hdr.Timestamp; d <= ulawFrame {
				t.Fatalf("resume: step %d, want a gap", d)
			}
			for i := 41; i < 60; i++ {
				if d := out[i].hdr.Timestamp - out[i-1].hdr.Timestamp; d != ulawFrame {
					t.Fatalf("packet %d after resume: step %d, want %d", i, d, ulawFrame)
				}
			}
			for i := 1; i < len(out); i++ {
				if out[i].hdr.Marker {
					t.Fatalf("packet %d: marker on a stream that never restarted", i)
				}
				if d := out[i].hdr.SequenceNumber - out[i-1].hdr.SequenceNumber; d != 1 {
					t.Fatalf("packet %d: sequence stepped %d", i, d)
				}
				if d := int32(out[i].hdr.Timestamp - out[i-1].hdr.Timestamp); d < 0 {
					t.Fatalf("packet %d: timestamp went backwards by %d", i, -d)
				}
			}
		})
	}
}

// DTMF travels as RFC 4733 telephone-event packets in the audio stream: a
// key press is a run of packets that all carry the timestamp the press
// started at, the first with the marker, then three end packets. The
// relay must forward them under the far leg's event payload type, in the
// stream's sequence and timeline, and must not read the repeated timestamp
// as a frozen clock. Before 2026-10-17 they went out under the audio
// payload type: a burst of noise, and no digit (CUCM checklist item d).
func eventPacket(seq uint16, ts, ssrc uint32, marker, end bool, digit byte) rtp.Packet {
	flags := byte(10) // volume
	if end {
		flags |= 0x80
	}
	return rtp.Packet{
		Header:  rtp.Header{Version: 2, PayloadType: 101, SequenceNumber: seq, Timestamp: ts, SSRC: ssrc, Marker: marker},
		Payload: []byte{digit, flags, 0x03, 0x20},
	}
}

func dtmfStream() []rtp.Packet {
	var pkts []rtp.Packet
	seq, ts := uint16(10), uint32(5000)
	for i := 0; i < 5; i++ { // 100 ms of audio
		pkts = append(pkts, packet(seq, ts, 0xd7, i == 0))
		seq++
		ts += ulawFrame
	}
	start := ts
	for i := 0; i < 8; i++ { // a 160 ms key press: 8 packets on one timestamp
		pkts = append(pkts, eventPacket(seq, start, 0xd7, i == 0, false, 5))
		seq++
	}
	for i := 0; i < 3; i++ { // the end, sent three times
		pkts = append(pkts, eventPacket(seq, start, 0xd7, false, true, 5))
		seq++
	}
	ts += 11 * ulawFrame // audio resumes where the clock would be
	for i := 0; i < 5; i++ {
		pkts = append(pkts, packet(seq, ts, 0xd7, false))
		seq++
		ts += ulawFrame
	}
	return pkts
}

func runEventPump(t *testing.T, src *fakeSource, dstEvent uint8, hasDst bool) (*fakeSink, *pump) {
	t.Helper()
	sink := &fakeSink{}
	rr := media.NewRTPPacketReader(src, media.CodecAudioUlaw)
	rw := media.NewRTPPacketWriter(sink, media.CodecAudioUlaw)
	p := &pump{r: rr, w: rw}
	p.setPacketPath(rr, rw, media.CodecAudioUlaw)
	p.srcEvent, p.hasSrcEvent = 101, true
	p.dstEvent, p.hasDstEvent = dstEvent, hasDst
	done := make(chan struct{})
	go func() {
		p.run(context.Background(), slog.New(slog.NewTextHandler(io.Discard, nil)))
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("relay did not finish")
	}
	return sink, p
}

func TestRelayForwardsDTMFEventsUnderTheFarLegsPayloadType(t *testing.T) {
	src := &fakeSource{pkts: dtmfStream()}
	sink, p := runEventPump(t, src, 96, true)
	out := sink.all()
	if len(out) != len(src.pkts) {
		t.Fatalf("forwarded %d of %d packets", len(out), len(src.pkts))
	}
	if p.events.Load() != 11 || p.eventsDropped.Load() != 0 {
		t.Fatalf("events=%d dropped=%d, want 11 forwarded", p.events.Load(), p.eventsDropped.Load())
	}
	if p.breaks.Load() != 0 {
		t.Fatalf("the key press's repeated timestamp was read as a timeline break (%d)", p.breaks.Load())
	}
	// Payload types: audio stays 0, events become 96; nothing goes out as 101.
	for i, o := range out {
		want := uint8(0)
		if i >= 5 && i < 16 {
			want = 96
		}
		if o.hdr.PayloadType != want {
			t.Errorf("packet %d: payload type %d, want %d", i, o.hdr.PayloadType, want)
		}
	}
	// Sequence numbers stay contiguous through the digit.
	for i := 1; i < len(out); i++ {
		if out[i].hdr.SequenceNumber != out[i-1].hdr.SequenceNumber+1 {
			t.Fatalf("packet %d: sequence not contiguous across the digit", i)
		}
	}
	// The event's timestamp is the press start, held for all 11 packets,
	// and sits where the audio clock was; the marker rides on the first.
	evTS := out[5].hdr.Timestamp
	if evTS != out[4].hdr.Timestamp+ulawFrame {
		t.Errorf("event timestamp %d, want %d (one frame after the last audio)", evTS, out[4].hdr.Timestamp+ulawFrame)
	}
	if !out[5].hdr.Marker {
		t.Error("the first packet of the key press must keep its marker")
	}
	for i := 6; i < 16; i++ {
		if out[i].hdr.Timestamp != evTS {
			t.Errorf("event packet %d: timestamp %d, want %d held through the press", i, out[i].hdr.Timestamp, evTS)
		}
		if out[i].hdr.Marker {
			t.Errorf("event packet %d carries a marker it did not have", i)
		}
	}
	// Audio after the digit continues on the same timeline, no rebase.
	if got, want := out[16].hdr.Timestamp, evTS+11*ulawFrame; got != want {
		t.Errorf("audio after the digit at %d, want %d", got, want)
	}
}

func TestRelayDropsDTMFEventsTheFarLegDidNotNegotiate(t *testing.T) {
	src := &fakeSource{pkts: dtmfStream()}
	sink, p := runEventPump(t, src, 0, false)
	out := sink.all()
	if len(out) != 10 {
		t.Fatalf("forwarded %d packets, want the 10 audio packets only", len(out))
	}
	if p.eventsDropped.Load() != 11 || p.events.Load() != 0 {
		t.Fatalf("events=%d dropped=%d, want 11 dropped", p.events.Load(), p.eventsDropped.Load())
	}
	for i, o := range out {
		if o.hdr.PayloadType != 0 {
			t.Errorf("packet %d went out as payload type %d; a digit must never be sent as audio", i, o.hdr.PayloadType)
		}
	}
	// The audio after the digit still follows the clock.
	if got, want := out[5].hdr.Timestamp, out[4].hdr.Timestamp+12*ulawFrame; got != want {
		t.Errorf("audio after the dropped digit at %d, want %d", got, want)
	}
}
