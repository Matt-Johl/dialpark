package b2bua

import (
	"context"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/emiago/diago/media"
)

// Audio-continuity lab (pump_continuity.go): the relay measures the arrival
// pattern at its socket — the backlog that drains when the pumps start,
// bursts and gaps per window — so the start-of-call drop on the app can be
// placed from the server log alone.

// runContinuity relays everything the source has, as runPump does, and
// returns the pump for its continuity figures.
func runContinuity(t *testing.T, src *fakeSource, setup func(p *pump)) *pump {
	t.Helper()
	sink := &fakeSink{}
	rr := media.NewRTPPacketReader(src, media.CodecAudioUlaw)
	rw := media.NewRTPPacketWriter(sink, media.CodecAudioUlaw)
	p := &pump{r: rr, w: rw}
	p.setPacketPath(rr, rw, media.CodecAudioUlaw)
	if setup != nil {
		setup(p)
	}
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
	return p
}

// paced appends n packets to src, the first `burst` of them delivered at
// once and the rest one every 20 ms (the source stalls before each).
func paced(src *fakeSource, n, burst int, seq0 uint16, ts0, ssrc uint32) {
	if src.delayBefore == nil {
		src.delayBefore = map[int]time.Duration{}
	}
	for i := 0; i < n; i++ {
		k := len(src.pkts)
		if i >= burst {
			src.delayBefore[k] = 20 * time.Millisecond
		}
		src.pkts = append(src.pkts, packet(seq0+uint16(i), ts0+uint32(i)*ulawFrame, ssrc, i == 0))
	}
}

// Ten packets waiting in the socket when the pump starts drain as one run:
// that is the backlog, and its RTP span is nine frames — 10 × 20 ms packets
// cover 180 ms from the first timestamp to the last (160 samples a frame at
// 8 kHz).
func TestContinuityMeasuresTheStartBacklog(t *testing.T) {
	src := &fakeSource{}
	paced(src, 20, 10, 0, 1000, 0xabc)
	p := runContinuity(t, src, nil)
	w := p.cont.window()
	if w.backlogPkts != 10 || w.backlogMs != 180 {
		t.Fatalf("backlog = %d pkts / %d ms, want 10 / 180", w.backlogPkts, w.backlogMs)
	}
	if w.firstRTPMs > 20 {
		t.Fatalf("first_rtp_ms = %d; a waiting backlog is read at once", w.firstRTPMs)
	}
	// The backlog is also the window's and the call's largest burst.
	if w.maxBurst != 10 || w.burstMs != 180 {
		t.Fatalf("window max_burst = %d / %d ms, want 10 / 180", w.maxBurst, w.burstMs)
	}
	if !strings.Contains(p.String(), " backlog=10/180 max_gap_ms=") || !strings.Contains(p.String(), " max_burst=10 burst_ms=180 ") {
		t.Fatalf("summary lacks the continuity tail: %s", p.String())
	}
	// The existing fields lead, unchanged, so the harness greps still match.
	if !strings.HasPrefix(p.String(), "read=20 written=20 write_errs=0 lost=0 reordered=0 jitter_ms=") {
		t.Fatalf("summary head changed: %s", p.String())
	}
}

// A lone first packet is a packet arriving, not a queue: no backlog.
func TestContinuityNoBacklogWhenTheFirstPacketStandsAlone(t *testing.T) {
	src := &fakeSource{}
	paced(src, 8, 1, 0, 1000, 0xabc)
	p := runContinuity(t, src, nil)
	w := p.cont.window()
	if w.backlogPkts != 0 || w.backlogMs != 0 {
		t.Fatalf("backlog = %d/%d, want 0/0", w.backlogPkts, w.backlogMs)
	}
	if w.maxBurst != 1 {
		t.Fatalf("max_burst = %d, want 1 (a paced stream has no burst)", w.maxBurst)
	}
}

