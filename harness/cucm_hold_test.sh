#!/bin/sh
# CUCM's hold and resume on a registered line, replayed (SPEC §7.3 item 10
# e; lines bench 2026-10-17 14:06). CUCM puts a call on hold with a
# re-INVITE carrying a=inactive and c=0.0.0.0, and takes it back with a
# re-INVITE carrying NO SDP: it asks us for the offer. The server answered
# that with the direction last negotiated — inactive — so CUCM could only
# answer inactive and the call never resumed. Now the offer states our own
# direction, sendrecv, and the ACK's answer is applied as a media update.
#
# SIPp plays CUCM at the trunk listener: a delayed-offer call to app 211,
# echoed media for a few seconds, the hold, a pause, the bodiless resume,
# echoed media again, BYE. Asserted: SIPp sees a=inactive in our answer to
# the hold and a=sendrecv in our offer on the resume (its own regexes); the
# server logs the hold and its release on the caller's side; and the app's
# recording carries the tone in its last seconds, after the resume. Exit 0
# = pass. Publishes no host ports.
#
#   make harness-cucm-hold
#   KEEP=1 make harness-cucm-hold
set -eu
cd "$(dirname "$0")/.."

COMPOSE="docker compose -f harness/docker-compose.yml -f harness/docker-compose.noports.yml --profile test"
export DIALPARK_PUBLIC_HOST=dialpark
# SIPp follows its scenario and treats any other request as a failed call,
# and the server asks each leg an in-dialog OPTIONS on the peer-timeout
# watchdog's interval, which this call (talk, hold, talk) outlasts. The
# watchdog has its own gate (harness-peer-gone); here it is off.
export DIALPARK_PEER_TIMEOUT=0
NET=dialpark-harness_default
MEDIA_DIR=harness/baresip/media
TALK_SECONDS="${TALK_SECONDS:-6}"
KEEP="${KEEP:-0}"

python3 harness/baresip/media/gen_tone.py "$MEDIA_DIR/in.wav" >/dev/null
rm -f "$MEDIA_DIR/out-211.wav"

cleanup() { [ "$KEEP" = 1 ] || $COMPOSE down -v >/dev/null 2>&1 || true; }
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

echo "== call: the PBX (SIPp) calls 211, talks ${TALK_SECONDS}s, holds 4s with inactive/0.0.0.0, resumes with a bodiless re-INVITE, talks ${TALK_SECONDS}s"
MARK="$(logs | wc -l | tr -d ' ')"
set +e
$COMPOSE run --rm --entrypoint sipp sipp dialpark:5060 -t u1 -sf /scenarios/cucm_hold_resume.xml \
  -s 211 -m 1 -nostdin -timeout 60s -timeout_error -d "$((TALK_SECONDS * 1000))" -rtp_echo \
  -trace_err -error_file /dev/stderr > "$MEDIA_DIR/sipp-cucm-hold.out" 2>&1
rc=$?
set -e
sleep 2
fail=0
if [ "$rc" -eq 0 ]; then
  echo "   SIPp: the hold was answered inactive; the bodiless resume got an offer with a=sendrecv; BYE answered"
else
  echo "   FAIL: SIPp exit $rc — the resume's 200 OK did not offer sendrecv, or the exchange broke"
  # SIPp's own account: which step, and what arrived instead.
  grep -A12 "Aborting call\|Last Error\|Unexpected" "$MEDIA_DIR/sipp-cucm-hold.out" | head -30 | sed 's/^/   sipp: /'
  grep -E "^ *[0-9]+ *: " "$MEDIA_DIR/sipp-cucm-hold.out" | head -20 | sed 's/^/   sipp: /'
  fail=1
fi
rm -f "$MEDIA_DIR/sipp-cucm-hold.out"

slog="$(logs | tail -n +"$((MARK + 1))")"
printf '%s\n' "$slog" | grep -E 'bridged|playing to the waiting|hold released|call ended|level=(ERROR|WARN)' | grep -v "relay write failed" | tail -8 | sed 's/^/   /'
if printf '%s' "$slog" | grep -q 'playing to the waiting party.*playing_to=callee'; then
  echo "   the app was given the server's music while the PBX held"
else
  echo "   FAIL: the hold was not recognised (no music to the app)"; fail=1
fi
if printf '%s' "$slog" | grep -q 'hold released.*held_by=caller'; then
  echo "   the PBX's resume released the hold"
else
  echo "   FAIL: the PBX's resume did not release the hold"; fail=1
fi
if printf '%s' "$slog" | grep -q 'msg="call ended"'; then :; else
  echo "   FAIL: the call never ended cleanly"; fail=1
fi

# What the app heard, by segment. The app plays the 440 Hz test tone
# throughout and records what comes back: its own tone echoed by the PBX
# while talking, the server's music while held. The share of each
# segment's energy at 440 Hz tells the two apart (measured 2026-10-17:
# 0.75 talking, 0.03 music, 0.82 after the resume). The correlation check
# the other gates use cannot align a segment this far into the reference,
# which is why it is not used here. The WAV header is repaired first
# (baresip reopens its recorder on a re-INVITE, see delayed_offer_test.sh).
if python3 - "$MEDIA_DIR/out-211.wav" "$TALK_SECONDS" <<'PY'
import math, os, struct, sys, wave
p, talk = sys.argv[1], float(sys.argv[2])
size = os.path.getsize(p)
with open(p, "r+b") as f:
    f.seek(4); f.write(struct.pack("<I", size - 8)); f.seek(40); f.write(struct.pack("<I", size - 44))
w = wave.open(p); rate = w.getframerate(); ch = w.getnchannels(); n = w.getnframes()
mono = struct.unpack("<%dh" % (n * ch), w.readframes(n))[::ch]; w.close()
dur = n / rate
def tone(a, b):
    x = mono[int(a * rate):int(b * rate)]
    if len(x) < rate // 2:
        return 0.0
    k = 2 * math.cos(2 * math.pi * 440 / rate); s1 = s2 = 0.0
    for v in x:
        s0 = v + k * s1 - s2; s2, s1 = s1, s0
    return (s1 * s1 + s2 * s2 - k * s1 * s2) / ((sum(v * v for v in x) or 1) * len(x) / 2)
held = tone(talk + 0.5, talk + 3.5)
after = tone(dur - (talk - 1), dur - 0.5)
print("   app heard: 440 Hz share while held %.2f (music), after the resume %.2f (tone)" % (held, after))
if after < 0.5:
    sys.exit("FAIL: no tone after the resume — the call did not really come back")
if held > 0.3:
    sys.exit("FAIL: the app heard the tone while the PBX had it on hold — the hold was not honoured")
PY
then
  echo "   the app heard its tone again after the resume: media came back"
else
  fail=1
fi

if [ "$fail" = 0 ]; then
  echo "PASS: CUCM's hold is honoured and its bodiless resume brings the call back with audio"
else
  echo "FAIL cucm-hold"
fi
exit $fail
