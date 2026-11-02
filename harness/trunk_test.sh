#!/bin/sh
# Headless PBX-leg calls (SPEC §4.4 rule 7, Phase 2): the light server as a
# SIP trunk peer of Asterisk, both directions, asserted on recorded audio.
#
#   out:  app 211 (baresip-a) dials 100 → server → trunk (TCP) → Asterisk →
#         desk phone 100 (baresip-c, registered to Asterisk over UDP with
#         Digest, G.711 only). Asserts the desk phone recorded the app's tone.
#   in:   desk phone 100 dials 211 → Asterisk dial plan → PJSIP/211@dialpark →
#         server's trunk listener → app 211 (registered). Asserts the app
#         recorded the desk phone's tone.
#   transfer: desk phone 100 dials 211, then the app transfers it to 600
#         (Asterisk's Echo()). Both parties are on the PBX, so the server
#         must hand the transfer to Asterisk (REFER on the trunk leg) and
#         drop out: its call ends at once, the app sees the transfer
#         complete, and the desk phone — with the app silent — records its
#         own tone coming back from the PBX.
#   xfer-app: app 211 dials app 212 (Opus), then transfers 212 to the desk
#         phone 100. The trunk answers G.722, so the server must move the
#         remaining app leg from Opus to G.722 by re-INVITE (never
#         transcode); the desk phone records 212's tone.
#
# Both legs of a trunk call share one codec — G.722 first, G.711 fallback
# (the trunk is offered g722,pcmu,pcma and the app is answered with the
# codec the trunk took) — so the raw relay never transcodes.
#
#   make harness-trunk              # all four
#   DIRECTION=out|in|transfer|xfer-app make harness-trunk
#   TRUNK_SRTP=sdes make harness-trunk # the PBX is built with
#                                   media_encryption=sdes and the trunk leg
#                                   must come up encrypted both ways.
#   TRUNK_TLS=1 make harness-trunk  # the trunk moves to SIP/TLS, mutually
#                                   authenticated against a private CA (the
#                                   PBX demands a client certificate), which
#                                   is what secures the SDES keys above —
#                                   so the two are usually run together:
#                                   TRUNK_TLS=1 TRUNK_SRTP=sdes
#   NARROWBAND=1 make harness-trunk # Asterisk allows ulaw/alaw only: every
#                                   # scenario must fall back to PCMU (the
#                                   # server's G.722-first offer must not
#                                   # strand a PBX without it)
set -eu
cd "$(dirname "$0")/.."

# HARNESS_NOPORTS=1 publishes nothing on the host, so this can run beside a
# native `make dev-server` without fighting it for 7443 / 5061. Safe for any
# test that lives entirely inside the compose network; NOT for ones a
# simulator or a real phone has to reach (sim_call.sh, ring_*.sh, probe_*).
NOPORTS=""
[ "${HARNESS_NOPORTS:-0}" = 1 ] && { NOPORTS="-f harness/docker-compose.noports.yml"; export DIALPARK_PUBLIC_HOST=dialpark; }
COMPOSE="docker compose -f harness/docker-compose.yml $NOPORTS --profile test"
PBX_CODEC=G722
if [ "${NARROWBAND:-0}" = 1 ]; then
  export ASTERISK_CODECS=ulaw,alaw
  PBX_CODEC=PCMU
fi
# TRUNK_SRTP=sdes builds the PBX with a secure trunk profile and
# tells the server to use it, then asserts the trunk leg really is encrypted
# (SPEC §6 item 3a). Unset = the default deployment: plain RTP to the PBX.
if [ -n "${TRUNK_SRTP:-}" ]; then
  export ASTERISK_SRTP=yes
  export DIALPARK_TRUNK_SRTP="$TRUNK_SRTP"
