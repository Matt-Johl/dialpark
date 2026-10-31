#!/bin/sh
# Audio continuity bench (lab/audio-continuity): does the receiving phone
# play every millisecond it was sent, or does it drop or pad some?
#
# Users hear brief drops in the app at call start and sometimes mid-call,
# and the drops are audio REMOVED, not silence: a decoded 20 ms frame
# discarded by the phone's jitter or play buffer, the rest closing up behind
# it. The silence-based gate (assert_audio.py --reference) cannot see that.
# Here the sending phone plays the tone with a click train on it
# (gen_tone.py --clicks: a 2 ms click exactly every 250 ms, through the
# tone's off periods too) and the receiving phone's recording is read for
# the spacing between successive clicks (assert_audio.py --continuity): a
# spacing short of 250 ms is audio removed, long is time inserted.
#
# App 211 (baresip-a) calls app 212 (baresip-b) through the server's relay;
# what 212 played is /media/out-212.wav, the impaired direction; what 211
# played (212's tone back) is out-211.wav, the clean direction, printed as
# the phones' own baseline. Scenarios (SCENARIO=control|burst|stall|quiet|
# all, default all), each a fresh compose run that publishes no host ports:
#
#   control  a clean 30 s call.
#   burst    212's inbound RTP is held from before the call and released
#            300 ms after the server bridged it, so its first audio arrives
#            as one back-to-back burst (what a phone sees when the far end's
#            early packets were queued somewhere and let go at once).
#   stall    mid-call, at 10 s and 20 s of a 30 s call, 212's inbound RTP is
#            held for 60 ms and released: three frames late, then a burst,
#            nothing lost.
#   quiet    a clean 60 s call: does the jitter buffer shrinking step by
#            step cost a frame per step?
#
# How the hold is made: the netem sidecar shares the server's network
# namespace (as pbx_outage_test.sh) and a tbf qdisc sits on the UDP packets
# to 212's address alone (SIP is TCP and passes). Open it runs at 1 Gbit;
# "hold" changes it to 100 bit/s with a 300-byte bucket, so the stream
# queues in order; "release" changes it back, which refills the bucket and
# drains the whole queue in one burst. Proven on a bare UDP stream before
# this script was written: 301 ms hold -> 15 packets in 0.4 ms, in order,
# none lost. The alternatives do not do this: deleting a netem delay
# qdisc DROPS what it holds, changing its delay to zero lets new packets
# overtake the held ones (reorder), and sch_plug, built for exactly this,
# is not in Docker Desktop's kernel ("Specified qdisc kind is unknown").
#
# Per scenario the output has the continuity line for each direction, the
# server's bridged / last relay per direction / call ended lines, and for
# burst and stall the tbf backlog at release (the burst size in packets).
# The whole server window is kept in harness/baresip/media/continuity-
# <scenario>.log. No pass/fail bound: exit 0 unless a scenario could not
# run. KEEP=1 leaves the last stack up.
#
#   make harness-continuity
#   SCENARIO=burst sh harness/continuity_test.sh
set -eu
cd "$(dirname "$0")/.."

COMPOSE="docker compose -f harness/docker-compose.yml -f harness/docker-compose.noports.yml --profile test --profile impair"
export DIALPARK_PUBLIC_HOST=dialpark
# The sidecar is only the tool here: no loss, no delay of its own.
export NETEM_LOSS=0% NETEM_DELAY=0ms NETEM_JITTER=0ms
NET=dialpark-harness_default
MEDIA_DIR=harness/baresip/media
SCENARIO="${SCENARIO:-all}"
KEEP="${KEEP:-0}"
STACK_UP=0

