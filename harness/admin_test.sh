#!/bin/sh
# The admin API cannot disturb a call (ADMIN-API.md §4.7 and §7; SPEC §6
# item 9b step 10). With a dev-ha ↔ dev-hb call bridged and its audio
# recorded:
#
#   1. isolation — revoke dev-s, replace dev-a's directory, mint dev-a a
#      code, set the log level, read status, events and calls; and
#   2. load — for LOAD_SECONDS, eight containers flood the admin listener
#      with status and device reads well past the rate limit, one PUTs a
#      4 MiB directory replace-all continuously, one holds hundreds of
#      idle connections, and one sends the adversarial bodies to every
#      write route;
#
# and the call must not notice: the callee's recording passes the usual
# audio gate, neither harness phone sees a session close, a re-INVITE or a
# directory_changed, the server neither panics nor grows past LIMIT_RSS_MB,
# and the admin listener answers with 429s and 503s rather than hanging.
#
# A third party's latency (contract §4.7): SIPp, as dev-hc/213 (no phone
# uses it), REGISTERs and INVITEs 214 (a user with no phone, answered 480
# by the wake path) every PROBE_INTERVAL seconds, idle first and then
# throughout the flood. The median under load must stay within twice the
# idle median, with a PROBE_FLOOR_MS floor because SIPp reports whole
# milliseconds and the idle figure is about one.
#
# Exit 0 = pass. Driven inside the compose network like call_test.sh.
set -eu
cd "$(dirname "$0")/.."

COMPOSE_FILE="${COMPOSE_FILE:-harness/docker-compose.yml}"
PROJECT="${PROJECT:-dialpark-harness}"
MEDIA_DIR="${MEDIA_DIR:-harness/baresip/media}"
LOAD_SECONDS="${LOAD_SECONDS:-60}"
PROBE_INTERVAL="${PROBE_INTERVAL:-5}"
PROBE_FLOOR_MS="${PROBE_FLOOR_MS:-10}"
LIMIT_RSS_MB="${LIMIT_RSS_MB:-64}"
KEEP="${KEEP:-0}"
TOKEN="${DIALPARK_ADMIN_TOKEN:-harness}"
API="https://dialpark:8081"

NOPORTS=""
[ "${HARNESS_NOPORTS:-0}" = 1 ] && { NOPORTS="-f harness/docker-compose.noports.yml"; export DIALPARK_PUBLIC_HOST=dialpark; }
COMPOSE="docker compose -f $COMPOSE_FILE $NOPORTS --profile test"
NET="${PROJECT}_default"

python3 harness/baresip/media/gen_tone.py "$MEDIA_DIR/in.wav" >/dev/null
rm -f "$MEDIA_DIR"/out-*.wav

