#!/bin/sh
# Headless PBX **lines** mode (SPEC §6 item 3c): the light server registers
# one third-party SIP line per device to the PBX instead of being an
# IP-trusted trunk peer. Asterisk stands in for CUCM — it is the only
# exchange available — and what it can and cannot prove is written down in
# the SPEC item; the CUCM-only half is the §7.3 item 10 checklist.
#
#   register: both lines reach a registration the PBX will dial, and the
#         PBX's own OPTIONS keep-alive on them is answered.
#   in:   desk phone 100 dials 211 → Asterisk dials the registered line at
#         the contact our REGISTER advertised (rewrite_contact=no, so a
#         wrong contact fails here rather than being papered over) → app
#         211. Asserts the app recorded the desk phone's tone.
#   out:  app 211 dials 100 → the server's INVITE goes out as line 211 and
#         is CHALLENGED by Asterisk (auth= on the endpoint, as CUCM
#         challenges line-side INVITEs) → desk phone 100. Asserts the desk
#         phone recorded the tone AND that the call arrived as 211 rather
#         than as some shared identity.
#   badpass: one line's credential is replaced with a wrong one through the
#         admin API. That line must latch "refused" and stop — no retry
#         storm — while the other line stays registered and still calls.
#
#   make harness-pbx-lines
#   SCENARIO=register|in|out|badpass make harness-pbx-lines
#   KEEP=1 make harness-pbx-lines    # leave the stack up to poke at
set -eu
cd "$(dirname "$0")/.."

# No published host ports: everything here happens inside the compose
# network, so this is safe to run beside a native `make dev-server`.
COMPOSE="docker compose -f harness/docker-compose.yml -f harness/docker-compose.noports.yml --profile test"
export DIALPARK_PUBLIC_HOST=dialpark

# The PBX becomes a registrar for our lines, and the server presents them.
export ASTERISK_LINES=yes
export DIALPARK_PBX_MODE=lines
# The host part of each line's address of record. An exchange matches the
# registration by the user part, but sending a bare address where a domain
# belongs is the kind of thing a real one rejects.
export DIALPARK_PBX_DOMAIN=asterisk
# Short enough that a refresh happens inside a test run, long enough not to
# be a storm: the refresh is at three quarters of what the PBX grants.
export DIALPARK_PBX_EXPIRY=120s
# A socket per line: each line registers from, and is called on, its own
# port of this range (the first is the trunk listener, so -trunk-addr moves
# with it; 5060-5067 would take in the app leg's 5061). An exchange binds a
# third-party device to the address and port it registers from — CUCM
# accepted one line at a time from the shared socket (2026-10-29) — so the
# register scenario checks the two contacts name different ports.
export DIALPARK_PBX_LINE_PORTS=5070-5077 DIALPARK_TRUNK_ADDR=:5070

NET=dialpark-harness_default
MEDIA_DIR=harness/baresip/media
SCENARIO="${SCENARIO:-all}"
CALL_SECONDS="${CALL_SECONDS:-8}"
KEEP="${KEEP:-0}"

python3 harness/baresip/media/gen_tone.py "$MEDIA_DIR/in.wav" >/dev/null
rm -f "$MEDIA_DIR"/out-*.wav

