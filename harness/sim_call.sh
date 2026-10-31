#!/bin/sh
# The app's call path, end to end, with no phone and no human: the real
# engine + audiounit driver run on the iOS simulator (a process spawned
# inside the simulator is not subject to the sandbox that blocks this shell
# from reaching localhost), register through the docker server, phone-b
# dials in and plays a tone, and the result is asserted on what the
# simulated phone received: RTP packets and the energy of the rendered
# audio. Loss/jitter/jitter-buffer counters make blips visible too.
#
#   make harness-up                      # once (advertises this Mac's en0 address)
#   make sim-call                        # PASS / PASS with GAPS / FAIL: <why>
#   ACTIVATE_MS=1500 make sim-call       # CallKit activation after establishment
#   SIM="iPhone 16 Pro" make sim-call
set -eu
cd "$(dirname "$0")/.."
SIM="${SIM:-iPhone 16}"
# The address the server advertises for SIP and media. It must be reachable
# both from the simulated phone (this Mac) and from the caller inside the
# docker network, so it is this Mac's LAN address, not localhost: with
# 127.0.0.1 the caller's media would be sent to the container's own loopback.
HOST="${HOST:-$(ipconfig getifaddr en0 2>/dev/null || ifconfig en0 2>/dev/null | awk '/inet /{print $2; exit}')}"
[ -n "$HOST" ] || { echo "FAIL: cannot determine this Mac's LAN address; set HOST=..."; exit 1; }
ACTIVATE_MS="${ACTIVATE_MS:-150}"
# Ringing time before the scripted user answers. A person takes seconds,
# and the caller streams into the server the whole time (ANSWER_MS=8000
# reproduces the device's long ring).
ANSWER_MS="${ANSWER_MS:-800}"
# Calls taken by ONE simulated phone process (the app takes many per
# launch; CALLS=2 reproduces "first call fine, second silent").
CALLS="${CALLS:-1}"
WAIT="${WAIT:-$((30 * CALLS + 15))}"
# A simctl-spawned process has no microphone, so by default the simulated
# phone transmits a tone file instead — a real phone transmits, and that
# is what makes the server latch its symmetric RTP onto the phone's source
# address. SIM_SOURCE=mic uses the (absent) microphone, i.e. no transmit.
TONE="$(pwd)/harness/baresip/media/in.wav"
case "${SIM_SOURCE:-tone}" in
  mic)  SOURCE="" ;;
  tone) SOURCE="aufile,$TONE" ;;
  *)    SOURCE="$SIM_SOURCE" ;;
esac
SCRATCH="${TMPDIR:-/tmp}/spm-build-ios"
IOS_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
OUT="${TMPDIR:-/tmp}/sim-call.log"
C="docker compose -f harness/docker-compose.yml --profile test"
NET=dialpark-harness_default
# The server must advertise an address the simulated phone can reach for SIP
# and media; localhost works because Docker publishes those ports there.
# Exported so every compose invocation below sees the same config — a
# differing value makes `compose up` recreate the server mid-test.
export DIALPARK_PUBLIC_HOST="$HOST"

echo "== build sim-call for the simulator"
# SwiftPM writes module caches under ~/Library by default, which the build
# sandbox refuses — including for the manifest compile, so the package
# cannot even be read without these (2026-09-16).
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/spm-modcache"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/clang-modcache"
( cd ios/DiallerEngine && swift build --disable-sandbox --scratch-path "$SCRATCH" \
    --triple arm64-apple-ios17.0-simulator --sdk "$IOS_SDK" --product sim-call 2>&1 \
  | grep -E 'error|Build of' || true )
# SwiftPM's scratch layout moved with the Xcode that ships Swift 6.4 (flat
# `debug/`); older toolchains used `<triple>/debug/`. Take whichever exists
# so this keeps working across an update (2026-09-16).
BIN="$SCRATCH/debug/sim-call"
[ -x "$BIN" ] || BIN="$SCRATCH/arm64-apple-ios-simulator/debug/sim-call"
[ -x "$BIN" ] || { echo "FAIL: $BIN not built"; exit 1; }

