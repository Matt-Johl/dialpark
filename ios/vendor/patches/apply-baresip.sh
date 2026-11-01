#!/bin/sh
# In-place, idempotent source patches for baresip beyond the audiounit
# full-file replacements. Usage: apply-baresip.sh <baresip-src-dir>
#
# ua_refresh_register(): send a REGISTER now on the existing register
# clients. baresip's ua_register() destroys and re-creates its clients, and
# libre's client sends an un-REGISTER for the same contact as it is
# destroyed — which lands AFTER the new REGISTER and leaves the server with
# no binding (found by `make sim-call`). Refreshing in place (sipreg_send)
# has no such side effect.
set -eu
SRC="$1"

if ! grep -q 'reg_refresh' "$SRC/src/reg.c"; then
  perl -0pi -e 's/\nbool reg_isok\(const struct reg \*reg\)\n/\nint reg_refresh(struct reg *reg)\n{\n\tif (!reg)\n\t\treturn EINVAL;\n\n\tif (!reg->sipreg)\n\t\treturn ENOENT;\n\n\treturn sipreg_send(reg->sipreg);\n}\n\n\nbool reg_isok(const struct reg *reg)\n/' "$SRC/src/reg.c"
  grep -q 'reg_refresh' "$SRC/src/reg.c" || { echo "patch: reg.c anchor not found"; exit 1; }
fi

if ! grep -q 'reg_refresh' "$SRC/src/core.h"; then
  perl -pi -e 's/^(void reg_stop\(struct reg \*reg\);)$/$1\nint  reg_refresh(struct reg *reg);/' "$SRC/src/core.h"
  grep -q 'reg_refresh' "$SRC/src/core.h" || { echo "patch: core.h anchor not found"; exit 1; }
fi

if ! grep -q 'ua_refresh_register' "$SRC/src/ua.c"; then
  perl -0pi -e 's/(\t\treg_unregister\(reg\);\n\t\}\n\}\n)/$1\n\n\/**\n * Dialler: send a REGISTER now on every existing register client, keeping\n * the clients (so no un-REGISTER is sent on the way).\n *\n * \@param ua User-Agent\n *\n * \@return 0 if success, ENOENT if no register client exists, else errorcode\n *\/\nint ua_refresh_register(struct ua *ua)\n{\n\tstruct le *le;\n\tint err = ENOENT;\n\n\tif (!ua)\n\t\treturn EINVAL;\n\n\tfor (le = ua->regl.head; le; le = le->next) {\n\t\tstruct reg *reg = le->data;\n\t\tint e = reg_refresh(reg);\n\n\t\tif (!e)\n\t\t\terr = 0;\n\t\telse if (err == ENOENT)\n\t\t\terr = e;\n\t}\n\n\treturn err;\n}\n/' "$SRC/src/ua.c"
  grep -q 'ua_refresh_register' "$SRC/src/ua.c" || { echo "patch: ua.c anchor not found"; exit 1; }
fi

if ! grep -q 'ua_refresh_register' "$SRC/include/baresip.h"; then
  perl -pi -e 's/^(void ua_unregister\(struct ua \*ua\);)$/$1\nint  ua_refresh_register(struct ua *ua);/' "$SRC/include/baresip.h"
  grep -q 'ua_refresh_register' "$SRC/include/baresip.h" || { echo "patch: baresip.h anchor not found"; exit 1; }
fi
echo "   baresip: ua_refresh_register patch present"

