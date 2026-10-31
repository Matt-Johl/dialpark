package b2bua

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/emiago/diago"
	"github.com/emiago/diago/media"
	"github.com/emiago/sipgo"
	"github.com/emiago/sipgo/sip"

	"dialpark/server/internal/moh"
	"dialpark/server/internal/routing"
	"dialpark/server/internal/wire"
)

// callLeg is one side of a bridged call as the relay sees it.
type callLeg struct {
	name  string
	trunk bool
	sess  diago.DialogSession
	codec media.Codec
	// party is who is on this leg, for wakes and logs (the caller's From
	// on the incoming leg, the dialled user on an outgoing one).
	party wire.Party
	// answeredAt is when this leg was answered (the callee's 200 OK, or
	// ours to the caller), so the pump that reads it can say how long its
	// RTP may have queued before the relay started (answer_to_pump_ms).
	// Zero when unknown (a transfer target).
	answeredAt time.Time
}

// bridgedCall owns the two legs of a call and the pumps between them, and
// can replace one leg by another on a transfer (SPEC §4.4 rule 6: REFER is
// handled here, never passed to the far leg).
type bridgedCall struct {
	s      *Server
	log    *slog.Logger
	callID string
	since  time.Time

	mu     sync.Mutex
	a, b   *callLeg // b == nil while a is on echo (self-relay)
	pumps  []*pump
	cancel context.CancelFunc
	// swapped wakes the wait loop so it watches the new leg's context.
	swapped chan struct{}
	// offload is non-nil while the PBX is completing a transfer for us and
	// closed when that attempt is over; offloaded says it succeeded, i.e.
	// finishOffload released both legs and wait() must not hang up either.
	offload   chan struct{}
	offloaded bool
	// woken lists devices a transfer woke for this call; their pending
	// wakes are forgotten when the call ends (the invite path does the same
	// for the callee it woke).
	woken []string
	// Hold (SPEC §4.4 rule 8b): the leg whose party pressed hold, and the
	// stop for the music playing to the other one. Nil when nobody holds.
	heldBy   *callLeg
	holdStop context.CancelFunc
	// Non-nil while this server is completing a transfer, closed when it is
	// decided. The referrer is released as soon as the target rings, so its
	// BYE must not be read as the end of the call (rule 6a).
	handing chan struct{}
	// Closed once a party has stopped answering (qualifyLegs). wait()
	// selects on it exactly as it does on a leg ending, because a party
	// that vanished cannot send a BYE and will not answer ours — so its
	// dialog context never completes, and nothing else would ever notice
	// that the call is over.
	gone     chan struct{}
	goneOnce sync.Once
}

func newBridgedCall(s *Server, log *slog.Logger, callID string, a, b *callLeg) *bridgedCall {
	return &bridgedCall{
		s: s, log: log, callID: callID, a: a, b: b, since: time.Now(),
		swapped: make(chan struct{}, 1),
		gone:    make(chan struct{}),
	}
}

// start (re)starts the relay pumps between the current legs.
func (c *bridgedCall) start() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.startLocked()
}

func (c *bridgedCall) startLocked() error {
	if c.cancel != nil {
		c.cancel()
	}
	// The pumps are about to be replaced (a transfer): the music was
	// playing on one of the old ones.
	c.stopHoldLocked()
	ctx, cancel := context.WithCancel(context.Background())
	c.cancel = cancel
	// The leg that stays keeps its stream: whichever new pump writes to
	// it carries on from where the old one left off (pump.inheritTimeline).
	prev := c.pumps
	inherit := func(p *pump) {
		for _, old := range prev {
			p.inheritTimeline(old)
		}
	}
	c.pumps = nil
	if c.b == nil {
		// Echo: the remaining party hears itself.
		p, err := newPump(c.a.sess.Media(), c.a.sess.Media())
		if err != nil {
			return err
		}
		inherit(p)
		p.setTrace(c.s.cfg.RTPTraceDir, c.callID, c.a.name+"-"+c.a.name)
		c.pumps = []*pump{p}
		go p.run(ctx, c.log.With("dir", c.a.name+"→"+c.a.name))
		return nil
	}
	ab, err := newPump(c.a.sess.Media(), c.b.sess.Media())
	if err != nil {
		return err
	}
	ba, err := newPump(c.b.sess.Media(), c.a.sess.Media())
	if err != nil {
		return err
	}
	inherit(ab)
	inherit(ba)
	// Continuity lab (2026-10-31): the first start of the call knows when
	// each leg was answered; a restart (transfer) does not describe a start
	// of RTP, so it carries nothing.
	if prev == nil {
		ab.answeredAt, ba.answeredAt = c.a.answeredAt, c.b.answeredAt
	}
	ab.setTrace(c.s.cfg.RTPTraceDir, c.callID, c.a.name+"-"+c.b.name)
	ba.setTrace(c.s.cfg.RTPTraceDir, c.callID, c.b.name+"-"+c.a.name)
	c.pumps = []*pump{ab, ba}
	go ab.run(ctx, c.log.With("dir", c.a.name+"→"+c.b.name))
	go ba.run(ctx, c.log.With("dir", c.b.name+"→"+c.a.name))
	return nil
}