# SERVER=native: the server runs on this Mac (`make dev-server`); only the
# docker caller is started, registered to it over outbound NAT.
#
# What this run starts, it tears down on exit (KEEP=1 to leave it up for a
# look); a harness the user brought up themselves (`make harness-up`) is
# left alone. A harness left running after a test has captured the user's
# phone twice — with the native server stopped, the iPhone registers to the
# docker server through the published ports and takes, or loses, the calls
# (2026-09-18) — so nothing that publishes 5061/7443 may outlive the test
# that needed it.
STARTED=0
SERVER="${SERVER:-docker}"
if [ "$SERVER" = native ]; then
  echo "== native server at $HOST (make dev-server); starting the docker caller only"
  STARTED=1
  BARESIP_B_OUTBOUND="$HOST:5061" $C up -d --no-deps --force-recreate baresip-b >/dev/null 2>&1
elif docker ps --format '{{.Names}}' | grep -q '^dialpark-harness-dialpark-1$'; then
  # Leave a running server alone (its flags, e.g. -log-level, were chosen
  # by whoever started it); a plain `up` would recreate it with defaults.
  echo "== server already running (leaving it as is)"
  # phone-b is (re)created once, below, when it is the callee.
  [ -n "${OUTBOUND:-}" ] || $C up -d --no-deps baresip-b >/dev/null 2>&1
else
  echo "== server advertising $HOST"
  STARTED=1
  # --build: the other suites rebuild the server image; without it this one
  # ran whatever image was last built (a stale one failed Phase F for an
  # hour, 2026-09-13).
  $C up -d --build dialpark baresip-b >/dev/null 2>&1
  # A server we started has an empty data volume (a previous test's
  # `down -v` removed it): enrol the dev devices and seed the directory,
  # or every registration is refused as an unknown device.
  sleep 2
  sh harness/innet.sh "$NET" harness/provision.sh >/dev/null
fi

# REFUSED needs a PBX behind the trunk: the point is a real refusal from the
# far end, and with no Asterisk the INVITE only runs into Timer B — the
# "refusal" is then a 32 s timeout wearing the same clothes (which is
# silently what it was until 2026-09-15). Outside the branches above: in
# `sim-call-all` the server is already up from the previous run, so the
# branch that starts it never runs.
[ -z "${REFUSED:-}" ] || [ "$SERVER" = native ] || $C up -d --no-deps asterisk >/dev/null 2>&1
sleep 2

if [ -n "${OUTBOUND:-}" ] && [ "$OUTBOUND" != echo ] && [ "$OUTBOUND" != 600 ]; then
  # The simulated phone dials phone-b the moment it registers, so phone-b
  # must already hold a live registration with THIS server instance:
  # recreate it and wait for that registration BEFORE the phone starts.
  # (echo / 600 need no callee: the server or the PBX answers.)
  echo "== phone-b (212) must be registered (callee)"
  MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ "$SERVER" = native ]; then
    BARESIP_B_OUTBOUND="$HOST:5061" $C up -d --no-deps --force-recreate baresip-b >/dev/null 2>&1
    sleep 4
  else
    $C up -d --no-deps --force-recreate baresip-b >/dev/null 2>&1
    i=0
    until $C logs --no-log-prefix --since "$MARK" dialpark 2>/dev/null | grep -q 'sip register" user=212'; do
      i=$((i+1)); [ $i -le 25 ] || { echo "FAIL: phone-b did not register within 25s"; exit 1; }
      sleep 1
    done
  fi
  echo "   phone-b registered"
fi

# IMPAIR=1: 2 % loss and 30 ± 10 ms jitter on everything the docker server
# sends (harness/netem), so the simulated phone's decoder has to conceal.
# Started last — a later `up` recreating the server would strand the
# shaper in a dead namespace. The sim is told, so a lossy verdict is not
# a failure in that run.
if [ "${IMPAIR:-0}" = 1 ]; then
  [ "$SERVER" = native ] && { echo "FAIL: IMPAIR=1 needs the docker server"; exit 1; }
  docker compose -f harness/docker-compose.yml --profile impair up --build -d netem >/dev/null 2>&1
  sleep 1
  echo "== impaired: $(docker compose -f harness/docker-compose.yml --profile impair logs --no-log-prefix netem 2>&1 | grep 'netem applied' | tail -1)"
  export SIMCTL_CHILD_IMPAIRED=1