fi
# TRUNK_TLS=1 moves the whole trunk leg onto SIP/TLS with mutual
# authentication against a private CA — the shape of a CUCM secure trunk
# (SPEC §6 item 3b). Certificates are generated, not committed.
if [ "${TRUNK_TLS:-0}" = 1 ]; then
  sh harness/tls/gen_certs.sh
  export ASTERISK_TLS=yes
  export DIALPARK_TRUNK="sip:172.30.0.20:5061;transport=tls"
  # Not :5061 — that is the app leg's port.
  export DIALPARK_TRUNK_ADDR=":5062"
  export DIALPARK_TRUNK_TLS_CERT=/tls/dialpark.pem
  export DIALPARK_TRUNK_TLS_KEY=/tls/dialpark.key
  export DIALPARK_TRUNK_TLS_CA=/tls/ca.pem
fi
NET=dialpark-harness_default
MEDIA_DIR=harness/baresip/media
DIRECTION="${DIRECTION:-both}"
CALL_SECONDS="${CALL_SECONDS:-8}"
KEEP="${KEEP:-0}"

# CLICKS=1: the tone carries a click train and each recording is also read
# for audio removed or inserted at the receiving phone (none allowed), with
# the server's relay required to have started at the answer (SPEC §4.4 rule
# 3, 2026-11-02). The plain tone is restored on exit.
CLICKS="${CLICKS:-0}"
if [ "$CLICKS" = 1 ]; then
  python3 harness/baresip/media/gen_tone.py --clicks --seconds "$((CALL_SECONDS + 5))" "$MEDIA_DIR/in.wav" >/dev/null
else
  python3 harness/baresip/media/gen_tone.py "$MEDIA_DIR/in.wav" >/dev/null
fi
# A silent source for the transfer scenario (same format as the tone).
python3 - "$MEDIA_DIR/silence.wav" <<'EOF'
import sys, wave
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
    w.writeframes(b"\0" * (48000 * 2 * 2 * 20))
EOF
rm -f "$MEDIA_DIR"/out-*.wav