FLOODERS=""
cleanup() {
  for c in $FLOODERS; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  [ "$KEEP" = 1 ] || $COMPOSE down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

# admin METHOD PATH [BODY] — one admin call from inside the network; prints
# "STATUS BODY". curl is installed into the throwaway container because
# busybox wget cannot PUT, DELETE or report a status code.
admin() {
  docker run --rm --network "$NET" -v "$(pwd):/repo:ro" --entrypoint sh curlimages/curl:8.11.1 -c \
    "curl -sk -o /tmp/b -w '%{http_code}' -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' -X $1 '$API$2' ${3:+-d '$3'}; echo; cat /tmp/b"
}
ctl() {
  docker run --rm --network "$NET" alpine:3.20 sh -c \
    "p='$1'; len=\$(printf %s \"\$p\" | wc -c | tr -d ' '); printf '%s:%s,' \"\$len\" \"\$p\" | nc -w2 baresip-a 4444 >/dev/null"
}
# probe COUNT INTERVAL — the SIPp latency probe (harness/sipp/probe.sh),
# one "<register ms> <invite ms>" line per round.
probe() {
  $COMPOSE run --rm --entrypoint /work/probe.sh sipp "$1" "$2" 2>/dev/null | grep -E '^ *[0-9?]+ +[0-9?]+$|^FAIL' || true
}
# median FILE COLUMN — of the integer values in that column.
median() {
  awk -v c="$2" '$c ~ /^[0-9]+$/ {print $c}' "$1" | sort -n | awk '{v[NR]=$1} END {if (!NR) print "?"; else print v[int((NR+1)/2)]}'
}
rss_mb() {
  docker stats --no-stream --format '{{.MemUsage}}' "${PROJECT}-dialpark-1" 2>/dev/null | awk '{v=$1; if (v ~ /GiB/) {sub(/GiB/,"",v); v*=1024} else {sub(/MiB/,"",v)} printf "%d", v}'
}

echo "== up"
$COMPOSE up --build -d dialpark >/dev/null 2>&1
# The probe lives in the sipp image; build it now so `compose run` finds it.
$COMPOSE build sipp >/dev/null 2>&1
sleep 2
sh harness/innet.sh "$NET" harness/provision.sh >/dev/null
$COMPOSE up --build -d baresip-a baresip-b >/dev/null 2>&1
sleep 5

echo "== dial 211 -> 212 and let it settle"
ctl '{"command":"dial","params":"212@dialpark"}'
sleep 4
if ! $COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -q 'msg=bridged'; then
  echo "FAIL: the call did not bridge"; exit 1
fi
LOGS_BEFORE_A="$($COMPOSE logs --no-log-prefix baresip-a 2>&1 | wc -l | tr -d ' ')"
LOGS_BEFORE_B="$($COMPOSE logs --no-log-prefix baresip-b 2>&1 | wc -l | tr -d ' ')"
RSS_BEFORE="$(rss_mb)"

echo "== idle baseline: the probe registers and dials beside the call"
IDLE="$(mktemp)"
probe 6 1 > "$IDLE"
if grep -q FAIL "$IDLE"; then echo "FAIL: the probe cannot register or dial while idle:"; cat "$IDLE"; exit 1; fi
IDLE_REG="$(median "$IDLE" 1)"; IDLE_INV="$(median "$IDLE" 2)"
echo "   idle medians: REGISTER ${IDLE_REG} ms, INVITE→480 ${IDLE_INV} ms ($(wc -l < "$IDLE" | tr -d ' ') rounds)"

echo "== isolation: admin actions on OTHER devices while the call runs"
expect() { # expect STATUS METHOD PATH [BODY]
  want="$1"; shift
  out="$(admin "$@")"
  code="$(printf '%s\n' "$out" | head -n1)"
  case "$code" in
    $want) ;;
    *) echo "FAIL: $1 $2 → $code (want $want): $(printf '%s\n' "$out" | tail -n +2 | head -c 300)"; exit 1 ;;
  esac
}
expect 204 DELETE /v1/admin/devices/dev-s
expect 200 PUT /v1/admin/devices/dev-a/directory '{"contacts":[{"display_name":"Replaced","uri":"sip:900@dialpark","mode":"local"}]}'
expect 200 POST /v1/admin/devices/dev-a/enrol-code
# A PBX line set while the server is in trunk mode: stored for a later
# switch, nothing to register, and the request must be answered (it
# panicked the handler on 2026-09-26; the connection just closed).
expect 200 PUT /v1/admin/devices/dev-a/pbx-line '{"digest_user":"line201","secret":"dialpark-line-201"}'
expect 204 DELETE /v1/admin/devices/dev-a/pbx-line
expect 200 PUT /v1/admin/log '{"level":"debug","for_seconds":30}'
expect 200 PUT /v1/admin/log '{"level":"info"}'
expect 200 GET /v1/admin/status
expect 200 GET /v1/admin/events
expect 200 GET /v1/admin/calls
expect 200 GET /v1/admin/server
if ! admin GET /v1/admin/calls | grep -q '"state":"bridged"'; then
  echo "FAIL: the calls view does not show the bridged call"; exit 1
fi
# The replace-all above is recorded as the admin's write (ADMIN-API.md §5.9).
if ! admin GET '/v1/admin/events?limit=1000' | grep -q '"kind":"directory_changed"[^}]*"by":"admin"'; then
  echo "FAIL: no directory_changed event names the admin as the writer"; exit 1
fi

echo "== load: $LOAD_SECONDS s of floods against the admin listener"
flood() { # flood NAME SCRIPT — a container running SCRIPT until the deadline
  c="admin-flood-$1"
  docker run -d --name "$c" --network "$NET" --entrypoint sh curlimages/curl:8.11.1 -c \
    "end=\$((\$(date +%s)+$LOAD_SECONDS)); $2" >/dev/null
  FLOODERS="$FLOODERS $c"
}
# Eight sources reading status and devices as fast as they can: far past
# 50/s per source and 200/s in total, so most answers are 429.
for i in 1 2 3 4 5 6 7 8; do
  flood "read$i" "while [ \$(date +%s) -lt \$end ]; do for j in 1 2 3 4 5 6 7 8; do curl -sk -o /dev/null -H 'Authorization: Bearer $TOKEN' $API/v1/admin/status & curl -sk -o /dev/null -H 'Authorization: Bearer $TOKEN' $API/v1/admin/devices & done; wait; done"
