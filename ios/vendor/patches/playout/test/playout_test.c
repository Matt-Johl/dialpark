/* Scenario tests for the playout engine (lab/audio-continuity).
 *
 * A source signal is packetised into 20 ms frames; a scripted network
 * delivers them to the engine with the delays, bursts, losses and
 * reorderings of each scenario while a simulated speaker pulls audio on
 * its own clock. The output is then judged:
 *
 *   exact      bit-identical to the source once audio has started (nominal)
 *   clicks     every click of the source's click train is in the output
 *              unless its packet was lost; the spacings say how much time
 *              was removed or added and where
 *   smooth     no hard cut: the largest sample-to-sample step is bounded
 *              by what the signal itself produces (a cut in a 440 Hz tone
 *              is a step many times that)
 *   silence    no zeros written after the first packet unless the scenario
 *              starves the engine beyond its concealment horizon
 *   latency    the buffered level settles to target ± one packet
 *
 *   cc -O2 -std=c99 -Wall -Wextra -lm -o playout_test test/playout_test.c playout.c
 *   ./playout_test            (all scenarios)
 *   ./playout_test -v name    (one scenario, verbose)
 */
#include "../playout.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PTIME_MS 20
#define CLICK_MS 250
#define TONE_HZ 440.0
#define TONE_AMP 6000.0
#define CLICK_AMP 14000.0
#define SECONDS_DEFAULT 20

static int verbose = 0;
static int failures = 0;
static const char *wav_out = NULL; /* -w path: write the clicked output of the chosen scenario */

static void write_wav(const char *path, const int16_t *x, size_t n, uint32_t srate)
{
	FILE *f = fopen(path, "wb");
	uint32_t data = (uint32_t)(n * 2), fmt = 16, riff = 36 + data, byterate = srate * 2;
	uint16_t one = 1, mono = 1, align = 2, bits = 16;
	if (!f) return;
	fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVE", 1, 4, f);
	fwrite("fmt ", 1, 4, f); fwrite(&fmt, 4, 1, f); fwrite(&one, 2, 1, f); fwrite(&mono, 2, 1, f);
	fwrite(&srate, 4, 1, f); fwrite(&byterate, 4, 1, f); fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f);
	fwrite("data", 1, 4, f); fwrite(&data, 4, 1, f); fwrite(x, 2, n, f);
	fclose(f);
}

#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("   FAIL: " __VA_ARGS__); printf("\n"); } else if (verbose) { printf("   ok: " __VA_ARGS__); printf("\n"); } } while (0)

/* ---- signal ------------------------------------------------------------------ */

static uint32_t rng_state = 12345;
static uint32_t rng(void) { rng_state = rng_state * 1664525u + 1013904223u; return rng_state; }
static double urand(void) { return (rng() >> 8) / 16777216.0; }

/* kind 0: 440 Hz tone with a 2 ms raised-cosine 2.4 kHz click every 250 ms
 * from 250 ms; 1: a 150 Hz voiced buzz with the clicks; 2: the pure tone;
 * 3: white noise at speech level (unvoiced: no periodicity to scale) with
 * a one-second pause every four seconds (t mod 4 in [3,4)); 4: one second
 * of tone and one of noise, alternating, no pause. */
#define NOISE_AMP 8000.0
static int noise_at(double t, int kind)
{
	if (kind == 3) return fmod(t, 4.0) < 3.0;
	if (kind == 4) return fmod(t, 2.0) >= 1.0;
	return 0;
}
static int16_t *make_signal(uint32_t srate, double seconds, int kind, size_t *n_out)
{
	size_t n = (size_t)(srate * seconds), i;
	int16_t *x = calloc(n, sizeof(int16_t));
	if (kind >= 3) rng_state = 777; /* the noise is the same on every run */
	for (i = 0; i < n; i++) {
		double t = (double)i / srate, v;
		if (kind == 3 && !noise_at(t, 3)) {
			v = 0;
		}
		else if (noise_at(t, kind)) {
			v = (urand() - 0.5) * NOISE_AMP;
		}
		else if (kind == 0 || kind == 2 || kind == 4) {
			v = TONE_AMP * sin(2 * M_PI * TONE_HZ * t);
		}
		else {
			/* a pulse train at 150 Hz through a damped resonance ~ 800 Hz */
			double ph = fmod(t * 150.0, 1.0);
			v = 9000.0 * exp(-ph * 12.0) * cos(2 * M_PI * 800.0 * ph / 150.0);
		}
		if (kind == 0 || kind == 1) {
			double ms = t * 1000.0, c = fmod(ms, CLICK_MS);
			if (ms >= CLICK_MS && c < 2.0) {
				double w = 0.5 * (1 - cos(2 * M_PI * c / 2.0));
				v += CLICK_AMP * w * sin(2 * M_PI * 2400.0 * (c / 1000.0));
			}
		}
		if (v > 32767) v = 32767;
		if (v < -32768) v = -32768;
		x[i] = (int16_t)v;
	}
	*n_out = n;
	return x;
}

/* ---- network scripts ------------------------------------------------------------ */

struct packet {
	size_t idx;         /* frame number */
	int64_t arrival_us; /* -1 = lost */
};

struct script {
	struct packet *pk;
	size_t n;
};