cleanup() { [ "$KEEP" = 1 ] || $COMPOSE down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== up: server in lines mode, asterisk as a registrar, apps 211/212, desk phone 100"
$COMPOSE up --build -d dialpark asterisk >/dev/null 2>&1
sleep 2
# PBX_LINES=1 seeds the two line credentials the PBX config expects.
PBX_LINES=1 sh harness/innet.sh "$NET" harness/provision.sh >/dev/null
# The server reads its lines at start-up, so it has to come back to pick up
# credentials provisioned after it. (An admin write to a running server
# registers that line at once — that is what the badpass scenario uses.)
$COMPOSE restart dialpark >/dev/null 2>&1
sleep 3
$COMPOSE up --build -d baresip-a baresip-b baresip-c >/dev/null 2>&1
sleep 6

ctl() { # phone json
  docker run --rm --network "$NET" alpine:3.20 sh -c \
    "p='$2'; len=\$(printf %s \"\$p\" | wc -c | tr -d ' '); printf '%s:%s,' \"\$len\" \"\$p\" | nc -w2 $1 4444 >/dev/null"
}

set_line() { # device digest_user secret
  sh harness/innet.sh "$NET" harness/set_pbx_line.sh "$1" "$2" "$3" >/dev/null
}

fail=0

# ---- register ---------------------------------------------------------------
# Both halves matter. The server must think it registered, and the exchange
# must hold a contact it is willing to dial — the two can disagree, and only
# the second is what a call depends on.
if [ "$SCENARIO" = register ] || [ "$SCENARIO" = all ]; then
  echo "== register: both lines registered to the PBX"
  i=0
  until [ "$($COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -c 'pbx line: registered')" -ge 2 ]; do
    i=$((i+1)); [ $i -le 40 ] || break
    sleep 1
  done
  ok=1
  port211=""; port212=""
  for line in 211 212; do
    if $COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -q "pbx line: registered.*dn=$line"; then
      echo "   the server registered line $line"
    else
      echo "   FAIL: the server never registered line $line"; ok=0
    fi
    # `pjsip show contacts`, not `show aor`: the AOR view does not list the
    # bindings a REGISTER created, which is the thing a call depends on.
    contacts="$($COMPOSE exec -T asterisk asterisk -rx "pjsip show contacts" 2>/dev/null || true)"
    if printf '%s' "$contacts" | grep -q "$line/sip:$line@172.30.0.10"; then
      echo "   the PBX holds a contact for $line: $(printf '%s' "$contacts" | grep -o "$line/sip:[^ ]*" | head -1)"
    else
      echo "   FAIL: the PBX has no contact for line $line"
      printf '%s\n' "$contacts" | tail -6 | sed 's/^/   asterisk: /'; ok=0
    fi
    eval "port$line=\"$(printf '%s' "$contacts" | grep -o "$line/sip:$line@172.30.0.10:[0-9]*" | head -1 | sed 's/.*://')\""
  done
  # A socket per line (DIALPARK_PBX_LINE_PORTS): the two contacts the PBX
  # holds name different ports of the range, and each REGISTER left from
  # the port it advertised (the PBX's own OPTIONS go to that port, below).
  case "$port211:$port212" in
    507[0-7]:507[0-7])
      if [ "$port211" = "$port212" ]; then
        echo "   FAIL: both lines registered from port $port211; a socket per line was expected"; ok=0
      else
        echo "   the lines registered from their own sockets: 211 on $port211, 212 on $port212"
      fi;;
    *) echo "   FAIL: contact ports $port211/$port212 are not in the line port range 5070-5077"; ok=0;;
  esac
  if ! $COMPOSE logs --no-log-prefix dialpark 2>&1 | grep "pbx line: registered.*dn=212" | grep -q "port=$port212"; then
    echo "   FAIL: the server's registration log for 212 does not name port $port212"; ok=0
  fi
  # The exchange polls a registered line like any phone, and drops a contact
  # that stops answering. Our trunk listener must answer those OPTIONS.
  i=0
  until $COMPOSE logs --no-log-prefix asterisk 2>&1 | grep -q "is now Reachable"; do
    i=$((i+1)); [ $i -le 20 ] || { echo "   FAIL: the PBX never qualified a line as reachable (OPTIONS unanswered)"; ok=0; break; }
    sleep 1
  done
  # The exchange tells every registered line about its mailbox with an
  # unsolicited message-summary NOTIFY (RFC 3842) — CUCM on each REGISTER,
  # Asterisk once the endpoint has a mailbox (voicemail.conf) — and expects
  # 200 OK. Until 2026-10-17 diago answered these 400 Bad Request, which
  # CUCM logged against the line.
  i=0
  until $COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -q "pbx: message waiting.*line=211"; do
    i=$((i+1)); [ $i -le 20 ] || break
    sleep 1
  done
  if $COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -q "pbx: message waiting.*line=211"; then
    echo "   the PBX's message-waiting NOTIFY for line 211 was answered 200: $($COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -o 'message waiting.*line=211.*' | head -1 | sed 's/source=.*//')"
  else
    echo "   FAIL: no message-waiting NOTIFY for line 211 was answered"
    $COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -i notify | tail -3 | sed 's/^/   /'; ok=0
  fi
  if $COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -q 'Failed to handle request.*req.method=NOTIFY'; then
    echo "   FAIL: a NOTIFY still fell through to diago and was answered 400"; ok=0
  fi
  [ "$ok" = 1 ] && echo "PASS register" || { echo "FAIL register"; fail=1; }
