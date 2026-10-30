#!/bin/sh
# Every state a client can be in, and what the admin UI says about it
# (SPEC §6 item 9c). The real server and the real UI, driven with curl
# inside the compose network; the phone is played by the enrol API, the
# fake app (gateway sessions) and baresip (SIP registration). Two phases:
# trunk mode for the enrolment lifecycle, lines mode for the PBX line
# column. Each step asserts the Clients row and, where it matters, the
# client page. Exit 0 = pass.
set -eu
cd "$(dirname "$0")/.."
COMPOSE="docker compose -f harness/docker-compose.yml -f harness/docker-compose.noports.yml --profile test"
export DIALPARK_PUBLIC_HOST=dialpark
NET=dialpark-harness_default
KEEP="${KEEP:-0}"
cleanup() { [ "$KEEP" = 1 ] || $COMPOSE down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

# One container holds the browser session; helpers run a shell inside it.
# It is started once per phase and torn down with the stack.
start_browser() {
  docker rm -f states-browser >/dev/null 2>&1 || true
  # The image ships curl (no apk fetch at test time, which not every
  # network allows) and runs unprivileged, hence the jar under /tmp.
  docker run -d --name states-browser --network "$NET" --entrypoint sh curlimages/curl:8.11.1 -c 'touch /tmp/ready; sleep 3600' >/dev/null
  until docker exec states-browser test -f /tmp/ready 2>/dev/null; do sleep 1; done
  docker exec states-browser curl -sk -c /tmp/jar -b /tmp/jar -o /dev/null -d "username=admin&password=harness" https://admin:8443/login
}
ui() { docker exec states-browser curl -sk -c /tmp/jar -b /tmp/jar "$@"; }
csrf() { ui https://admin:8443/clients | sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' | head -n1; }
api() { docker exec states-browser curl -sk -H 'Authorization: Bearer harness' -H 'Content-Type: application/json' "$@"; }
# row EXT — the Clients table row for that extension, tags stripped to text.
row() { ui https://admin:8443/clients | awk -v ext=">$1</a>" 'BEGIN{RS="</tr>"} index($0,ext){print}' | sed 's/<[^>]*>/ /g; s/  */ /g'; }
page() { ui "https://admin:8443/clients/$1" | sed 's/<[^>]*>/ /g; s/  */ /g'; }
expect() { # expect "label" "text" "needle" [needle…]
  label="$1"; text="$2"; shift 2
  for n in "$@"; do
    case "$text" in *"$n"*) ;; *) echo "FAIL: $label: expected \"$n\" in: $(printf '%s' "$text" | head -c 400)"; exit 1 ;; esac
  done
}
refuse() { # refuse "label" "text" "needle" — the text must NOT contain it
  case "$2" in *"$3"*) echo "FAIL: $1: did not expect \"$3\" in: $(printf '%s' "$2" | head -c 400)"; exit 1 ;; esac
}
fakeapp() { # fakeapp NAME DEVICE TOKEN KIND — a gateway session held for 40 s
  docker rm -f "$1" >/dev/null 2>&1 || true
  docker run -d --name "$1" --network "$NET" --entrypoint /fake-app dialpark-harness-dialpark -server dialpark:7443 -device "$2" -token "$3" -kind "$4" -timeout 40s >/dev/null
}

echo "== phase 1: trunk mode — the enrolment lifecycle"
$COMPOSE up --build -d dialpark >/dev/null 2>&1
sleep 2
sh harness/innet.sh "$NET" harness/provision.sh >/dev/null
$COMPOSE up -d admin >/dev/null 2>&1
sleep 2
start_browser
CSRF="$(csrf)"
[ -n "$CSRF" ] || { echo "FAIL: no csrf"; exit 1; }