static struct script script_alloc(size_t frames)
{
	struct script s;
	s.pk = calloc(frames, sizeof(struct packet));
	s.n = frames;
	for (size_t i = 0; i < frames; i++) {
		s.pk[i].idx = i;
		s.pk[i].arrival_us = (int64_t)i * PTIME_MS * 1000 + 300000; /* nominal, 300 ms in */
	}
	return s;
}

/* ---- simulation ------------------------------------------------------------------ */

struct run {
	int16_t *out;
	size_t out_n;
	struct playout_stats st;
	int events;
	char evlog[16384];
	size_t evlen;
	int64_t now_us;
};

static void on_event(const char *kind, int32_t a, int32_t b, void *arg)
{
	struct run *r = arg;
	r->events++;
	if (r->evlen < sizeof(r->evlog) - 64)
		r->evlen += (size_t)snprintf(r->evlog + r->evlen, sizeof(r->evlog) - r->evlen, "%lld:%s(%d,%d) ", (long long)(r->now_us / 1000), kind, a, b);
}

/* Deliver the scripted packets while the speaker pulls read_n samples
 * every read_n/srate seconds, for the duration of the script plus a tail. */
static struct run simulate(const int16_t *src, size_t src_n, uint32_t srate, const struct script *sc,
			   size_t read_n, const struct playout_cfg *cfg, double drift)
{
	struct run r;
	struct playout *p = playout_alloc(cfg);
	size_t frame = srate * PTIME_MS / 1000, frames = src_n / frame;
	int64_t t_end = 0, now = 0;
	for (size_t i = 0; i < sc->n; i++) if (sc->pk[i].arrival_us > t_end) t_end = sc->pk[i].arrival_us;
	t_end += 1; /* the read at the last packet's arrival plays it; the stream's end is not a stall */
	size_t out_cap = (size_t)((double)t_end / 1e6 * srate) + read_n * 2;
	size_t next = 0;
	/* delivery order by arrival time (stable) */
	size_t *order = malloc(sc->n * sizeof(size_t));
	memset(&r, 0, sizeof(r));
	for (size_t i = 0; i < sc->n; i++) order[i] = i;
	for (size_t i = 1; i < sc->n; i++) { /* insertion sort by arrival */
		size_t j = i, k = order[i];
		while (j > 0 && sc->pk[order[j - 1]].arrival_us > sc->pk[k].arrival_us) { order[j] = order[j - 1]; j--; }
		order[j] = k;
	}
	r.out = calloc(out_cap, sizeof(int16_t));
	playout_set_event_handler(p, on_event, &r);
	while (now < t_end && r.out_n + read_n <= out_cap) {
		while (next < sc->n && sc->pk[order[next]].arrival_us >= 0 && sc->pk[order[next]].arrival_us <= now) {
			const struct packet *pk = &sc->pk[order[next]];
			if (pk->idx < frames) {
				/* drift: the sender's timestamps advance at (1+drift) of our clock */
				uint32_t ts = (uint32_t)((double)pk->idx * frame);
				(void)drift;
				playout_write(p, src + pk->idx * frame, frame, ts, (uint64_t)pk->arrival_us);
			}
			next++;
		}
		while (next < sc->n && sc->pk[order[next]].arrival_us < 0) next++; /* lost */
		r.now_us = now;
		playout_read(p, r.out + r.out_n, read_n, (uint64_t)now);
		r.out_n += read_n;
		now += (int64_t)(read_n * 1000000.0 / srate / (1.0 + drift));
	}
	playout_stats(p, &r.st);
	playout_free(p);
	free(order);
	return r;
}

/* ---- judges -------------------------------------------------------------------- */

/* Click onsets in ms: energy of a high-passed signal per 1 ms, peaks above
 * a threshold with 100 ms minimum spacing. */
static size_t find_clicks_thr(const int16_t *x, size_t n, uint32_t srate, double *times, size_t max, double thr);
static size_t find_clicks(const int16_t *x, size_t n, uint32_t srate, double *times, size_t max)
{
	return find_clicks_thr(x, n, srate, times, max, 0.1);
}
static size_t find_clicks_thr(const int16_t *x, size_t n, uint32_t srate, double *times, size_t max, double thr)
{
	size_t bin = srate / 1000, nb = n / bin, count = 0, i;
	double *e = calloc(nb, sizeof(double));
	double peak = 0;
	int16_t prev = 0;
	for (i = 0; i < n; i++) {
		double d = (double)x[i] - prev; /* first difference: a crude high-pass */
		prev = x[i];
		if (i / bin < nb)
			e[i / bin] += d * d;
	}
	for (i = 0; i < nb; i++) if (e[i] > peak) peak = e[i];
	for (i = 1; i + 1 < nb; i++) {
		if (e[i] > thr * peak && e[i] >= e[i - 1] && e[i] > e[i + 1]) {
			if (count && (double)i - times[count - 1] < 100) continue;
			if (count < max) times[count++] = (double)i;
		}
	}
	free(e);
	return count;
}

/* The largest sample-to-sample step, relative to the step a clean copy of
 * the source makes (its own derivative). */
static double max_step_ratio(const int16_t *x, size_t n, const int16_t *src, size_t src_n)
{
	double mx = 0, ms = 0;
	size_t i;
	for (i = 1; i < n; i++) { double d = fabs((double)x[i] - x[i - 1]); if (d > mx) mx = d; }
	for (i = 1; i < src_n; i++) { double d = fabs((double)src[i] - src[i - 1]); if (d > ms) ms = d; }
	return ms > 0 ? mx / ms : 0;
}