// setHeld starts or stops hold music after `by` re-INVITEd its leg into or
// out of hold (SPEC §4.4 rule 8b).
//
// The music plays to the OTHER leg — the party who did not press hold and
// would otherwise hear nothing at all, because hold means the holder has
// stopped sending. Nothing is signalled to them: their call carries on
// exactly as it was, which is why this works whatever is at the far end and
// however it is configured.
func (c *bridgedCall) setHeld(by *callLeg, held bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !held {
		if c.heldBy == by {
			c.log.Info("hold released", "held_by", by.name)
			c.stopHoldLocked()
		}
		return
	}
	if c.heldBy == by {
		return // a re-INVITE that changed something else; already holding
	}
	if c.playLocked(by, "music", "hold") {
		c.heldBy = by
	}
}

// playMusicLocked starts hold music to the party OPPOSITE `from`, on the
// pump that feeds them. Two things need it and they are the same thing from
// the far end's point of view — someone pressed hold, or someone transferred
// the call and the target is being dialled — so they share the mechanism
// and differ only in `why`, which is for the log.
//
// Returns false when there is nothing to play to. Caller holds c.mu.
func (c *bridgedCall) playLocked(from *callLeg, clip, why string) bool {
	// Never two players on one stream. A transfer is routinely preceded by
	// a hold — baresip holds before it REFERs, and a phone may too — so
	// this is the normal path, not an edge case.
	c.stopHoldLocked()
	other, feed := c.b, 0
	if from == c.b {
		other, feed = c.a, 1
	}
	if other == nil || feed >= len(c.pumps) {
		return false // echo, or the pumps are between restarts
	}
	frames := moh.Clip(clip, other.codec.Name)
	if frames == nil {
		// Nothing pre-encoded for what this leg negotiated: the waiting
		// party gets the silence it would have had anyway, but say so — it
		// means a codec reached production that gen_moh.py does not cover.
		c.log.Warn("nothing to play for the codec", "clip", clip, "why", why, "playing_to", other.name, "codec", other.codec.Name)
		return false
	}
	ctx, cancel := context.WithCancel(context.Background())
	c.holdStop = cancel
	c.log.Info("playing to the waiting party", "clip", clip, "why", why, "playing_to", other.name, "codec", other.codec.Name, "loop_s", frames.Seconds())
	go c.pumps[feed].playHold(ctx, frames, c.log.With("dir", from.name+"→"+other.name))
	return true
}

// Caller holds c.mu.
func (c *bridgedCall) stopHoldLocked() {
	if c.holdStop != nil {
		c.holdStop()
		c.holdStop = nil
	}
	c.heldBy = nil
}

// byeTimeout bounds a BYE sent to a party we already believe is not there.
// Matches the release path in finishOffload; without it Bye waits out the
// transaction's own Timer B (32 s) for a 200 that is never coming.
const byeTimeout = 5 * time.Second

