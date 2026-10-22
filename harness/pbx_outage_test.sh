#!/bin/sh
# The link to the PBX goes down and comes back: a registered line must be
# back on the exchange soon after, without a restart. (CUCM bench
# 2026-10-22 09:11–09:35: a twenty-minute outage, the retry interval
# climbed to its five-minute cap, and the line was still unregistered when
# the server was restarted — while a call from the app had already reached
# the exchange and been answered.)
#
# Lines bench (Asterisk as the registrar, lease 60 s). The server's packets
# to the PBX are black-holed with a tc filter in its own namespace (the
# netem sidecar, as trunk_stall_test.sh), so the refresh REGISTER times out
# and the line goes "retrying". Two rounds:
#
#   prompted: the black hole lifts and the app dials the PBX at once. The
#             PBX answers that INVITE, which proves it is reachable, and the
#             line must re-register on that proof within seconds — not at
#             the end of its backoff.
#   backoff:  the black hole lifts and nothing happens. The line must be
#             back within the retry cap plus one attempt (30 s + 32 s),
#             never minutes.
#
# Exit 0 = pass. Publishes no host ports.
#
#   make harness-pbx-outage
#   KEEP=1 make harness-pbx-outage
set -eu
cd "$(dirname "$0")/.."

COMPOSE="docker compose -f harness/docker-compose.yml -f harness/docker-compose.noports.yml --profile test --profile impair"
export DIALPARK_PUBLIC_HOST=dialpark
export ASTERISK_LINES=yes DIALPARK_PBX_MODE=lines DIALPARK_PBX_DOMAIN=asterisk
# Asterisk's minimum; the refresh is then due at 45 s and a black hole of
# 90 s is sure to catch it (45 s + a 32 s transaction).
export DIALPARK_PBX_EXPIRY=60s
# The impairment sidecar is only the tool here: no loss, no delay of its own.
export NETEM_LOSS=0% NETEM_DELAY=0ms NETEM_JITTER=0ms
NET=dialpark-harness_default
ASTERISK_IP=172.30.0.20
KEEP="${KEEP:-0}"

cleanup() { [ "$KEEP" = 1 ] || $COMPOSE down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

logs() { $COMPOSE logs --no-log-prefix --since "$1" dialpark 2>&1; }
ctl() { # phone json
  docker run --rm --network "$NET" alpine:3.20 sh -c \
    "p='$2'; len=\$(printf %s \"\$p\" | wc -c | tr -d ' '); printf '%s:%s,' \"\$len\" \"\$p\" | nc -w2 $1 4444 >/dev/null"
}
tc_in_server() { $COMPOSE exec -T netem sh -c "$1"; }
blackhole_on() {
  tc_in_server "tc qdisc replace dev eth0 root handle 1: prio \
    && tc filter add dev eth0 parent 1: protocol ip prio 1 u32 match ip dst $ASTERISK_IP/32 flowid 1:3 \
    && tc qdisc add dev eth0 parent 1:3 handle 30: netem loss 100%" >/dev/null
  tc_in_server "tc qdisc show dev eth0" | grep -q "loss 100%" || { echo "FAIL: the black hole did not apply"; exit 1; }
}
blackhole_off() { tc_in_server "tc qdisc del dev eth0 root" >/dev/null; }
wait_for() { # seconds what cmd...
  n=$1; what=$2; shift 2
  i=0
  until "$@"; do
    i=$((i+1)); [ $i -lt "$n" ] || { echo "FAIL: $what"; return 1; }
    sleep 1
  done
}
registered_since() { logs "$1" | grep -q 'pbx line: registered.*dn=211'; }
retrying_since() { logs "$1" | grep -q 'pbx line: registration failed; retrying.*dn=211'; }

echo "== up: server in lines mode (lease 60 s), asterisk as registrar, app 211, netem sidecar"
$COMPOSE up --build -d dialpark asterisk netem >/dev/null 2>&1
sleep 2
PBX_LINES=1 sh harness/innet.sh "$NET" harness/provision.sh >/dev/null
# The server reads its lines at start-up: come back up with them (and the
# sidecar, which lives in the server's network namespace).
MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
$COMPOSE up -d --no-deps --force-recreate dialpark netem >/dev/null 2>&1
sleep 3
$COMPOSE up --build -d baresip-a >/dev/null 2>&1
wait_for 30 "line 211 never registered" registered_since "$MARK" || { logs "$MARK" | grep -i "pbx line" | tail -4 | sed 's/^/   /'; exit 1; }
echo "   line 211 registered"
fail=0

# ---- round 1: prompted by the exchange's answer to a call ------------------
echo "== round 1: black hole on; wait for the refresh to fail"
MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
blackhole_on
wait_for 100 "the refresh never failed under the black hole" retrying_since "$MARK" || { blackhole_off; exit 1; }
echo "   line 211 is retrying ($(logs "$MARK" | grep -o 'err="[^"]*"' | head -1))"
# Let the first retry be in flight, so the next one by backoff alone is
# tens of seconds away.
sleep 8
echo "== round 1: black hole off; the app dials 100 at once"
blackhole_off
T0=$(date +%s); MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ctl baresip-a '{"command":"dial","params":"100@dialpark"}'
if wait_for 15 "the line did not re-register on the exchange's answer" registered_since "$MARK"; then
  echo "   re-registered $(( $(date +%s) - T0 )) s after the link came back, prompted: $(logs "$MARK" | grep -o 'reachable again[^"]*' | head -1)"
  logs "$MARK" | grep -q 'the exchange is reachable again' || { echo "   FAIL: registered, but not by the prompt"; fail=1; }
else
  logs "$MARK" | grep -E 'pbx line|invite' | tail -5 | sed 's/^/   /'; fail=1
fi
ctl baresip-a '{"command":"hangup"}'
sleep 3

# ---- round 2: backoff alone -------------------------------------------------
echo "== round 2: black hole on again; wait for the refresh to fail"
MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
blackhole_on
wait_for 100 "the refresh never failed under the second black hole" retrying_since "$MARK" || { blackhole_off; exit 1; }
sleep 8
echo "== round 2: black hole off; nobody calls — the line must be back within the retry cap plus one attempt"
blackhole_off
T0=$(date +%s); MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if wait_for 70 "the line did not re-register within the cap plus one attempt (62 s)" registered_since "$MARK"; then
  # Asterisk keeps polling a contact it still holds, and that poll is the
  # exchange being heard from — so this round is usually prompted too.
  # Either way the bound is what matters; say which path it took.
  how="by backoff alone"
  logs "$MARK" | grep -q 'the exchange is reachable again' && how="prompted by the exchange's own OPTIONS poll"
  echo "   re-registered $(( $(date +%s) - T0 )) s after the link came back, $how"
else
  logs "$MARK" | grep -E 'pbx line' | tail -5 | sed 's/^/   /'; fail=1
fi

if [ "$fail" = 0 ]; then
  echo "PASS: a line comes back on its own after an outage, at once when the exchange is heard from"
else
  echo "FAIL pbx-outage"
fi
exit $fail
