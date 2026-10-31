#!/usr/bin/env python3
"""Assert on a phone's recording: that real audio was bridged (RMS well above
silence), and — given the file that was played into the call — how late it
arrived and whether any of it went missing. Standard library only.

Usage:
  assert_audio.py [recording.wav]                      RMS check only
  assert_audio.py recording.wav --reference in.wav \\
      [--max-delay-ms N] [--max-gap-ms M] [--max-gaps K]

With --reference the recording's envelope is correlated against the
reference's (the tone from harness/baresip/media/gen_tone.py, an aperiodic
on/off pattern) to find the lag with the best match: that lag is the
mouth-to-ear delay of the path under test as the harness sees it (playback
start to recording, through every buffer, relay and codec). Then, inside
each "on" burst of the reference (shifted by that lag), 10 ms frames whose
energy falls below 5 % of the burst level are gaps: lost or late packets
that nothing concealed. The result line is machine-greppable:

  audio: rms=7102 mouth_to_ear_ms=84 gaps=0 longest_gap_ms=0 match=0.97

Bounds given on the command line turn into a non-zero exit.

Continuity (--continuity, alongside any of the above):

  assert_audio.py recording.wav --continuity \\
      [--max-removed-ms N] [--max-inserted-ms M]
  assert_audio.py --selftest-continuity

The gap analysis sees silence; it cannot see audio that was REMOVED (a
decoded 20 ms frame discarded by a jitter or play buffer, the rest closing
up behind it) or time INSERTED (a pad). For that the tone is generated with
a click train (gen_tone.py --clicks): a 2 ms raised-cosine burst of 2.4 kHz
exactly every 250 ms, through the tone's off periods as well, so a cut or a
pad anywhere in the call shifts every later click. Only the recording is
analysed; the reference is not needed, so the absolute delay and a
recording that starts mid-stream do not matter, only changes in spacing.

  1. mono, decimated to 8 kHz; band-passed to the click's band, 1.6-3.4 kHz
     (Butterworth biquads: 4th-order high-pass, 2nd-order low-pass), so the
     440 Hz tone and its codec harmonics fall far below the click;
  2. energy per 1 ms bin; the floor is the median bin, the click level the
     99.6th percentile; the threshold is the larger of 20 x floor and 1 %
     of the click level (Opus leaves some clicks 25 x weaker than the
     median; a recording whose click level is not well above its floor has
     no click train: clicks=0);
  3. a click onset is a bin over the threshold that is the maximum of its
     +-75 ms neighbourhood (so onsets are >= 150 ms apart) AND whose energy
     in the click band is at least 0.3 x its energy in 0.7-1.3 kHz over
     +-5 ms: a step in the tone (the hard edge a discarded frame leaves,
     power falling as 1/f^2) puts most of its energy in the lower band
     (ratio <= 0.11), a click almost none (>= 0.7 through Opus); the onset
     is timed where the rising edge crosses half the peak, interpolated;
  4. each click gets a grid index k (advancing by round(spacing/250), so a
     vanished click leaves a hole, not a shift) and a phase
     phi = onset - 250 k. A cut or a pad moves every later click, a lasting
     step in phi; a click the codec smeared so its onset reads a few ms off
     (seen: up to 8 ms, always bouncing back on the next click) is a lone
     outlier, which a 3-point median filter removes while a step survives.
     A step of the filtered phase of 8 ms or more is an event: negative =
     removed audio, positive = inserted; the nearest multiple of 20 ms
     frames is named. A spacing of 2+ grid steps means clicks vanished
     altogether, as when the one frame carrying a click is dropped and the
     codec's concealment fills the time: reported as "removed >= 20 ms
     (click lost)" and counted as 20 ms each.

  continuity: clicks=N removed_ms=T inserted_ms=T events=K max_dev_ms=D
    +<t_s> removed <ms> ms (~<f> frame(s); between clicks +a and +b)
    +<t_s> inserted <ms> ms (...)

t is where the click that closed the interval sits in the recording. The
exit code is unaffected unless --max-removed-ms / --max-inserted-ms are
given. The self-test synthesises a click-train recording, cuts 20 ms at
5.0 s and pads 40 ms at 9.0 s, and checks exactly those two events are
reported, once clean and once with +-3 ms of jitter on every click.
"""
import argparse
import math
import random
import struct
import sys
import wave
from pathlib import Path