done
# One source replacing dev-a's directory with a body at the 4 MiB limit.
flood "big" "awk 'BEGIN{printf \"{\\\"contacts\\\":[\"; for(i=0;i<4900;i++){if(i)printf \",\"; printf \"{\\\"display_name\\\":\\\"%s\\\",\\\"uri\\\":\\\"sip:%d@dialpark\\\",\\\"mode\\\":\\\"local\\\"}\", sprintf(\"%700s\",\"x\"), 10000+i} printf \"]}\"}' > /tmp/big.json; while [ \$(date +%s) -lt \$end ]; do curl -sk -o /dev/null -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' -X PUT $API/v1/admin/devices/dev-a/directory --data-binary @/tmp/big.json; done"
# One source holding idle connections open.
flood "idle" "while [ \$(date +%s) -lt \$end ]; do for j in \$(seq 1 200); do (sleep 20 | nc dialpark 8081 >/dev/null 2>&1) & done; sleep 20; done"
# One source sending the adversarial bodies to every write route.
flood "adv" "while [ \$(date +%s) -lt \$end ]; do for body in '{' '[]' '{\"user\":\"201\",\"user\":\"202\"}' '{\"ssids\":[\"a\\u0000b\"]}' '{\"contacts\":[{\"uri\":\"../../etc\",\"mode\":\"local\"}]}' \"\$(head -c 70000 /dev/zero | tr '\\0' '[')\" '{\"digest_user\":\"u\",\"secret\":\"s\",\"dn\":\"../x\"}'; do for p in /v1/admin/devices /v1/admin/devices/dev-a/config /v1/admin/devices/dev-a/pbx-line /v1/admin/devices/dev-a/directory /v1/admin/devices/../pbx.key/config; do curl -sk -o /dev/null -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' -X PUT \"$API\$p\" -d \"\$body\"; done; done; done"
LOADED="$(mktemp)"
probe "$((LOAD_SECONDS / PROBE_INTERVAL))" "$PROBE_INTERVAL" > "$LOADED" &
PROBE_PID=$!
sleep "$LOAD_SECONDS"
wait $PROBE_PID || true
sleep 3
for c in $FLOODERS; do docker rm -f "$c" >/dev/null 2>&1 || true; done
FLOODERS=""

echo "== latency under load"
if grep -q FAIL "$LOADED"; then echo "FAIL: the probe could not register or dial during the flood:"; grep FAIL "$LOADED" | head -3; exit 1; fi
LOAD_REG="$(median "$LOADED" 1)"; LOAD_INV="$(median "$LOADED" 2)"
echo "   loaded medians: REGISTER ${LOAD_REG} ms, INVITE→480 ${LOAD_INV} ms ($(wc -l < "$LOADED" | tr -d ' ') rounds)"
bound() { b=$(( $1 * 2 )); [ "$b" -lt "$PROBE_FLOOR_MS" ] && b="$PROBE_FLOOR_MS"; echo "$b"; }
for pair in "REGISTER $IDLE_REG $LOAD_REG" "INVITE $IDLE_INV $LOAD_INV"; do
  set -- $pair
  case "$2$3" in *\?*) echo "FAIL: no $1 measurement"; exit 1 ;; esac
  if [ "$3" -gt "$(bound "$2")" ]; then
    echo "FAIL: $1 median rose from $2 ms idle to $3 ms under admin load (bound $(bound "$2") ms)"; exit 1
  fi
done

echo "== the listener still answers, and answered with refusals rather than hangs"
SERVER_JSON="$(admin GET /v1/admin/server | tail -n +2)"
printf '%s\n' "$SERVER_JSON" | grep -o '"admin":{[^}]*}' | sed 's/^/   /'
if ! printf '%s\n' "$SERVER_JSON" | grep -q '"rejected_rate":[1-9]'; then
  echo "FAIL: the flood was never rate-limited"; exit 1
fi

echo "== the call (checked before it is hung up, so the hangup's own lines do not count)"
if $COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -q 'panic:'; then
  echo "FAIL: the server panicked"; $COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -A5 'panic:' | head -20; exit 1
fi
if $COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -q 'msg="call ended"'; then
  echo "FAIL: the call ended during the load:"; $COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -E 'call ended|hangup|BYE|gone|timed out' | tail -5; exit 1
fi
for phone in baresip-a baresip-b; do
  eval "before=\$LOGS_BEFORE_$( [ $phone = baresip-a ] && echo A || echo B )"
  new="$($COMPOSE logs --no-log-prefix "$phone" 2>&1 | tail -n +"$((before+1))")"
  if printf '%s\n' "$new" | grep -qiE 'session closed|re-invite|directory_changed|registration failed|unauthorized'; then
    echo "FAIL: $phone was disturbed:"; printf '%s\n' "$new" | grep -iE 'session closed|re-invite|directory_changed|registration failed|unauthorized' | head -5; exit 1
  fi
done
ctl '{"command":"hangup"}'
sleep 2
RSS_AFTER="$(rss_mb)"
echo "   server RSS ${RSS_BEFORE:-?} MiB → ${RSS_AFTER:-?} MiB"
if [ -n "$RSS_BEFORE" ] && [ -n "$RSS_AFTER" ] && [ $((RSS_AFTER - RSS_BEFORE)) -gt "$LIMIT_RSS_MB" ]; then
  echo "FAIL: server memory grew by more than $LIMIT_RSS_MB MiB under admin load"; exit 1
fi

echo "== media"
python3 harness/spike/assert_audio.py "$MEDIA_DIR/out-212.wav"
echo "ADMIN ISOLATION AND LOAD PASS"