# Packet-loss concealment on the receive path. baresip 3.15's aurecv_receive
# discards the lost-frame count it is given ("TODO: what if lostc > 1") and
# never calls the codec's PLC handler, so every lost packet is 20 ms of
# silence whatever the codec — Opus's own concealment and its in-band FEC
# were never used (measured: 2 % loss → one audible gap per lost packet).
# Now each lost frame is concealed before the arriving packet is decoded:
# the frame right before it gets the packet, so Opus can decode the FEC it
# carries; earlier ones get plain PLC (a NULL packet). Concealed frames
# take their own timestamps, spaced evenly across the hole. Codecs without
# a PLC handler (G.711 until ios/vendor/patches adds one) are unchanged.
if ! grep -q 'Dialler: conceal lost frames' "$SRC/src/aureceiver.c"; then
  PLC_NEW="$(mktemp)"
  cat > "$PLC_NEW" <<'EOF'
	/* Dialler: conceal lost frames before decoding this packet (see
	 * ios/vendor/patches/apply-baresip.sh). The codec's PLC handler makes
	 * one frame per call; the frame right before this packet gets the
	 * packet itself, so Opus decodes its in-band FEC, the rest get PLC. */
	if (lostc && ar->ac && ar->ac->plch) {
		struct mbuf empty;
		uint32_t step;
		unsigned i, n = lostc > 5 ? 5 : lostc;

		mbuf_init(&empty);
		step = (hdr->ts - prev_ts) / (lostc + 1);
		for (i = lostc - n; i < lostc; i++) {
			struct rtp_header lh = *hdr;
			lh.ts = hdr->ts - step * (lostc - i);
			lh.m  = false;
			(void)aurecv_stream_decode(ar, &lh,
						   i + 1 == lostc ? mb : &empty,
						   1, drop);
		}
	}

	(void)aurecv_stream_decode(ar, hdr, mb, 0, drop);
EOF
  PLC_NEW="$PLC_NEW" perl -0pi -e 'BEGIN { local $/; open my $f, "<", $ENV{PLC_NEW} or die; $new = <$f>; close $f }
    s/\t\/\* TODO:  what if lostc > 1 \?\*\/.*?\t\(void\)aurecv_stream_decode\(ar, hdr, mb, 0, drop\);\n/$new/s;
    s/\tint wrap;\n\t\(void\) lostc;\n/\tint wrap;\n\tuint32_t prev_ts;\n/;
    s/(\twrap = timestamp_wrap\(hdr->ts, ar->ts_recv\.last\);\n)/\tprev_ts = ar->ts_recv.last;\n$1/;' "$SRC/src/aureceiver.c"
  rm -f "$PLC_NEW"
  grep -q 'Dialler: conceal lost frames' "$SRC/src/aureceiver.c" || { echo "patch: aureceiver.c anchor not found"; exit 1; }
  grep -q 'prev_ts = ar->ts_recv.last' "$SRC/src/aureceiver.c" || { echo "patch: aureceiver.c prev_ts anchor not found"; exit 1; }
fi
echo "   baresip: receive-path PLC/FEC patch present"

# NOT applied — tried and reverted 2026-09-12: counting the packets missing
# between the tail and a new arrival as frames in the jitter buffer (so the
# packet after a loss is released on time and concealed in its slot). It
# released packets early, drained the buffer and made the impaired echo
# WORSE (4–13 gaps per call instead of 1–2). The residual one 20–40 ms gap
# per lost packet is the buffer's own refill after a loss; any fix needs a
# timeline-driven concealment (decode on a timer, not on arrival), not a
# change to the frame count. See ios/vendor/patches/README.md.