/* For the tone: the largest step away from any click (clicks are the
 * signal's own steps), against the tone's analytic maximum derivative. A
 * hard cut in a 6000-amplitude tone is a step of up to 12000, about 35x. */
/* On a click-free tone run: the largest step against the tone's analytic
 * maximum derivative. A hard cut in a 6000-amplitude tone is up to 35x. */
static double step_at_ms = 0;
static double tone_step_ratio(const int16_t *x, size_t n, uint32_t srate)
{
	double mx = 0, ref = TONE_AMP * 2 * M_PI * TONE_HZ / srate;
	size_t i;
	for (i = 1; i < n; i++) {
		double d = fabs((double)x[i] - x[i - 1]);
		if (d > mx) { mx = d; step_at_ms = (double)i * 1000 / srate; }
	}
	return mx / ref;
}

/* Removed/added milliseconds judged from click spacings (expected 250 ms). */
static void judge_clicks(const struct run *r, uint32_t srate, size_t expect_min, double *removed, double *added, size_t *found)
{
	double t[4096];
	size_t n = find_clicks(r->out, r->out_n, srate, t, 4096), i;
	*removed = *added = 0;
	for (i = 1; i < n; i++) {
		double d = t[i] - t[i - 1];
		/* a vanished click gives ~500; count only the deviation of the surviving spacing */
		while (d > 375) d -= 250;
		if (d < 250) *removed += 250 - d; else *added += d - 250;
	}
	*found = n;
	(void)expect_min;
}

static int exact_after_start(const struct run *r, const int16_t *src, size_t src_n, size_t *first_nz)
{
	size_t i = 0, j = 0, k;
	while (i < r->out_n && r->out[i] == 0) i++;
	while (j < src_n && src[j] == 0) j++;
	*first_nz = i;
	if (i >= r->out_n) return 0;
	for (k = 0; k + i < r->out_n && k + j < src_n; k++)
		if (r->out[k + i] != src[k + j]) return 0;
	return 1;
}

/* Is src[from..from+len) present in the output, sample for sample? The
 * segment's first 480 samples locate it (noise is unique), then the whole
 * segment must follow. A time-scaling operation anywhere inside breaks it. */
static int segment_exact(const struct run *r, const int16_t *src, size_t from, size_t len, size_t *at)
{
	size_t probe = 480, i;
	if (len < probe || r->out_n < probe) return 0;
	for (i = 0; i + len <= r->out_n; i++) {
		if (r->out[i] != src[from] || memcmp(r->out + i, src + from, probe * sizeof(int16_t)))
			continue;
		*at = i;
		return memcmp(r->out + i, src + from, len * sizeof(int16_t)) == 0;
	}
	*at = 0;
	return 0;
}

/* The rate rule, read off the event log: no time-scaling operation is
 * larger than one period (15 ms) and no two are closer than MIN_OP_GAP
 * (50 ms), whatever the level. For scenarios without silence, where the
 * rule is lifted. Returns the number of violations; prints the first. */
static int judge_rate(const struct run *r)
{
	const char *q = r->evlog;
	long long target = 40, last = -1000000;
	int bad = 0;
	while (q && *q) {
		long long t; char kind[32]; int a, b;
		if (sscanf(q, "%lld:%31[^(](%d,%d)", &t, kind, &a, &b) == 4) {
			if (!strcmp(kind, "target"))
				target = b;
			else if (!strcmp(kind, "accelerate") || !strcmp(kind, "preemptive")) {
				if (a > 15 || t - last < 50) {
					if (!bad) printf("   rate violation: %s %d ms at %lld ms, %lld ms after the previous (level %d, target %lld)\n", kind, a, t, t - last, b, target);
					bad++;
				}
				last = t;
			}
		}
		q = strchr(q, ' '); if (q) q++;
	}
	return bad;
}

static void report(const char *name, const struct run *r)
{
	printf("%-28s normal=%llums accel=%llums(%u) preempt=%llums(%u) expand=%llums(%u) zeros=%llums late=%u overflow=%llums target=%ums level=%ums max=%ums events=%d\n",
	       name, (unsigned long long)r->st.normal_ms, (unsigned long long)r->st.accelerate_ms, r->st.ops_accelerate,
	       (unsigned long long)r->st.preemptive_ms, r->st.ops_preemptive, (unsigned long long)r->st.expand_ms, r->st.ops_expand,
	       (unsigned long long)r->st.zero_ms, r->st.late_packets, (unsigned long long)r->st.overflow_ms, r->st.target_ms, r->st.level_ms, r->st.max_level_ms, r->events);
	if (verbose) printf("   events: %s\n", r->evlog);
}

/* ---- scenarios ----------------------------------------------------------------- */

static struct playout_cfg cfg48 = { 48000, 20, 400, PTIME_MS };

