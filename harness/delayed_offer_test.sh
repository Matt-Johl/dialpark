#!/bin/sh
# A delayed-offer INVITE from the PBX (RFC 3261 §13.2.1; SPEC §6 item 3c).
# CUCM's INVITE to a third-party SIP line carries no SDP: it wants the 200
# OK to make the offer and answers it in the ACK. On the 2026-10-17 CUCM
# bench every inbound call rang the app and died the moment it was
# answered — diago refused to answer a caller with no offer ("no sdp
# present in INVITE") and the server hung the app up.
#
# Asterisk never sends a delayed offer, so SIPp stands in for the PBX at
# the trunk listener (any non-TLS source is the trunk, SPEC §6 item 3c):
#
#   SIPp (as the PBX) → INVITE with no SDP → server → app 211 rings and
#   answers → the server's 200 OK offers the one codec 211 took (G.722) →
#   SIPp's ACK answers it and echoes every RTP packet back → app 211
#   records its own tone.
#
# Two calls. In the first the PBX answers with the app's own codec, G.722.
# In the second it answers PCMU — what the CUCM cluster did on 2026-10-17
# (asked for G.722 alone it sent an ACK with no SDP and a BYE; it takes
# PCMU from a list) — and the server must move the app onto PCMU by
# re-INVITE before bridging, so the relay still never transcodes.
#
# Asserted per call: the 200 OK's offer leads with G.722 (SIPp's own regex
# checks), the app's recording contains the tone (so the relay ran on the
# addresses the ACK's SDP named, and after the move in the PCMU case), and
# the server log shows the call bridged on the expected codec with no
# error. Exit 0 = pass. Publishes no host ports.
#
# OPUS=1 runs one call instead, with the server offering Opus first and the
# PBX answering Opus at ITS payload type, 114 rather than our 96 — CUCM's
# habit (bench 2026-10-17 13:24): the relay must send the PBX Opus marked
# 114 or the PBX drops it all and the app-to-PBX direction is silent.
#
#   make harness-delayed-offer
#   make harness-delayed-offer-opus
#   KEEP=1 make harness-delayed-offer
set -eu
cd "$(dirname "$0")/.."

COMPOSE="docker compose -f harness/docker-compose.yml -f harness/docker-compose.noports.yml --profile test"
export DIALPARK_PUBLIC_HOST=dialpark
OPUS="${OPUS:-0}"
[ "$OPUS" = 1 ] && export DIALPARK_TRUNK_CODECS=opus,g722,pcmu,pcma
NET=dialpark-harness_default
MEDIA_DIR=harness/baresip/media
CALL_SECONDS="${CALL_SECONDS:-8}"
KEEP="${KEEP:-0}"

python3 harness/baresip/media/gen_tone.py "$MEDIA_DIR/in.wav" >/dev/null
rm -f "$MEDIA_DIR/out-211.wav"