fi

# ---- in ---------------------------------------------------------------------
if [ "$SCENARIO" = in ] || [ "$SCENARIO" = all ]; then
  echo "== in: desk phone 100 dials 211 (the PBX dials our registered line)"
  rm -f "$MEDIA_DIR/out-211.wav"
  ctl baresip-c '{"command":"dial","params":"211@asterisk"}'
  sleep "$CALL_SECONDS"
  ctl baresip-c '{"command":"hangup"}'
  sleep 2
  $COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -E 'invite|callee answered|bridged|call ended|level=(ERROR|WARN)' | tail -6 | sed 's/^/   /'
  if python3 harness/spike/assert_audio.py "$MEDIA_DIR/out-211.wav" --reference "$MEDIA_DIR/in.wav" \
       --max-gap-ms "${MAX_GAP_MS:-0}" --max-gaps "${MAX_GAPS:-0}"; then
    echo "PASS in: the app heard the desk phone through its registered line"
  else
    echo "FAIL in"; fail=1
    $COMPOSE logs --no-log-prefix asterisk 2>&1 | grep -iE "211|error|warn" | tail -8 | sed 's/^/   asterisk: /'
  fi
fi

# ---- out --------------------------------------------------------------------
# The identity assertion is the point of this one. A trunk call can go out
# under any From the peer tolerates; a line call must arrive as that line,
# or the exchange puts the wrong name on the callee's phone and the wrong
# number in its records.
if [ "$SCENARIO" = out ] || [ "$SCENARIO" = all ]; then
  echo "== out: app 211 dials 100 — the INVITE is challenged and must arrive as line 211"
  rm -f "$MEDIA_DIR/out-100.wav"
  MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ctl baresip-a '{"command":"dial","params":"100@dialpark"}'
  sleep "$CALL_SECONDS"
  ctl baresip-a '{"command":"hangup"}'
  sleep 2
  $COMPOSE logs --no-log-prefix dialpark 2>&1 | grep -E 'invite|callee answered|bridged|call ended|level=(ERROR|WARN)' | tail -6 | sed 's/^/   /'
  ok=1
  if python3 harness/spike/assert_audio.py "$MEDIA_DIR/out-100.wav" --reference "$MEDIA_DIR/in.wav" \
       --max-gap-ms "${MAX_GAP_MS:-0}" --max-gaps "${MAX_GAPS:-0}"; then
    echo "   the desk phone heard the app"
  else
    echo "   FAIL: the desk phone heard nothing"; ok=0
  fi
  alog="$($COMPOSE logs --no-log-prefix --since "$MARK" asterisk 2>&1)"
  if printf '%s' "$alog" | grep -q "PJSIP/211-"; then
    echo "   the PBX saw the call on endpoint 211 — the calling line, not a shared identity"
  else
    echo "   FAIL: the PBX did not attribute the call to line 211"
    printf '%s\n' "$alog" | grep -iE "invite|unauthor|endpoint|100" | tail -8 | sed 's/^/   asterisk: /'; ok=0
  fi
  # That this call was CHALLENGED, rather than reaching an endpoint which
  # accepts anything, is proved by the badpass scenario below: the same call
  # with a wrong credential must be refused by the PBX.
  [ "$ok" = 1 ] && echo "PASS out" || { echo "FAIL out"; fail=1; }
fi