THRESHOLD = 200  # 16-bit RMS; silence is ~0, the 440Hz tone is thousands
FRAME_MS = 10    # analysis resolution
ANALYSIS_RATE = 8000
GAP_LEVEL = 0.05    # of the burst's median frame RMS
EDGE_FRAMES = 3     # ignore 30 ms at each burst edge (codec/jitter smear)
MIN_MATCH = 0.5     # correlation below this = the recording is not the tone

# Continuity (click train, see the docstring and gen_tone.py --clicks).
CLICK_PERIOD_MS = 250.0
CLICK_MIN_SPACING_MS = 150   # two onsets closer than this are one click
CLICK_BAND_HZ = (1600.0, 3400.0)  # the click's band (2.4 kHz, 2 ms Hann: main lobe +-1 kHz)
STEP_BAND_HZ = (700.0, 1300.0)    # between the tone and the click: a step's power lands here
# A candidate is a click only if its click-band energy is at least this
# times its step-band energy over +-5 ms. Measured 2026-10-31: clicks
# through Opus 0.7-24 (median 6.4), uncoded 4.8-12; a hard cut or step in
# the tone (what a discarded frame leaves) 0.03-0.11; tone edges <= 0.02.
CLICK_BAND_RATIO = 0.3
CLICK_BIN_MS = 1             # envelope resolution
CLICK_EVENT_MS = 8.0         # |deviation| at or above this is an event
PLAY_FRAME_MS = 20           # the phone's decode/play frame
# Threshold: at least CLICK_FLOOR_RATIO x the median bin and at least
# CLICK_LEVEL_RATIO x the click level. Measured on an Opus app-to-app call
# (2026-10-31): the background away from clicks peaks at ~9 x the floor,
# while Opus leaves some clicks 25 x weaker than the median one (the
# weakest at ~170 x the floor), so the threshold sits between: ~3 x above
# the background's worst bin, ~6 x under the weakest click.
CLICK_FLOOR_RATIO = 20.0
CLICK_LEVEL_RATIO = 0.01
CLICK_LOST_MS = 20           # a vanished click means at least one frame gone