cleanup() { [ "$KEEP" = 1 ] || $COMPOSE down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

logs() { $COMPOSE logs --no-log-prefix dialpark 2>&1; }

echo "== up: server (trunk listener :5060/udp), app 211"
$COMPOSE up --build -d dialpark >/dev/null 2>&1
sleep 2
sh harness/innet.sh "$NET" harness/provision.sh >/dev/null
$COMPOSE build sipp >/dev/null 2>&1
$COMPOSE up --build -d baresip-a >/dev/null 2>&1
sleep 5
logs | grep -q 'sip register.*user=211' || { echo "FAIL: app 211 never registered"; logs | tail -5; exit 1; }
echo "   app 211 registered"

fail=0
# call PT CODEC — one delayed-offer call answered with payload type PT.
call() {
  pt="$1"; codec="$2"
  rm -f "$MEDIA_DIR/out-211.wav"
  echo "== call: the PBX (SIPp) INVITEs 211 with no SDP, answers $codec in the ACK, echoes the media, hangs up after ${CALL_SECONDS}s"
  MARK="$(logs | wc -l | tr -d ' ')"
  set +e
  scenario=delayed_offer_invite.xml
  [ "$codec" = opus ] && scenario=delayed_offer_invite_opus.xml
  $COMPOSE run --rm --entrypoint sipp sipp dialpark:5060 -t u1 -sf "/scenarios/$scenario" \
    -s 211 -m 1 -nostdin -timeout 45s -timeout_error -d "$((CALL_SECONDS * 1000))" -rtp_echo -key pt "$pt" -key codec "$codec" \
    -trace_err -error_file /tmp/delayed_offer.err > "$MEDIA_DIR/sipp-delayed-offer.out" 2>&1
  rc=$?
  set -e
  sleep 2
  ok=1
  if [ "$rc" -eq 0 ]; then
    echo "   SIPp: the 200 OK led with the app's codec; the ACK's $codec answer was taken; BYE answered"
  else
    echo "   FAIL: SIPp exit $rc — the 200 OK was late, had no SDP, or did not lead with the app's codec"
    tail -n 12 "$MEDIA_DIR/sipp-delayed-offer.out" | sed 's/^/   sipp: /'
    ok=0
  fi
  rm -f "$MEDIA_DIR/sipp-delayed-offer.out"
  # This call's lines only: the log from where it stood before the call.
  slog="$(logs | tail -n +"$((MARK + 1))")"
  printf '%s\n' "$slog" | grep -E 'invite|callee answered|late offer|bridged|call ended|level=(ERROR|WARN)' | tail -8 | sed 's/^/   /'
  printf '%s' "$slog" | grep -q 'invite: delayed offer' || { echo "   FAIL: the server did not log the delayed offer"; ok=0; }
  if printf '%s' "$slog" | grep -q "msg=bridged.*codec=$codec"; then
    echo "   the call bridged on $codec"
  else
    echo "   FAIL: the call did not bridge on $codec"; ok=0
  fi
  if [ "$pt" = 0 ]; then
    if printf '%s' "$slog" | grep -q 'late offer: the caller took another codec; moving the callee'; then
      echo "   the app was moved from G.722 to PCMU by re-INVITE"
    else
      echo "   FAIL: the server did not move the app to the PBX's codec"; ok=0
    fi
  fi
  if printf '%s' "$slog" | grep -q 'no sdp present in INVITE\|would not move\|carried no SDP'; then
    echo "   FAIL: the answer path failed:"; printf '%s\n' "$slog" | grep 'no sdp present\|late offer' | tail -2 | sed 's/^/   /'; ok=0
  fi
  # The harness phone's recorder cannot survive a mid-call codec change:
  # baresip stops its first file player at the re-INVITE and opens a second
  # on the same path, and the first handle, closing later, rewrites the WAV
  # header with its own count of zero frames over a file full of audio
  # (seen 2026-10-17: 172 KB on disk, header says 0 frames). The audio is
  # all there, so the header is repaired from the file size before the
  # assertion reads it. A real phone has no recorder; this is the bench.
  python3 - "$MEDIA_DIR/out-211.wav" <<'PY'
import os, struct, sys
p = sys.argv[1]
size = os.path.getsize(p)
if size > 44:
    with open(p, "r+b") as f:
        f.seek(4); f.write(struct.pack("<I", size - 8))
        f.seek(40); f.write(struct.pack("<I", size - 44))
PY
  # The harness phone's recorder cannot survive a mid-call codec change:
  # baresip stops its first file player at the re-INVITE and opens a second
  # on the same path, and the first handle, closing later, rewrites the WAV
  # header with its own count of zero frames over a file full of audio
  # (seen 2026-10-17: 172 KB on disk, header says 0 frames). The audio is
  # all there, so the header is repaired from the file size before the
  # assertion reads it. A real phone has no recorder; this is the bench.
  python3 - "$MEDIA_DIR/out-211.wav" <<'PY'
import os, struct, sys
p = sys.argv[1]
size = os.path.getsize(p)
if size > 44:
    with open(p, "r+b") as f:
        f.seek(4); f.write(struct.pack("<I", size - 8))
        f.seek(40); f.write(struct.pack("<I", size - 44))
PY
  if python3 harness/spike/assert_audio.py "$MEDIA_DIR/out-211.wav" --reference "$MEDIA_DIR/in.wav" \
       --max-gap-ms "${MAX_GAP_MS:-0}" --max-gaps "${MAX_GAPS:-0}"; then
    echo "   the app heard its own tone back on $codec"
  else
    echo "   FAIL: the app recorded no tone on $codec"; ok=0
  fi
  [ "$ok" = 1 ] && echo "PASS $codec" || { echo "FAIL $codec"; fail=1; }
}

if [ "$OPUS" = 1 ]; then
  call 114 opus
else
  call 9 G722
  call 0 PCMU
fi

if [ "$fail" = 0 ]; then
  echo "PASS: a delayed-offer INVITE from the PBX carries audio whether the PBX takes the app's codec or another"
else
  echo "FAIL delayed-offer"
fi
exit $fail