cleanup() { [ "$KEEP" = 1 ] || [ "$STACK_UP" = 0 ] || $COMPOSE down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

logs() { $COMPOSE logs --no-log-prefix --since "$1" dialpark 2>&1; }
ctl() { # phone json
  docker run --rm --network "$NET" alpine:3.20 sh -c \
    "p='$2'; len=\$(printf %s \"\$p\" | wc -c | tr -d ' '); printf '%s:%s,' \"\$len\" \"\$p\" | nc -w2 $1 4444 >/dev/null"
}
tc_in_server() { $COMPOSE exec -T netem sh -c "$1"; }
TBF="tc qdisc change dev eth0 parent 1:3 handle 30: tbf limit 1000000"
TBF_OPEN="$TBF rate 1gbit burst 1000000"
TBF_HOLD="$TBF rate 100bit burst 300"
# hold_arm <ip>: route the server's UDP to <ip> through an open tbf.
hold_arm() {
  tc_in_server "tc qdisc replace dev eth0 root handle 1: prio \
    && tc filter add dev eth0 parent 1: protocol ip prio 1 u32 match ip dst $1/32 match ip protocol 17 0xff flowid 1:3 \
    && tc qdisc add dev eth0 parent 1:3 handle 30: tbf rate 1gbit burst 1000000 limit 1000000" >/dev/null
  tc_in_server "tc qdisc show dev eth0" | grep -q 'tbf 30:' || { echo "FAIL: the tbf did not apply"; exit 1; }
}
hold_on() { tc_in_server "$TBF_HOLD" >/dev/null; }
# hold_off_after <usec>: inside the sidecar, wait, report the backlog, release.
hold_off_after() {
  tc_in_server "usleep $1; tc -s qdisc show dev eth0 | grep -A2 'tbf 30:' | grep -o 'backlog [^ ]* [0-9]*p'; $TBF_OPEN"
}
wait_for() { # seconds what cmd...
  n=$1; what=$2; shift 2
  i=0
  until "$@"; do
    i=$((i+1)); [ $i -lt "$n" ] || { echo "FAIL: $what"; return 1; }
    sleep 0.2
  done
}
bridged_since() { logs "$1" | grep -q 'msg=bridged'; }
registered_since() { logs "$1" | grep -q "sip register.*user=$2"; }
# repair_wav <file>: a header that says 0 frames over a file full of audio
# (baresip's recorder closing out of order) is rewritten from the size.
repair_wav() {
  python3 - "$1" <<'PY'
import os, struct, sys
p = sys.argv[1]
if not os.path.exists(p):
    sys.exit(0)
size = os.path.getsize(p)
if size > 44:
    with open(p, "rb") as f:
        f.seek(40); n = struct.unpack("<I", f.read(4))[0]
    if n == 0:
        with open(p, "r+b") as f:
            f.seek(4); f.write(struct.pack("<I", size - 8))
            f.seek(40); f.write(struct.pack("<I", size - 44))
PY
}

# scenario <name> <call seconds>
scenario() {
  name="$1"; secs="$2"
  echo "=== scenario $name (${secs}s call, 211 -> 212)"
  # Clicks for the whole call: the file must outlast it (no loop seam).
  python3 harness/baresip/media/gen_tone.py --clicks --seconds "$((secs + 5))" "$MEDIA_DIR/in.wav" >/dev/null
  rm -f "$MEDIA_DIR"/out-*.wav
  if [ "$STACK_UP" = 1 ]; then $COMPOSE down -v >/dev/null 2>&1 || true; fi
  STACK_UP=1
  MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # backlog: the server itself holds the pumps back 300 ms after the ACK
  # (-lab-pump-delay), so 212's first packets queue in the server's socket
  # and drain as one burst the moment the relay starts — the start-of-call
  # backlog a slow ACK makes on app→CUCM calls, by the same mechanism.
  if [ "$name" = backlog ]; then export DIALPARK_LAB_PUMP_DELAY=300ms; else export DIALPARK_LAB_PUMP_DELAY=0s; fi
  $COMPOSE up --build -d dialpark >/dev/null 2>&1
  sleep 2
  sh harness/innet.sh "$NET" harness/provision.sh >/dev/null
  $COMPOSE up --build -d baresip-a baresip-b >/dev/null 2>&1
  wait_for 75 "211 never registered" registered_since "$MARK" 211 || { logs "$MARK" | tail -5; return 1; }
  wait_for 75 "212 never registered" registered_since "$MARK" 212 || { logs "$MARK" | tail -5; return 1; }
  if [ "$name" = burst ] || [ "$name" = stall ]; then
    # Last, once nothing will recreate the server (the sidecar shapes the
    # server container's own interface).
    $COMPOSE up --build -d netem >/dev/null 2>&1
    sleep 1
    B_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$($COMPOSE ps -q baresip-b)")"
    [ -n "$B_IP" ] || { echo "FAIL: no address for baresip-b"; return 1; }
    hold_arm "$B_IP"
    echo "   tbf on the server's UDP to 212 ($B_IP): open"
  fi
  [ "$name" = burst ] && { hold_on; echo "   hold on before the call"; }

  MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  T0=$(date +%s)
  ctl baresip-a '{"command":"dial","params":"212@dialpark"}'
  wait_for 75 "the call never bridged" bridged_since "$MARK" || {
    [ "$name" = burst ] && tc_in_server "$TBF_OPEN" >/dev/null
    logs "$MARK" | grep -E 'invite|level=(ERROR|WARN)' | tail -5 | sed 's/^/   /'; return 1; }
  TB=$(date +%s)
  case "$name" in
    burst)
      echo "   bridged; releasing 300 ms on: $(hold_off_after 300000 | tr '\n' ' ')" ;;
    stall)
      # In the sidecar as one script, so each hold is timed there and not
      # by a docker exec round trip.
      n=$((secs / 10 - 1))
      tc_in_server "i=0; while [ \$i -lt $n ]; do i=\$((i+1)); sleep 10; $TBF_HOLD; usleep 60000; \
        echo \"   stall \$i at +\$((i*10)) s: \$(tc -s qdisc show dev eth0 | grep -A2 'tbf 30:' | grep -o 'backlog [^ ]* [0-9]*p')\"; $TBF_OPEN; done" \
        > "$MEDIA_DIR/continuity-stall.txt" 2>&1 &
      STALL_PID=$! ;;
  esac
  sleep "$((secs - (TB - T0)))"
  ctl baresip-a '{"command":"hangup"}'
  sleep 2
  if [ "$name" = stall ]; then
    wait "$STALL_PID" 2>/dev/null || true
    cat "$MEDIA_DIR/continuity-stall.txt"; rm -f "$MEDIA_DIR/continuity-stall.txt"
  fi

  echo "== server"
  logs "$MARK" > "$MEDIA_DIR/continuity-$name.log"
  grep -E 'msg=bridged' "$MEDIA_DIR/continuity-$name.log" | tail -1 | sed 's/^/   /'
  for dir in $(grep -F 'msg=relay ' "$MEDIA_DIR/continuity-$name.log" | grep -o 'dir=[^ ]*' | sort -u); do
    grep -F 'msg=relay ' "$MEDIA_DIR/continuity-$name.log" | grep -F "$dir" | tail -1 | sed 's/^/   /'
  done
  grep -E 'msg="call ended"' "$MEDIA_DIR/continuity-$name.log" | tail -1 | sed 's/^/   /'
  grep -E 'level=(ERROR|WARN)' "$MEDIA_DIR/continuity-$name.log" | tail -3 | sed 's/^/   /'

  echo "== continuity: what 212 played (211's clicks, the impaired direction)"
  repair_wav "$MEDIA_DIR/out-212.wav"
  python3 harness/spike/assert_audio.py "$MEDIA_DIR/out-212.wav" --continuity | grep -v '^PASS' | sed 's/^/   /'
  echo "== continuity: what 211 played (212's clicks, the clean direction)"
  repair_wav "$MEDIA_DIR/out-211.wav"
  python3 harness/spike/assert_audio.py "$MEDIA_DIR/out-211.wav" --continuity | grep -v '^PASS' | sed 's/^/   /'
  cp "$MEDIA_DIR/out-212.wav" "$MEDIA_DIR/continuity-$name-212.wav"
  cp "$MEDIA_DIR/out-211.wav" "$MEDIA_DIR/continuity-$name-211.wav"
  echo "   kept: $MEDIA_DIR/continuity-$name.log, continuity-$name-212.wav, continuity-$name-211.wav"
}

rc=0
case "$SCENARIO" in
  control) scenario control 30 || rc=1 ;;
  backlog) scenario backlog 30 || rc=1 ;;
  burst)   scenario burst 30 || rc=1 ;;
  stall)   scenario stall 30 || rc=1 ;;
  quiet)   scenario quiet 60 || rc=1 ;;
  all)
    for s in control backlog burst stall; do scenario "$s" 30 || rc=1; done
    scenario quiet 60 || rc=1 ;;
  *) echo "unknown SCENARIO=$SCENARIO (control|backlog|burst|stall|quiet|all)"; exit 2 ;;
esac
exit $rc
