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
# Asserted: the 200 OK carries a one-codec G.722 offer (SIPp's own regex
# checks), the app's recording contains the tone (so the relay ran on the
# addresses the ACK's SDP named), and the server log shows a bridged call
# with no error. Exit 0 = pass. Publishes no host ports.
#
#   make harness-delayed-offer
#   KEEP=1 make harness-delayed-offer
set -eu
cd "$(dirname "$0")/.."

COMPOSE="docker compose -f harness/docker-compose.yml -f harness/docker-compose.noports.yml --profile test"
export DIALPARK_PUBLIC_HOST=dialpark
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

echo "== call: the PBX (SIPp) INVITEs 211 with no SDP, echoes the media, hangs up after ${CALL_SECONDS}s"
set +e
$COMPOSE run --rm --entrypoint sipp sipp dialpark:5060 -t u1 -sf /scenarios/delayed_offer_invite.xml \
  -s 211 -m 1 -nostdin -timeout 45s -timeout_error -d "$((CALL_SECONDS * 1000))" -rtp_echo \
  -trace_err -error_file /tmp/delayed_offer.err > "$MEDIA_DIR/sipp-delayed-offer.out" 2>&1
rc=$?
set -e
sleep 2
fail=0
if [ "$rc" -eq 0 ]; then
  echo "   SIPp: 200 OK carried a one-codec G.722 offer; the ACK's answer was taken; BYE answered"
else
  echo "   FAIL: SIPp exit $rc — the 200 OK was late, had no SDP, or offered more than the callee's codec"
  tail -n 12 "$MEDIA_DIR/sipp-delayed-offer.out" | sed 's/^/   sipp: /'
  fail=1
fi
rm -f "$MEDIA_DIR/sipp-delayed-offer.out"

# A fresh stack per run, so the whole log is this call's.
slog="$(logs)"
printf '%s\n' "$slog" | grep -E 'invite|callee answered|bridged|call ended|level=(ERROR|WARN)' | tail -8 | sed 's/^/   /'
if printf '%s' "$slog" | grep -q 'invite: delayed offer'; then
  echo "   the server saw the INVITE as a delayed offer"
else
  echo "   FAIL: the server did not log the delayed offer"; fail=1
fi
if printf '%s' "$slog" | grep -q 'msg=bridged'; then
  echo "   the call bridged"
else
  echo "   FAIL: the call never bridged"; fail=1
fi
if printf '%s' "$slog" | grep -q 'no sdp present in INVITE\|late offer:'; then
  echo "   FAIL: the answer path failed:"; printf '%s\n' "$slog" | grep 'no sdp present\|late offer' | tail -2 | sed 's/^/   /'; fail=1
fi

if python3 harness/spike/assert_audio.py "$MEDIA_DIR/out-211.wav" --reference "$MEDIA_DIR/in.wav" \
     --max-gap-ms "${MAX_GAP_MS:-0}" --max-gaps "${MAX_GAPS:-0}"; then
  echo "   the app heard its own tone back: media ran on the addresses the ACK's SDP named"
else
  echo "   FAIL: the app recorded no tone — no media on the late-offer leg"; fail=1
fi

if [ "$fail" = 0 ]; then
  echo "PASS: a delayed-offer INVITE from the PBX is answered with the callee's codec and carries audio"
else
  echo "FAIL delayed-offer"
fi
exit $fail
