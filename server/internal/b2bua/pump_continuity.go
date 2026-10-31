package b2bua

import (
	"bufio"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/emiago/diago/media"
	"github.com/pion/rtp"
)

// Audio-continuity lab (2026-10-31). Users hear brief drops — audio
// removed, not silence — on the app. The relay forwards each packet the
// moment it is read, so what the far end's playout buffer sees is the
// arrival pattern at our socket, and this file measures that pattern:
//
//   - the BACKLOG at pump start: the pumps start only on the caller's ACK,
//     200–300 ms after the callee's 200 OK, and whatever the callee sent in
//     between is queued in the socket and drains in one burst. The phone's
//     play buffer keeps 40 ms of that and throws the rest away.
//   - per 2 s window, the largest GAP between consecutive reads and the
//     largest BURST of back-to-back reads, with the RTP time the burst spans.
//
// A burst is a run of reads each within pumpBurstGap of the one before. A
// live source paces its packets a frame (20 ms) apart, so two reads closer
// than 5 ms mean the second was already queued when the first was taken:
// the measure needs no timeline, is unaffected by where a packet's
// timestamp sits against the arrival clock (the skew figures already cover
// that), and tolerates a slow read loop up to the threshold. The run is
// counted from the first read; a run of one is no burst. The backlog is the
// run the pump's FIRST read starts, measured the same way — zero when that
// first packet stands alone.
const pumpBurstGap = 5 * time.Millisecond

// continuity is the arrival-continuity tracker of one pump. Written by the
// relay goroutine on every read; read by the 2 s log line and the
// call-ended summary under its own lock (uncontended: one packet every
// 20 ms).
type continuity struct {
	mu       sync.Mutex
	started  time.Time // pump start (run)
	lastRead time.Time // zero until the first read
	// The open run of back-to-back reads: count and the RTP timestamps of
	// its first and latest packet.
	runN           int64
	runTs0, runTs  uint32
	firstRun       bool // the open run is the one the first read started
	backlogPkts    int64
	backlogMs      int64
	firstRTPMs     int64 // pump start → first read
	answerToPumpMs int64 // source leg answered → pump start; 0 = unknown
	// Window maxima (reset by window) and call maxima.
	win, call continuityMax
}

type continuityMax struct {
	maxGapMs int64 // largest gap between consecutive reads
	maxBurst int64 // largest run of back-to-back reads (1 = none)
	burstMs  int64 // RTP time that run spans
}

// continuityWindow is what one 2 s line reports.
type continuityWindow struct {
	backlogPkts, backlogMs, firstRTPMs, answerToPumpMs int64
	maxGapMs, maxBurst, burstMs                        int64
}

func (c *continuity) start(now, answeredAt time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.started = now
	if !answeredAt.IsZero() {
		c.answerToPumpMs = now.Sub(answeredAt).Milliseconds()
	}
}

// noteRead accounts one packet read at now. hdr is the packet's RTP header
// (nil on the byte-copy path, where spans stay 0); codec supplies the RTP
// clock the span is measured in.
func (c *continuity) noteRead(now time.Time, hdr *rtp.Header, codec media.Codec) {
	var ts uint32
	if hdr != nil {
		ts = hdr.Timestamp
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.lastRead.IsZero() {
		c.firstRTPMs = now.Sub(c.started).Milliseconds()
		c.runN, c.runTs0, c.runTs, c.firstRun = 1, ts, ts, true
	} else {
		gap := now.Sub(c.lastRead)
		if ms := gap.Milliseconds(); ms > c.win.maxGapMs {
			c.win.maxGapMs = ms
		}
		if ms := gap.Milliseconds(); ms > c.call.maxGapMs {
			c.call.maxGapMs = ms
		}
		if gap <= pumpBurstGap {
			c.runN++
			c.runTs = ts
		} else {
			c.runN, c.runTs0, c.runTs, c.firstRun = 1, ts, ts, false
		}
	}
	c.lastRead = now
	span := rtpSpanMs(c.runTs0, c.runTs, codec)
	if c.firstRun && c.runN >= 2 {
		c.backlogPkts, c.backlogMs = c.runN, span
	}
	if c.runN > c.win.maxBurst {
		c.win.maxBurst, c.win.burstMs = c.runN, span
	}
	if c.runN > c.call.maxBurst {
		c.call.maxBurst, c.call.burstMs = c.runN, span
	}
}

// rtpSpanMs is the RTP time from ts0 to ts1 in the codec's clock, in ms.
func rtpSpanMs(ts0, ts1 uint32, codec media.Codec) int64 {
	if codec.SampleRate == 0 {
		return 0
	}
	return int64(int32(ts1-ts0)) * 1000 / int64(codec.SampleRate)
}

// window returns the current window's figures and resets its maxima.
func (c *continuity) window() continuityWindow {
	c.mu.Lock()
	defer c.mu.Unlock()
	w := continuityWindow{
		backlogPkts: c.backlogPkts, backlogMs: c.backlogMs, firstRTPMs: c.firstRTPMs, answerToPumpMs: c.answerToPumpMs,
		maxGapMs: c.win.maxGapMs, maxBurst: c.win.maxBurst, burstMs: c.win.burstMs,
	}
	c.win = continuityMax{}
	return w
}

// summary is the call-level tail of pump.String.
func (c *continuity) summary() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return fmt.Sprintf("backlog=%d/%d max_gap_ms=%d max_burst=%d burst_ms=%d first_rtp_ms=%d answer_to_pump_ms=%d",
		c.backlogPkts, c.backlogMs, c.call.maxGapMs, c.call.maxBurst, c.call.burstMs, c.firstRTPMs, c.answerToPumpMs)
}

