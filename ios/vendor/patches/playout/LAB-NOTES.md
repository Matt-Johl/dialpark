# Lab notes — brief audio drops (lab/audio-continuity, 2026-10-31 to 2026-11-01)

The finding, the trial fix, its measurements, and what the production branch
should carry. The instrument and the attribution live in this branch's
history; this file is the brief.

## Attribution (device 10911, 14 calls over two days, Wi-Fi then Ethernet server)

Every audible drop was the phone's play buffer (`aubuf`/`ajb`, baresip 3.15)
converting a disturbance into removed or padded audio:

| Pattern | Mechanism in the phone | Trigger | Removed / inserted |
|---|---|---|---|
| Opening of every call cut | first-read trim to 40 ms, overrun beyond 160 ms | app→CUCM: 7–15 packets queued at the server between CUCM's 200 OK and the app's ACK (230–320 ms); CUCM→app: CallKit activation + first render 240–420 ms after the first packet | 20–360 ms removed |
| Periodic pads then skips | underrun → 40 ms zeros; `ajb` HIGH → 10–20 ms skips to shed latency | the server host on Wi-Fi batching all inbound RTP per beacon (~100 ms, both directions, even a wired desk phone's stream); gone on Ethernet (server jitter 8 → 0.4 ms) | 13–18 pads + 14–17 skips per minute |
| Phase of pads/skips mid-call | same | the phone's own Wi-Fi power save (its uplink in 5-packet/105 ms bursts for 32–34 s; low battery, screen off) | pads at onset, skips at the end |
| Isolated hiccup | same | a real 50–150 ms stall, 2–3 per minute | 40 ms pad + 20 ms skip each |

The jitter buffer's wish never changed on the device (it reacts to reordering,
not timing); the simulator's `wish_down` excision did not occur on hardware.
Server relay: nothing dropped, ever. CoreAudio: no mid-call render gaps.

## The trial fix: `playout` (this directory)

NetEq-style playout on the speaker's clock replacing `aubuf`: keep the start
backlog and accelerate it away (WSOLA, one pitch period per 20 ms read at the
quietest offset), stretch when below target, conceal underruns by repeating
the last period without advancing the timeline (late audio is played, delay
grows, acceleration brings it back), merge real audio with a cross-fade,
skip only holes with later audio present, drop only packets already behind
the playout position; target = 95th percentile of arrival lateness vs the
fastest recent packet + one packet, decisions on a filtered level.

### Measurements, before → after

Real engine (iOS simulator, CoreAudio output, docker server):

| Scenario | aubuf (before) | playout (after) |
|---|---|---|
| clean call, 6 s | 120–160 ms removed at start (first-read + overrun) | 0 removed; 148–196 ms time-compressed over the first 2 s; 0 concealed; 0 zeros |
| server backlog 300 ms | 260 ms removed at start | 0 removed; 271 ms compressed; 0 concealed |
| clean 30 s | 120 ms removed at start | 148 ms compressed in the first 2 s, then **no operation for 28 s** |
| impaired 30 s (2 % loss, 30 ± 10 ms jitter) | 150 ms removed (4 wish-shrink cuts, 7 ajb skips), 200 ms zeros, 5 underruns | 0 removed, 0 concealed by the engine (Opus PLC/FEC first), 1 ms zeros at hangup, target 40–145 |

Bench (harness phones, click-train detector on the recording):

| Scenario | before | after |
|---|---|---|
| control 30 s | 0 / 0 | 0 / 0 |
| backlog 300 ms | 20 ms removed at +7.6 s (shrink cut) | 115–141 ms compressed in the first 2.7 s, 1 of 118 clicks attenuated below detection |
| burst 700 ms at +0.7 s | 0 events — the burst stayed as permanent latency (upstream re#1645) | 453 ms compressed over 1.4 s, all 123 clicks present |
| stall 60 ms ×2 | 36 ms removed, 40 ms inserted | 0 removed, 40 ms inserted (the wait itself) |
| quiet 60 s | 0 / 0 | 12 ms compressed at start, one 20 ms wait |

Unit scenarios (`make lab-playout-test`): 26, all pass; nominal paths bit-exact.
Regression with the engine in the harness phones: harness-trunk (all
scenarios), harness-delayed-offer, harness-call pass.

What "compressed" means: time-scaled speech, pitch-preserved, not deleted
content; the detector measures click spacing. The one attenuated click in a
600 ms drain is a transient that fell inside a cross-fade; speech plosives
are longer than 2 ms and the quiet-offset choice avoids them when the block
has a stationary stretch.

## What the production branch should do

1. **Phone:** the engine as in README.md (hunks 1–6, `rtprecv.c` loss count,
   config `audio_jitter_buffer_type off`, `audio_buffer 20-400`), dropping
   `aubuf` from the receive path entirely. Keep `make lab-playout-test` as a
   permanent unit gate and the continuity bench scenarios as a harness gate
   with a threshold (control/quiet: 0 removed, 0 inserted; backlog/burst: no
   click lost; stall: inserted ≤ the stall).
2. **Server:** start the relay when the callee answers, not at the caller's
   ACK. Not done in the lab because it is a vendored-diago change, not a
   bridge reorder: `answerSession` initialises the caller's RTP session,
   then `RespondSDP` sends the 200 OK and blocks until the ACK, and only then
   `Finalize()` (SRTP contexts) and `MonitorBackground()` run. The relay
   needs a hook after the 200 OK is written with `Finalize` moved before the
   ACK wait (both SDPs are known by then). With the engine in place the
   backlog costs only 200–300 ms of latency for the first second or two, so
   this is a refinement, not the fix.
3. **Deployment rules:** the server host on a wire; access points with WMM,
   U-APSD and DTIM 1 for voice. The phone-side power save cannot be
   controlled by the app on iOS beyond the voice service type it already
   sets.
4. **Leave in the lab:** the event ring and its dump, the `AB_*`/`JB_*`
   hooks, `-lab-pump-delay`, `-rtp-trace`, the per-packet trace, the
   correlation tool (useful, but a tools/ item, not product code).
