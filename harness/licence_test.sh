#!/bin/sh
# The product licence (SPEC §4.9) against the real server and the headless
# app: the dev licence installs, a bad paste is refused with its reason, a
# smaller licence suspends exactly the newest holders (refused at the
# gateway with "no licence seat", refused a fixture token with 409), and
# the restored licence lets them back in. Trunk mode, no PBX needed. The
# lines-mode half of seat loss (the PBX line dropped) is unit-tested in
# cmd/dialpark-server and proven live by pbx_lines_test.sh's registrar.
# Exit 0 = pass.
set -eu
cd "$(dirname "$0")/.."
COMPOSE="docker compose -f harness/docker-compose.yml -f harness/docker-compose.noports.yml --profile test"
export DIALPARK_PUBLIC_HOST=dialpark
NET=dialpark-harness_default
KEEP="${KEEP:-0}"
cleanup() { [ "$KEEP" = 1 ] || $COMPOSE down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

[ -s harness/dialpark/licence ] || { echo "FAIL: no harness/dialpark/licence (see provision.sh)"; exit 1; }
[ -s harness/dialpark/licence-2seats ] || { echo "FAIL: no harness/dialpark/licence-2seats: issue one with -seats 2 for the same install id"; exit 1; }

start_shell() {
  docker rm -f licence-shell >/dev/null 2>&1 || true
  # The image ships curl: no apk fetch at test time (which not every
  # network allows, 2026-10-29). It runs unprivileged, hence /tmp.
  docker run -d --name licence-shell --network "$NET" -v "$(pwd):/repo:ro" -w /repo --entrypoint sh curlimages/curl:8.11.1 -c 'touch /tmp/ready; sleep 3600' >/dev/null
  until docker exec licence-shell test -f /tmp/ready 2>/dev/null; do sleep 1; done
}
api() { docker exec licence-shell curl -sk -H 'Authorization: Bearer harness' -H 'Content-Type: application/json' "$@"; }
# put FILE — installs the licence in FILE, prints "HTTP <code> <body>"
put() { docker exec licence-shell sh -c "curl -sk -o /tmp/out -w '%{http_code}' -H 'Authorization: Bearer harness' -H 'Content-Type: application/json' -X PUT --data-binary \"{\\\"licence\\\":\\\"\$(tr -d '\n' < $1)\\\"}\" https://dialpark:8081/v1/admin/licence; echo; cat /tmp/out"; }
expect() { # expect "label" "text" "needle" [needle…]
  label="$1"; text="$2"; shift 2
  for n in "$@"; do
    case "$text" in *"$n"*) ;; *) echo "FAIL: $label: expected \"$n\" in: $(printf '%s' "$text" | head -c 500)"; exit 1 ;; esac
  done
}
refuse() { case "$2" in *"$3"*) echo "FAIL: $1: did not expect \"$3\" in: $(printf '%s' "$2" | head -c 500)"; exit 1 ;; esac; }
# licensed DEVICE — "true"/"false" from the status view
licensed() { api https://dialpark:8081/v1/admin/status | tr '}' '\n' | grep "\"device_id\":\"$1\"" | grep -o '"licensed":[a-z]*' | head -n1 | cut -d: -f2; }
# fakeapp DEVICE TOKEN — runs the headless app for a few seconds, prints its log
fakeapp() {
  docker rm -f licence-app >/dev/null 2>&1 || true
  docker run --name licence-app --network "$NET" --entrypoint /fake-app dialpark-harness-dialpark -server dialpark:7443 -device "$1" -token "$2" -kind app -timeout 4s >/dev/null 2>&1 || true
  docker logs licence-app 2>&1 || true
  docker rm -f licence-app >/dev/null 2>&1 || true
}

echo "== up: the dev licence installs through provision.sh"
$COMPOSE up --build -d dialpark >/dev/null 2>&1
sleep 2
out=$(sh harness/innet.sh "$NET" harness/provision.sh 2>&1) || { echo "FAIL: provision: $out"; exit 1; }
expect "provision" "$out" "licence installed"
start_shell

echo "== read: the summary"
s=$(api https://dialpark:8081/v1/admin/licence)
expect "summary" "$s" '"state":"active"' '"seats":25' '"customer":"Dialpark harness"' '"install_id":"dialpark-harness-install-0001"' '"seats_used":6'
echo "ok: 25 seats, 6 in use, active"

echo "== refuse: a bad paste names its reason"
r=$(docker exec licence-shell curl -sk -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer harness' -H 'Content-Type: application/json' -X PUT -d '{"licence":"DP1.not.alicence"}' https://dialpark:8081/v1/admin/licence)
[ "$r" = 400 ] || { echo "FAIL: bad paste answered $r"; exit 1; }
b=$(api -X PUT -d '{"licence":"DP1.not.alicence"}' https://dialpark:8081/v1/admin/licence)
expect "bad paste" "$b" '"error":"invalid"' '"field":"licence"' 'not a licence token'
s=$(api https://dialpark:8081/v1/admin/licence)
expect "after a refusal" "$s" '"seats":25'
echo "ok: 400 invalid, licence untouched"

echo "== shrink: two seats keep the two oldest holders"
out=$(put harness/dialpark/licence-2seats)
expect "shrink" "$out" "200" '"seats":2'
[ "$(licensed dev-a)" = true ] && [ "$(licensed dev-ha)" = true ] || { echo "FAIL: dev-a/dev-ha should keep their seats: $(licensed dev-a) $(licensed dev-ha)"; exit 1; }
[ "$(licensed dev-hb)" = false ] && [ "$(licensed dev-s)" = false ] || { echo "FAIL: dev-hb/dev-s should be suspended"; exit 1; }
echo "ok: dev-a, dev-ha licensed; dev-hb, dev-s, dev-hc, dev-hd suspended"

echo "== gateway: the suspended device is told why; the licensed one connects"
log=$(fakeapp dev-hb tok_dev_hb_harness_fixed)
expect "dev-hb refused" "$log" "no welcome" "unauthorized" "no licence seat"
log=$(fakeapp dev-ha tok_dev_ha_harness_fixed)
refuse "dev-ha connects" "$log" "no welcome"
echo "ok: dev-hb refused with 'no licence seat', dev-ha welcomed"

echo "== enrol: a fixture token with no seat free is 409 no_seats; staging is still allowed"
b=$(api -X POST -d '{"device_id":"dev-x","user":"299","token":"tok_dev_x_harness_fixed"}' https://dialpark:8081/v1/admin/devices)
expect "fixture 409" "$b" '"error":"no_seats"'
b=$(api -X POST -d '{"device_id":"dev-y","user":"298"}' https://dialpark:8081/v1/admin/devices)
expect "staging" "$b" '"device_id":"dev-y"' '"code"'
code=$(echo "$b" | sed -n 's/.*"code":"\([A-Z0-9]*\)".*/\1/p')
r=$(docker exec licence-shell curl -sk -o /tmp/claim -w '%{http_code}' -H 'Content-Type: application/json' -d "{\"code\":\"$code\"}" https://dialpark:8080/v1/enrol)
[ "$r" = 403 ] || { echo "FAIL: claim with no seat answered $r: $(docker exec licence-shell cat /tmp/claim)"; exit 1; }
expect "claim 403" "$(docker exec licence-shell cat /tmp/claim)" '"error":"no_seats"'
echo "ok: 409 on the fixture token, 403 no_seats on the claim, the code is kept"

echo "== restore: the full licence reinstates them, and the kept code now claims"
out=$(put harness/dialpark/licence)
expect "restore" "$out" "200" '"seats":25'
[ "$(licensed dev-hb)" = true ] || { echo "FAIL: dev-hb should be licensed again"; exit 1; }
log=$(fakeapp dev-hb tok_dev_hb_harness_fixed)
refuse "dev-hb connects" "$log" "no welcome"
r=$(docker exec licence-shell curl -sk -o /tmp/claim -w '%{http_code}' -H 'Content-Type: application/json' -d "{\"code\":\"$code\"}" https://dialpark:8080/v1/enrol)
[ "$r" = 200 ] || { echo "FAIL: the kept code should claim once a seat is free: $r $(docker exec licence-shell cat /tmp/claim)"; exit 1; }
s=$(api https://dialpark:8081/v1/admin/licence)
expect "after the claim" "$s" '"seats_used":7'
echo "ok: dev-hb welcomed again; dev-y enrolled with the same code; 7 in use"

echo "== events: the seat changes were recorded"
ev=$(api 'https://dialpark:8081/v1/admin/events?since=0&limit=200')
expect "events" "$ev" '"seat_lost"' '"seat_gained"' '"licence_changed"'

docker rm -f licence-shell >/dev/null 2>&1 || true
echo "ALL PASS"