// pumpTrace is the per-packet TSV a pump writes when Config.RTPTraceDir is
// set: one line per packet read, written after the packet was forwarded so
// it carries the skew that packet produced. Written by the relay goroutine
// only; closed by it when the pump ends.
type pumpTrace struct {
	f       *os.File
	w       *bufio.Writer
	started time.Time
	log     *slog.Logger
	failed  bool
}

// setTrace names the trace file this pump writes if dir is set:
// <dir>/<call id>-<name>.tsv, the call id sanitised for a filename.
func (p *pump) setTrace(dir, callID, name string) {
	if dir == "" {
		return
	}
	p.traceDir, p.traceName = dir, safeFileName(callID)+"-"+safeFileName(name)
}

// safeFileName keeps letters, digits, '.', '_' and '-'; anything else
// (the '@' and '/' SIP call ids carry) becomes '_'.
func safeFileName(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '.', r == '_', r == '-':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	return b.String()
}

// openTrace opens the trace file, appending: a pump restarted by a transfer
// writes to the same file, and its new header (t_us restarts from 0) marks
// where. An error is logged once and the pump runs untraced.
func (p *pump) openTrace(log *slog.Logger) {
	if p.traceDir == "" || p.traceName == "" {
		return
	}
	if err := os.MkdirAll(p.traceDir, 0o755); err != nil {
		log.Warn("rtp trace: cannot create directory; not tracing", "dir", p.traceDir, "err", err)
		return
	}
	path := filepath.Join(p.traceDir, p.traceName+".tsv")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		log.Warn("rtp trace: cannot open file; not tracing", "path", path, "err", err)
		return
	}
	t := &pumpTrace{f: f, w: bufio.NewWriterSize(f, 64<<10), started: time.Now(), log: log}
	if _, err := t.w.WriteString("t_us\tseq\tts\tlen\tskew_ms\tmarker\n"); err != nil {
		t.fail(err)
	}
	p.trace = t
	log.Info("rtp trace: writing", "path", path)
}

// traceRead writes one packet's line, if tracing.
func (p *pump) traceRead(now time.Time, hdr *rtp.Header, n int) {
	if p.trace == nil {
		return
	}
	p.trace.write(now, hdr, n, &p.skewMs)
}

func (t *pumpTrace) write(now time.Time, hdr *rtp.Header, n int, skew *atomic.Int64) {
	if t.failed {
		return
	}
	var seq uint16
	var ts uint32
	marker := 0
	if hdr != nil {
		seq, ts = hdr.SequenceNumber, hdr.Timestamp
		if hdr.Marker {
			marker = 1
		}
	}
	if _, err := fmt.Fprintf(t.w, "%d\t%d\t%d\t%d\t%d\t%d\n", now.Sub(t.started).Microseconds(), seq, ts, n, skew.Load(), marker); err != nil {
		t.fail(err)
	}
}

func (t *pumpTrace) fail(err error) {
	if !t.failed {
		t.failed = true
		t.log.Warn("rtp trace: write failed; trace stops here", "err", err)
	}
}

// closeTrace flushes and closes the trace, if any.
func (p *pump) closeTrace() {
	t := p.trace
	if t == nil {
		return
	}
	p.trace = nil
	if err := t.w.Flush(); err != nil && !t.failed {
		t.log.Warn("rtp trace: flush failed", "err", err)
	}
	if err := t.f.Close(); err != nil {
		t.log.Warn("rtp trace: close failed", "err", err)
	}
}