# ---- badpass ----------------------------------------------------------------
if [ "$SCENARIO" = badpass ] || [ "$SCENARIO" = all ]; then
  echo "== badpass: line 211's credential is replaced with a wrong one"
  MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  set_line dev-ha line211 wrong-on-purpose
  sleep 8
  blog="$($COMPOSE logs --no-log-prefix --since "$MARK" dialpark 2>&1)"
  ok=1
  if printf '%s' "$blog" | grep -q "pbx line: refused"; then
    echo "   line 211 latched refused"
  else
    echo "   FAIL: a wrong credential did not produce a refusal"
    printf '%s\n' "$blog" | grep -i "pbx line" | tail -5 | sed 's/^/   /'; ok=0
  fi
  # Once, not once a second: devices retrying a bad password is how an
  # account gets locked out on a real exchange.
  n="$(printf '%s' "$blog" | grep -c "pbx line: refused" || true)"
  if [ "$n" -le 1 ]; then
    echo "   and said so once, not in a retry storm"
  else
    echo "   FAIL: the refusal repeated $n times in 8 s"; ok=0
  fi

  # The other half of the credential path, and the thing that makes the
  # "out" scenario mean something: the PBX challenges INVITEs too, so the
  # same outbound call now has to be REFUSED. If this passes with a wrong
  # password, the endpoint accepts anything and "out" proved nothing.
  echo "   outbound from 211 must now be refused by the PBX"
  rm -f "$MEDIA_DIR/out-100.wav"
  IMARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ctl baresip-a '{"command":"dial","params":"100@dialpark"}'
  sleep 6
  ctl baresip-a '{"command":"hangup"}'
  sleep 2
  if python3 harness/spike/assert_audio.py "$MEDIA_DIR/out-100.wav" >/dev/null 2>&1; then
    echo "   FAIL: the call went through with a wrong credential — the PBX is not challenging INVITEs"; ok=0
  elif $COMPOSE logs --no-log-prefix --since "$IMARK" asterisk 2>&1 | grep -q "Failed to authenticate"; then
    echo "   the PBX refused the INVITE (Failed to authenticate)"
  else
    echo "   FAIL: the call did not complete, but the PBX did not say why"
    $COMPOSE logs --no-log-prefix --since "$IMARK" asterisk 2>&1 | tail -6 | sed 's/^/   asterisk: /'; ok=0
  fi

  # An admin action affects one device (§4.8): 212 is still registered and
  # still takes calls.
  if printf '%s' "$blog" | grep -q "dn=212"; then
    echo "   FAIL: line 212 was disturbed by a write to 211"; ok=0
  fi
  rm -f "$MEDIA_DIR/out-212.wav"
  ctl baresip-c '{"command":"dial","params":"212@asterisk"}'
  sleep "$CALL_SECONDS"
  ctl baresip-c '{"command":"hangup"}'
  sleep 2
  if python3 harness/spike/assert_audio.py "$MEDIA_DIR/out-212.wav" --reference "$MEDIA_DIR/in.wav" \
       --max-gap-ms "${MAX_GAP_MS:-0}" --max-gaps "${MAX_GAPS:-0}"; then
    echo "   line 212 was untouched and still takes calls"
  else
    echo "   FAIL: line 212 stopped working when 211's credential broke"; ok=0
  fi

  # And the administrator's correction is picked up at once, not at a
  # refresh interval that a refused line is no longer running.
  RMARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  set_line dev-ha line211 linepass-211
  sleep 5
  if $COMPOSE logs --no-log-prefix --since "$RMARK" dialpark 2>&1 | grep -q "pbx line: registered.*dn=211"; then
    echo "   the corrected credential registered line 211 again"
  else
    echo "   FAIL: line 211 did not come back after the credential was fixed"
    $COMPOSE logs --no-log-prefix --since "$RMARK" dialpark 2>&1 | grep -i "pbx line" | tail -4 | sed 's/^/   /'; ok=0
  fi
  [ "$ok" = 1 ] && echo "PASS badpass" || { echo "FAIL badpass"; fail=1; }
fi

[ "$fail" = 0 ] || { echo "SOME SCENARIOS FAILED"; exit 1; }
echo "ALL PASS"