// qualifyLegs asks each party, on an interval, whether it is still there,
// and ends the call when one stops answering for PeerTimeout.
//
// A B2BUA cannot rely on a BYE: a phone that crashes, loses its network or
// is suspended sends none, and sipgo ends a dialog only on a BYE, a Hangup
// answered 200, or a failed ACK — so nothing cancels the dialog, wait()
// blocks for ever, and the call and its relay outlive everyone on it (14½
// hours, 2026-09-22).
//
// It asks rather than infers. Watching the media instead looks cheaper and
// is what this did first, but "is media flowing" is only a proxy for "is
// the peer there", and a proxy needs an exception for every state where a
// live party legitimately sends nothing — hold, mute, recvonly, inactive,
// a leg mid-transfer. That list has no end and each entry hides the next
// bug. An in-dialog OPTIONS asks the question itself: a held party answers
// it, a muted party answers it, a party being transferred answers it, and
// a party that has gone does not. Same pattern as the trunk leg's
// qualifier (qualify.go), and the principle in SPEC §4.7 — whether the far
// end answers when spoken to, not whether it has been busy.
func (c *bridgedCall) qualifyLegs(ctx context.Context, timeout time.Duration) {
	// Four asks across the window, so one lost OPTIONS cannot end a call:
	// a party has to miss every ask for the whole timeout. That is the
	// tolerance, rather than a retry count to get wrong.
	interval := timeout / 4
	if interval < 100*time.Millisecond {
		// Only a guard against a pathological timeout asking for a
		// zero-length ticker; at the 60 s default this is 15 s.
		interval = 100 * time.Millisecond
	}
	// Always finish an ask before the next one is due.
	probe := interval / 2
	if probe > byeTimeout {
		probe = byeTimeout
	}
	// Keyed by leg, so a leg a transfer swaps in starts with a clean slate
	// and one it swapped out is forgotten. No transfer case to special-case.
	answered := map[*callLeg]time.Time{}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		c.mu.Lock()
		legs := [2]*callLeg{c.a, c.b}
		c.mu.Unlock()

		here := map[*callLeg]bool{}
		for _, leg := range legs {
			if leg == nil || leg.sess == nil {
				continue
			}
			here[leg] = true
			if _, known := answered[leg]; !known {
				answered[leg] = time.Now()
			}
			if c.answers(ctx, leg, probe) {
				answered[leg] = time.Now()
				continue
			}
			if since := time.Since(answered[leg]); since > timeout {
				c.log.Warn("party stopped answering; ending the call", "party", leg.name,
					"unanswered_s", since.Round(time.Second).Seconds(), "timeout_s", timeout.Seconds())
				c.goneOnce.Do(func() { close(c.gone) })
				return
			}
		}
		for leg := range answered {
			if !here[leg] {
				delete(answered, leg)
			}
		}
	}
}

// answers asks one party, inside its own dialog, whether it is there.
//
// ANY final response means it is — 200, 405, 403, even 481. The question is
// whether something is still at the other end, not what it thinks of the
// request: stacks handle OPTIONS at wildly different levels (baresip
// answers from the user agent, without consulting the dialog at all), so
// reading a particular code as "this call is over" would end live calls on
// the stacks that answer that way. Only silence counts as gone.
func (c *bridgedCall) answers(ctx context.Context, leg *callLeg, within time.Duration) bool {
	if leg.sess.Context().Err() != nil {
		return false // already ended; wait() is dealing with it
	}
	ctx, cancel := context.WithTimeout(ctx, within)
	defer cancel()
	_, err := leg.sess.Do(ctx, sip.NewRequest(sip.OPTIONS, remoteTarget(leg.sess)))
	return err == nil
}

// wait blocks until either leg ends, hangs up the other, and stops the
// pumps. A transfer swaps a leg underneath it.
func (c *bridgedCall) wait() {
	if d := c.s.cfg.PeerTimeout; d > 0 {
		qctx, stop := context.WithCancel(context.Background())
		defer stop()
		go c.qualifyLegs(qctx, d)
	}
	for {
		c.mu.Lock()
		a, b := c.a, c.b
		c.mu.Unlock()
		var bDone <-chan struct{}
		if b != nil {
			bDone = b.sess.Context().Done()
		}
		aEnded, peerGone := false, false
		select {
		case <-a.sess.Context().Done():
			aEnded = true
		case <-bDone:
		case <-c.swapped:
			continue
		case <-c.gone:
			peerGone = true
		}
		// A transfer the PBX is completing ends the legs on its own terms:
		// let finishOffload do the orderly release (final NOTIFY to the
		// referrer first) rather than racing it with a plain BYE.
		if c.awaitOffload() {
			break
		}
		// A transfer we are completing releases the referrer the moment the
		// target rings (SPEC §4.4 rule 6a), so its BYE arrives while the
		// call is very much alive. Wait for the transfer to be decided and
		// then look again at whatever legs are left.
		if c.awaitHandover() {
			continue
		}
		if peerGone {
			// Nobody is answering, so neither dialog will end itself and at
			// least one BYE is going nowhere. Bound them: a dialog's own
			// context never expires, and Bye waits for a 200 that a party
			// which has gone will never send (Timer B, 32 s, twice).
			hctx, hcancel := context.WithTimeout(context.Background(), byeTimeout)
			_ = a.sess.Hangup(hctx)
			if b != nil {
				_ = b.sess.Hangup(hctx)
			}
			hcancel()
			break
		}
		if aEnded {
			if b != nil {
				_ = b.sess.Hangup(b.sess.Context())
			}
		} else {
			_ = a.sess.Hangup(a.sess.Context())
		}
		break
	}
	c.mu.Lock()
	if c.cancel != nil {
		c.cancel()
	}
	summary := make([]string, 0, len(c.pumps))
	for _, p := range c.pumps {
		summary = append(summary, p.String())
	}
	woken := c.woken
	c.mu.Unlock()
	if c.s.waker != nil {
		for _, dev := range woken {
			c.s.waker.ForgetWake(dev, c.callID)
		}
	}
	c.log.Info("call ended", "relay", strings.Join(summary, " | "))
}