# ---- Dialler lab: audio continuity events (lab/audio-continuity) ------------
# Hooks for the event ring declared in libre's re_tmr.h (apply-re.sh): the
# jitter buffer's late/over-wish/wish-change/flush/first-packet events and
# the aureceiver's discard of a decoded frame.
patch_insert() { # file marker anchor-file new-file mode(after|before|replace)
  f="$1"; marker="$2"; A="$3"; N="$4"; mode="$5"
  grep -qF "$marker" "$f" && return 0
  A="$A" N="$N" MODE="$mode" perl -0pi -e 'BEGIN { local $/; open(my $a, "<", $ENV{A}) or die; $anchor = <$a>; close $a; open(my $n, "<", $ENV{N}) or die; $new = <$n>; close $n; }
    $rep = $ENV{MODE} eq "after" ? $anchor.$new : $ENV{MODE} eq "before" ? $new.$anchor : $new;
    $cnt = s/\Q$anchor\E/$rep/; die "anchor not found in $ARGV\n" unless $cnt;' "$f"
  grep -qF "$marker" "$f" || { echo "patch: $marker not applied to $f"; exit 1; }
}
T="$(mktemp -d)"
printf '\t\t\tSTAT_INC(n_late);\n' > "$T/a1"
printf '\t\t\tau_ev_push(AU_EV_JB_LATE, (int32_t)seq, (int32_t)jb->seq_get); /* Dialler lab: audio events */\n' > "$T/n1"
patch_insert "$SRC/src/jbuf.c" 'AU_EV_JB_LATE' "$T/a1" "$T/n1" after
printf '\tif (wish > jb->wish) {\n\t\tDEBUG_INFO("wish size changed %%u --> %%u\\n", jb->wish, wish);\n\t\tjb->wish = wish;\n' > "$T/a2"
printf '\tif (wish > jb->wish) {\n\t\tDEBUG_INFO("wish size changed %%u --> %%u\\n", jb->wish, wish);\n\t\tau_ev_push(AU_EV_JB_WISH, (int32_t)jb->wish, (int32_t)wish);\n\t\tjb->wish = wish;\n' > "$T/n2"
patch_insert "$SRC/src/jbuf.c" 'au_ev_push(AU_EV_JB_WISH, (int32_t)jb->wish, (int32_t)wish)' "$T/a2" "$T/n2" replace
printf '\t\t--jb->wish;\n' > "$T/a3"
printf '\t\tau_ev_push(AU_EV_JB_WISH, (int32_t)jb->wish, (int32_t)jb->wish - 1);\n' > "$T/n3"
patch_insert "$SRC/src/jbuf.c" 'AU_EV_JB_WISH, (int32_t)jb->wish, (int32_t)jb->wish - 1' "$T/a3" "$T/n3" before
printf '\t\t\t   jb->nf, jb->min, jb->wish, jb->max);\n\t\terr = EAGAIN;\n' > "$T/a4"
printf '\t\t\t   jb->nf, jb->min, jb->wish, jb->max);\n\t\tau_ev_push(AU_EV_JB_OVER, (int32_t)jb->nf, (int32_t)jb->wish);\n\t\terr = EAGAIN;\n' > "$T/n4"
patch_insert "$SRC/src/jbuf.c" 'AU_EV_JB_OVER' "$T/a4" "$T/n4" replace
printf 'success:\n\t/* Update last sequence */\n\tjb->running = true;\n' > "$T/a5"
printf 'success:\n\tif (!jb->running)\n\t\tau_ev_push(AU_EV_FIRST_RTP, (int32_t)seq, 0);\n\t/* Update last sequence */\n\tjb->running = true;\n' > "$T/n5"
patch_insert "$SRC/src/jbuf.c" 'AU_EV_FIRST_RTP' "$T/a5" "$T/n5" replace
printf '\tif (jb->packetl.head) {\n\t\tDEBUG_INFO("flush: %%u frames\\n", jb->n);\n\t}\n' > "$T/a6"
printf '\tif (jb->packetl.head)\n\t\tau_ev_push(AU_EV_JB_FLUSH, (int32_t)jb->n, 0);\n' > "$T/n6"
patch_insert "$SRC/src/jbuf.c" 'AU_EV_JB_FLUSH' "$T/a6" "$T/n6" after
printf '\tif (drop) {\n\t\taubuf_drop_auframe(ar->aubuf, &af);\n' > "$T/a7"
printf '\t\tau_ev_push(AU_EV_JB_DROP, (int32_t)auframe_bytes_to_ms(&af, auframe_size(&af)), 0); /* Dialler lab: audio events */\n' > "$T/n7"
patch_insert "$SRC/src/aureceiver.c" 'AU_EV_JB_DROP' "$T/a7" "$T/n7" after
rm -rf "$T"
echo "   baresip: lab audio continuity hooks present (jbuf.c, aureceiver.c)"