cleanup() {
  [ "$KEEP" = 1 ] || $COMPOSE down -v >/dev/null 2>&1 || true
  [ "$CLICKS" = 1 ] && python3 harness/baresip/media/gen_tone.py "$MEDIA_DIR/in.wav" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# continuity_check <scenario> <recording>: with CLICKS=1, nothing removed or
# inserted at the receiving phone, and the relay started at the answer.
continuity_check() {
  [ "$CLICKS" = 1 ] || return 0
  if cont="$(python3 harness/spike/assert_audio.py "$2" --continuity --max-removed-ms 0)"; then
    printf '%s\n' "$cont" | sed 's/^/   /'
    echo "   continuity $1: nothing removed at the receiving phone"
  else
    printf '%s\n' "$cont" | sed 's/^/   /'
    echo "FAIL $1: audio removed at the receiving phone"; fail=1
  fi
  slog="$($COMPOSE logs --no-log-prefix --since 60s dialpark 2>&1)"
  a2r="$(printf '%s\n' "$slog" | grep 'msg=bridged' | tail -1 | grep -o 'answer_to_relay_ms=[0-9-]*' | cut -d= -f2)"
  if [ -n "$a2r" ] && [ "$a2r" -lt 50 ]; then
    echo "   relay started ${a2r} ms after the callee answered"
  else
    echo "FAIL $1: answer_to_relay_ms=${a2r:-missing}, want under 50"; fail=1
  fi
  for b in $(printf '%s\n' "$slog" | grep 'msg="call ended"' | tail -1 | grep -o 'backlog_pkts=[0-9]*' | cut -d= -f2); do
    # up to four: the harness phone's own three-packet start burst; a
    # relay that waited for the caller's ACK finds 12 or more
    [ "$b" -le 4 ] || { echo "FAIL $1: a pump found $b packets queued when it started"; fail=1; }
  done
}

echo "== up: server, asterisk, apps 211 and 212, desk phone 100"
$COMPOSE up --build -d dialpark asterisk >/dev/null 2>&1
sleep 2
sh harness/innet.sh "$NET" harness/provision.sh >/dev/null
$COMPOSE up --build -d baresip-a baresip-b baresip-c >/dev/null 2>&1
sleep 6

ctl() { # phone json
  docker run --rm --network "$NET" alpine:3.20 sh -c \
    "p='$2'; len=\$(printf %s \"\$p\" | wc -c | tr -d ' '); printf '%s:%s,' \"\$len\" \"\$p\" | nc -w2 $1 4444 >/dev/null"
}

if ! $COMPOSE logs --no-log-prefix baresip-c 2>&1 | grep -q "200 OK"; then
  echo "FAIL: desk phone 100 did not register to Asterisk"
  $COMPOSE logs --no-log-prefix baresip-c 2>&1 | tail -8 | sed 's/^/   /'
  exit 1
fi
echo "   desk phone 100 registered to Asterisk; app 211 registered to the server"

# Asterisk only dials a trunk contact it has qualified (OPTIONS → 200).
i=0
until $COMPOSE logs --no-log-prefix asterisk 2>&1 | grep -q "is now Reachable.*RTT\|Contact dialpark/.* is now Reachable"; do
  i=$((i+1)); [ $i -le 40 ] || { echo "FAIL: Asterisk never qualified the server as reachable"; $COMPOSE logs --no-log-prefix asterisk 2>&1 | grep -i reachable | tail -3; exit 1; }
  sleep 1
done
echo "   Asterisk qualified the server's trunk listener (Reachable)"

fail=0

# TRUNK_TLS: both ends must really be on SIP/TLS. Asterisk qualifies the
# trunk with OPTIONS over the endpoint's transport and will not mark it
# Reachable otherwise, so arriving here at all already means a mutually
# authenticated handshake succeeded (require_client_cert=yes) — these
# checks name which end is misconfigured when it does not.
if [ "${TRUNK_TLS:-0}" = 1 ]; then
  ok=1
  $COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -q "b2bua listening.*trunk_tls=true" || {
    echo "   FAIL: the server did not build a trunk TLS config"; ok=0; }
  $COMPOSE exec -T asterisk asterisk -rx "pjsip show transport transport-tls" 2>/dev/null | grep -q "0.0.0.0:5061" || {
    echo "   FAIL: Asterisk has no TLS transport listening"
    $COMPOSE logs --no-log-prefix asterisk 2>&1 | grep -iE "tls|ssl|cert" | tail -6 | sed 's/^/   asterisk: /'; ok=0; }
  $COMPOSE exec -T asterisk asterisk -rx "pjsip show aor dialpark" 2>/dev/null | grep -q "transport=tls" || {
    echo "   FAIL: Asterisk's trunk contact is not a TLS URI"; ok=0; }
  # The warning §6 item 3a leaves on an unencrypted trunk: with TLS it must
  # be gone. Asserting on its absence is what keeps the two items honest —
  # SDES keys in cleartext SDP is the thing TLS is here to stop.
  if [ -n "${TRUNK_SRTP:-}" ] && $COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -q "trunk SRTP over unencrypted signalling"; then
    echo "   FAIL: the server still thinks the trunk signalling is in the clear"; ok=0
  fi
  [ "$ok" = 1 ] && echo "   trunk is SIP/TLS, mutually authenticated (Asterisk requires a client certificate)"
  [ "$ok" = 1 ] || fail=1
fi
# Wideband on the trunk needs the PBX's G.722 codec module (ships with the
# Asterisk core, but an install without it silently falls back to G.711).
if $COMPOSE exec -T asterisk asterisk -rx "core show codecs audio" 2>/dev/null | grep -q g722; then
  echo "   Asterisk has codec g722"
else
  echo "FAIL: Asterisk has no g722 codec"; exit 1
fi
echo "   Asterisk allows: $($COMPOSE exec -T asterisk asterisk -rx "pjsip show endpoint dialpark" 2>/dev/null | grep -E '^ *allow ' | head -1 | tr -s ' ')"

# The trunk call must negotiate one codec end to end (SPEC §4.4 rule 4):
# G.722 with a wideband PBX, PCMU when the PBX only has G.711.
codec_check() {
  if $COMPOSE logs --no-log-prefix --since 60s dialpark 2>&1 | grep -q "callee answered.*codec=$PBX_CODEC"; then
    echo "   negotiated $PBX_CODEC on both legs"
  else
    echo "FAIL $1: the call did not negotiate $PBX_CODEC"; $COMPOSE logs --no-log-prefix --since 60s dialpark 2>&1 | grep 'callee answered' | tail -2 | sed 's/^/   /'; fail=1
  fi
}

# TRUNK_SRTP: with the PBX built for SDES and the server told to use it, the
# trunk leg must actually come up encrypted — otherwise the whole point of
# SPEC §6 item 3a is lost silently, since an unencrypted call still works.
# `$1` is the leg to check as the server logs it ("callee" out, "caller" in).
srtp_check() {
  [ -n "${TRUNK_SRTP:-}" ] || return 0
  if $COMPOSE logs --no-log-prefix --since 60s dialpark 2>&1 | grep -qE "bridged.*$2_srtp=on"; then
    echo "   trunk leg is SRTP ($2_srtp=on)"
  else
    echo "FAIL $1: the trunk leg is not encrypted under -trunk-srtp=$TRUNK_SRTP"
    $COMPOSE logs --no-log-prefix --since 60s dialpark 2>&1 | grep -E 'bridged|callee answered' | tail -2 | sed 's/^/   /'
    fail=1
  fi
}

if [ "$DIRECTION" = out ] || [ "$DIRECTION" = both ]; then
  echo "== out: app 211 dials 100 (desk phone via the trunk)"
  ctl baresip-a '{"command":"dial","params":"100@dialpark"}'
  sleep "$CALL_SECONDS"
  ctl baresip-a '{"command":"hangup"}'
  sleep 2
  $COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -E 'invite|callee answered|bridged|call ended|level=(ERROR|WARN)' | tail -6 | sed 's/^/   /'
  if python3 harness/spike/assert_audio.py "$MEDIA_DIR/out-100.wav" --reference "$MEDIA_DIR/in.wav" \
       --max-gap-ms "${MAX_GAP_MS:-0}" --max-gaps "${MAX_GAPS:-0}"; then
    echo "PASS out: the desk phone heard the app through the trunk"
    codec_check out
    srtp_check out callee
    continuity_check out "$MEDIA_DIR/out-100.wav"
  else
    echo "FAIL out"; fail=1
    $COMPOSE logs --no-log-prefix asterisk 2>&1 | grep -iE "dialpark|100|error|warn|rtp" | tail -8 | sed 's/^/   asterisk: /'
  fi
fi

if [ "$DIRECTION" = in ] || [ "$DIRECTION" = both ]; then
  echo "== in: desk phone 100 dials 211 (app via Asterisk → trunk)"
  rm -f "$MEDIA_DIR/out-211.wav"
  ctl baresip-c '{"command":"dial","params":"211@asterisk"}'
  sleep "$CALL_SECONDS"
  ctl baresip-c '{"command":"hangup"}'
  sleep 2
  $COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -E 'invite|callee answered|bridged|call ended|level=(ERROR|WARN)' | tail -6 | sed 's/^/   /'
  if python3 harness/spike/assert_audio.py "$MEDIA_DIR/out-211.wav" --reference "$MEDIA_DIR/in.wav" \
       --max-gap-ms "${MAX_GAP_MS:-0}" --max-gaps "${MAX_GAPS:-0}"; then
    echo "PASS in: the app heard the desk phone through the trunk"
    codec_check in
    srtp_check in caller
    continuity_check in "$MEDIA_DIR/out-211.wav"
  else
    echo "FAIL in"; fail=1
    $COMPOSE logs --no-log-prefix asterisk 2>&1 | grep -iE "dialpark|211|error|warn" | tail -8 | sed 's/^/   asterisk: /'
  fi
fi

if [ "$DIRECTION" = transfer ] || [ "$DIRECTION" = both ]; then
  echo "== transfer: desk phone 100 dials 211; the app transfers it to 600 (PBX echo) — the server must drop out"
  # The app is silent for this one, so any audio the desk phone records is
  # its own tone coming back from Asterisk's Echo(): proof the PBX completed
  # the transfer and carries the audio itself.
  AUDIO_SOURCE="aufile,/media/silence.wav" $COMPOSE up -d --no-deps --force-recreate baresip-a >/dev/null 2>&1
  sleep 5
  rm -f "$MEDIA_DIR/out-100.wav"
  MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ctl baresip-c '{"command":"dial","params":"211@asterisk"}'
  sleep 4
  ctl baresip-a '{"command":"transfer","params":"600"}'
  sleep 3
  # While the desk phone is still on the (transferred) call, the server's
  # part of it must already be over.
  early="$($COMPOSE logs --no-log-prefix --since "$MARK" dialpark 2>&1)"
  sleep 5
  ctl baresip-c '{"command":"hangup"}'
  sleep 2
  echo "$early" | grep -E 'transfer|call ended|level=(ERROR|WARN)' | tail -8 | sed 's/^/   /'
  ok=1
  echo "$early" | grep -q 'transfer: offloaded to PBX' || { echo "   FAIL: the server did not hand the transfer to the PBX"; ok=0; }
  echo "$early" | grep -q 'call ended' || { echo "   FAIL: the server was still on the call 3 s after the transfer"; ok=0; }
  $COMPOSE logs --no-log-prefix --since "$MARK" baresip-a 2>&1 | grep -qi 'transfer' || { echo "   FAIL: the app did not see the transfer complete (no NOTIFY 200)"; ok=0; }
  if python3 harness/spike/assert_audio.py "$MEDIA_DIR/out-100.wav"; then
    [ "$ok" = 1 ] && echo "PASS transfer: the PBX completed it; the desk phone heard the echo with the server out of the path"
  else
    echo "   FAIL: the desk phone heard nothing after the transfer"; ok=0
  fi
  if [ "$ok" != 1 ]; then
    echo "FAIL transfer"; fail=1
    $COMPOSE logs --no-log-prefix --since "$MARK" asterisk 2>&1 | grep -iE "refer|transfer|600|error|warn" | tail -10 | sed 's/^/   asterisk: /'
  fi
fi

if [ "$DIRECTION" = xfer-app ] || [ "$DIRECTION" = both ]; then
  echo "== xfer-app: app 211 dials app 212 (Opus), then transfers 212 to desk phone 100 ($PBX_CODEC) — the server must re-INVITE 212 onto $PBX_CODEC"
  # 211 is silent so the only audio 100 can record is 212's tone, relayed
  # by the server after the codec change.
  AUDIO_SOURCE="aufile,/media/silence.wav" $COMPOSE up -d --no-deps --force-recreate baresip-a >/dev/null 2>&1
  sleep 5
  rm -f "$MEDIA_DIR/out-100.wav"
  MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ctl baresip-a '{"command":"dial","params":"212@dialpark"}'
  sleep 4
  ctl baresip-a '{"command":"transfer","params":"100"}'
  sleep "$CALL_SECONDS"
  ctl baresip-b '{"command":"hangup"}'
  sleep 2
  logs="$($COMPOSE logs --no-log-prefix --since "$MARK" dialpark 2>&1)"
  echo "$logs" | grep -E 'callee answered|transfer|call ended|level=(ERROR|WARN)' | tail -8 | sed 's/^/   /'
  ok=1
  echo "$logs" | grep -q 'callee answered.*codec=opus' || { echo "   FAIL: the app↔app call was not Opus"; ok=0; }
  echo "$logs" | grep -q "transfer: remaining leg renegotiated.*codec=$PBX_CODEC" || { echo "   FAIL: the remaining app leg was not moved to $PBX_CODEC"; ok=0; }
  # The codec change restarts 212's audio pipeline: up to two ≤40 ms gaps
  # at the switch are the cost of the re-INVITE (measured one of 10 ms to
  # G.722, two of 20 ms to PCMU where the resampler restarts too), not loss.
  if python3 harness/spike/assert_audio.py "$MEDIA_DIR/out-100.wav" --reference "$MEDIA_DIR/in.wav" \
       --max-gap-ms "${XFER_MAX_GAP_MS:-40}" --max-gaps "${XFER_MAX_GAPS:-2}"; then
    [ "$ok" = 1 ] && echo "PASS xfer-app: 212 was moved to $PBX_CODEC and the desk phone heard it through the trunk"
  else
    echo "   FAIL: the desk phone did not hear 212 after the transfer"; ok=0
  fi
  if [ "$ok" != 1 ]; then
    echo "FAIL xfer-app"; fail=1
    $COMPOSE logs --no-log-prefix --since "$MARK" baresip-b 2>&1 | grep -iE "invite|update|codec|G722|opus|error" | tail -8 | sed 's/^/   212: /'
  fi
fi

if [ "$DIRECTION" = xfer-echo ] || [ "$DIRECTION" = both ]; then
  echo "== xfer-echo: app 211 dials 600 (PBX echo), then transfers 600 to desk phone 100 — the PBX cannot REFER an unbridged Echo() channel, so the server bridges the two trunk legs itself"
  # The phone scenario of 2026-09-17 18:25: no audio either way after
  # the transfer, on an SRTP trunk only. Echo() is not in a bridge, so
  # Asterisk answers the REFER with 400 and the server falls back to
  # relaying trunk↔trunk — the one transfer shape no other scenario runs.
  # The desk phone hears its own tone come back through 600 only if BOTH
  # directions of that relay work, so one recording proves both.
  AUDIO_SOURCE="aufile,/media/silence.wav" $COMPOSE up -d --no-deps --force-recreate baresip-a >/dev/null 2>&1
  sleep 5
  rm -f "$MEDIA_DIR/out-100.wav"
  MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ctl baresip-a '{"command":"dial","params":"600@dialpark"}'
  sleep 4
  ctl baresip-a '{"command":"transfer","params":"100"}'
  sleep "$CALL_SECONDS"
  ctl baresip-c '{"command":"hangup"}'
  sleep 2
  logs="$($COMPOSE logs --no-log-prefix --since "$MARK" dialpark 2>&1)"
  echo "$logs" | grep -E 'transfer|msg=relay.*transfer|call ended|level=(ERROR|WARN)' | tail -8 | sed 's/^/   /'
  ok=1
  if echo "$logs" | grep -q 'transfer: offloaded to PBX'; then
    echo "   (the PBX took the REFER after all: this run did not exercise the server-bridged path)"
  else
    echo "$logs" | grep -q 'transfer: bridged' || { echo "   FAIL: the server neither offloaded nor bridged the transfer"; ok=0; }
  fi
  if python3 harness/spike/assert_audio.py "$MEDIA_DIR/out-100.wav" --reference "$MEDIA_DIR/in.wav" \
       --max-gap-ms "${XFER_MAX_GAP_MS:-40}" --max-gaps "${XFER_MAX_GAPS:-2}"; then
    [ "$ok" = 1 ] && echo "PASS xfer-echo: the desk phone heard its own tone back through 600 across the transferred, server-bridged trunk legs"
  else
    echo "   FAIL: the desk phone heard nothing back through 600 after the transfer"; ok=0
  fi
  if [ "$ok" != 1 ]; then
    echo "FAIL xfer-echo"; fail=1
    echo "$logs" | grep -E 'msg=relay' | tail -4 | sed 's/^/   /'
    $COMPOSE logs --no-log-prefix --since "$MARK" asterisk 2>&1 | grep -iE "refer|srtp|unprotect|replay|error|warn" | tail -8 | sed 's/^/   asterisk: /'
  fi
fi

exit $fail