// onRefer is the OnRefer hook for a leg: the party on `from` asked us to
// connect the other party to referTo instead. diago has already answered
// the REFER (202) and sent NOTIFY 100; it dials nothing itself because we
// return before touching the dialog it prepared (we route the target
// ourselves). On success we send the final NOTIFY and hang the referrer
// up; on error diago sends a failure NOTIFY from the returned error.
func (c *bridgedCall) onRefer(from *callLeg) diago.OnReferDialogFunc {
	return func(rd *diago.DialogClientSession) error {
		return c.transfer(from, rd.InviteRequest.Recipient)
	}
}

// transfer replaces `from` with a new leg to referTo, bridged to the other
// party, then releases `from`.
func (c *bridgedCall) transfer(from *callLeg, referTo sip.Uri) error {
	c.mu.Lock()
	other := c.b
	if from == c.b {
		other = c.a
	}
	c.mu.Unlock()
	if other == nil {
		return errors.New("transfer: nothing to transfer (echo)")
	}
	log := c.log.With("transfer_from", from.name, "refer_to", referTo.String())
	log.Info("transfer: requested")

	target := referTarget(referTo)
	d := c.s.router.Resolve(target)
	ctx, cancel := context.WithTimeout(other.sess.Context(), c.s.cfg.RingTimeout)
	defer cancel()

	if shouldOffload(other, d.Target) {
		// Both parties are on the PBX: let it complete the transfer itself
		// and get this server out of the media path (SPEC §4.4 rule 6).
		err := c.offloadToPBX(ctx, log, from, other, d.User)
		var refused *offloadRefused
		switch {
		case err == nil:
			return nil
		case errors.As(err, &refused):
			log.Info("transfer: PBX declined the REFER; handling it here", "why", refused.why)
		default:
			return err
		}
	}

	// The remaining party is about to wait while the target is resolved,
	// woken and rung — seconds, and up to the ring timeout if a wake is
	// involved. They were left in silence until now (SPEC §6 near-term item
	// 2); give them the same music a hold does, from the same place.
	// The waiting party hears music while the target is resolved and woken,
	// then ring-back the moment it actually alerts — and that alert is also
	// when the referrer is let go (rule 6a).
	c.mu.Lock()
	c.playLocked(from, "music", "transfer")
	c.handing = make(chan struct{})
	handing := c.handing
	origA, origB := c.a, c.b
	c.mu.Unlock()
	var released atomic.Bool
	handed := false
	defer func() {
		close(handing) // wait() may look at the legs again
		c.mu.Lock()
		defer c.mu.Unlock()
		if handed || c.a != origA || c.b != origB {
			return // the transfer happened; these legs are gone
		}
		c.stopHoldLocked()
		if released.Load() {
			return // nobody to go back to; the failure path dealt with it
		}
		// Refused before it ever rang, so the referrer was never released
		// and the original call stands. They are usually still HOLDING —
		// most phones, baresip included, hold before they REFER — so the
		// transfer's music gives way to an ordinary hold rather than to
		// the silence this rule exists to remove.
		ms := from.sess.Media().MediaSession()
		if ms != nil && heldMode(ms.NegotiatedMode()) && c.playLocked(from, "music", "hold") {
			c.heldBy = from
		}
	}()

	var newLeg *callLeg
	switch d.Target {
	case routing.Unknown:
		log.Info("transfer: unknown destination")
		return &sipgo404{}
	case routing.Echo:
		newLeg = nil
	case routing.Trunk, routing.Local:
		dst, trunk, err := c.s.transferDestination(ctx, log, c, d, other)
		if err != nil {
			return err
		}
		out, err := c.s.dg.NewDialog(dst, diago.NewDialogOptions{TransportID: c.s.calleeTransport(trunk, uriUser(other.party.URI))})
		if err != nil {
			return err
		}
		codecs := []media.Codec{other.codec}
		if trunk {
			// The remaining leg's codec first, so the PBX keeps the call
			// on it whenever it can; the rest of the trunk set as fallback
			// (the remaining leg is then moved by re-INVITE, below).
			for _, tc := range c.s.cfg.trunkCodecs() {
				if tc != other.codec {
					codecs = append(codecs, tc)
				}
			}
		}
		out.SetCodecs(codecs)
		leg := &callLeg{name: "transfer", trunk: trunk, sess: out, party: wire.Party{URI: dst.String()}}
		nat := c.s.legNAT(trunk)
		// The remaining party is who ends up in this call, so in lines mode
		// it is their line the PBX must see it come from — not the
		// referrer's, who is about to be released.
		headers, digestUser, digestSecret, identified := c.s.calleeInvite(c.callID, trunk, uriUser(other.party.URI))
		if !identified {
			log.Warn("transfer: no PBX line for the remaining party and no default line; refusing",
				"party", other.party.URI)
			out.Close()
			return &sipgo403{}
		}
		err = out.Invite(ctx, diago.InviteClientOptions{
			Headers:       headers,
			Username:      digestUser,
			Password:      digestSecret,
			OnMediaUpdate: func(m *diago.DialogMedia) { m.MediaSession().RTPNAT = nat },
			OnRefer:       c.onRefer(leg),
			// The target alerting is the hand-off: the number exists and
			// is free, so the waiting party moves from music to ring-back
			// and the referrer is let go (rule 6a). Before this point a
			// refusal still belongs to the referrer, who keeps the call.
			OnResponse: func(res *sip.Response) error {
				if res == nil || !handsOver(int(res.StatusCode)) {
					return nil
				}
				if !released.CompareAndSwap(false, true) {
					return nil
				}
				c.mu.Lock()
				c.playLocked(from, "ringback", "transfer: target ringing")
				c.mu.Unlock()
				log.Info("transfer: target is ringing; releasing the referrer", "status", res.StatusCode)
				// Not inline: releaseReferrer waits out a BYE grace, and
				// this runs on the response path of a live transaction.
				go c.releaseReferrer(context.Background(), log, from)
				return nil
			},
		})
		if err != nil {
			_ = out.Hangup(out.Context())
			out.Close()
			if !released.Load() {
				log.Info("transfer: refused before it rang; the call stays where it is", "err", err)
				return err
			}
			// It rang, so the referrer has gone and there is nobody to put
			// the waiting party back with. Busy tone, then let them go —
			// the ordinary end of a blind transfer nobody answered.
			log.Info("transfer: failed after ringing; the referrer is already released", "err", err)
			c.mu.Lock()
			c.playLocked(from, "busy", "transfer: failed after release")
			c.mu.Unlock()
			select {
			case <-time.After(busyBeforeHangup):
			case <-other.sess.Context().Done():
			}
			c.mu.Lock()
			c.stopHoldLocked()
			c.mu.Unlock()
			if other.sess.Context().Err() == nil {
				_ = other.sess.Hangup(context.Background())
			}
			handed = true
			return err
		}
		if err := out.Ack(ctx); err != nil {
			out.Close()
			return err
		}
		leg.codec = media.CodecAudioFromSession(out.Media().MediaSession())
		if !sameCodec(leg.codec, other.codec) {
			// The relay copies encoded audio, so both legs must share a
			// codec: move the remaining leg onto the target's by re-INVITE
			// (an app on Opus transferred to the PBX lands on G.722). Only
			// if the remaining party refuses is the transfer impossible.
			log.Info("transfer: codec mismatch, renegotiating the remaining leg", "target", leg.codec.Name, "remaining", other.codec.Name)
			if err := renegotiateCodec(ctx, other, leg.codec); err != nil {
				log.Info("transfer: remaining leg would not move codec", "codec", leg.codec.Name, "err", err)
				_ = out.Hangup(out.Context())
				out.Close()
				return &sipgo488{}
			}
			log.Info("transfer: remaining leg renegotiated", "codec", other.codec.Name)
		}
		newLeg = leg
	}

	// Swap legs and restart the pumps before releasing the referrer, so
	// the remaining party never hears a gap longer than the dial.
	c.mu.Lock()
	if from == c.a {
		c.a, c.b = other, newLeg
	} else {
		c.b = newLeg
	}
	err := c.startLocked()
	c.mu.Unlock()
	if err != nil {
		return err
	}
	select {
	case c.swapped <- struct{}{}:
	default:
	}
	log.Info("transfer: bridged", "remaining", other.name, "to", target)

	handed = true
	if !released.Load() {
		// Answered without ever alerting (an auto-answering phone, the PBX
		// echo): the referrer is still waiting to be told.
		c.releaseReferrer(ctx, log, from)
	}
	return nil
}