# ---- Dialler lab: the playout engine replaces aubuf on the receive path --
# (lab/audio-continuity; see ios/vendor/patches/playout/README.md for the
# design and the exact hunks to carry to the production branch.)
#
#   aureceiver.c  decoded frames go to playout_write with their RTP
#                 timestamp in samples and their arrival time; the player's
#                 read handler pulls from playout_read; SSRC change and
#                 aurecv_flush flush it; its events reach the continuity
#                 ring. aubuf stays allocated but unused (zero-risk removal
#                 later).
#   rtprecv.c     with the jitter buffer off, the lost-packet count that
#                 drives the codec's PLC/FEC was passed as 0; it is now
#                 computed the same way as with a jitter buffer.
#   CMakeLists    src/playout.c joins the build (the file itself is copied
#                 by build-baresip.sh apply_patches).
T="$(mktemp -d)"
printf '#include "core.h"\n' > "$T/a1"
printf '#include "playout.h" /* Dialler lab: playout engine */\n' > "$T/n1"
patch_insert "$SRC/src/aureceiver.c" 'Dialler lab: playout engine' "$T/a1" "$T/n1" after
printf '\tstruct aubuf *aubuf;          /**< Audio buffer before auplay        */\n' > "$T/a2"
printf '\tstruct playout *po;           /**< Dialler lab: adaptive playout      */\n' > "$T/n2"
patch_insert "$SRC/src/aureceiver.c" 'struct playout *po;' "$T/a2" "$T/n2" after
printf '\tmem_deref(ar->aubuf);\n' > "$T/a3"
printf '\tplayout_free(ar->po); /* Dialler lab */\n' > "$T/n3"
patch_insert "$SRC/src/aureceiver.c" 'playout_free(ar->po);' "$T/a3" "$T/n3" before
# the event bridge, before the aubuf allocator
printf 'static int aurecv_alloc_aubuf(struct audio_recv *ar, const struct auframe *af)\n' > "$T/a4"
cat > "$T/n4" <<'EOF'
/* Dialler lab: the playout engine's events on the continuity ring */
static void aurecv_po_event(const char *kind, int32_t a, int32_t b, void *arg)
{
	uint32_t k = AU_EV_NONE;
	(void)arg;
	if (!strcmp(kind, "accelerate")) k = AU_EV_PO_ACCEL;
	else if (!strcmp(kind, "preemptive")) k = AU_EV_PO_PREEMPT;
	else if (!strcmp(kind, "expand")) k = AU_EV_PO_EXPAND;
	else if (!strcmp(kind, "zeros")) k = AU_EV_PO_ZEROS;
	else if (!strcmp(kind, "merge")) k = AU_EV_PO_MERGE;
	else if (!strcmp(kind, "late")) k = AU_EV_PO_LATE;
	else if (!strcmp(kind, "target")) k = AU_EV_PO_TARGET;
	else if (!strcmp(kind, "flush")) k = AU_EV_PO_FLUSH;
	else if (!strcmp(kind, "overflow")) k = AU_EV_PO_OVERFLOW;
	if (k != AU_EV_NONE)
		au_ev_push(k, a, b);
}


EOF
patch_insert "$SRC/src/aureceiver.c" 'aurecv_po_event' "$T/a4" "$T/n4" before
# push: allocate the engine on the first frame, write frames to it
cat > "$T/a5" <<'EOF'
	if (!ar->aubuf) {
		err = aurecv_alloc_aubuf(ar, af);
		if (err)
			return err;
	}
EOF
cat > "$T/n5" <<'EOF'
	if (!ar->aubuf) {
		err = aurecv_alloc_aubuf(ar, af);
		if (err)
			return err;
	}
	/* Dialler lab: the playout engine, sized from the config's audio
	 * buffer range, at the frame's (post-filter) rate */
	if (!ar->po) {
		struct playout_cfg pc;
		pc.srate = af->srate;
		pc.min_delay_ms = (uint32_t)ar->cfg->buffer.min;
		pc.max_delay_ms = (uint32_t)ar->cfg->buffer.max;
		pc.ptime_ms = (uint32_t)(ar->ptime / 1000);
		if (pc.ptime_ms == 0)
			pc.ptime_ms = 20;
		mtx_lock(ar->aubuf_mtx);
		ar->po = playout_alloc(&pc);
		if (ar->po)
			playout_set_event_handler(ar->po, aurecv_po_event, ar);
		mtx_unlock(ar->aubuf_mtx);
		if (!ar->po)
			return ENOMEM;
	}
EOF
patch_insert "$SRC/src/aureceiver.c" 'ar->po = playout_alloc(&pc);' "$T/a5" "$T/n5" replace
cat > "$T/a6" <<'EOF'
	err = aubuf_write_auframe(ar->aubuf, af);
	if (err)
		return err;
