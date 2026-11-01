#!/bin/sh
# Lab (lab/audio-continuity): the real phone engine (the simulator build of
# the app's DiallerEngine, CoreAudio output and all, driven headless by
# sim-call) under the continuity scenarios, reading its own audio
# continuity events — the instrument the harness phones do not have.
#
#   SCENARIO=control|backlog|impaired|all sh harness/sim_continuity.sh
#
#   control   the simulated phone dials 212; clean network.
#   backlog   the same, with the docker server holding its pumps back 300 ms
#             after the ACK (-lab-pump-delay): 212's first 15 packets reach
#             the simulator as one burst the moment the relay starts — the
#             start-of-call backlog app→CUCM calls show (227–276 ms).
#   impaired  the same under IMPAIR=1 (2 % loss, 30 ± 10 ms jitter on what
#             the server sends), for the mid-call recovery events.
#
# Each run prints the engine's per-call continuity summary and every audio
# event ("engine: audio event +T KIND a= b=") from sim-call's output, plus
# the server's relay lines. Needs the published-port harness: the native
# dev-server must be stopped (sim_call.sh refuses otherwise).
set -eu
cd "$(dirname "$0")/.."
SCENARIO="${SCENARIO:-all}"
OUT="${OUT:-harness/baresip/media}"
run() { # name [TONE_SECONDS=N] env...
  name="$1"; shift
  echo "=== sim scenario $name"
  log="$OUT/sim-continuity-$name.log"
  # The caller plays harness/baresip/media/in.wav (20 s by default, from
  # `make tone`); a longer call needs a longer tone, and the default is
  # put back afterwards so the other gates see the file they expect.
  secs=20
  for kv in "$@"; do case "$kv" in TONE_SECONDS=*) secs="${kv#TONE_SECONDS=}";; esac; done
  [ "$secs" = 20 ] || python3 harness/baresip/media/gen_tone.py --seconds "$secs" harness/baresip/media/in.wav >/dev/null
  env "$@" OUTBOUND=212 sh harness/sim_call.sh > "$log" 2>&1 || echo "   (sim_call.sh exited non-zero; see $log)"
  [ "$secs" = 20 ] || python3 harness/baresip/media/gen_tone.py harness/baresip/media/in.wav >/dev/null
  grep -E "continuity|audio event|PASS|FAIL" "$log" | sed 's/^/   /' | head -80
  echo "   kept: $log"
}
case "$SCENARIO" in
  control)  run control ;;
  backlog)  run backlog DIALPARK_LAB_PUMP_DELAY=300ms ;;
  impaired) run impaired IMPAIR=1 ;;
  long)     run long TONE_SECONDS=40 CALL_SECONDS=30 ;;   # clean 30 s
  long-impaired) run long-impaired TONE_SECONDS=40 IMPAIR=1 CALL_SECONDS=30 ;;
  all)      run control; run backlog DIALPARK_LAB_PUMP_DELAY=300ms; run impaired IMPAIR=1; run long TONE_SECONDS=40 CALL_SECONDS=30; run long-impaired TONE_SECONDS=40 IMPAIR=1 CALL_SECONDS=30 ;;
  *) echo "unknown SCENARIO=$SCENARIO (control|backlog|impaired|long|long-impaired|all)"; exit 2 ;;
esac
