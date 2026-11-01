# playout — adaptive playout on the speaker's clock (lab/audio-continuity)

This directory is the trial fix for the brief audio drops heard in the app
(attribution 2026-11-01: every drop was the receive path's play buffer
`aubuf`/`ajb` reacting to a disturbance by discarding audio on its first
read, padding zeros on an underrun and skipping 10–20 ms chunks to shed
latency; the disturbances were a start-of-call backlog, the server host's
Wi-Fi batching, the phone's own Wi-Fi power save, and ordinary stalls).

It replaces `aubuf` on the receive path with a buffer designed after
WebRTC's NetEq, which is how the industry handles the same problem:

| | aubuf / ajb (baresip 3.15) | playout (this) |
|---|---|---|
| start of call | trims everything beyond 40 ms on the first read: the far end's opening is discarded | keeps it all, accelerates it away |
| above target | skips a render buffer (10–20 ms) when its silence test, taken on the wrong frame, allows | removes one pitch period per read with WSOLA, at the quietest offset in the block |
| below target | nothing | inserts one pitch period per read (preemptive expand) |
| underrun | writes zeros, then refills to 40 ms | conceals by repeating the last pitch period with decay, merges real audio back with a cross-fade, and does not advance the timeline (late audio plays, delay grows, acceleration brings it back) |
| loss (hole with later audio present) | zeros | concealed and skipped; the codec's own PLC/FEC still runs first (aureceiver's lost-frame patch) |
| rate of correction | one skip per render buffer, no limit | 10 % of read time in speech (NetEq's timescale countdown, as a budget), unlimited in silence or ≥ 200 ms above target |
| target | reorder-driven jitter buffer wish + adaptive play buffer | a high quantile of arrival lateness relative to the fastest recent packet, plus one packet; up at once, down one packet at a time; bumped on an underrun |
| decision input | raw level | low-pass filtered level (NetEq's BufferLevelFilter), so bunched arrival does not cause accelerate/stretch oscillation |

Plain C99, one lock, no dependencies, mono S16LE at the player's rate.

## Files

- `playout.h`, `playout.c` — the engine. Copied into `baresip/src/` by
  `build-baresip.sh apply_patches` and added to `CMakeLists.txt` by
  `apply-baresip.sh`.
- `test/playout_test.c` — 26 scenario tests, `make lab-playout-test`:
  nominal (bit-exact at 8/16/48 kHz, 20 ms reads; one packet of headroom
  built once for unaligned 512/1024-sample reads; 5 minutes), start
  backlogs of 8/15/30 packets, stalls of 60/100/150/300 ms, Wi-Fi bunching
  5-per-105 ms and 10-per-200 ms, jitter 0–30/0–80 ms, loss 2 %/5 %/double,
  reordered pairs, ±0.1 % clock drift, a 600 ms straggler, flush/restart.
  Judges: bit-exactness, every click of a click train surviving, spacing
  deviations, no sample step larger than the signal's own (hard cut),
  zeros only before the first packet or past the 240 ms concealment
  horizon, level settled to target. `-w out.wav <scenario>` writes the
  output; `harness/spike/assert_audio.py --continuity` on it is the
  independent cross-check (backlog-30: 79/79 clicks, bunching: 0 events,
  stall-60: 46 ms inserted, nothing removed).

## Integration hunks (apply-baresip.sh, "Dialler lab" markers)

`src/aureceiver.c`:
1. `#include "playout.h"` after `core.h`.
2. `struct playout *po;` next to `struct aubuf *aubuf;`; `playout_free` in the destructor.
3. `aurecv_po_event`: the engine's events onto the continuity ring (`AU_EV_PO_*`, declared by `apply-re.sh` in `re_tmr.h`).
4. `aurecv_push_aubuf`: allocate the engine on the first decoded frame from `cfg->buffer.min/max` (ms), the frame's post-filter sample rate and `ar->ptime`; write each frame with `playout_write(pcm, sampc, ts_samples, now_us)` where `ts_samples = af.timestamp * srate / AUDIO_TIMEBASE`; a late packet is a statistic, not an error; `stats.latency` from `playout_stats().level_ms`.
5. SSRC change (`flush`) and `aurecv_flush` also `playout_flush`.
6. `aurecv_read`: the player pulls `playout_read(af->sampv, af->sampc, now_us)`; the engine has its own lock, `aubuf_mtx` only guards the pointer.
   `aubuf` is still allocated and written nowhere; it can be removed outright on the production branch.

`src/rtprecv.c`: with the jitter buffer off, `handle_rtp` received `lostc = 0`; it now gets `lostcalc()` like the jitter-buffer path, so Opus PLC/FEC still conceal real losses before the engine sees a hole.

`CMakeLists.txt`: `src/playout.c`.

App config (`BaresipCallEngine.stackConfig`): `audio_jitter_buffer_type off`, `audio_buffer 20-400` (the engine's min/max target). `StackConfigTests` updated accordingly.

## For the production branch

Carry over: the engine (unchanged, with its tests and make target), hunks 1–6 (dropping `aubuf` entirely rather than leaving it allocated), the `rtprecv.c` loss-count hunk, the config change, and a per-call summary line reduced to the engine's counters (`po_accel_ms`, `po_stretch_ms`, `po_conceal_ms`, `po_zero_ms`, `po_late`, target range). Leave behind: the event ring and dump (lab instrumentation), the AB_*/JB_* hooks (the code they instrument is no longer on the path), `-lab-pump-delay`, `-rtp-trace`.

Tunables worth knowing on the production branch: `SCALE_RATE` 0.10 and `FAST_ABOVE_MS` 200 (the correction rate; one period per read was heard as a 75 % speed-up on the device), `TARGET_QUANTILE` 0.95, `HIST_PACKETS` 100.

Known limits: mono S16LE only (what the app negotiates); concealment decays to silence after ~240 ms (any PLC does); acceleration attenuates an isolated 2 ms transient that falls inside a cross-fade (the quiet-offset choice avoids it when the block has a stationary stretch; the harness detector saw none lost on the 600 ms backlog drain).