// handsOver reports whether a response from a transfer target means the
// hand-off has happened and the referrer can be let go (rule 6a).
//
// Only 18x. **100 Trying is not alerting** — it says the INVITE arrived,
// nothing more, and releasing on it would let the referrer go a moment
// before a 404 came back, leaving the waiting party with nobody and the
// referrer told it worked. A final response is not alerting either: it is
// the outcome, and until something rings the call still belongs to the
// referrer.
func handsOver(status int) bool { return status >= 180 && status < 200 }

// How long the party left behind by a failed transfer hears busy before the
// call is ended. Long enough to be recognised, short enough not to nag.
const busyBeforeHangup = 4 * time.Second

// How long the referrer gets to hang up on its own after the final NOTIFY.
const referrerByeGrace = 1500 * time.Millisecond

// releaseReferrer reports success to the party that asked for the transfer
// and lets it end its own call: baresip, like any RFC 3515 client, sends
// BYE on the final NOTIFY, so hanging it up ourselves in the same instant
// makes the two BYEs cross and one is answered 481. Give it a moment, then
// hang up only if it is still there.
func (c *bridgedCall) releaseReferrer(ctx context.Context, log *slog.Logger, from *callLeg) {
	notify := referNotify(remoteTarget(from.sess), 200, "OK")
	if _, err := from.sess.Do(ctx, notify); err != nil {
		log.Info("transfer: final NOTIFY to the referrer failed", "err", err)
	}
	select {
	case <-from.sess.Context().Done(): // it hung up on the NOTIFY, as expected
	case <-time.After(referrerByeGrace):
		_ = from.sess.Hangup(ctx)
	}
	from.sess.Close()
}

