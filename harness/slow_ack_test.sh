#!/bin/sh
# The relay starts at the answer, not at the caller's ACK (SPEC §4.4 rule 3,
# 2026-11-02). SIPp stands in for the exchange at the server's trunk
# listener and calls app 211 with an early offer; when the 200 OK comes it
# holds its ACK back ACK_MS (default 500 ms) — a slow caller, the shape of
# an app leg's 230–320 ms round trip on a real call — and echoes every RTP
# packet back. App 211 plays the tone with a click train on it from the
# moment it answers, so its recording of its own echo shows whether its
# opening was held in the server's socket until the ACK and then released
# as one burst (the harness phone's play buffer discards most of such a
# burst, as the real app's did) or relayed as it came.
#
# Asserted: the server's bridged line has answer_to_relay_ms under 50 (the
# relay ran before the ACK could have arrived); the caller's ACK is logged
# at about ACK_MS; neither pump found more than four packets waiting when
# it started (the harness phone sends its first three as a burst; a relay
# that waited for the ACK finds 25); and the click train in the app's recording has lost no
# time at the start (assert_audio.py --continuity, removed 0 ms). Against
# the old blocking answer the same call relays nothing until the ACK
# (server/internal/b2bua/relay_at_answer_test.go, run both ways on
# 2026-11-02: 0 packets before the ACK, then 13). Exit 0 = pass. Publishes
# no host ports.
#
#   make harness-slow-ack
#   ACK_MS=300 sh harness/slow_ack_test.sh
set -eu
cd "$(dirname "$0")/.."

COMPOSE="docker compose -f harness/docker-compose.yml -f harness/docker-compose.noports.yml --profile test"
export DIALPARK_PUBLIC_HOST=dialpark
NET=dialpark-harness_default
MEDIA_DIR=harness/baresip/media
CALL_SECONDS="${CALL_SECONDS:-8}"
ACK_MS="${ACK_MS:-500}"
KEEP="${KEEP:-0}"

# Clicks for the whole call, and the plain tone restored afterwards: the
# other gates correlate their recordings against the plain file.
python3 harness/baresip/media/gen_tone.py --clicks --seconds "$((CALL_SECONDS + 5))" "$MEDIA_DIR/in.wav" >/dev/null
rm -f "$MEDIA_DIR/out-211.wav"

cleanup() {
  [ "$KEEP" = 1 ] || $COMPOSE down -v >/dev/null 2>&1 || true
  python3 harness/baresip/media/gen_tone.py "$MEDIA_DIR/in.wav" >/dev/null 2>&1 || true
}
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
echo "== call: the PBX (SIPp) INVITEs 211 with an early offer, ACKs ${ACK_MS} ms after the 200 OK, echoes the media, hangs up after ${CALL_SECONDS}s"
MARK="$(logs | wc -l | tr -d ' ')"
set +e
$COMPOSE run --rm --entrypoint sipp sipp dialpark:5060 -t u1 -sf /scenarios/early_offer_slow_ack.xml \
  -s 211 -m 1 -nostdin -timeout 45s -timeout_error -d "$((CALL_SECONDS * 1000))" -rtp_echo -key ack_ms "$ACK_MS" \
  -trace_err -error_file /tmp/slow_ack.err > "$MEDIA_DIR/sipp-slow-ack.out" 2>&1
rc=$?
set -e
sleep 2
if [ "$rc" -eq 0 ]; then
  echo "   SIPp: answered, ACKed late, BYE answered"
else
  echo "   FAIL: SIPp exit $rc"; tail -n 12 "$MEDIA_DIR/sipp-slow-ack.out" | sed 's/^/   sipp: /'; fail=1
fi
rm -f "$MEDIA_DIR/sipp-slow-ack.out"
slog="$(logs | tail -n +"$((MARK + 1))")"
printf '%s\n' "$slog" | grep -E 'invite|callee answered|bridged|caller acked|call ended|level=(ERROR|WARN)' | tail -8 | sed 's/^/   /'

echo "== server: when the relay started"
a2r="$(printf '%s\n' "$slog" | grep 'msg=bridged' | grep -o 'answer_to_relay_ms=[0-9-]*' | head -1 | cut -d= -f2)"
if [ -n "$a2r" ] && [ "$a2r" -lt 50 ]; then
  echo "   relay started ${a2r} ms after the callee answered (before the ACK could arrive)"
else
  echo "   FAIL: answer_to_relay_ms=${a2r:-missing}, want under 50 — the relay waited for something"; fail=1
fi
ack="$(printf '%s\n' "$slog" | grep 'msg="caller acked"' | grep -o 'ack_ms=[0-9]*' | head -1 | cut -d= -f2)"
if [ -n "$ack" ] && [ "$ack" -ge "$((ACK_MS - 100))" ]; then
  echo "   the caller's ACK arrived ${ack} ms after the 200 OK, as scripted"
else
  echo "   FAIL: caller acked ack_ms=${ack:-missing}, want about ${ACK_MS}"; fail=1
fi
for b in $(printf '%s\n' "$slog" | grep 'msg="call ended"' | grep -o 'backlog_pkts=[0-9]*' | cut -d= -f2); do
  if [ "$b" -le 4 ]; then
    echo "   a pump started with backlog_pkts=$b"
  else
    echo "   FAIL: a pump found $b packets queued when it started — the relay started late"; fail=1
  fi
done
printf '%s\n' "$slog" | grep -q 'msg="call ended"' || { echo "   FAIL: no call-ended line"; fail=1; }

echo "== media: what 211 played (its own clicks, echoed by the PBX)"
# The harness recorder's header can say 0 frames over a full file (closed
# out of order); repaired from the size, as the other gates do.
python3 - "$MEDIA_DIR/out-211.wav" <<'PY'
import os, struct, sys
p = sys.argv[1]
if os.path.exists(p) and os.path.getsize(p) > 44:
    size = os.path.getsize(p)
    with open(p, "rb") as f:
        f.seek(40); n = struct.unpack("<I", f.read(4))[0]
    if n == 0:
        with open(p, "r+b") as f:
            f.seek(4); f.write(struct.pack("<I", size - 8))
            f.seek(40); f.write(struct.pack("<I", size - 44))
PY
if cont="$(python3 harness/spike/assert_audio.py "$MEDIA_DIR/out-211.wav" --continuity --max-removed-ms 0)"; then
  printf '%s\n' "$cont" | sed 's/^/   /'
  echo "   no audio removed: the opening came through as it was sent"
else
  printf '%s\n' "$cont" | sed 's/^/   /'
  echo "   FAIL: audio removed at the receiving phone — the opening arrived as a burst"; fail=1
fi

[ "$fail" = 0 ] && echo "PASS: the relay started at the answer and the slow ACK cost nothing" || echo "FAIL"
exit "$fail"