EOF
cat > "$T/n6" <<'EOF'
	/* Dialler lab: into the playout engine instead of aubuf. Mono S16LE
	 * is what the app's codecs and auconv produce; anything else is
	 * refused rather than mis-played. The timestamp is the RTP one in
	 * samples at this frame's rate (the engine wraps as RTP does). */
	if (af->fmt != AUFMT_S16LE || af->ch != 1)
		return EINVAL;
	err = playout_write(ar->po, af->sampv, af->sampc,
			    (uint32_t)(af->timestamp * af->srate / AUDIO_TIMEBASE),
			    tmr_jiffies_usec());
	if (err == ETIMEDOUT)
		err = 0; /* a late packet is the engine's statistic, not an error */
	if (err)
		return err;
EOF
patch_insert "$SRC/src/aureceiver.c" 'into the playout engine instead of aubuf' "$T/a6" "$T/n6" replace
cat > "$T/a7" <<'EOF'
	if (bpms)
		re_atomic_rlx_set(&ar->stats.latency,
				  aubuf_cur_size(ar->aubuf) / bpms);
EOF
cat > "$T/n7" <<'EOF'
	if (bpms) {
		struct playout_stats ps; /* Dialler lab */
		playout_stats(ar->po, &ps);
		re_atomic_rlx_set(&ar->stats.latency, ps.level_ms);
	}
EOF
patch_insert "$SRC/src/aureceiver.c" 'playout_stats(ar->po, &ps);' "$T/a7" "$T/n7" replace
printf '\tif (flush)\n\t\taubuf_flush(ar->aubuf);\n' > "$T/a8"
printf '\tif (flush) {\n\t\taubuf_flush(ar->aubuf);\n\t\tplayout_flush(ar->po); /* Dialler lab */\n\t}\n' > "$T/n8"
patch_insert "$SRC/src/aureceiver.c" 'playout_flush(ar->po); /* Dialler lab */' "$T/a8" "$T/n8" replace
cat > "$T/a9" <<'EOF'
	if (ar->aubuf)
		aubuf_read_auframe(ar->aubuf, af);
	else
		memset(af->sampv, 0, auframe_size(af));
EOF
cat > "$T/n9" <<'EOF'
	/* Dialler lab: the player pulls from the playout engine (its own
	 * lock; aubuf_mtx above only guards the pointer) */
	if (ar->po && af->fmt == AUFMT_S16LE && af->ch == 1)
		playout_read(ar->po, af->sampv, af->sampc, tmr_jiffies_usec());
	else
		memset(af->sampv, 0, auframe_size(af));
EOF
patch_insert "$SRC/src/aureceiver.c" 'the player pulls from the playout engine' "$T/a9" "$T/n9" replace
printf 'void aurecv_flush(struct audio_recv *ar)\n{\n' > "$T/a10"
printf '\tplayout_flush(ar ? ar->po : NULL); /* Dialler lab: aurecv_flush */\n' > "$T/n10"
patch_insert "$SRC/src/aureceiver.c" 'Dialler lab: aurecv_flush' "$T/a10" "$T/n10" after
# rtprecv: the loss count with the jitter buffer off
cat > "$T/a11" <<'EOF'
	else {
		(void)handle_rtp(rx, hdr, mb, 0, false);
	}
EOF
cat > "$T/n11" <<'EOF'
	else {
		/* Dialler lab: with the jitter buffer off the lost-packet count
		 * that drives the codec's PLC/FEC was always 0; count it as the
		 * jitter buffer path does (a reordered packet counts 0) */
		int lostc = lostcalc(rx, hdr->seq);
		(void)handle_rtp(rx, hdr, mb, lostc > 0 ? lostc : 0, false);
	}
EOF
patch_insert "$SRC/src/rtprecv.c" 'Dialler lab: with the jitter buffer off' "$T/a11" "$T/n11" replace
# CMake
printf '  src/aureceiver.c\n' > "$T/a12"
printf '  src/playout.c\n' > "$T/n12"
patch_insert "$SRC/CMakeLists.txt" 'src/playout.c' "$T/a12" "$T/n12" after
rm -rf "$T"
echo "   baresip: lab playout engine integration present (aureceiver.c, rtprecv.c, CMakeLists.txt)"