// transferDestination resolves a routed transfer target to a dial URI,
// waking an unregistered local user like a fresh call would.
func (s *Server) transferDestination(ctx context.Context, log *slog.Logger, c *bridgedCall, d routing.Decision, other *callLeg) (sip.Uri, bool, error) {
	var dst sip.Uri
	callID := c.callID
	if d.Target == routing.Trunk {
		if s.cfg.Trunk == nil {
			return dst, false, errors.New("no trunk")
		}
		err := sip.ParseUri(s.cfg.Trunk.URI(d.User), &dst)
		return dst, true, err
	}
	ep := d.Endpoint
	if d.Registered && !s.cfg.KeepAdvertisedContact && !s.flowAlive(ep.Contact) {
		s.reg.Unregister(ep.User)
		d.Registered = false
	}
	if !d.Registered {
		from := sip.FromHeader{Address: sip.Uri{}}
		_ = sip.ParseUri(other.party.URI, &from.Address)
		from.DisplayName = other.party.DisplayName
		woken, err := s.wakeAndWaitFrom(ctx, log, nil, callID, &from, ep, nil)
		if err != nil {
			return dst, false, err
		}
		c.mu.Lock()
		c.woken = append(c.woken, ep.DeviceID)
		c.mu.Unlock()
		ep = woken
	}
	err := sip.ParseUri(ep.Contact, &dst)
	return dst, false, err
}

// remoteTarget is the far end's Contact for in-dialog requests: the INVITE's
// Contact when they called us, the 2xx's when we called them.
func remoteTarget(d diago.DialogSession) sip.Uri {
	if rc, ok := d.(interface{ RemoteContact() *sip.ContactHeader }); ok {
		if c := rc.RemoteContact(); c != nil {
			return c.Address
		}
	}
	dlg := d.DialogSIP()
	if dlg.InviteResponse != nil {
		if c := dlg.InviteResponse.Contact(); c != nil {
			return c.Address
		}
	}
	if c := dlg.InviteRequest.Contact(); c != nil {
		return c.Address
	}
	return dlg.InviteRequest.Recipient
}

