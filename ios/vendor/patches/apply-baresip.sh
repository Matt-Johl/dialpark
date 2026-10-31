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
