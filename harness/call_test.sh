#!/bin/sh
# Headless app↔app call (SPEC §7.2): PHONE_A (211) dials 212, the server
# bridges the legs with media proxied through itself, and the callee's
# recording is asserted to contain audio. Exit 0 = pass.
#
# Driven entirely inside the compose network (a throwaway alpine container
# talks to baresip's ctrl_tcp), so it works from sandboxes that cannot
# connect to published localhost ports.
#
# Defaults target the main harness (the real dialpark-server). The engine
# spike uses the same script with its own compose file and service names.
set -eu
cd "$(dirname "$0")/.."

COMPOSE_FILE="${COMPOSE_FILE:-harness/docker-compose.yml}"
PROJECT="${PROJECT:-dialpark-harness}"
SERVER="${SERVER:-dialpark}"
PHONE_A="${PHONE_A:-baresip-a}"
PHONE_B="${PHONE_B:-baresip-b}"
DOMAIN="${DOMAIN:-dialpark}"
MEDIA_DIR="${MEDIA_DIR:-harness/baresip/media}"
PROFILE="${PROFILE:---profile test}"
PROVISION="${PROVISION:-1}"
CALL_SECONDS="${CALL_SECONDS:-8}"
KEEP="${KEEP:-0}"

# HARNESS_NOPORTS=1 publishes nothing on the host, so this can run beside a
# native `make dev-server` without fighting it for 7443 / 5061. Safe for any
# test that lives entirely inside the compose network; NOT for ones a
# simulator or a real phone has to reach (sim_call.sh, ring_*.sh, probe_*).
NOPORTS=""
[ "${HARNESS_NOPORTS:-0}" = 1 ] && { NOPORTS="-f harness/docker-compose.noports.yml"; export DIALPARK_PUBLIC_HOST=dialpark; }
COMPOSE="docker compose -f $COMPOSE_FILE $NOPORTS $PROFILE"
NET="${PROJECT}_default"

# CLICKS=1: the tone carries a click train (gen_tone.py --clicks) and the
# callee's recording is also read for audio removed or inserted at the
# receiving phone (assert_audio.py --continuity, none allowed), with the
# server's relay required to have started at the answer (SPEC §4.4 rule 3,
# 2026-11-02: answer_to_relay_ms on bridged, backlog_pkts on call ended).
CLICKS="${CLICKS:-0}"
if [ "$CLICKS" = 1 ]; then
  python3 harness/baresip/media/gen_tone.py --clicks --seconds "$((CALL_SECONDS + 5))" "$MEDIA_DIR/in.wav" >/dev/null
else
  python3 harness/baresip/media/gen_tone.py "$MEDIA_DIR/in.wav" >/dev/null
fi
rm -f "$MEDIA_DIR"/out-*.wav

cleanup() {
  [ "$KEEP" = 1 ] || $COMPOSE down -v >/dev/null 2>&1 || true
  [ "$CLICKS" = 1 ] && python3 harness/baresip/media/gen_tone.py "$MEDIA_DIR/in.wav" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== up ($COMPOSE_FILE)"
$COMPOSE up --build -d "$SERVER" >/dev/null 2>&1
if [ "$PROVISION" = 1 ]; then
  sleep 2
  sh harness/innet.sh "$NET" harness/provision.sh >/dev/null
fi
$COMPOSE up --build -d "$PHONE_A" "$PHONE_B" >/dev/null 2>&1
sleep 5

ctl() {
  docker run --rm --network "$NET" alpine:3.20 sh -c \
    "p='$1'; len=\$(printf %s \"\$p\" | wc -c | tr -d ' '); printf '%s:%s,' \"\$len\" \"\$p\" | nc -w2 $PHONE_A 4444 >/dev/null"
}

echo "== dial 211 -> 212@$DOMAIN"
ctl "{\"command\":\"dial\",\"params\":\"212@$DOMAIN\"}"
sleep "$CALL_SECONDS"
ctl '{"command":"hangup"}'
sleep 2

echo "== server"
$COMPOSE logs --no-log-prefix "$SERVER" 2>&1 | grep -E 'invite|bridged|call ended|sip register|level=(ERROR|WARN)' | tail -12 | sed 's/^/   /'
if ! $COMPOSE logs --no-log-prefix "$SERVER" 2>&1 | grep -q 'msg=bridged'; then
  echo "FAIL: server never bridged the call"; exit 1
fi
# SRTP is mandatory on the app leg (SPEC §4.4 rule 4): both legs of an
# app↔app call must have negotiated SDES.
if ! $COMPOSE logs --no-log-prefix "$SERVER" 2>&1 | grep 'msg=bridged' | grep -q 'caller_srtp=on callee_srtp=on'; then
  echo "FAIL: an app leg was bridged without SRTP"; exit 1
fi

echo "== callee"
$COMPOSE logs --no-log-prefix "$PHONE_B" 2>&1 | grep -iE 'Call established|incoming rtp' | sed 's/^/   /'

echo "== media"
python3 harness/spike/assert_audio.py "$MEDIA_DIR/out-212.wav"
if [ "$CLICKS" = 1 ]; then
  echo "== continuity: what 212 played (211's clicks)"
  cont="$(python3 harness/spike/assert_audio.py "$MEDIA_DIR/out-212.wav" --continuity --max-removed-ms 0)" || { printf '%s\n' "$cont" | sed 's/^/   /'; echo "FAIL: audio removed at the receiving phone"; exit 1; }
  printf '%s\n' "$cont" | sed 's/^/   /'
  echo "== relay start"
  slog="$($COMPOSE logs --no-log-prefix "$SERVER" 2>&1)"
  a2r="$(printf '%s\n' "$slog" | grep 'msg=bridged' | tail -1 | grep -o 'answer_to_relay_ms=[0-9-]*' | cut -d= -f2)"
  [ -n "$a2r" ] && [ "$a2r" -lt 50 ] || { echo "FAIL: answer_to_relay_ms=${a2r:-missing}, want under 50"; exit 1; }
  echo "   relay started ${a2r} ms after the callee answered"
  for b in $(printf '%s\n' "$slog" | grep 'msg="call ended"' | tail -1 | grep -o 'backlog_pkts=[0-9]*' | cut -d= -f2); do
    # the harness phone itself sends its first three packets as a burst
    # (early_max_ms=35 on every answer), so up to four; a relay that
    # waited for the caller's ACK finds 12 or more
    [ "$b" -le 4 ] || { echo "FAIL: a pump found $b packets queued when it started"; exit 1; }
  done
  echo "   no backlog at either pump's start"
fi