// referTarget turns a Refer-To URI into what the router understands: the
// user part, with our own host kept so foreign domains stay foreign.
func referTarget(u sip.Uri) string {
	if u.Host == "" {
		return u.User
	}
	return "sip:" + u.User + "@" + u.Host
}

// referNotify builds the NOTIFY that reports a REFER's outcome (RFC 3515):
// a sipfrag body with the status, subscription terminated.
func referNotify(remote sip.Uri, code int, reason string) *sip.Request {
	req := sip.NewRequest(sip.NOTIFY, remote)
	req.AppendHeader(sip.NewHeader("Event", "refer"))
	req.AppendHeader(sip.NewHeader("Subscription-State", "terminated;reason=noresource"))
	req.AppendHeader(sip.NewHeader("Content-Type", "message/sipfrag;version=2.0"))
	req.SetBody([]byte(fmt.Sprintf("SIP/2.0 %d %s", code, reason)))
	return req
}

// ---- transfer offload to the PBX --------------------------------------------

// shouldOffload: when the party that stays on the call is on the PBX trunk
// and the transfer target is a PBX destination too, the PBX can complete
// the transfer itself and this server leaves the media path entirely.
// Anything involving an app leg, or the server's own echo, stays here.
func shouldOffload(remaining *callLeg, target routing.Target) bool {
	return remaining != nil && remaining.trunk && target == routing.Trunk
}

// offloadRefused: the PBX did not complete the transfer (REFER rejected, a
// failure NOTIFY, or no answer); the server does the transfer itself.
type offloadRefused struct{ why string }

func (e *offloadRefused) Error() string { return "PBX declined the transfer: " + e.why }

// referOutcome classifies a NOTIFY status about our REFER: not final yet
// (1xx), success (2xx), or a refusal.
func referOutcome(code int) (final, success bool) {
	switch {
	case code < 200:
		return false, false
	case code < 300:
		return true, true
	default:
		return true, false
	}
}

// responseStatus is the SIP status inside a sipgo dialog error, or 0.
func responseStatus(err error) int {
	var byVal sipgo.ErrDialogResponse
	var byPtr *sipgo.ErrDialogResponse
	if errors.As(err, &byVal) && byVal.Res != nil {
		return byVal.Res.StatusCode
	}
	if errors.As(err, &byPtr) && byPtr != nil && byPtr.Res != nil {
		return byPtr.Res.StatusCode
	}
	return 0
}

// How long to wait for the PBX to report the transfer's outcome.
const referOutcomeTimeout = 10 * time.Second

// offloadToPBX re-issues the app's transfer to the PBX: our own REFER on
// the remaining party's trunk leg, Refer-To the target as the PBX knows
// it. The PBX moves its endpoint (the phone) to the target, reports the
// outcome in a NOTIFY and hangs our leg up. On success both of our legs
// are released and the referrer gets its final NOTIFY 200; the audio then
// runs phone ↔ PBX ↔ target with this server gone. Returns offloadRefused
// when the PBX would not do it, so transfer() falls back to dialling.
func (c *bridgedCall) offloadToPBX(ctx context.Context, log *slog.Logger, from, remaining *callLeg, user string) error {
	if c.s.cfg.Trunk == nil {
		return &offloadRefused{"no trunk configured"}
	}
	var referTo sip.Uri
	if err := sip.ParseUri(c.s.cfg.Trunk.URI(user), &referTo); err != nil {
		return err
	}
	outcome := make(chan int, 8)
	onNotify := func(code int) {
		select {
		case outcome <- code:
		default:
		}
	}
	var err error
	switch sess := remaining.sess.(type) {
	case *diago.DialogServerSession: // the PBX called us
		err = sess.ReferOptions(ctx, referTo, diago.ReferServerOptions{OnNotify: onNotify})
	case *diago.DialogClientSession: // we called the PBX
		err = sess.ReferOptions(ctx, referTo, diago.ReferClientOptions{OnNotify: onNotify})
	default:
		return &offloadRefused{"leg cannot send REFER"}
	}
	if err != nil {
		if code := responseStatus(err); code != 0 {
			return &offloadRefused{fmt.Sprintf("REFER rejected with %d", code)}
		}
		return &offloadRefused{"REFER failed: " + err.Error()}
	}
	log.Info("transfer: REFER accepted by the PBX; waiting for its outcome", "refer_to", referTo.String())
	c.beginOffload()

	timeout := time.NewTimer(referOutcomeTimeout)
	defer timeout.Stop()
	for {
		select {
		case code := <-outcome:
			final, ok := referOutcome(code)
			if !final {
				continue
			}
			if !ok {
				c.endOffload(false)
				return &offloadRefused{fmt.Sprintf("PBX reported %d", code)}
			}
			c.finishOffload(log, from, remaining, user)
			return nil
		case <-remaining.sess.Context().Done():
			// The PBX moved the phone and hung our leg up before (or
			// instead of) a final NOTIFY: same outcome.
			c.finishOffload(log, from, remaining, user)
			return nil
		case <-timeout.C:
			c.endOffload(false)
			return &offloadRefused{"no final NOTIFY from the PBX"}
		}
	}
}