// A 60 ms hole in the arrivals mid-window is the window's largest gap.
func TestContinuityMeasuresTheLargestGap(t *testing.T) {
	src := &fakeSource{}
	paced(src, 15, 1, 0, 1000, 0xabc)
	src.delayBefore[8] = 60 * time.Millisecond
	p := runContinuity(t, src, nil)
	w := p.cont.window()
	if w.maxGapMs < 60 {
		t.Fatalf("max_gap_ms = %d, want >= 60", w.maxGapMs)
	}
	if w.maxGapMs > 200 {
		t.Fatalf("max_gap_ms = %d; the 60 ms stall should not read as %d", w.maxGapMs, w.maxGapMs)
	}
	p.cont.mu.Lock()
	callMax := p.cont.call.maxGapMs
	p.cont.mu.Unlock()
	if callMax != w.maxGapMs {
		t.Fatalf("call max_gap_ms = %d, window %d; the first window's gap is the call's", callMax, w.maxGapMs)
	}
	// A window reset clears the window, not the call.
	if again := p.cont.window(); again.maxGapMs != 0 || again.maxBurst != 0 {
		t.Fatalf("window not reset: %+v", again)
	}
	if !strings.Contains(p.String(), " max_gap_ms=") {
		t.Fatalf("summary lacks the gap: %s", p.String())
	}
}

// Four packets delivered together mid-call are a burst of four spanning
// three frames (60 ms); the paced packets around them are runs of one.
func TestContinuityMeasuresABurstMidCall(t *testing.T) {
	src := &fakeSource{}
	paced(src, 15, 1, 0, 1000, 0xabc)
	// Packets 6..9 arrive together: a stall before 6 (the paced 20 ms), then
	// nothing before 7, 8 and 9.
	delete(src.delayBefore, 7)
	delete(src.delayBefore, 8)
	delete(src.delayBefore, 9)
	p := runContinuity(t, src, nil)
	w := p.cont.window()
	if w.maxBurst != 4 || w.burstMs != 60 {
		t.Fatalf("max_burst = %d / %d ms, want 4 / 60", w.maxBurst, w.burstMs)
	}
	if w.backlogPkts != 0 {
		t.Fatalf("backlog = %d; a mid-call burst is not the start backlog", w.backlogPkts)
	}
	if !strings.Contains(p.String(), " max_burst=4 burst_ms=60 ") {
		t.Fatalf("summary lacks the burst: %s", p.String())
	}
}

// answer_to_pump_ms is carried from the source leg's answer time.
func TestContinuityCarriesTheAnswerToPumpDelay(t *testing.T) {
	src := &fakeSource{}
	paced(src, 3, 3, 0, 1000, 0xabc)
	p := runContinuity(t, src, func(p *pump) { p.answeredAt = time.Now().Add(-250 * time.Millisecond) })
	if ms := p.cont.window().answerToPumpMs; ms < 250 || ms > 1000 {
		t.Fatalf("answer_to_pump_ms = %d, want about 250", ms)
	}
	if !strings.Contains(p.String(), " answer_to_pump_ms=") {
		t.Fatalf("summary lacks the delay: %s", p.String())
	}
}

// With RTPTraceDir set the pump writes one TSV line per packet read, after
// a header, into a file named for the (sanitised) call id and direction.
func TestContinuityWritesThePerPacketTrace(t *testing.T) {
	dir := t.TempDir()
	src := &fakeSource{}
	paced(src, 12, 5, 100, 1000, 0xabc)
	p := runContinuity(t, src, func(p *pump) { p.setTrace(dir, "abc@10.0.0.1/x", "caller-callee") })
	path := filepath.Join(dir, "abc_10.0.0.1_x-caller-callee.tsv")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("trace file: %v", err)
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) != 1+12 {
		t.Fatalf("trace has %d lines, want header + 12:\n%s", len(lines), data)
	}
	if lines[0] != "t_us\tseq\tts\tlen\tskew_ms\tmarker" {
		t.Fatalf("header = %q", lines[0])
	}
	first := strings.Split(lines[1], "\t")
	if len(first) != 6 || first[1] != "100" || first[2] != "1000" || first[5] != "1" {
		t.Fatalf("first packet line = %q, want seq 100, ts 1000, marker 1", lines[1])
	}
	if second := strings.Split(lines[2], "\t"); second[1] != "101" || second[5] != "0" {
		t.Fatalf("second packet line = %q, want seq 101, marker 0", lines[2])
	}
	if p.trace != nil {
		t.Fatal("trace not closed when the pump ended")
	}
}

// Without a trace directory nothing is opened and nothing is written.
func TestContinuityTraceOffByDefault(t *testing.T) {
	src := &fakeSource{}
	paced(src, 3, 3, 0, 1000, 0xabc)
	p := runContinuity(t, src, func(p *pump) { p.setTrace("", "abc", "caller-callee") })
	if p.trace != nil || p.traceDir != "" || p.traceName != "" {
		t.Fatal("trace armed with no directory")
	}
}
