#!/usr/bin/env python3
"""Generate in.wav: 20 s of a 440 Hz tone gated by a fixed pseudo-random
on/off pattern, 48 kHz **stereo** 16-bit, for the headless baresip phones.

Why a pattern and not a steady tone: the audio-quality gates
(harness/spike/assert_audio.py) measure mouth-to-ear delay by correlating a
recording's envelope with this file's, and count gaps inside the "on"
bursts. A steady sine correlates at every period and hides gaps; a periodic
burst pattern is ambiguous by its period. The pattern here is aperiodic
(seeded, so every run gets the same file): "on" runs of 300–700 ms and
"off" runs of 100–200 ms, about 70 % on, so a 2 s window always contains
tone (the app's own 2 s/5 s audio self-check needs energy in every window)
and every loss-induced gap sits inside an on-run where it can be seen.

Long enough to outlast a hold/resume cycle and a slow answer within one
test call. Stereo because the phones negotiate opus/48000/2 and baresip's
aufile source requires the file's channel count to match. Media tests play
this from one phone and assert on the other phone's recording (SPEC §7.2).
Standard library only.

Usage: gen_tone.py [--clicks] [--seconds N] [output.wav ...]
       (default: in.wav next to this script, 20 s, no clicks)

--clicks (or CLICKS=1) superimposes a click train for the continuity gate
(harness/continuity_test.sh, assert_audio.py --continuity): a 2 ms
raised-cosine burst of 2.4 kHz, high in level, at exactly every 250 ms from
t = 250 ms, through the "off" periods too. A receiver that discards or pads
audio moves every later click, so the spacing between successive clicks in
a recording shows removed or inserted time anywhere in the call, which the
silence-based gap analysis cannot see. Without the flag the file is exactly
the one the other gates correlate against. Tone 12000 + click 18000 stays
under 16-bit full scale.
"""
import argparse
import math
import os
import random
import struct
import sys
import wave
from pathlib import Path

RATE, SECONDS, FREQ, AMP, CHANNELS = 48000, 20, 440.0, 12000, 2
CLICK_MS_PERIOD, CLICK_MS, CLICK_FREQ, CLICK_AMP = 250, 2, 2400.0, 18000
SLOT_MS = 100          # pattern resolution
ON_SLOTS = (3, 5, 7)   # 300, 500, 700 ms bursts
OFF_SLOTS = (1, 2)     # 100, 200 ms silences
SEED = 7               # fixed: the analyser relies on the file, not the seed


def pattern(seconds: int = SECONDS) -> list:
    """One bool per SLOT_MS slot: True = tone on. Deterministic."""
    rng = random.Random(SEED)
    slots = []
    total = seconds * 1000 // SLOT_MS
    while len(slots) < total:
        slots += [True] * rng.choice(ON_SLOTS)
        slots += [False] * rng.choice(OFF_SLOTS)
    return slots[:total]


def click_shape() -> list:
    """The click: CLICK_MS of a CLICK_FREQ sine under a raised-cosine (Hann)
    window, so its energy sits in a band well above the 440 Hz tone (the
    continuity detector high-passes at ~1.2 kHz to pick it out) and inside
    what every codec on the path carries (PCMU stops at 4 kHz)."""
    n = RATE * CLICK_MS // 1000
    return [CLICK_AMP * 0.5 * (1 - math.cos(2 * math.pi * k / n)) * math.sin(2 * math.pi * CLICK_FREQ * k / RATE)
            for k in range(n)]


def write(out: Path, seconds: int = SECONDS, clicks: bool = False) -> None:
    slots = pattern(seconds)
    per_slot = RATE * SLOT_MS // 1000
    ramp = RATE // 200  # 5 ms fade at each edge: no clicks, no codec pre-echo
    shape = click_shape() if clicks else []
    period = RATE * CLICK_MS_PERIOD // 1000  # samples between click onsets: exact
    with wave.open(str(out), "wb") as w:
        w.setnchannels(CHANNELS)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = bytearray()
        for i in range(RATE * seconds):
            slot = i // per_slot
            on = slots[slot]
            s = 0
            if on:
                pos = i - slot * per_slot
                gain = 1.0
                if pos < ramp and (slot == 0 or not slots[slot - 1]):
                    gain = pos / ramp
                elif pos >= per_slot - ramp and (slot + 1 >= len(slots) or not slots[slot + 1]):
                    gain = (per_slot - pos) / ramp
                s = int(AMP * gain * math.sin(2 * math.pi * FREQ * i / RATE))
            if shape and i >= period:
                k = i % period
                if k < len(shape):
                    s += int(shape[k])
            frames += struct.pack("<hh", s, s)
        w.writeframes(bytes(frames))
    on_ms = sum(1 for s in slots if s) * SLOT_MS
    extra = f", a click every {CLICK_MS_PERIOD} ms from {CLICK_MS_PERIOD} ms" if clicks else ""
    print(f"wrote {out} ({RATE * seconds} frames, {CHANNELS} ch, tone on {on_ms / 1000:.1f} s of {seconds}{extra})")


def main(argv: list) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("outputs", nargs="*", help="WAV path(s); default in.wav next to this script")
    ap.add_argument("--clicks", action="store_true", default=os.environ.get("CLICKS") == "1",
                    help="superimpose the click train (also CLICKS=1 in the environment)")
    ap.add_argument("--seconds", type=int, default=SECONDS, help=f"length in seconds (default {SECONDS})")
    args = ap.parse_args(argv)
    targets = [Path(p) for p in args.outputs] or [Path(__file__).with_name("in.wav")]
    for t in targets:
        t.parent.mkdir(parents=True, exist_ok=True)
        write(t, args.seconds, args.clicks)


if __name__ == "__main__":
    main(sys.argv[1:])