func (c *bridgedCall) beginOffload() {
	c.mu.Lock()
	c.offload = make(chan struct{})
	c.mu.Unlock()
}

// endOffload records the attempt's result and releases wait() if it is
// holding for it.
func (c *bridgedCall) endOffload(succeeded bool) {
	c.mu.Lock()
	c.offloaded = succeeded
	ch := c.offload
	c.mu.Unlock()
	if ch != nil {
		close(ch)
	}
}

// awaitHandover is wait()'s side of a server-completed transfer: while one
// is in flight, block until it is decided rather than tearing the call down
// under it. Returns true when wait() should look at the legs afresh.
func (c *bridgedCall) awaitHandover() bool {
	c.mu.Lock()
	ch := c.handing
	c.mu.Unlock()
	if ch == nil {
		return false
	}
	<-ch
	c.mu.Lock()
	c.handing = nil
	c.mu.Unlock()
	return true
}

// awaitOffload is wait()'s side: if a PBX-side transfer is in progress,
// block until it is decided, then report whether the legs were already
// released by finishOffload.
func (c *bridgedCall) awaitOffload() bool {
	c.mu.Lock()
	ch := c.offload
	c.mu.Unlock()
	if ch == nil {
		return false
	}
	<-ch
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.offloaded
}

// finishOffload stops relaying, tells the referrer the transfer succeeded
// (baresip ends its call as "transferred" on that NOTIFY), and releases
// both legs. Uses its own context: the legs' contexts may already be over.
func (c *bridgedCall) finishOffload(log *slog.Logger, from, remaining *callLeg, user string) {
	c.mu.Lock()
	if c.cancel != nil {
		c.cancel() // no more relaying: the PBX carries the audio now
	}
	summary := make([]string, 0, len(c.pumps))
	for _, p := range c.pumps {
		summary = append(summary, p.String())
	}
	c.mu.Unlock()
	log.Info("transfer: offloaded to PBX", "remaining", remaining.name, "to", user, "relayed_until_now", strings.Join(summary, " | "))

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c.releaseReferrer(ctx, log, from)
	if remaining.sess.Context().Err() == nil {
		_ = remaining.sess.Hangup(ctx)
	}
	remaining.sess.Close()
	c.endOffload(true)
}

// Errors carrying a SIP status for diago's failure NOTIFY.
type sipgo403 struct{}
type sipgo404 struct{}
type sipgo488 struct{}

func (*sipgo403) Error() string { return "403 Forbidden" }
func (*sipgo404) Error() string { return "404 Not Found" }
func (*sipgo488) Error() string { return "488 Not Acceptable Here" }

func sameCodec(a, b media.Codec) bool {
	return a.Name == b.Name && a.SampleRate == b.SampleRate && a.NumChannels == b.NumChannels
}

// reInviter is what both diago session types offer beyond DialogSession.
type reInviter interface {
	ReInvite(ctx context.Context) error
}

// renegotiateCodec moves an established leg onto codec: narrows its offer
// to that one codec, re-INVITEs, and checks the answer took it. The leg's
// codec is updated; on failure the previous negotiation is restored so the
// call carries on as it was.
func renegotiateCodec(ctx context.Context, leg *callLeg, codec media.Codec) error {
	ri, ok := leg.sess.(reInviter)
	if !ok {
		return errors.New("session cannot re-INVITE")
	}
	m := leg.sess.Media()
	prev := m.MediaSession().CommonCodecs()
	if len(prev) == 0 {
		prev = []media.Codec{leg.codec}
	}
	m.SetCodecs([]media.Codec{codec})
	err := ri.ReInvite(ctx)
	if err == nil {
		if got := media.CodecAudioFromSession(m.MediaSession()); sameCodec(got, codec) {
			leg.codec = got
			return nil
		}
		err = errors.New("answer did not take the codec")
	}
	m.SetCodecs(prev)
	return err
}