def load_mono_8k(path: Path) -> list:
    """Samples as floats, channels averaged, decimated to 8 kHz."""
    with wave.open(str(path), "rb") as w:
        n, ch, rate, width = w.getnframes(), w.getnchannels(), w.getframerate(), w.getsampwidth()
        if n == 0:
            return []
        raw = w.readframes(n)
    if width != 2:
        raise SystemExit(f"FAIL: {path}: only 16-bit WAV is supported")
    ints = struct.unpack("<%dh" % (len(raw) // 2), raw)
    mono = [sum(ints[i:i + ch]) / ch for i in range(0, len(ints) - ch + 1, ch)]
    step = rate // ANALYSIS_RATE
    if step <= 1:
        return mono
    # Block-average decimation: enough anti-aliasing for an envelope.
    return [sum(mono[i:i + step]) / step for i in range(0, len(mono) - step + 1, step)]


def frame_rms(samples: list) -> list:
    n = ANALYSIS_RATE * FRAME_MS // 1000
    out = []
    for i in range(0, len(samples) - n + 1, n):
        blk = samples[i:i + n]
        out.append((sum(s * s for s in blk) / n) ** 0.5)
    return out


def rms(path: Path) -> float:
    s = load_mono_8k(path)
    if not s:
        return 0.0
    return (sum(x * x for x in s) / len(s)) ** 0.5


def bursts(ref_frames: list) -> list:
    """(start, end) frame ranges where the reference is on."""
    peak = max(ref_frames) if ref_frames else 0.0
    on = [f > 0.2 * peak for f in ref_frames]
    runs, i = [], 0
    while i < len(on):
        if on[i]:
            j = i
            while j < len(on) and on[j]:
                j += 1
            runs.append((i, j))
            i = j
        else:
            i += 1
    return runs


def best_lag(ref_frames: list, rec_frames: list, max_lag: int) -> tuple:
    """Lag (frames) maximising normalised correlation of the two envelopes,
    over the part of the reference the recording overlaps."""
    n = len(rec_frames)
    if n < 20 or len(ref_frames) < 20:
        return 0, 0.0
    ref_on = [1.0 if f > 0.2 * max(ref_frames) else 0.0 for f in ref_frames]
    peak = max(rec_frames)
    rec_on = [1.0 if f > 0.2 * peak else 0.0 for f in rec_frames] if peak > 0 else [0.0] * n
    best, best_lag = -1.0, 0
    for lag in range(0, max_lag + 1):
        m = min(n - lag, len(ref_on))
        if m < 20:
            break
        a = ref_on[:m]
        b = rec_on[lag:lag + m]
        ma, mb = sum(a) / m, sum(b) / m
        num = sum((x - ma) * (y - mb) for x, y in zip(a, b))
        da = sum((x - ma) ** 2 for x in a) ** 0.5
        db = sum((y - mb) ** 2 for y in b) ** 0.5
        c = num / (da * db) if da > 0 and db > 0 else 0.0
        if c > best:
            best, best_lag = c, lag
    return best_lag, best


def gaps(ref_frames: list, rec_frames: list, lag: int) -> list:
    """Lengths (ms) of silent runs inside the reference's bursts, shifted."""
    found = []
    for start, end in bursts(ref_frames):
        lo, hi = start + lag + EDGE_FRAMES, end + lag - EDGE_FRAMES
        if hi - lo < 5 or hi > len(rec_frames):
            continue  # burst not (fully) inside the recording
        window = rec_frames[lo:hi]
        level = sorted(window)[len(window) // 2]
        if level <= 0:
            continue
        run = 0
        for f in window:
            if f < GAP_LEVEL * level:
                run += 1
            elif run:
                found.append(run * FRAME_MS)
                run = 0
        if run:
            found.append(run * FRAME_MS)
    return found


# ---- continuity: the click train -------------------------------------------

def biquad(samples: list, fc: float, rate: int, high: bool, passes: int = 1) -> list:
    """2nd-order Butterworth biquad (high- or low-pass), applied `passes` times."""
    k = math.tan(math.pi * fc / rate)
    norm = 1.0 / (1.0 + math.sqrt(2.0) * k + k * k)
    if high:
        b0, b1, b2 = norm, -2.0 * norm, norm
    else:
        b0 = k * k * norm
        b1, b2 = 2.0 * b0, b0
    a1, a2 = 2.0 * (k * k - 1.0) * norm, (1.0 - math.sqrt(2.0) * k + k * k) * norm
    out = samples
    for _ in range(passes):
        y = [0.0] * len(out)
        x1 = x2 = y1 = y2 = 0.0
        for i, x in enumerate(out):
            v = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2, x1, y2, y1 = x1, x, y1, v
            y[i] = v
        out = y
    return out


def highpass(samples: list, fc: float, rate: int = ANALYSIS_RATE, passes: int = 2) -> list:
    return biquad(samples, fc, rate, True, passes)


def band_envelope(samples: list, band: tuple, rate: int = ANALYSIS_RATE) -> list:
    """Energy per CLICK_BIN_MS bin of the signal band-passed to `band`: a
    4th-order high-pass at the lower edge, a 2nd-order low-pass at the upper."""
    bp = biquad(highpass(samples, band[0], rate), band[1], rate, False)
    n = rate * CLICK_BIN_MS // 1000
    return [sum(v * v for v in bp[i:i + n]) for i in range(0, len(bp) - n + 1, n)]


def click_envelope(samples: list, rate: int = ANALYSIS_RATE) -> list:
    return band_envelope(samples, CLICK_BAND_HZ, rate)


def click_onsets(env: list, step_env: list = None) -> list:
    """Onset times (ms) of the clicks in an envelope, >= CLICK_MIN_SPACING_MS
    apart, each timed at the half-peak crossing of its rising edge. With the
    step-band envelope given, a candidate whose click-band energy is not
    CLICK_BAND_RATIO x its step-band energy over +-5 ms is a step (a cut or
    a pad edge in the tone), not a click, and is skipped."""
    if len(env) < 2 * CLICK_MIN_SPACING_MS:
        return []
    ranked = sorted(env)
    floor = ranked[len(ranked) // 2]
    level = ranked[min(len(ranked) - 1, int(len(ranked) * 0.996))]
    if level <= 0 or level < CLICK_FLOOR_RATIO * max(floor, 1e-9):
        return []  # no click train in this recording
    thr = max(CLICK_FLOOR_RATIO * floor, CLICK_LEVEL_RATIO * level)
    half = CLICK_MIN_SPACING_MS // 2
    onsets = []
    i = 0
    while i < len(env):
        e = env[i]
        if e <= thr:
            i += 1
            continue
        lo, hi = max(0, i - half), min(len(env), i + half + 1)
        if e < max(env[lo:hi]):
            i += 1
            continue
        if step_env is not None:
            w_lo, w_hi = max(0, i - 4), min(len(env), i + 6)
            if sum(env[w_lo:w_hi]) < CLICK_BAND_RATIO * sum(step_env[w_lo:w_hi]):
                i += 1  # a step, not a click
                continue
        # i is the peak of this click: walk back to the half-peak crossing.
        j = i
        while j > 0 and env[j - 1] >= 0.5 * e:
            j -= 1
        t = float(j)
        if j > 0 and env[j] > env[j - 1]:
            t = (j - 1) + (0.5 * e - env[j - 1]) / (env[j] - env[j - 1])
        onsets.append(t * CLICK_BIN_MS)
        i += half  # nothing closer than the minimum spacing can be another click
    return onsets


def continuity_events(onsets: list) -> tuple:
    """(removed_ms, inserted_ms, events, max_dev_ms) from the click times.
    Each event: (t_ms, kind, ms, note, t_prev_ms); max_dev_ms is the largest
    step that did NOT make an event (the wobble under the threshold).

    Each click gets a grid index k (advancing by round(spacing / 250), so a
    vanished click leaves a hole, not a shift) and a phase
    phi = onset - 250 k. A cut or a pad moves every later click: a lasting
    step in phi. A click the codec smeared so its onset reads a few ms off
    is a lone outlier in phi, which a 3-point median removes; the step
    survives it. Events are the steps of the filtered phase."""
    removed = inserted = max_dev = 0.0
    events = []
    if len(onsets) < 2:
        return removed, inserted, events, max_dev
    ks, phis = [0], [onsets[0]]
    for a, b in zip(onsets, onsets[1:]):
        n = max(1, int(round((b - a) / CLICK_PERIOD_MS)))
        if n >= 2:
            lost = n - 1
            events.append((b, "removed >=", CLICK_LOST_MS,
                           f"{lost} click{'s' if lost > 1 else ''} lost; spacing {b - a:.1f} ms", a))
            removed += CLICK_LOST_MS * lost
        ks.append(ks[-1] + n)
        phis.append(b - ks[-1] * CLICK_PERIOD_MS)
    med = []
    for i in range(len(phis)):
        lo, hi = max(0, i - 1), min(len(phis), i + 2)
        if hi - lo < 3:  # an edge: widen inward so an outlier at the end is still outvoted
            lo, hi = (0, min(3, len(phis))) if i == 0 else (max(0, len(phis) - 3), len(phis))
        med.append(sorted(phis[lo:hi])[(hi - lo) // 2])
    for i in range(1, len(med)):
        dev = med[i] - med[i - 1]
        if abs(dev) < CLICK_EVENT_MS:
            max_dev = max(max_dev, abs(dev))
            continue
        frames = max(1, int(round(abs(dev) / PLAY_FRAME_MS)))
        kind = "removed" if dev < 0 else "inserted"
        events.append((onsets[i], kind, abs(dev), f"~{frames} frame{'s' if frames > 1 else ''}", onsets[i - 1]))
        if dev < 0:
            removed += -dev
        else:
            inserted += dev
    events.sort(key=lambda e: e[0])
    return removed, inserted, events, max_dev


def continuity(samples: list, rate: int = ANALYSIS_RATE) -> dict:
    env = click_envelope(samples, rate)
    onsets = click_onsets(env, band_envelope(samples, STEP_BAND_HZ, rate))
    removed, inserted, events, max_dev = continuity_events(onsets)
    return {"clicks": len(onsets), "removed_ms": removed, "inserted_ms": inserted, "events": events,
            "onsets": onsets, "max_dev_ms": max_dev}


def print_continuity(res: dict) -> None:
    print(f"continuity: clicks={res['clicks']} removed_ms={res['removed_ms']:.0f} "
          f"inserted_ms={res['inserted_ms']:.0f} events={len(res['events'])} max_dev_ms={res['max_dev_ms']:.1f}")
    for t, kind, ms, note, prev in res["events"]:
        print(f"  +{t / 1000:.3f} {kind} {ms:.0f} ms ({note}; between clicks +{prev / 1000:.3f} and +{t / 1000:.3f})")


def selftest_continuity() -> int:
    """Synthesise a click-train recording at 48 kHz (tone + clicks as
    gen_tone.py makes them), cut 20 ms just after the click at 5.0 s and pad
    40 ms just after the click at 9.0 s, and require exactly those two
    events; then the same with every click moved by up to +-3 ms."""
    rate, secs = 48000, 14
    period, click_n = rate // 4, rate * 2 // 1000

    def synth(jitter_ms: float, seed: int = 3) -> list:
        rng = random.Random(seed)
        sig = [0.0] * (rate * secs)
        for i in range(len(sig)):  # 440 Hz, 500 ms on / 150 ms off
            if (i % (rate * 650 // 1000)) < rate // 2:
                sig[i] = 12000 * math.sin(2 * math.pi * 440 * i / rate)
        k = 1
        while k * period + click_n < len(sig):
            at = k * period + int(rng.uniform(-jitter_ms, jitter_ms) * rate / 1000)
            for j in range(click_n):
                sig[at + j] += 18000 * 0.5 * (1 - math.cos(2 * math.pi * j / click_n)) * math.sin(2 * math.pi * 2400 * j / rate)
            k += 1
        return sig

    def decimate(sig: list) -> list:
        step = rate // ANALYSIS_RATE
        return [sum(sig[i:i + step]) / step for i in range(0, len(sig) - step + 1, step)]

    def mutate(sig: list) -> list:
        cut_at, cut_len = int(5.010 * rate), rate * 20 // 1000      # 20 ms removed after the 5.0 s click
        pad_at, pad_len = int(9.010 * rate) - cut_len, rate * 40 // 1000  # 40 ms of zeros after the 9.0 s click
        sig = sig[:cut_at] + sig[cut_at + cut_len:]
        return sig[:pad_at] + [0.0] * pad_len + sig[pad_at:]

    ok = True
    for label, jitter in (("clean", 0.0), ("+-3 ms jitter", 3.0)):
        res = continuity(decimate(mutate(synth(jitter))))
        print(f"selftest {label}:")
        print_continuity(res)
        ev = [(t, kind.split()[0], ms) for t, kind, ms, _, _ in res["events"]]
        want = [("removed", 20.0, 5.0), ("inserted", 40.0, 9.0)]
        good = len(ev) == 2 and res["clicks"] >= 50
        for (t, kind, ms), (wkind, wms, wt) in zip(sorted(ev), want):
            good = good and kind == wkind and abs(ms - wms) <= 2 * jitter + 1.5 and abs(t / 1000 - wt) <= 0.3
        print(f"  {'ok' if good else 'FAIL'}: expected removed 20 ms at ~5.0 s and inserted 40 ms at ~9.0 s, nothing else")
        ok = ok and good
    print("PASS: continuity self-test" if ok else "FAIL: continuity self-test")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("recording", nargs="?", default=str(Path(__file__).with_name("media") / "out-202.wav"))
    ap.add_argument("--reference", help="the WAV played into the call (delay + gap analysis)")
    ap.add_argument("--max-delay-ms", type=int, help="fail if mouth-to-ear exceeds this")
    ap.add_argument("--max-gap-ms", type=int, help="fail if any gap is longer than this")
    ap.add_argument("--max-gaps", type=int, help="fail if more gaps than this")
    ap.add_argument("--max-lag-ms", type=int, default=2000, help="delay search range")
    ap.add_argument("--continuity", action="store_true", help="click-train analysis: removed / inserted time")
    ap.add_argument("--max-removed-ms", type=float, help="fail if the click train shows more removed time than this")
    ap.add_argument("--max-inserted-ms", type=float, help="fail if the click train shows more inserted time than this")
    ap.add_argument("--selftest-continuity", action="store_true", help="synthetic cut/pad check of the click detector")
    args = ap.parse_args()

    if args.selftest_continuity:
        return selftest_continuity()

    rec = Path(args.recording)
    if not rec.exists():
        print(f"FAIL: no recording at {rec}")
        return 1
    energy = rms(rec)
    print(f"callee recording RMS = {energy:.0f} (threshold {THRESHOLD})")
    if energy < THRESHOLD:
        print("FAIL: recording is silent — media did not bridge")
        return 1
    cont_failed = []
    if args.continuity or args.max_removed_ms is not None or args.max_inserted_ms is not None:
        res = continuity(load_mono_8k(rec))
        print_continuity(res)
        if args.max_removed_ms is not None and res["removed_ms"] > args.max_removed_ms:
            cont_failed.append(f"removed {res['removed_ms']:.0f} ms > {args.max_removed_ms:.0f} ms")
        if args.max_inserted_ms is not None and res["inserted_ms"] > args.max_inserted_ms:
            cont_failed.append(f"inserted {res['inserted_ms']:.0f} ms > {args.max_inserted_ms:.0f} ms")
    if not args.reference:
        for f in cont_failed:
            print(f"FAIL: {f}")
        if cont_failed:
            return 1
        print("PASS: media bridged through the server")
        return 0

    ref = Path(args.reference)
    if not ref.exists():
        print(f"FAIL: no reference at {ref}")
        return 1
    ref_frames = frame_rms(load_mono_8k(ref))
    rec_frames = frame_rms(load_mono_8k(rec))
    lag, match = best_lag(ref_frames, rec_frames, args.max_lag_ms // FRAME_MS)
    delay_ms = lag * FRAME_MS
    found = gaps(ref_frames, rec_frames, lag) if match >= MIN_MATCH else []
    longest = max(found) if found else 0
    print(f"audio: rms={energy:.0f} mouth_to_ear_ms={delay_ms} gaps={len(found)} longest_gap_ms={longest} match={match:.2f}")

    failed = list(cont_failed)
    if match < MIN_MATCH:
        failed.append(f"recording does not match the reference pattern (match {match:.2f})")
    if args.max_delay_ms is not None and delay_ms > args.max_delay_ms:
        failed.append(f"mouth-to-ear {delay_ms} ms > {args.max_delay_ms} ms")
    if args.max_gap_ms is not None and longest > args.max_gap_ms:
        failed.append(f"longest gap {longest} ms > {args.max_gap_ms} ms")
    if args.max_gaps is not None and len(found) > args.max_gaps:
        failed.append(f"{len(found)} gaps > {args.max_gaps}")
    if failed:
        for f in failed:
            print(f"FAIL: {f}")
        return 1
    print("PASS: media bridged through the server")
    return 0


if __name__ == "__main__":
    sys.exit(main())