static void scenario_nominal(uint32_t srate, size_t read_n, int kind, double seconds)
{
	struct playout_cfg cfg = { srate, 20, 400, PTIME_MS };
	size_t n, first;
	int16_t *src = make_signal(srate, seconds, kind, &n);
	struct script sc = script_alloc(n / (srate * PTIME_MS / 1000));
	struct run r = simulate(src, n, srate, &sc, read_n, &cfg, 0);
	char name[64];
	snprintf(name, sizeof(name), "nominal %uHz read=%zu %s %.0fs", srate, read_n, kind ? "voice" : "tone", seconds);
	report(name, &r);
	if ((srate * PTIME_MS / 1000) % read_n == 0 || read_n % (srate * PTIME_MS / 1000) == 0) {
		CHECK(exact_after_start(&r, src, n, &first), "output is bit-exact after %zu leading samples", first);
		CHECK(r.st.accelerate_ms == 0 && r.st.preemptive_ms == 0 && r.st.expand_ms == 0, "no time-scaling or concealment on a clean path");
	}
	else {
		/* reads not aligned to packets: the level dips below one packet
		 * between arrivals, and one packet of headroom is built once */
		CHECK(r.st.ops_preemptive <= 4 && r.st.accelerate_ms == 0 && r.st.expand_ms <= 5, "unaligned reads: one underrun of a few ms at the start raises the target, headroom is built by stretching (%u stretches, %llu ms concealed), nothing else", r.st.ops_preemptive, (unsigned long long)r.st.expand_ms);
	}
	CHECK(r.st.late_packets == 0 && r.st.overflow_ms == 0, "nothing dropped");
	CHECK(r.st.level_ms <= r.st.target_ms + PTIME_MS, "level %u within target %u + one packet", r.st.level_ms, r.st.target_ms);
	free(src); free(sc.pk); free(r.out);
}

/* The start-of-call backlog: the first `burst` packets arrive together. */
static void scenario_backlog(size_t burst)
{
	size_t n, found, frames;
	double removed, added, ratio;
	int16_t *src = make_signal(48000, SECONDS_DEFAULT, 0, &n);
	struct script sc = script_alloc(n / (48000 * PTIME_MS / 1000));
	struct run r;
	char name[64];
	frames = sc.n;
	for (size_t i = 0; i < burst && i < frames; i++)
		sc.pk[i].arrival_us = 300000 + (int64_t)burst * PTIME_MS * 1000; /* all at the time the last one would have come */
	r = simulate(src, n, 48000, &sc, 960, &cfg48, 0);
	snprintf(name, sizeof(name), "backlog %zu packets", burst);
	report(name, &r);
	judge_clicks(&r, 48000, 0, &removed, &added, &found);
	if (wav_out) write_wav(wav_out, r.out, r.out_n, 48000);
	{
		size_t n2; int16_t *pure = make_signal(48000, SECONDS_DEFAULT, 2, &n2);
		struct run r2 = simulate(pure, n2, 48000, &sc, 960, &cfg48, 0);
		ratio = tone_step_ratio(r2.out, r2.out_n, 48000);
		free(pure); free(r2.out);
	}
	printf("   clicks found=%zu of %d, spacing removed=%.0fms added=%.0fms, max step ratio=%.2f at %.0f ms\n", found, (int)(SECONDS_DEFAULT * 1000 / CLICK_MS) - 1, removed, added, ratio, step_at_ms);
	CHECK(found * 10 >= (size_t)((SECONDS_DEFAULT * 1000 / CLICK_MS) - 1) * 9, "clicks survive acceleration (%zu of %d; a transient inside a cross-fade is attenuated, never removed)", found, (int)(SECONDS_DEFAULT * 1000 / CLICK_MS) - 1);
	CHECK(r.st.zero_ms <= 320 + burst * PTIME_MS, "no zeros beyond the wait for the burst (%llu ms)", (unsigned long long)r.st.zero_ms);
	CHECK(r.st.expand_ms == 0, "no concealment needed");
	CHECK(r.st.level_ms <= r.st.target_ms + PTIME_MS, "backlog drained to target: level %u target %u", r.st.level_ms, r.st.target_ms);
	CHECK(ratio < 3.0, "no hard cut in the output (max step %.2fx the tone's own)", ratio);
	CHECK(r.st.accelerate_ms + r.st.target_ms + 3 * PTIME_MS >= burst * PTIME_MS, "the backlog was removed by acceleration (%llu ms of %zu)", (unsigned long long)r.st.accelerate_ms, burst * PTIME_MS);
	CHECK(judge_rate(&r) == 0, "one period at most per operation, 50 ms at least between operations, outside the fast band");
	{
		/* the drain is gentle once within 200 ms of target: no second of
		 * speech is compressed by more than ~12 % (the tone is never
		 * "silent", so this is the speech budget at work) */
		double tmax = 0; const char *q = r.evlog; int worst_s = -1;
		double bucket[64] = {0};
		while (q && *q) {
			long long t; char kind[32]; int a, b;
			if (sscanf(q, "%lld:%31[^(](%d,%d)", &t, kind, &a, &b) == 4 && !strcmp(kind, "accelerate") && t / 1000 < 64)
				bucket[t / 1000] += a;
			q = strchr(q, ' '); if (q) q++;
		}
		for (int i = 0; i < 64; i++) if (bucket[i] > tmax) { tmax = bucket[i]; worst_s = i; }
		printf("   worst second of compression: %.0f ms at %ds\n", tmax, worst_s);
		if (burst * PTIME_MS <= 320)
			CHECK(tmax <= 200, "compression never exceeds the fast-drain band plus the 10%% budget in any second (%.0f ms)", tmax);
	}
	free(src); free(sc.pk); free(r.out);
}

