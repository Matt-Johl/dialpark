/* playout — an adaptive playout buffer driven by the speaker's clock.
 *
 * Lab build (lab/audio-continuity). Replaces baresip's aubuf/ajb on the
 * receive path of the Dialler app. Design after WebRTC's NetEq (BSD):
 *
 *   - decoded PCM goes in with its RTP timestamp and arrival time;
 *   - the speaker pulls N samples at a time and gets exactly N;
 *   - a target delay is estimated from arrival statistics (how late each
 *     packet is against a constant-rate timeline anchored on the fastest
 *     recent packet, taken at a high quantile), bounded by min/max;
 *   - when more audio is buffered than the target, playout is
 *     ACCELERATED by removing one pitch period per read with a
 *     waveform-similarity overlap-add (WSOLA); when less, it is
 *     PREEMPTIVELY EXPANDED by inserting one; when nothing has arrived,
 *     the hole is CONCEALED by repeating the last pitch period with
 *     decay (EXPAND), and real audio is MERGED back with a cross-fade.
 *   - nothing is ever discarded on a first read, and no zeros are ever
 *     written while there is history to conceal from. A packet is
 *     dropped only when it is already behind the playout position.
 *
 * Plain C99, no dependencies, so it is unit-tested on its own
 * (test/playout_test.c) before it is wired into baresip (aureceiver.c).
 * Mono 16-bit only, which is what the app's codecs produce.
 */
#ifndef PLAYOUT_H
#define PLAYOUT_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

struct playout;

struct playout_cfg {
	uint32_t srate;         /* samples per second (8000, 16000, 48000) */
	uint32_t min_delay_ms;  /* target floor, e.g. 20 */
	uint32_t max_delay_ms;  /* target ceiling and buffer capacity, e.g. 400 */
	uint32_t ptime_ms;      /* nominal packet time, e.g. 20 (for statistics) */
};

/* Counters, cumulative since alloc. All in milliseconds of audio. */
struct playout_stats {
	uint64_t normal_ms;       /* played as received */
	uint64_t accelerate_ms;   /* removed by time compression */
	uint64_t preemptive_ms;   /* added by time stretching */
	uint64_t expand_ms;       /* concealed (no audio available) */
	uint64_t zero_ms;         /* silence written with no history to conceal from */
	uint32_t late_packets;    /* arrived behind the playout position, dropped */
	uint64_t overflow_ms;     /* oldest audio skipped because the ring was full */
	uint32_t ops_accelerate, ops_preemptive, ops_expand, ops_merge;
	uint32_t target_ms;       /* current target delay */
	uint32_t level_ms;        /* audio buffered ahead of the playout position */
	uint32_t max_level_ms;    /* high-water mark of level_ms */
};

struct playout *playout_alloc(const struct playout_cfg *cfg);
void playout_free(struct playout *p);

/* Decoded audio for RTP timestamp ts (in samples at srate), arrived at
 * now_us (monotonic microseconds). Returns 0, or ETIMEDOUT for a packet
 * already behind the playout position (dropped), or EINVAL. */
int playout_write(struct playout *p, const int16_t *pcm, size_t sampc,
		  uint32_t ts, uint64_t now_us);

/* Fill out with exactly sampc samples for the speaker, deciding per call
 * between normal, accelerate, preemptive expand and expand. */
void playout_read(struct playout *p, int16_t *out, size_t sampc, uint64_t now_us);

/* Forget everything (a new stream: SSRC change, resume after hold). */
void playout_flush(struct playout *p);

void playout_stats(const struct playout *p, struct playout_stats *st);

/* Lab: an event hook for the continuity ring (kind strings below). NULL
 * to disable. a and b are milliseconds or counts as documented per kind. */
typedef void (playout_event_h)(const char *kind, int32_t a, int32_t b, void *arg);
void playout_set_event_handler(struct playout *p, playout_event_h *h, void *arg);
/* kinds: "accelerate" a=ms removed b=level_ms; "preemptive" a=ms added;
 * "expand" a=ms concealed b=level_ms; "zeros" a=ms; "merge";
 * "late" a=samples behind; "target" a=old b=new (ms); "flush". */

#endif
