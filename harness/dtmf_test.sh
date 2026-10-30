#!/bin/sh
# DTMF both ways across the server (SPEC §7.3 item 10 d). Digits travel as
# RFC 4733 telephone-event packets inside the audio stream; the server
# offers telephone-event on both legs and the relay forwards each event
# packet under the far leg's event payload type. Before 2026-10-17 it
# offered none on the PBX leg — CUCM read that as a device with no DTMF —
# and would have forwarded a digit as audio under the audio payload type.
#
#   app → PBX: app 211 dials 650, the PBX answers and Read()s three digits;
#              the app sends 1 5 9 (baresip's sndcode, RFC 4733 since the
#              call negotiated it). Asserted on the PBX's log line.
#   PBX → app: desk phone 100 dials 811 → the PBX dials app 211 and, once
#              it answers, sends it 1 5 9 (Dial's D option). Asserted on
#              the app's control-port events (CALL_DTMF_START per digit).
#
# Both directions also assert the server's relay counted the events, so a
# digit that reached the far end by some other path cannot pass. Trunk mode
# by default; LINES=1 runs the same on the lines bench. Publishes no host
# ports. Exit 0 = pass.
#
#   make harness-dtmf
#   LINES=1 make harness-dtmf
#   KEEP=1 make harness-dtmf
set -eu
cd "$(dirname "$0")/.."

COMPOSE="docker compose -f harness/docker-compose.yml -f harness/docker-compose.noports.yml --profile test"
export DIALPARK_PUBLIC_HOST=dialpark
NET=dialpark-harness_default
MEDIA_DIR=harness/baresip/media
KEEP="${KEEP:-0}"
LINES="${LINES:-0}"
if [ "$LINES" = 1 ]; then
  export ASTERISK_LINES=yes DIALPARK_PBX_MODE=lines DIALPARK_PBX_DOMAIN=asterisk DIALPARK_PBX_EXPIRY=120s DIALPARK_PBX_LINE_PORTS=5070-5077 DIALPARK_TRUNK_ADDR=:5070
  DIAL_PBX="650@dialpark"; DIAL_APP="811@asterisk"
else
  DIAL_PBX="650@dialpark"; DIAL_APP="811@asterisk"
fi

python3 harness/baresip/media/gen_tone.py "$MEDIA_DIR/in.wav" >/dev/null

cleanup() { [ "$KEEP" = 1 ] || $COMPOSE down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

logs() { $COMPOSE logs --no-log-prefix dialpark 2>&1; }
alogs() { $COMPOSE logs --no-log-prefix asterisk 2>&1; }
ctl() { # phone json
  docker run --rm --network "$NET" alpine:3.20 sh -c \
    "p='$2'; len=\$(printf %s \"\$p\" | wc -c | tr -d ' '); printf '%s:%s,' \"\$len\" \"\$p\" | nc -w2 $1 4444 >/dev/null"
}

echo "== up: server ($([ "$LINES" = 1 ] && echo lines || echo trunk) mode), asterisk, app 211, desk phone 100"
$COMPOSE up --build -d dialpark asterisk >/dev/null 2>&1
sleep 2
PBX_LINES="$LINES" sh harness/innet.sh "$NET" harness/provision.sh >/dev/null
if [ "$LINES" = 1 ]; then
  $COMPOSE restart dialpark >/dev/null 2>&1
  sleep 3
fi
$COMPOSE up --build -d baresip-a baresip-c >/dev/null 2>&1
sleep 6
logs | grep -q 'sip register.*user=211' || { echo "FAIL: app 211 never registered"; exit 1; }
alogs | grep -q "200 OK\|Added contact 'sip:100" || true
echo "   app 211 and desk phone 100 up"
fail=0

# ---- app → PBX ---------------------------------------------------------------
echo "== app → PBX: 211 dials 650, sends 1 5 9; the PBX reads them"
MARK="$(logs | wc -l | tr -d ' ')"
AMARK="$(alogs | wc -l | tr -d ' ')"
ctl baresip-a '{"command":"dial","params":"'"$DIAL_PBX"'"}'
sleep 3
ctl baresip-a '{"command":"sndcode","params":"159"}'
sleep 4
ctl baresip-a '{"command":"hangup"}'
sleep 2
ok=1
alog="$(alogs | tail -n +"$((AMARK + 1))")"
if printf '%s' "$alog" | grep -q "DTMF received: 159"; then
  echo "   the PBX read 159 from the app"
else
  echo "   FAIL: the PBX did not read 159"; printf '%s\n' "$alog" | grep -i "dtmf\|Read(" | tail -4 | sed 's/^/   asterisk: /'; ok=0
fi
slog="$(logs | tail -n +"$((MARK + 1))")"
if printf '%s' "$slog" | grep "call ended" | grep -q "events=[1-9]"; then
  echo "   the server relayed the digits as events: $(printf '%s' "$slog" | grep -o 'events=[0-9]* events_dropped=[0-9]*' | head -1)"
else
  echo "   FAIL: the server's relay counted no events"; printf '%s\n' "$slog" | grep "call ended\|bridged" | tail -2 | sed 's/^/   /'; ok=0
fi
[ "$ok" = 1 ] && echo "PASS app→PBX" || { echo "FAIL app→PBX"; fail=1; }

# ---- PBX → app ---------------------------------------------------------------
echo "== PBX → app: desk phone 100 dials 811; the PBX sends 1 5 9 to the app once it answers"
MARK="$(logs | wc -l | tr -d ' ')"
EV="$MEDIA_DIR/dtmf-events.txt"
rm -f "$EV"
# Listen on the app's control port for the events of the coming call; the
# listener is the only client, since nothing commands baresip-a meanwhile.
# busybox nc hangs up when its stdin ends, so stdin is held open for the
# length of the call.
docker run --rm --network "$NET" alpine:3.20 sh -c "sleep 15 | nc baresip-a 4444" > "$EV" 2>/dev/null &
LISTENER=$!
sleep 1
ctl baresip-c '{"command":"dial","params":"'"$DIAL_APP"'"}'
sleep 9
ctl baresip-c '{"command":"hangup"}'
wait $LISTENER 2>/dev/null || true
sleep 1
ok=1
for d in 1 5 9; do
  if grep -q "CALL_DTMF_START.*\"param\":\"$d\"" "$EV" 2>/dev/null; then
    echo "   the app reported digit $d"
  else
    echo "   FAIL: the app did not report digit $d"; ok=0
  fi
done
[ "$ok" = 1 ] || { echo "   --- app events ---"; tr ',' '\n' < "$EV" | grep -i "dtmf\|type" | head -12 | sed 's/^/   /'; }
slog="$(logs | tail -n +"$((MARK + 1))")"
if printf '%s' "$slog" | grep "call ended" | grep -q "events=[1-9]"; then
  echo "   the server relayed the digits as events: $(printf '%s' "$slog" | grep -o 'events=[0-9]* events_dropped=[0-9]*' | head -1)"
else
  echo "   FAIL: the server's relay counted no events"; printf '%s\n' "$slog" | grep "call ended\|bridged" | tail -2 | sed 's/^/   /'; ok=0
fi
rm -f "$EV"
[ "$ok" = 1 ] && echo "PASS PBX→app" || { echo "FAIL PBX→app"; fail=1; }

if [ "$fail" = 0 ]; then
  echo "PASS: DTMF travels both ways as RFC 4733 events through the server"
else
  echo "FAIL dtmf"
fi
exit $fail