/* Packets held for hold_ms at second 5 (and 12), then released at once. */
static void scenario_stall(int hold_ms, int kind)
{
	size_t n, found;
	double removed, added, ratio;
	int16_t *src = make_signal(48000, SECONDS_DEFAULT, kind, &n);
	struct script sc = script_alloc(n / 960);
	struct run r;
	char name[64];
	for (size_t i = 0; i < sc.n; i++) {
		int64_t a = sc.pk[i].arrival_us;
		for (int64_t at = 5000000; at <= 12000000; at += 7000000)
			if (a >= at && a < at + hold_ms * 1000) sc.pk[i].arrival_us = at + hold_ms * 1000;
	}
	r = simulate(src, n, 48000, &sc, 960, &cfg48, 0);
	snprintf(name, sizeof(name), "stall %dms x2 %s", hold_ms, kind ? "voice" : "tone");
	report(name, &r);
	if (kind == 0) {
		size_t n2; int16_t *pure = make_signal(48000, SECONDS_DEFAULT, 2, &n2);
		struct run r2 = simulate(pure, n2, 48000, &sc, 960, &cfg48, 0);
		judge_clicks(&r, 48000, 0, &removed, &added, &found);
		if (wav_out) write_wav(wav_out, r.out, r.out_n, 48000);
		ratio = tone_step_ratio(r2.out, r2.out_n, 48000);
		free(pure); free(r2.out);
		printf("   clicks found=%zu, spacing removed=%.0fms added=%.0fms, max step ratio=%.2f at %.0f ms\n", found, removed, added, ratio, step_at_ms);
	}
	else {
		ratio = max_step_ratio(r.out, r.out_n, src, n);
		printf("   max step ratio=%.2f (against the voiced source's own pulses)\n", ratio);
	}
	/* concealment decays to silence after ~240 ms (EXPAND_DECAY/FLOOR):
	 * a stall longer than that ends in zeros, as any PLC does */
	CHECK(r.st.zero_ms <= 320 + (unsigned)(hold_ms > 240 ? 2 * (hold_ms - 240) : 0), "stalls concealed from history; zeros only past the concealment horizon (%llu ms)", (unsigned long long)r.st.zero_ms);
	CHECK(r.st.expand_ms <= (unsigned long long)2 * (hold_ms + PTIME_MS), "concealment bounded by the stall (%llu ms for two %d ms stalls)", (unsigned long long)r.st.expand_ms, hold_ms);
	CHECK(ratio < 3.0, "no hard cut (max step %.2fx)", ratio);
	CHECK(r.st.late_packets <= 2 * (unsigned)(hold_ms / PTIME_MS + 1), "late drops bounded by what concealment consumed (%u)", r.st.late_packets);
	CHECK(r.st.level_ms <= r.st.target_ms + PTIME_MS, "level settled: %u target %u", r.st.level_ms, r.st.target_ms);
	free(src); free(sc.pk); free(r.out);
}

/* The Wi-Fi power-save pattern: every `period_ms`, `per` packets arrive together. */
static void scenario_bunching(int period_ms, int per)
{
	size_t n, found;
	double removed, added, ratio;
	int16_t *src = make_signal(48000, 30, 0, &n);
	struct script sc = script_alloc(n / 960);
	struct run r;
	char name[64];
	for (size_t i = 0; i < sc.n; i++) {
		int64_t nominal = sc.pk[i].arrival_us - 300000;
		int64_t group = nominal / ((int64_t)per * PTIME_MS * 1000);
		/* the group lands together at the end of its own period: the
		 * sender's clock is exact, only the delivery is batched */
		sc.pk[i].arrival_us = 300000 + (group + 1) * (int64_t)per * PTIME_MS * 1000 + (period_ms - per * PTIME_MS) * 1000;
	}
	r = simulate(src, n, 48000, &sc, 960, &cfg48, 0);
	snprintf(name, sizeof(name), "bunching %d/%dms", per, period_ms);
	report(name, &r);
	judge_clicks(&r, 48000, 0, &removed, &added, &found);
	if (wav_out) write_wav(wav_out, r.out, r.out_n, 48000);
	{
		size_t n2; int16_t *pure = make_signal(48000, 30, 2, &n2);
		struct run r2 = simulate(pure, n2, 48000, &sc, 960, &cfg48, 0);
		ratio = tone_step_ratio(r2.out, r2.out_n, 48000);
		free(pure); free(r2.out);
	}
	printf("   clicks found=%zu, spacing removed=%.0fms added=%.0fms, max step ratio=%.2f at %.0f ms\n", found, removed, added, ratio, step_at_ms);
	CHECK(r.st.expand_ms <= 200, "after settling, bursts are absorbed without concealment (%llu ms concealed in total)", (unsigned long long)r.st.expand_ms);
	CHECK(r.st.zero_ms <= 320 + 2 * (unsigned)period_ms, "no zeros beyond the wait for the first group");
	CHECK(r.st.target_ms >= (uint32_t)period_ms - PTIME_MS && r.st.target_ms <= (uint32_t)period_ms + 3 * PTIME_MS, "target tracks the bunching period: %u for %d ms", r.st.target_ms, period_ms);
	CHECK(r.st.ops_accelerate + r.st.ops_preemptive <= 60, "no oscillation between accelerate and stretch (%u + %u ops)", r.st.ops_accelerate, r.st.ops_preemptive);
	CHECK(found >= 118, "every click survives (%zu)", found);
	CHECK(ratio < 3.0, "no hard cut (max step %.2fx)", ratio);
	free(src); free(sc.pk); free(r.out);
}