fi

echo "== simulator $SIM"
xcrun simctl boot "$SIM" 2>/dev/null || true
: > "$OUT"
# GATEWAY=no: no wire-protocol session, so no wake; calls ring from the INVITE.
# OUTBOUND=212 (or any target): the simulated phone dials phone-b, which
# auto-answers and plays its tone — the keypad / directory path.
MODE=""; [ "${GATEWAY:-yes}" = no ] && MODE=nogateway
[ -n "${OUTBOUND:-}" ] && MODE="outbound:$OUTBOUND"
SIGNAL_PORT="${SIGNAL_PORT:-${DIALPARK_SIGNAL_HOSTPORT:-7443}}"
# HOLD_MS=3000: hold the call for 3 s after the first verdict, then resume;
# asserts media stops while held and flows again after.
# TRANSFER=echo: after the first verdict the simulated phone REFERs the
# caller (phone-b) to "echo"; our call must end as transferred, and phone-b's
# recording must then contain audio it did not get from us (its own echo).
if [ -n "${TRANSFER:-}" ]; then SOURCE=""; fi   # silent phone, so any audio phone-b records is the echo
# DECLINE=1: the simulated phone rejects each call from the CallKit banner
# (the red button) after ANSWER_MS of ringing. Asserts the caller (phone-b)
# is told 486 Busy Here — not 480, which PBXs and phones show as "no
# response" — and that our side never established the call.
# DECLINE_RESET=1: the same, and the SIP transports are reset the instant
# the decline is sent — the 486's ACK then lands on a connection the reset
# has torn down. That crashed the app (SIGSEGV in libre's receive handler,
# 2026-09-17 16:29). Pair with IMPAIR=1: the 30 ms the server's packets are
# held makes the ACK certain to arrive after the reset. The verdict is the
# process living to report at all.
# RING_RESET=1: the registration reset the app runs when its gateway session
# comes back is issued while the call rings, as on 2026-09-18 15:12 when the
# INVITE was read 0.3 ms after the app's "no call is up" check and the reset
# freed the user agent under it (486: the caller was told the call failed).
# The stack must refuse the reset ("registration reset refused by the
# stack") and the call must be answered as in the plain run.
KIND=""
[ -n "${DECLINE:-}" ] && KIND=decline
[ -n "${DECLINE_RESET:-}" ] && { DECLINE=1; KIND=decline-reset; }
[ -n "${RING_RESET:-}" ] && KIND=ring-reset
if [ -n "${DECLINE:-}" ]; then SOURCE=""; fi
# REFUSED=1 (with OUTBOUND=<target the server will refuse>): the far end
# refuses our outgoing call, and the caller must hear busy or congestion
# BEFORE the call disappears — the end report is held back for the length
# of the tone, because CallKit takes the audio session away with the call
# (plan Phase J). Asserted in the sim, which times the two.
if [ -n "${REFUSED:-}" ]; then SOURCE=""; fi
# dev-s / 203: the simulator's own enrolment (harness/provision.sh), so a
# real phone registered as dev-a / 201 to this server never takes its calls.
# CALLWAITING=1: phone-b calls first; once that call is up, phone-a (211)
# calls too. The simulated phone takes it with Hold & Accept, swaps back,
# and ends both; asserted in the sim (RTP per active call, two stack ids)
# and on phone-a's recording (it heard the sim while it was the active call).
[ -z "${CALL_SECONDS:-}" ] || export SIMCTL_CHILD_CALL_SECONDS="$CALL_SECONDS" # lab: longer calls
xcrun simctl spawn "$SIM" "$BIN" "$HOST" "$SIGNAL_PORT" dev-s tok_dev_s_harness_fixed "$WAIT" "$ACTIVATE_MS" "$SOURCE" "$ANSWER_MS" "$CALLS" "$MODE" "${HOLD_MS:-0}" "${TRANSFER:-}" "${KIND}${CALLWAITING:+callwaiting}${REFUSED:+refused}" > "$OUT" 2>&1 &
PID=$!
cleanup() {
  kill $PID 2>/dev/null || true
  if [ "$STARTED" = 1 ] && [ "${KEEP:-0}" != 1 ]; then
    $C --profile impair down -v >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

i=0
until grep -q 'sim: registered' "$OUT"; do
  i=$((i+1)); [ $i -le 30 ] || { echo "FAIL: simulated phone did not register within 30s"; grep -E 'sim:|engine:' "$OUT" | sed 's/^/   /'; exit 1; }
  grep -q 'sim: FAIL\|sim: gateway error' "$OUT" && { grep -E 'sim:|engine:' "$OUT" | sed 's/^/   /'; exit 1; }
  sleep 1
done
echo "   registered as 203 (dev-s)"

# RESTART_SERVER=1: restart the server under the registered app. The app
# must reconnect its gateway session on its own (backoff), get a new
# welcome, rebuild its SIP registration on a fresh connection, and then
# take the call as usual. This is the "app came back from suspension and
# could not dial" case (ECONNABORTED) in headless form.
if [ -n "${RESTART_SERVER:-}" ]; then
  [ "$SERVER" = native ] && { echo "FAIL: RESTART_SERVER needs the docker server"; exit 1; }
  echo "== restarting the server under the registered app"
  $C restart dialpark >/dev/null 2>&1
  i=0
  until [ "$(grep -c 'sim: gateway connected' "$OUT")" -ge 2 ] && [ "$(grep -c 'engine: registered' "$OUT")" -ge 2 ]; do
    i=$((i+1)); [ $i -le 45 ] || { echo "FAIL: the simulated phone did not reconnect and re-register within 45s"; grep -E 'sim:|engine:' "$OUT" | tail -14 | sed 's/^/   /'; exit 1; }
    sleep 1
  done
  echo "   reconnected and re-registered after the restart ($(grep -c 'reconnecting in' "$OUT") backoff notice(s))"
  # The docker caller lost its connection too; give it a fresh one.
  $C up -d --no-deps --force-recreate baresip-b >/dev/null 2>&1
  sleep 4
fi

[ -n "${OUTBOUND:-}" ] || echo "== phone-b (212) dials 203 (the simulator)"
ctl_to() { # phone json
  docker run --rm --network "$NET" alpine:3.20 sh -c \
    "p='$2'; len=\$(printf %s \"\$p\" | wc -c | tr -d ' '); printf '%s:%s,' \"\$len\" \"\$p\" | nc -w2 $1 4444 >/dev/null"
}
ctl() { ctl_to baresip-b "$1"; }
n=1
while :; do
  if [ -n "${OUTBOUND:-}" ]; then
    echo "   (outbound: the simulated phone dials $OUTBOUND)"
  else
    ctl '{"command":"dial","params":"203@dialpark"}'
  fi
  if [ -n "${CALLWAITING:-}" ]; then
    # The second caller: phone-a dials once the first call is up.
    if [ "$SERVER" = native ]; then
      BARESIP_A_OUTBOUND="$HOST:5061" $C up -d --no-deps --force-recreate baresip-a >/dev/null 2>&1
    else
      $C up -d --no-deps baresip-a >/dev/null 2>&1
    fi
    i=0
    until grep -q 'sim: in call' "$OUT"; do
      i=$((i+1)); [ $i -le 30 ] || { echo "FAIL: the first call never established"; break; }
      sleep 1
    done
    sleep 3 # past the sim's 2 s verdict, so it is ready for the second ring
    echo "== phone-a (211) dials 203 too (call waiting)"
    ctl_to baresip-a '{"command":"dial","params":"203@dialpark"}'
  fi
  i=0
  until grep -q "sim: call $n: \|sim: FAIL" "$OUT"; do
    i=$((i+1)); [ $i -le 45 ] || break
    sleep 1
  done
  ctl '{"command":"hangup"}' 2>/dev/null || true
  [ -n "${CALLWAITING:-}" ] && { ctl_to baresip-a '{"command":"hangup"}' 2>/dev/null || true; }
  [ "$n" -lt "$CALLS" ] || break
  n=$((n+1))
  # Wait for the simulated phone to report the previous call ended.
  i=0
  until grep -q "sim: ready for call $n" "$OUT"; do
    i=$((i+1)); [ $i -le 20 ] || break
    sleep 1
  done
  echo "== phone-b dials 203 again (call $n)"
  sleep 2
done
i=0
until grep -q 'sim: PASS\|sim: FAIL' "$OUT"; do
  i=$((i+1)); [ $i -le 15 ] || break
  sleep 1
done
wait $PID 2>/dev/null || true
# The EXIT trap stays armed: the container logs below are read first,
# and the teardown runs when the script ends.

echo "== simulated phone"
grep -E 'sim:|engine:|callkit|audiounit:|stream:|INVITE|answered|incoming|wake|call .* ended|registering' "$OUT" | grep -v '^  baresip:' | sed 's/^/   /'
if [ -n "${TRANSFER:-}" ]; then
  echo "== transfer: did phone-b hear the echo after being transferred?"
  sleep 3
  python3 harness/spike/assert_audio.py "$(pwd)/harness/baresip/media/out-212.wav" || { echo "FAIL: phone-b heard nothing after the transfer"; exit 1; }
fi
if [ -n "${CALLWAITING:-}" ]; then
  echo "== call waiting: did phone-a hear the sim while it was the active call?"
  grep -q 'sim: callwaiting: PASS' "$OUT" || { echo "FAIL: the sim did not pass the call-waiting sequence"; exit 1; }
  sleep 3
  python3 harness/spike/assert_audio.py "$(pwd)/harness/baresip/media/out-211.wav" || { echo "FAIL: phone-a heard nothing"; exit 1; }
  echo "   PASS: second caller was taken with Hold & Accept and heard the phone"
fi
if [ -n "${OUTBOUND:-}" ] && [ -z "${REFUSED:-}" ] && [ "$OUTBOUND" != echo ] && [ "$OUTBOUND" != 600 ]; then
  echo "== ring-back (plan Phase J): did the caller hear one while the far end rang?"
  grep -q 'callkit: tone ringback' "$OUT" || { echo "FAIL: the controller never asked for ring-back on the 180"; exit 1; }
  grep -q 'callkit: tone stop' "$OUT" || { echo "FAIL: the ring-back was never stopped"; exit 1; }
  # The invariant that matters, and the one whose absence cost the app its
  # audio on every call (2026-09-15): the 180 beats CallKit's didActivate,
  # and a tone must never be what activates the session. So ring-back asked
  # for before didActivate must be HELD, never played. (Whether it is then
  # played or dropped depends on the call: this harness callee answers ~50ms
  # after the 180, so the held tone is usually dropped, which is correct.)
  act="$(grep -n 'callkit: didActivate' "$OUT" | head -1 | cut -d: -f1)"
  played="$(grep -n 'callkit: tone ringback$' "$OUT" | head -1 | cut -d: -f1)"
  if [ -n "$played" ] && [ -n "$act" ] && [ "$played" -lt "$act" ]; then
    echo "FAIL: ring-back PLAYED before CallKit activated the session — AVAudioPlayer would activate it behind CallKit's back"
    exit 1
  fi
  if grep -q 'tone ringback HELD' "$OUT"; then
    echo "   PASS: ring-back asked for on the 180 and held until CallKit's session, never played into a session of its own"
  else
    echo "   PASS: ring-back played on a session CallKit had already activated, and stopped on the answer"
  fi
fi
if [ -n "${REFUSED:-}" ]; then
  echo "== refused call (plan Phase J): tone first, then the call disappears"
  # And it must be a refusal, not a wait: with the PBX there, an extension
  # it does not have is 404 in milliseconds. A slow one means the INVITE
  # went nowhere and timed out — a different bug wearing the same clothes.
  dialled="$(grep -n 'sim: dialling' "$OUT" | head -1 | cut -d: -f1)"
  toned="$(grep -n 'callkit: tone \(busy\|congestion\)' "$OUT" | head -1 | cut -d: -f1)"
  at() { sed -n "${1}p" "$OUT" | awk '{print $1}'; }
  gap="$(awk -v a="$(at "$dialled")" -v b="$(at "$toned")" 'BEGIN{printf "%.0f", b-a}')"
  [ "$gap" -le 10 ] || { echo "FAIL: the tone took ${gap}s — the call timed out rather than being refused"; exit 1; }
  echo "   refused and tone started ${gap}s after dialling"
  # And the screen must say why, not "Calling…" (2026-09-15).
  grep -q 'screen says "Calling…"' "$OUT" && ! grep -qE 'screen says "(Busy|Declined|Unavailable|Unknown number|No answer|Call failed)"' "$OUT" && {
    echo "FAIL: the call was refused but the screen still read Calling…"; exit 1; }
  grep -qE 'screen says "(Busy|Declined|Unavailable|Unknown number|No answer|Call failed)"' "$OUT" || {
    echo "FAIL: the refused call was never explained on screen"; exit 1; }
  grep -E 'screen says' "$OUT" | sed 's/^/   /'
  grep -q 'PASS: refused' "$OUT" || { echo "FAIL: the refused call did not play its tone before being reported ended"; exit 1; }
  grep -E 'sim: (callkit: tone|call [0-9]+: PASS: refused)' "$OUT" | sed 's/^/   /'
fi
if [ -n "${DECLINE:-}" ]; then
  echo "== decline: what was the caller (phone-b) told?"
  sleep 1
  closed="$($C logs --no-log-prefix --since 120s baresip-b 2>&1 | grep -E 'session closed' | tail -n "$CALLS")"
  echo "$closed" | sed 's/^/   /'
  got="$(printf '%s\n' "$closed" | grep -c '486 Busy Here' || true)"
  if [ "$got" -lt "$CALLS" ]; then
    echo "FAIL: phone-b was not told 486 Busy Here for every declined call (a 480 here is the old 'Call failed: NO RESPONSE' behaviour)"
    exit 1
  fi
  echo "   PASS: caller received 486 Busy Here for $CALLS declined call(s)"
fi
# Recents (SPEC §6 item 6): the controller logs one "recents:" line per
# call as it leaves its table — the same record the app persists — so each
# mode asserts the record its call must leave, and that there is one per call.
echo "== recents: what record did each call leave?"
if [ -n "${REFUSED:-}" ]; then
  want='recents: (busy|declined|noAnswer|unknownNumber|unavailable|failed) outgoing'
elif [ -n "${DECLINE:-}" ]; then
  want='recents: declined incoming'
elif [ -n "${OUTBOUND:-}" ]; then
  want='recents: completed outgoing'
else
  want='recents: completed incoming'
fi
expected="$CALLS"
[ -n "${CALLWAITING:-}" ] && expected=2   # the first call and the one taken on top of it
got="$(grep -cE "$want" "$OUT" || true)"
total="$(grep -c 'recents: ' "$OUT" || true)"
grep -E 'recents: ' "$OUT" | sed 's/^/   /'
if [ "$got" -lt "$expected" ]; then
  echo "FAIL: expected $expected record(s) matching /$want/, found $got"; exit 1
fi
if [ "$total" -ne "$expected" ]; then
  echo "FAIL: $total recents line(s) for $expected call(s) — every call must be recorded exactly once"; exit 1
fi
echo "   PASS: $got record(s) as expected"

if [ "$SERVER" = native ]; then
  echo "== server: native; its relay lines are in the dev-server terminal"
else
  echo "== server"
  $C logs --no-log-prefix --since 90s dialpark 2>&1 | grep -E 'invite|woke|wake_ack|register|bridged|ended|480|rtp|media|relay|RELAY' | tail -20 | sed 's/^/   /' || true
fi

if [ -n "${RING_RESET:-}" ]; then
  echo "== ring-reset: was the reset refused while the call rang, and the call answered regardless?"
  grep -q 'ring-reset: resetting the registration' "$OUT" || { echo "FAIL: the reset was never issued"; exit 1; }
  grep -q 'registration reset refused by the stack' "$OUT" || { echo "FAIL: the stack did not refuse the reset — the ringing call was freed under the caller"; exit 1; }
  grep -E 'ring-reset:|refused by the stack|cbaresip: ua_free' "$OUT" | sed 's/^/   /'
fi

grep -q 'sim: PASS' "$OUT"