# S1 created, code not yet claimed
loc=$(ui -o /dev/null -w '%{redirect_url}' -d "csrf=$CSRF&user=301&description=Lifecycle" https://admin:8443/clients)
ID=$(echo "$loc" | sed -n 's|.*/clients/\(dev_[A-Z0-9]*\)/code.*|\1|p')
[ -n "$ID" ] || { echo "FAIL: add client: $loc"; exit 1; }
CODE=$(ui "$loc" | sed -n 's/.*<p class="bigcode">\([A-Z0-9]*\)<.*/\1/p' | head -n1)
r=$(row 301); expect "S1 created" "$r" "Offline" "Not enrolled" "code valid until"; refuse "S1" "$r" "Registered"
p=$(page "$ID"); expect "S1 page" "$p" "Not enrolled yet" "none yet: the phone claims one with its code" "pending, valid until"
echo "ok: S1 created, not enrolled: Offline / — / — / Not enrolled + code"

# S2 the phone claims the code (enrolled, nothing connected)
claim=$(docker exec states-browser curl -sk -H 'Content-Type: application/json' -d "{\"code\":\"$CODE\"}" https://dialpark:8080/v1/enrol)
TOKEN=$(echo "$claim" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
[ -n "$TOKEN" ] || { echo "FAIL: claim: $claim"; exit 1; }
r=$(row 301); expect "S2 enrolled" "$r" "Offline" "Enrolled"; refuse "S2" "$r" "Not enrolled"; refuse "S2" "$r" "code valid"
p=$(page "$ID"); expect "S2 page" "$p" "issued" "none outstanding"
echo "ok: S2 enrolled, offline: Offline / — / — / Enrolled, no code"

# S3 only the wake extension connected
fakeapp states-ext "$ID" "$TOKEN" extension; sleep 2
r=$(row 301); expect "S3 wake only" "$r" "Wake only" "Enrolled"
p=$(page "$ID"); expect "S3 page" "$p" "Wake extension" "Connected"
docker rm -f states-ext >/dev/null
echo "ok: S3 extension only: Wake only"

# S4 the app connected
fakeapp states-app "$ID" "$TOKEN" app; sleep 2
r=$(row 301); expect "S4 app" "$r" "App fake-app" "Enrolled"; refuse "S4" "$r" "Registered"
docker rm -f states-app >/dev/null; sleep 1
r=$(row 301); expect "S4 gone" "$r" "Offline"
echo "ok: S4 app connected then gone: App fake-app → Offline"

# S5 SIP registered (baresip as dev-ha/211): the gateway is not involved, so
#    the phone column stays Offline while SIP says Registered.
r=$(row 211); expect "S5 before" "$r" "Offline" "Enrolled"; refuse "S5 before" "$r" "Registered"
$COMPOSE up -d baresip-a >/dev/null 2>&1; sleep 5
r=$(row 211); expect "S5 registered" "$r" "Registered" "Enrolled"
p=$(page dev-ha); expect "S5 page" "$p" "Registered until"
$COMPOSE stop baresip-a >/dev/null 2>&1; sleep 2
r=$(row 211); refuse "S5 unregistered" "$r" "Registered"
echo "ok: S5 SIP registered then unregistered (phone column unaffected)"

# S6 a PBX line configured while the server is in trunk mode
api -X PUT "https://dialpark:8081/v1/admin/devices/$ID/pbx-line" -d '{"digest_user":"line301","secret":"dialpark-line-301"}' >/dev/null
r=$(row 301); expect "S6 line stored" "$r" "stored"
p=$(page "$ID"); expect "S6 page" "$p" "stored; the server is in trunk mode"
echo "ok: S6 line in trunk mode: stored"

# S7 revoked from the UI
ui -o /dev/null -d "csrf=$CSRF" "https://admin:8443/clients/$ID/revoke"
r=$(row 301); expect "S7 revoked" "$r" "Revoked" "Offline" "stored"; refuse "S7" "$r" "Enrolled"; refuse "S7" "$r" "Registered"
# the credential is dead: the phone cannot connect
docker run --rm --network "$NET" --entrypoint /fake-app dialpark-harness-dialpark -server dialpark:7443 -device "$ID" -token "$TOKEN" -kind app -timeout 3s >/dev/null 2>&1 && { echo "FAIL: S7: a revoked credential still connects"; exit 1; }
echo "ok: S7 revoked: Revoked, credential refused"

# S8 a new code on a revoked client shows beside Revoked
loc=$(ui -o /dev/null -w '%{redirect_url}' -d "csrf=$CSRF" "https://admin:8443/clients/$ID/code")
CODE=$(ui "$loc" | sed -n 's/.*<p class="bigcode">\([A-Z0-9]*\)<.*/\1/p' | head -n1)
[ -n "$CODE" ] || { echo "FAIL: S8 code"; exit 1; }
r=$(row 301); expect "S8 revoked+code" "$r" "Revoked" "code valid until"
echo "ok: S8 revoked with a new code: Revoked + code"

# S9 the replacement phone claims it: un-revoked, line kept
claim=$(docker exec states-browser curl -sk -H 'Content-Type: application/json' -d "{\"code\":\"$CODE\"}" https://dialpark:8080/v1/enrol)
echo "$claim" | grep -q '"token"' || { echo "FAIL: S9 claim: $claim"; exit 1; }
r=$(row 301); expect "S9 re-enrolled" "$r" "Enrolled" "stored"; refuse "S9" "$r" "Revoked"
echo "ok: S9 re-enrolled by claim: Enrolled, line still stored"

# S10 "the app un-enrolled itself": nothing reaches the server; it looks
#     like S2 (Enrolled, Offline) until the operator revokes or re-enrols.
r=$(row 301); expect "S10" "$r" "Enrolled" "Offline"
echo "ok: S10 app-side un-enrol is invisible to the server: still Enrolled, Offline (by design)"

# S11 purged: gone
ui -o /dev/null -d "csrf=$CSRF&confirm=$ID" "https://admin:8443/clients/$ID/purge"
if ui https://admin:8443/clients | grep -q ">301</a>"; then echo "FAIL: S11: purged client still listed"; exit 1; fi
[ "$(ui -o /dev/null -w '%{http_code}' "https://admin:8443/clients/$ID")" = 404 ] || { echo "FAIL: S11: purged client page not 404"; exit 1; }
echo "ok: S11 purged: gone"
docker rm -f states-browser >/dev/null 2>&1
$COMPOSE down -v >/dev/null 2>&1

echo "== phase 2: lines mode — the PBX line column"
export ASTERISK_LINES=yes DIALPARK_PBX_MODE=lines DIALPARK_PBX_DOMAIN=asterisk DIALPARK_PBX_EXPIRY=120s DIALPARK_PBX_LINE_PORTS=5070-5077 DIALPARK_TRUNK_ADDR=:5070
$COMPOSE up --build -d dialpark asterisk >/dev/null 2>&1
sleep 2
PBX_LINES=1 sh harness/innet.sh "$NET" harness/provision.sh >/dev/null
# Lines are read at start: restart the server so it registers them.
$COMPOSE restart dialpark >/dev/null 2>&1
$COMPOSE up -d admin >/dev/null 2>&1
sleep 6
start_browser
CSRF="$(csrf)"

# L1 a line that registers
r=$(row 211); expect "L1 registered" "$r" "registered"
p=$(page dev-ha); expect "L1 page" "$p" "registered" "realm"
echo "ok: L1 line registered"
# L2 no line at all
r=$(row 203); refuse "L2 no line" "$r" "registered"; refuse "L2" "$r" "stored"
echo "ok: L2 no line: —"
# L3 a wrong secret latches refused
api -X PUT https://dialpark:8081/v1/admin/devices/dev-hb/pbx-line -d '{"digest_user":"line212","secret":"wrong"}' >/dev/null
sleep 4
r=$(row 212); expect "L3 refused" "$r" "refused"
p=$(page dev-hb); expect "L3 page" "$p" "refused"
echo "ok: L3 wrong secret: refused"
# L4 the right secret again registers
api -X PUT https://dialpark:8081/v1/admin/devices/dev-hb/pbx-line -d '{"digest_user":"line212","secret":"linepass-212"}' >/dev/null
sleep 4
r=$(row 212); expect "L4 registered again" "$r" "registered"
echo "ok: L4 secret fixed: registered"
# L5 revoking drops the registration; the line stays stored
ui -o /dev/null -d "csrf=$CSRF" https://admin:8443/clients/dev-hb/revoke
sleep 2
r=$(row 212); expect "L5 revoked" "$r" "Revoked" "stored"; refuse "L5" "$r" "registered"
echo "ok: L5 revoked: line unregistered, stored"
# L6 removing the line
api -X DELETE https://dialpark:8081/v1/admin/devices/dev-ha/pbx-line >/dev/null
sleep 2
r=$(row 211); refuse "L6 removed" "$r" "registered"; refuse "L6" "$r" "stored"
echo "ok: L6 line removed: —"
docker rm -f states-browser >/dev/null 2>&1
echo "ALL CLIENT STATES CONSISTENT"