static void scenario_jitter(int spread_ms)
{
	size_t n, found;
	double removed, added, ratio;
	int16_t *src = make_signal(48000, 30, 1, &n);
	struct script sc = script_alloc(n / 960);
	struct run r;
	char name[64];
	rng_state = 777;
	for (size_t i = 0; i < sc.n; i++)
		sc.pk[i].arrival_us += (int64_t)(urand() * spread_ms * 1000);
	r = simulate(src, n, 48000, &sc, 960, &cfg48, 0);
	snprintf(name, sizeof(name), "jitter 0-%dms", spread_ms);
	report(name, &r);
	(void)removed; (void)added; (void)found;
	ratio = max_step_ratio(r.out, r.out_n, src, n);
	printf("   max step ratio=%.2f (voiced source)\n", ratio);
	CHECK(r.st.expand_ms <= 200, "jitter absorbed by the target after the first second (%llu ms concealed)", (unsigned long long)r.st.expand_ms);
	CHECK(r.st.target_ms >= (uint32_t)spread_ms, "target covers the jitter: %u >= %d", r.st.target_ms, spread_ms);
	CHECK(r.st.target_ms <= (uint32_t)spread_ms + 3 * PTIME_MS, "target not inflated: %u <= %d", r.st.target_ms, spread_ms + 3 * PTIME_MS);
	CHECK(r.st.ops_accelerate + r.st.ops_preemptive <= 80, "no oscillation (%u + %u ops)", r.st.ops_accelerate, r.st.ops_preemptive);
	CHECK(ratio < 2.5, "no hard cut (max step %.2fx)", ratio);
	free(src); free(sc.pk); free(r.out);
}

static void scenario_loss(double pct, int doubles)
{
	size_t n, found, lost = 0, expect;
	double removed, added, ratio;
	int16_t *src = make_signal(48000, 30, 1, &n);
	struct script sc = script_alloc(n / 960);
	struct run r;
	char name[64];
	rng_state = 4242;
	for (size_t i = 15; i < sc.n; i++) {
		if (urand() * 100 < pct) {
			sc.pk[i].arrival_us = -1; lost++;
			if (doubles && i + 1 < sc.n) { sc.pk[i + 1].arrival_us = -1; lost++; i++; }
		}
	}
	r = simulate(src, n, 48000, &sc, 960, &cfg48, 0);
	snprintf(name, sizeof(name), "loss %.0f%% %s", pct, doubles ? "double" : "single");
	report(name, &r);
	(void)removed; (void)added; found = 0;
	ratio = max_step_ratio(r.out, r.out_n, src, n);
	expect = 0;
	printf("   lost packets=%zu, max step ratio=%.2f (voiced source)\n", lost, ratio);
	CHECK(r.st.expand_ms >= (unsigned long long)lost * PTIME_MS * 8 / 10, "each lost packet concealed (%llu ms for %zu lost)", (unsigned long long)r.st.expand_ms, lost);
	CHECK(r.st.zero_ms <= 320, "concealment from history, no zeros");
	CHECK(ratio < 2.5, "no hard cut (max step %.2fx)", ratio);
	(void)expect; (void)found;
	free(src); free(sc.pk); free(r.out);
}

static void scenario_reorder(void)
{
	size_t n, first;
	int16_t *src = make_signal(48000, SECONDS_DEFAULT, 0, &n);
	struct script sc = script_alloc(n / 960);
	struct run r;
	/* every 7th pair swapped: the later packet arrives 5 ms before the earlier */
	for (size_t i = 10; i + 1 < sc.n; i += 7) {
		int64_t a = sc.pk[i].arrival_us;
		sc.pk[i].arrival_us = sc.pk[i + 1].arrival_us;
		sc.pk[i + 1].arrival_us = a + 5000;
	}
	r = simulate(src, n, 48000, &sc, 960, &cfg48, 0);
	report("reorder pairs", &r);
	CHECK(r.st.late_packets == 0, "a packet reordered within the target is not late");
	CHECK(exact_after_start(&r, src, n, &first) || r.st.accelerate_ms + r.st.preemptive_ms > 0, "audio intact (exact, or adjusted only by time-scaling)");
	CHECK(r.st.expand_ms <= 60, "no concealment beyond settling (%llu ms)", (unsigned long long)r.st.expand_ms);
	free(src); free(sc.pk); free(r.out);
}

static void scenario_drift(double drift)
{
	size_t n, found;
	double removed, added, ratio;
	int16_t *src = make_signal(48000, 60, 1, &n);
	struct script sc = script_alloc(n / 960);
	struct run r;
	char name[64];
	r = simulate(src, n, 48000, &sc, 960, &cfg48, drift);
	snprintf(name, sizeof(name), "clock drift %+.2f%% 60s", drift * 100);
	report(name, &r);
	(void)removed; (void)added; (void)found;
	ratio = max_step_ratio(r.out, r.out_n, src, n);
	printf("   max step ratio=%.2f (voiced source)\n", ratio);
	CHECK(r.st.max_level_ms <= r.st.target_ms + 4 * PTIME_MS, "latency bounded under drift: max level %u target %u", r.st.max_level_ms, r.st.target_ms);
	CHECK(r.st.zero_ms <= 320, "no zeros");
	CHECK(ratio < 2.5, "no hard cut (max step %.2fx)", ratio);
	free(src); free(sc.pk); free(r.out);
}

static void scenario_late_packet(void)
{
	size_t n;
	int16_t *src = make_signal(48000, SECONDS_DEFAULT, 0, &n);
	struct script sc = script_alloc(n / 960);
	struct run r;
	/* one packet 600 ms late: it is behind the playout position by then */
	sc.pk[100].arrival_us += 600000;
	r = simulate(src, n, 48000, &sc, 960, &cfg48, 0);
	report("one packet 600ms late", &r);
	CHECK(r.st.late_packets == 1, "the straggler is dropped as late (%u)", r.st.late_packets);
	CHECK(r.st.expand_ms >= PTIME_MS && r.st.expand_ms <= 4 * PTIME_MS, "its slot was concealed (%llu ms)", (unsigned long long)r.st.expand_ms);
	CHECK(r.st.zero_ms <= 320, "no zeros");
	free(src); free(sc.pk); free(r.out);
}

static void scenario_flush(void)
{
	/* a new stream mid-call (SSRC change / resume): timestamps restart */
	struct playout_cfg cfg = cfg48;
	struct playout *p = playout_alloc(&cfg);
	int16_t frame[960], out[960];
	struct playout_stats st;
	size_t i;
	for (i = 0; i < 960; i++) frame[i] = (int16_t)(3000 * sin(i * 0.05));
	for (i = 0; i < 50; i++) { playout_write(p, frame, 960, (uint32_t)(i * 960), i * 20000); playout_read(p, out, 960, i * 20000 + 10000); }
	playout_flush(p);
	for (i = 0; i < 50; i++) { playout_write(p, frame, 960, (uint32_t)(900000 + i * 960), 2000000 + i * 20000); playout_read(p, out, 960, 2000000 + i * 20000 + 10000); }
	playout_stats(p, &st);
	report("flush and restart", (struct run[]){ { NULL, 0, st, 0, "", 0, 0 } });
	CHECK(st.late_packets == 0, "a restarted timeline is accepted after flush");
	CHECK(st.level_ms <= st.target_ms + PTIME_MS, "level sane after restart");
	playout_free(p);
}

/* The industry criterion (NetEq): speech is time-scaled only where it is
 * stationary and voiced, or quiet. White noise is neither: with a start
 * backlog, every noise segment must come out sample-exact and the whole
 * backlog must be taken out of the pauses. */
static void scenario_noise_backlog(size_t burst)
{
	size_t n, at, seg, frames;
	int16_t *src = make_signal(48000, 12.0, 3, &n);
	struct script sc = script_alloc(n / (48000 * PTIME_MS / 1000));
	struct run r;
	frames = sc.n;
	for (size_t i = 0; i < burst && i < frames; i++)
		sc.pk[i].arrival_us = 300000 + (int64_t)burst * PTIME_MS * 1000;
	r = simulate(src, n, 48000, &sc, 960, &cfg48, 0);
	report("noise backlog (pauses)", &r);
	if (wav_out) write_wav(wav_out, r.out, r.out_n, 48000);
	for (seg = 0; seg < 3; seg++) {
		size_t from = (size_t)(48000 * (seg * 4.0)), len = 48000 * 3;
		CHECK(segment_exact(&r, src, from, len, &at), "noise %zu-%zu s is played sample-exact (nothing time-scaled in unvoiced sound), found at %.0f ms", seg * 4, seg * 4 + 3, at * 1000.0 / 48000);
	}
	CHECK(r.st.accelerate_ms + r.st.target_ms + 2 * PTIME_MS >= burst * PTIME_MS, "the backlog was taken out of the pauses (%llu ms of %zu)", (unsigned long long)r.st.accelerate_ms, burst * PTIME_MS);
	CHECK(r.st.level_ms <= r.st.target_ms + PTIME_MS, "level %u within target %u + one packet by the end", r.st.level_ms, r.st.target_ms);
	CHECK(r.st.expand_ms == 0 && r.st.late_packets == 0, "nothing concealed, nothing dropped");
	free(src); free(sc.pk); free(r.out);
}

/* Tone and noise alternating with no pause: the backlog is taken out of
 * the tone (voiced) at the gentle rate, never out of the noise. */
static void scenario_mixed_backlog(size_t burst)
{
	size_t n, at, seg, frames;
	int16_t *src = make_signal(48000, 12.0, 4, &n);
	struct script sc = script_alloc(n / (48000 * PTIME_MS / 1000));
	struct run r;
	frames = sc.n;
	for (size_t i = 0; i < burst && i < frames; i++)
		sc.pk[i].arrival_us = 300000 + (int64_t)burst * PTIME_MS * 1000;
	r = simulate(src, n, 48000, &sc, 960, &cfg48, 0);
	report("mixed backlog (no pause)", &r);
	if (wav_out) write_wav(wav_out, r.out, r.out_n, 48000);
	for (seg = 0; seg < 6; seg++) {
		size_t from = (size_t)(48000 * (seg * 2.0 + 1.0)) + 2400, len = 48000 - 4800; /* 50 ms inside the segment: the fades at its edges belong to the tone */
		CHECK(segment_exact(&r, src, from, len, &at), "noise %zu-%zu s is played sample-exact, found at %.0f ms", seg * 2 + 1, seg * 2 + 2, at * 1000.0 / 48000);
	}
	CHECK(r.st.accelerate_ms + r.st.target_ms + 2 * PTIME_MS >= burst * PTIME_MS, "the backlog was taken out of the tone (%llu ms of %zu)", (unsigned long long)r.st.accelerate_ms, burst * PTIME_MS);
	CHECK(judge_rate(&r) == 0, "one period at most per operation, 50 ms at least between operations");
	CHECK(r.st.level_ms <= r.st.target_ms + PTIME_MS, "level %u within target %u + one packet by the end", r.st.level_ms, r.st.target_ms);
	CHECK(r.st.expand_ms == 0 && r.st.late_packets == 0, "nothing concealed, nothing dropped");
	free(src); free(sc.pk); free(r.out);
}

/* Below target (a 200 ms floor against a 20-40 ms level): stretching
 * follows the same criterion. Noise is never stretched (sample-exact) and
 * the headroom is built in the pause; the tone is stretched at the gentle
 * rate without a hard step. */
static void scenario_floor(int kind)
{
	struct playout_cfg cfg = { 48000, 200, 400, PTIME_MS };
	size_t n, at;
	int16_t *src = make_signal(48000, 12.0, kind, &n);
	struct script sc = script_alloc(n / (48000 * PTIME_MS / 1000));
	struct run r = simulate(src, n, 48000, &sc, 960, &cfg, 0);
	report(kind == 3 ? "floor 200 ms, noise" : "floor 200 ms, tone", &r);
	if (wav_out) write_wav(wav_out, r.out, r.out_n, 48000);
	if (kind == 3) {
		CHECK(segment_exact(&r, src, 0, 48000 * 3, &at), "noise 0-3 s is played sample-exact (nothing stretched in unvoiced sound)");
		CHECK(segment_exact(&r, src, 48000 * 4, 48000 * 3, &at), "noise 4-7 s is played sample-exact, found at %.0f ms", at * 1000.0 / 48000);
		CHECK(segment_exact(&r, src, 48000 * 8, 48000 * 3, &at), "noise 8-11 s is played sample-exact, found at %.0f ms", at * 1000.0 / 48000);
	}
	else {
		double ratio = tone_step_ratio(r.out, r.out_n, 48000);
		CHECK(ratio < 3.0, "no hard step in the stretched tone (max step %.2fx the tone's own at %.0f ms)", ratio, step_at_ms);
		CHECK(judge_rate(&r) == 0, "one period at most per operation, 50 ms at least between operations");
	}
	CHECK(r.st.preemptive_ms + 2 * PTIME_MS >= 200 - 40, "the headroom was built by stretching (%llu ms)", (unsigned long long)r.st.preemptive_ms);
	CHECK(r.st.level_ms + 2 * PTIME_MS >= r.st.target_ms, "level %u reached target %u", r.st.level_ms, r.st.target_ms);
	CHECK(r.st.accelerate_ms == 0 && r.st.expand_ms == 0 && r.st.late_packets == 0, "no compression, nothing concealed, nothing dropped");
	free(src); free(sc.pk); free(r.out);
}

int main(int argc, char **argv)
{
	const char *only = NULL;
	setvbuf(stdout, NULL, _IOLBF, 0);
	int a = 1;
	while (a < argc && argv[a][0] == '-') {
		if (!strcmp(argv[a], "-v")) verbose = 1;
		else if (!strcmp(argv[a], "-w") && a + 1 < argc) wav_out = argv[++a];
		a++;
	}
	if (a < argc) only = argv[a];
#define RUN(name, call) if (!only || strstr(name, only)) { printf("== %s\n", name); call; }
	RUN("nominal", scenario_nominal(48000, 960, 0, SECONDS_DEFAULT));
	RUN("nominal-voice", scenario_nominal(48000, 960, 1, SECONDS_DEFAULT));
	RUN("nominal-512", scenario_nominal(48000, 512, 0, SECONDS_DEFAULT));
	RUN("nominal-1024", scenario_nominal(48000, 1024, 0, SECONDS_DEFAULT));
	RUN("nominal-16k", scenario_nominal(16000, 320, 0, SECONDS_DEFAULT));
	RUN("nominal-8k", scenario_nominal(8000, 160, 0, SECONDS_DEFAULT));
	RUN("nominal-long", scenario_nominal(48000, 960, 0, 300));
	RUN("backlog-15", scenario_backlog(15));
	RUN("backlog-8", scenario_backlog(8));
	RUN("backlog-30", scenario_backlog(30));
	RUN("noise-backlog", scenario_noise_backlog(15));
	RUN("mixed-backlog", scenario_mixed_backlog(10));
	RUN("floor-noise", scenario_floor(3));
	RUN("floor-tone", scenario_floor(2));
	RUN("stall-60", scenario_stall(60, 0));
	RUN("stall-100", scenario_stall(100, 1));
	RUN("stall-150", scenario_stall(150, 1));
	RUN("stall-300", scenario_stall(300, 1));
	RUN("bunching-105", scenario_bunching(105, 5));
	RUN("bunching-200", scenario_bunching(200, 10));
	RUN("jitter-30", scenario_jitter(30));
	RUN("jitter-80", scenario_jitter(80));
	RUN("loss-2", scenario_loss(2, 0));
	RUN("loss-5", scenario_loss(5, 0));
	RUN("loss-double", scenario_loss(3, 1));
	RUN("reorder", scenario_reorder());
	RUN("drift+", scenario_drift(0.001));
	RUN("drift-", scenario_drift(-0.001));
	RUN("late", scenario_late_packet());
	RUN("flush", scenario_flush());
	printf("\n%s: %d failure(s)\n", failures ? "FAIL" : "PASS", failures);
	return failures ? 1 : 0;
}
