/* playout — adaptive playout buffer on the speaker's clock. See playout.h.
 *
 * Lab build (lab/audio-continuity). Plain C99.
 */
#include "playout.h"

#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* ---- tunables -------------------------------------------------------------- */

#define HIST_PACKETS      100   /* arrival window for the target estimate (~2 s) */
#define TARGET_QUANTILE   0.95  /* of the window's relative delays */
#define PITCH_MIN_MS      2.5   /* 400 Hz */
#define PITCH_MAX_MS      15.0  /* 67 Hz */
#define CORR_WINDOW_MS    10.0  /* similarity window for the pitch search */
#define SILENCE_RMS       120   /* int16 RMS below which a block is "silent" */
#define OUT_HISTORY_MS    80    /* kept for expand and merge */
#define MERGE_MS          8     /* cross-fade real audio back after an expand */
#define EXPAND_DECAY      0.80  /* gain per read while concealing */
#define EXPAND_FLOOR      0.05  /* below this, concealment is zeros */
#define UNDERRUN_BUMP_US  500000 /* a target bump per underrun at most this often */
#define LEVEL_FILTER      0.125  /* per read: ~150 ms time constant at 20 ms reads */
#define SCALE_RATE        0.10   /* time-scaling budget in speech: 10 % (imperceptible) */
#define FAST_ABOVE_MS     200    /* this far above target, compress at full rate anyway */

struct playout {
	struct playout_cfg cfg;
	playout_event_h *evh;
	void *evarg;
	pthread_mutex_t lock;        /* the RTP thread writes, the audio thread reads */

	/* timeline: sample index 0 is the first packet's first sample */
	int16_t *ring;
	uint8_t *valid;
	size_t cap;
	bool started;
	uint32_t base_ts;
	int64_t read_pos;
	int64_t write_high;

	/* delay manager */
	uint64_t first_arrival_us;
	int32_t rel[HIST_PACKETS];   /* relative delay per packet, ms */
	int rel_n, rel_i;
	uint32_t target_ms;
	uint64_t last_bump_us;
	double level_f;              /* low-pass filtered level, ms (NetEq's BufferLevelFilter) */
	bool level_primed;
	double accel_credit;         /* ms of compression allowed in speech, accrued at SCALE_RATE */
	double stretch_credit;

	/* time scaling */
	int16_t *hist;               /* last OUT_HISTORY_MS of output */
	size_t hist_n;               /* capacity */
	size_t hist_len;             /* valid samples (<= hist_n), newest at end */
	bool expanding;
	double expand_gain;
	size_t expand_period;
	int64_t last_op_pos;

	struct playout_stats st;
};

static size_t ms_to_samp(const struct playout *p, double ms)
{
	return (size_t)(ms * p->cfg.srate / 1000.0 + 0.5);
}

static uint32_t samp_to_ms(const struct playout *p, int64_t s)
{
	if (s <= 0)
		return 0;
	return (uint32_t)(s * 1000 / p->cfg.srate);
}

static void emit(struct playout *p, const char *kind, int32_t a, int32_t b)
{
	if (p->evh)
		p->evh(kind, a, b, p->evarg);
}

struct playout *playout_alloc(const struct playout_cfg *cfg)
{
	struct playout *p;
	if (!cfg || !cfg->srate || cfg->max_delay_ms < cfg->min_delay_ms || !cfg->ptime_ms)
		return NULL;
	p = calloc(1, sizeof(*p));
	if (!p)
		return NULL;
	p->cfg = *cfg;
	pthread_mutex_init(&p->lock, NULL);
	/* the ring holds the target ceiling plus a second of slack for bursts */
	p->cap = ms_to_samp(p, cfg->max_delay_ms + 1000);
	p->ring = calloc(p->cap, sizeof(int16_t));
	p->valid = calloc(p->cap, 1);
	p->hist_n = ms_to_samp(p, OUT_HISTORY_MS);
	p->hist = calloc(p->hist_n, sizeof(int16_t));
	if (!p->ring || !p->valid || !p->hist) {
		playout_free(p);
		return NULL;
	}
	p->target_ms = cfg->min_delay_ms > 2 * cfg->ptime_ms ? cfg->min_delay_ms : 2 * cfg->ptime_ms;
	if (p->target_ms > cfg->max_delay_ms)
		p->target_ms = cfg->max_delay_ms;
	p->st.target_ms = p->target_ms;
	return p;
}

void playout_free(struct playout *p)
{
	if (!p)
		return;
	pthread_mutex_destroy(&p->lock);
	free(p->ring);
	free(p->valid);
	free(p->hist);
	free(p);
}

void playout_set_event_handler(struct playout *p, playout_event_h *h, void *arg)
{
	if (!p)
		return;
	p->evh = h;
	p->evarg = arg;
}

static void flush_locked(struct playout *p);
void playout_flush(struct playout *p)
{
	if (!p)
		return;
	pthread_mutex_lock(&p->lock);
	flush_locked(p);
	pthread_mutex_unlock(&p->lock);
}

static void flush_locked(struct playout *p)
{
	memset(p->valid, 0, p->cap);
	p->started = false;
	p->read_pos = p->write_high = 0;
	p->rel_n = p->rel_i = 0;
	p->hist_len = 0;
	p->expanding = false;
	p->last_op_pos = 0;
	p->level_f = 0;
	p->level_primed = false;
	p->accel_credit = p->stretch_credit = 0;
	emit(p, "flush", 0, 0);
}

/* ---- delay manager ---------------------------------------------------------- */

static int cmp_i32(const void *a, const void *b)
{
	int32_t x = *(const int32_t *)a, y = *(const int32_t *)b;
	return x < y ? -1 : x > y;
}

/* One packet's arrival: how late it was against a constant-rate timeline,
 * relative to the fastest packet of the recent window, drives the target. */
static void delay_update(struct playout *p, int64_t idx, uint64_t now_us)
{
	int32_t rel = (int32_t)((int64_t)(now_us - p->first_arrival_us) / 1000 - idx * 1000 / (int64_t)p->cfg.srate);
	int32_t sorted[HIST_PACKETS], anchor;
	int i, n;
	uint32_t target, old;

	p->rel[p->rel_i] = rel;
	p->rel_i = (p->rel_i + 1) % HIST_PACKETS;
	if (p->rel_n < HIST_PACKETS)
		p->rel_n++;
	n = p->rel_n;
	if (n < 5)
		return;
	anchor = p->rel[0];
	for (i = 1; i < n; i++)
		if (p->rel[i] < anchor)
			anchor = p->rel[i];
	for (i = 0; i < n; i++)
		sorted[i] = p->rel[i] - anchor;
	qsort(sorted, n, sizeof(sorted[0]), cmp_i32);
	i = (int)(TARGET_QUANTILE * (n - 1) + 0.5);
	/* the quantile of lateness, plus one packet of headroom */
	target = (uint32_t)sorted[i] + p->cfg.ptime_ms;
	if (target < p->cfg.min_delay_ms)
		target = p->cfg.min_delay_ms;
	if (target < 2 * p->cfg.ptime_ms)
		target = 2 * p->cfg.ptime_ms;
	if (target > p->cfg.max_delay_ms)
		target = p->cfg.max_delay_ms;
	old = p->target_ms;
	if (target != old) {
		/* up at once, down only by one packet per packet: the estimate
		 * falls as a disturbance leaves the window, and a slow descent
		 * is what keeps the accelerate rate gentle */
		if (target > old)
			p->target_ms = target;
		else
			p->target_ms = old - p->cfg.ptime_ms > target ? old - p->cfg.ptime_ms : target;
		if (p->target_ms != old) {
			p->st.target_ms = p->target_ms;
			emit(p, "target", (int32_t)old, (int32_t)p->target_ms);
		}
	}
}

/* ---- write ------------------------------------------------------------------ */

static int write_locked(struct playout *p, const int16_t *pcm, size_t sampc, uint32_t ts, uint64_t now_us);
int playout_write(struct playout *p, const int16_t *pcm, size_t sampc, uint32_t ts, uint64_t now_us)
{
	int err;
	if (!p || !pcm || !sampc)
		return EINVAL;
	pthread_mutex_lock(&p->lock);
	err = write_locked(p, pcm, sampc, ts, now_us);
	pthread_mutex_unlock(&p->lock);
	return err;
}

static int write_locked(struct playout *p, const int16_t *pcm, size_t sampc, uint32_t ts, uint64_t now_us)
{
	int64_t idx, end, i;

	if (!p->started) {
		p->started = true;
		p->base_ts = ts;
		p->first_arrival_us = now_us;
		p->read_pos = 0;
		p->write_high = 0;
		p->rel_n = p->rel_i = 0;
	}
	idx = (int64_t)(int32_t)(ts - p->base_ts);
	end = idx + (int64_t)sampc;
	if (end <= p->read_pos) {
		p->st.late_packets++;
		emit(p, "late", (int32_t)(p->read_pos - end), 0);
		return ETIMEDOUT;
	}
	/* a packet so far ahead that it would lap the ring: skip the playout
	 * position forward to keep it (the alternative is to lose the new
	 * audio; this loses the oldest, which NetEq does by flushing) */
	if (end - p->read_pos > (int64_t)p->cap) {
		int64_t skip = end - p->read_pos - (int64_t)p->cap;
		p->st.overflow_ms += samp_to_ms(p, skip);
		emit(p, "overflow", (int32_t)samp_to_ms(p, skip), 0);
		p->read_pos += skip;
		p->expanding = false;
	}
	for (i = idx < p->read_pos ? p->read_pos : idx; i < end; i++) {
		size_t r = (size_t)(i % (int64_t)p->cap);
		p->ring[r] = pcm[i - idx];
		p->valid[r] = 1;
	}
	if (end > p->write_high)
		p->write_high = end;
	delay_update(p, idx, now_us);
	return 0;
}

/* ---- analysis helpers -------------------------------------------------------- */

static bool valid_run(const struct playout *p, int64_t from, size_t n)
{
	size_t k;
	for (k = 0; k < n; k++)
		if (!p->valid[(size_t)((from + (int64_t)k) % (int64_t)p->cap)])
			return false;
	return true;
}

static size_t avail_from(const struct playout *p, int64_t from, size_t max)
{
	size_t k;
	for (k = 0; k < max; k++)
		if (!p->valid[(size_t)((from + (int64_t)k) % (int64_t)p->cap)])
			break;
	return k;
}

static void take(const struct playout *p, int64_t from, int16_t *dst, size_t n)
{
	size_t k;
	for (k = 0; k < n; k++)
		dst[k] = p->ring[(size_t)((from + (int64_t)k) % (int64_t)p->cap)];
}

static void consume(struct playout *p, int64_t from, size_t n)
{
	size_t k;
	for (k = 0; k < n; k++)
		p->valid[(size_t)((from + (int64_t)k) % (int64_t)p->cap)] = 0;
}

static double rms(const int16_t *x, size_t n)
{
	double acc = 0;
	size_t k;
	if (!n)
		return 0;
	for (k = 0; k < n; k++)
		acc += (double)x[k] * x[k];
	return sqrt(acc / n);
}

/* Best lag P in [pmin, pmax] such that x[0..w) resembles x[P..P+w):
 * normalised cross-correlation. x must hold pmax + w samples. */
static size_t find_pitch(const int16_t *x, size_t w, size_t pmin, size_t pmax, double *best_corr)
{
	size_t P, best = pmin, k;
	double bestc = -2;
	double e0 = 0;
	for (k = 0; k < w; k++)
		e0 += (double)x[k] * x[k];
	for (P = pmin; P <= pmax; P++) {
		double c = 0, e1 = 0;
		for (k = 0; k < w; k++) {
			c += (double)x[k] * x[k + P];
			e1 += (double)x[k + P] * x[k + P];
		}
		if (e0 <= 0 || e1 <= 0)
			continue;
		c /= sqrt(e0 * e1);
		if (c > bestc) {
			bestc = c;
			best = P;
		}
	}
	if (best_corr)
		*best_corr = bestc;
	return best;
}

/* Keep the last OUT_HISTORY_MS of what was played, for concealment. */
static void remember(struct playout *p, const int16_t *out, size_t n)
{
	if (n >= p->hist_n) {
		memcpy(p->hist, out + (n - p->hist_n), p->hist_n * sizeof(int16_t));
		p->hist_len = p->hist_n;
		return;
	}
	if (p->hist_len + n > p->hist_n) {
		size_t drop = p->hist_len + n - p->hist_n;
		memmove(p->hist, p->hist + drop, (p->hist_len - drop) * sizeof(int16_t));
		p->hist_len -= drop;
	}
	memcpy(p->hist + p->hist_len, out, n * sizeof(int16_t));
	p->hist_len += n;
}

/* ---- the operations ---------------------------------------------------------- */

/* Energy of x[from..from+len). */
static double energy(const int16_t *x, size_t from, size_t len)
{
	double e = 0;
	size_t k;
	for (k = 0; k < len; k++)
		e += (double)x[from + k] * x[from + k];
	return e;
}

/* The offset i in [0, limit] at which the two periods about to be
 * overlapped, x[i..i+P) and x[i+P..i+2P), are quietest: the cross-fade
 * attenuates whatever is inside them, and a transient (a plosive, a click)
 * must not be the thing attenuated when a stationary stretch is available
 * in the same block (measured: a 2 ms click erased in 3 of 10 cases with
 * the fade always at the block start). */
static size_t quiet_offset(const int16_t *x, size_t P, size_t limit)
{
	size_t cand = 8, c, best = 0;
	double beste = -1;
	for (c = 0; c <= cand; c++) {
		size_t i = limit * c / cand;
		double e = energy(x, i, P), e2 = energy(x, i + P, P);
		if (e2 > e)
			e = e2;
		if (beste < 0 || e < beste) {
			beste = e;
			best = i;
		}
	}
	return best;
}

/* Accelerate: n output samples from n + P input samples; one pitch period
 * removed by cross-fading x[i..i+P) into x[i+P..i+2P) at a quiet offset i.
 * Returns P, 0 if not done. */
static size_t accelerate(struct playout *p, int16_t *out, size_t n, double budget_ms)
{
	size_t pmin = ms_to_samp(p, PITCH_MIN_MS), pmax = ms_to_samp(p, PITCH_MAX_MS);
	size_t w = ms_to_samp(p, CORR_WINDOW_MS), need, P, k, i;
	int16_t *x;
	double corr = 0;

	/* the period removed must fit inside this read's cross-fade */
	if (pmax > n)
		pmax = n;
	if (pmax < pmin || w + pmax > n + pmax)
		return 0;
	need = n + pmax;
	if (!valid_run(p, p->read_pos, need))
		return 0;
	x = malloc(need * sizeof(int16_t));
	if (!x)
		return 0;
	take(p, p->read_pos, x, need);
	if (rms(x, n) < SILENCE_RMS) {
		/* silence or noise: no pitch to respect and nothing to hear,
		 * remove the most with a short fade, whatever the budget */
		P = pmax;
		corr = 1;
	}
	else {
		P = find_pitch(x, w, pmin, pmax, &corr);
		/* speech: only within the budget. Pitch-synchronous scaling is
		 * inaudible at ~10 %; 15 ms out of every 20 ms (one period per
		 * read, measured 2026-11-01) is a 75 % speed-up and was heard. */
		if (budget_ms >= 0 && (double)P * 1000 / p->cfg.srate > budget_ms) {
			free(x);
			return 0;
		}
	}
	i = quiet_offset(x, P, n - P);
	for (k = 0; k < i; k++)
		out[k] = x[k];
	for (k = i; k < i + P; k++) {
		double wgt = (double)(k - i) / P;
		out[k] = (int16_t)((1.0 - wgt) * x[k] + wgt * x[k + P]);
	}
	for (k = i + P; k < n; k++)
		out[k] = x[k + P];
	free(x);
	consume(p, p->read_pos, n + P);
	p->read_pos += (int64_t)(n + P);
	p->st.accelerate_ms += samp_to_ms(p, (int64_t)P);
	p->st.normal_ms += samp_to_ms(p, (int64_t)n);
	p->st.ops_accelerate++;
	return P;
}

/* Preemptive expand: n output samples from n - P input samples; the pitch
 * period x[i..i+P) is played twice, the repeat cross-faded in, at a quiet
 * offset i so a transient is not doubled. Returns P, 0 if not done. */
static size_t preemptive(struct playout *p, int16_t *out, size_t n, double budget_ms)
{
	size_t pmin = ms_to_samp(p, PITCH_MIN_MS), pmax = ms_to_samp(p, PITCH_MAX_MS);
	size_t w = ms_to_samp(p, CORR_WINDOW_MS), P, k, in_n, i;
	int16_t *x;
	double corr = 0;

	/* the period must fit twice, and the pitch search needs w samples
	 * one period in */
	if (pmax > n / 2)
		pmax = n / 2;
	if (pmax < pmin || pmax + w > n)
		return 0;
	if (!valid_run(p, p->read_pos, n))
		return 0;
	x = malloc(n * sizeof(int16_t));
	if (!x)
		return 0;
	take(p, p->read_pos, x, n);
	if (rms(x, n) < SILENCE_RMS) {
		P = pmax;
	}
	else {
		P = find_pitch(x, w, pmin, pmax, &corr);
		if (budget_ms >= 0 && (double)P * 1000 / p->cfg.srate > budget_ms) {
			free(x);
			return 0;
		}
	}
	in_n = n - P;
	/* out[i+2P..n) reads x[k-P] up to x[in_n-1]: i + 2P <= n (P <= n/2) */
	i = quiet_offset(x, P, n - 2 * P);
	/* out[0..i+P) = x[0..i+P); out[i+P..i+2P) fades x[i+P..i+2P) into
	 * x[i..i+P) (the period again); out[i+2P..n) = x[i+P..in_n) */
	for (k = 0; k < i + P; k++)
		out[k] = x[k];
	for (k = i + P; k < i + 2 * P; k++) {
		double wgt = (double)(k - i - P) / P;
		out[k] = (int16_t)((1.0 - wgt) * x[k] + wgt * x[k - P]);
	}
	for (k = i + 2 * P; k < n; k++)
		out[k] = x[k - P];
	free(x);
	consume(p, p->read_pos, in_n);
	p->read_pos += (int64_t)in_n;
	p->st.preemptive_ms += samp_to_ms(p, (int64_t)P);
	p->st.normal_ms += samp_to_ms(p, (int64_t)in_n);
	p->st.ops_preemptive++;
	return P;
}

/* Expand: conceal n samples by repeating the last pitch period of what
 * was played, decaying. The period is re-read from the history tail on
 * every block, so the continuation always starts where the last output
 * ended (a phase carried across blocks was off by n mod P each time and
 * put a hard step at every block boundary). Zeros when there is no
 * usable history. */
static void expand(struct playout *p, int16_t *out, size_t n)
{
	size_t pmin = ms_to_samp(p, PITCH_MIN_MS), pmax = ms_to_samp(p, PITCH_MAX_MS);
	size_t w = ms_to_samp(p, CORR_WINDOW_MS), k;

	if (!p->expanding) {
		/* a fresh expand: choose the period from the history's tail */
		if (p->hist_len >= pmax + w && rms(p->hist + p->hist_len - w, w) >= SILENCE_RMS) {
			/* find P such that hist[end-w-P..end-P) ~ hist[end-w..end) */
			const int16_t *tail = p->hist + p->hist_len - pmax - w;
			size_t P, best = pmin;
			double bestc = -2;
			for (P = pmin; P <= pmax; P++) {
				double c = 0, e0 = 0, e1 = 0;
				const int16_t *a = tail + pmax - P; /* window one period before the end */
				const int16_t *b = tail + pmax;     /* the last w samples */
				for (k = 0; k < w; k++) {
					c += (double)a[k] * b[k];
					e0 += (double)a[k] * a[k];
					e1 += (double)b[k] * b[k];
				}
				if (e0 <= 0 || e1 <= 0)
					continue;
				c /= sqrt(e0 * e1);
				if (c > bestc) {
					bestc = c;
					best = P;
				}
			}
			p->expand_period = best;
			p->expand_gain = 1.0;
		}
		else {
			p->expand_period = 0;
		}
		p->expanding = true;
		p->st.ops_expand++;
	}
	if (p->expand_period && p->expand_gain * EXPAND_DECAY >= EXPAND_FLOOR && p->hist_len >= p->expand_period) {
		/* the last P samples of the history, which already carry the
		 * decay applied so far; one more step of decay for this block */
		size_t P = p->expand_period;
		int16_t *period = malloc(P * sizeof(int16_t));
		if (period) {
			memcpy(period, p->hist + p->hist_len - P, P * sizeof(int16_t));
			for (k = 0; k < n; k++)
				out[k] = (int16_t)(EXPAND_DECAY * period[k % P]);
			free(period);
			p->expand_gain *= EXPAND_DECAY;
			p->st.expand_ms += samp_to_ms(p, (int64_t)n);
			emit(p, "expand", (int32_t)samp_to_ms(p, (int64_t)n), (int32_t)p->st.level_ms);
			return;
		}
	}
	memset(out, 0, n * sizeof(int16_t));
	p->st.zero_ms += samp_to_ms(p, (int64_t)n);
	p->st.expand_ms += samp_to_ms(p, (int64_t)n);
	emit(p, "zeros", (int32_t)samp_to_ms(p, (int64_t)n), 0);
}

/* Merge: after an expand, the first MERGE_MS of real audio are cross-faded
 * from what the expand would have produced next (the last period again). */
static void merge(struct playout *p, int16_t *out, size_t n)
{
	size_t m = ms_to_samp(p, MERGE_MS), k, P = p->expand_period;
	if (!p->expanding)
		return;
	p->expanding = false;
	p->st.ops_merge++;
	emit(p, "merge", 0, 0);
	if (!P || p->expand_gain < EXPAND_FLOOR || p->hist_len < P)
		return;
	if (m > n)
		m = n;
	for (k = 0; k < m; k++) {
		double wgt = (double)k / m;
		int16_t cont = (int16_t)(EXPAND_DECAY * p->hist[p->hist_len - P + k % P]);
		out[k] = (int16_t)((1.0 - wgt) * cont + wgt * out[k]);
	}
}

/* ---- read ------------------------------------------------------------------ */

static void read_locked(struct playout *p, int16_t *out, size_t sampc, uint64_t now_us);
void playout_read(struct playout *p, int16_t *out, size_t sampc, uint64_t now_us)
{
	if (!p || !out || !sampc)
		return;
	pthread_mutex_lock(&p->lock);
	read_locked(p, out, sampc, now_us);
	pthread_mutex_unlock(&p->lock);
}

static void read_locked(struct playout *p, int16_t *out, size_t sampc, uint64_t now_us)
{
	size_t avail, done = 0, hole;
	int64_t level, after;
	uint32_t level_ms;

	if (!p->started) {
		memset(out, 0, sampc * sizeof(int16_t));
		p->st.zero_ms += samp_to_ms(p, (int64_t)sampc);
		return;
	}
	level = p->write_high - p->read_pos;
	level_ms = samp_to_ms(p, level);
	p->st.level_ms = level_ms;
	if (level_ms > p->st.max_level_ms)
		p->st.max_level_ms = level_ms;
	if (!p->level_primed) {
		p->level_f = level_ms; /* the filter starts where the stream starts */
		p->level_primed = true;
	}
	/* Decisions are taken on a filtered level: bunched arrival makes the
	 * raw level saw-tooth by a whole burst between reads, and acting on
	 * each tooth would accelerate and stretch in turn (measured: 300
	 * accelerates and 700 stretches in 30 s on a 5-per-105 ms pattern).
	 * The filter follows the mean; the target already covers the teeth. */
	p->level_f += ((double)level_ms - p->level_f) * LEVEL_FILTER;

	/* The time-scaling budget: SCALE_RATE of every read, spent in speech,
	 * unlimited in silence (the operations check) or when the level is
	 * far from the target (a start-of-call backlog is drained at full
	 * rate until it is within FAST_ABOVE_MS, then gently). */
	{
		double read_ms = (double)sampc * 1000 / p->cfg.srate, cap = 2 * PITCH_MAX_MS;
		p->accel_credit += SCALE_RATE * read_ms;
		p->stretch_credit += SCALE_RATE * read_ms;
		if (p->accel_credit > cap) p->accel_credit = cap;
		if (p->stretch_credit > cap) p->stretch_credit = cap;
	}

	avail = avail_from(p, p->read_pos, sampc);
	if (avail >= sampc) {
		bool merged = p->expanding;
		size_t P = 0;
		if (p->level_f >= p->target_ms + p->cfg.ptime_ms && level_ms >= p->target_ms) {
			double budget = p->level_f >= p->target_ms + FAST_ABOVE_MS ? -1 : p->accel_credit;
			P = accelerate(p, out, sampc, budget);
			if (P) {
				double ms = (double)P * 1000 / p->cfg.srate;
				emit(p, "accelerate", (int32_t)samp_to_ms(p, (int64_t)P), (int32_t)level_ms);
				p->level_f -= ms;
				if (budget >= 0)
					p->accel_credit -= ms;
			}
		}
		else if (p->level_f + p->cfg.ptime_ms < p->target_ms && !merged) {
			double budget = p->level_f < p->cfg.ptime_ms ? -1 : p->stretch_credit;
			P = preemptive(p, out, sampc, budget);
			if (P) {
				double ms = (double)P * 1000 / p->cfg.srate;
				emit(p, "preemptive", (int32_t)samp_to_ms(p, (int64_t)P), (int32_t)level_ms);
				p->level_f += ms;
				if (budget >= 0)
					p->stretch_credit -= ms;
			}
		}
		if (!P) {
			take(p, p->read_pos, out, sampc);
			consume(p, p->read_pos, sampc);
			p->read_pos += (int64_t)sampc;
			p->st.normal_ms += samp_to_ms(p, (int64_t)sampc);
		}
		if (merged)
			merge(p, out, sampc);
		remember(p, out, sampc);
		return;
	}

	/* Not enough audio at the playout position. Play what there is, then
	 * conceal. Two cases, told apart by whether audio exists further on:
	 *   a hole (a lost or still-missing packet with later ones already
	 *   here) is concealed and skipped — the timeline moves on;
	 *   a true underrun (nothing beyond) is concealed WITHOUT moving the
	 *   playout position: the late audio is played when it arrives, the
	 *   delay has grown by the wait, and accelerate brings it back down.
	 * Moving on during an underrun would make every packet of a stall
	 * late and dropped — the feedback that dropped audio in the first
	 * version of this engine. */
	if (avail) {
		take(p, p->read_pos, out, avail);
		consume(p, p->read_pos, avail);
		p->read_pos += (int64_t)avail;
		p->st.normal_ms += samp_to_ms(p, (int64_t)avail);
		if (p->expanding)
			merge(p, out, avail);
		remember(p, out, avail);
		done = avail;
	}
	after = p->write_high - p->read_pos; /* samples of timeline beyond us */
	hole = 0;
	if (after > 0) {
		/* find the next valid sample: the hole is what lies before it */
		int64_t i;
		for (i = p->read_pos; i < p->write_high; i++)
			if (p->valid[(size_t)(i % (int64_t)p->cap)])
				break;
		hole = (size_t)(i - p->read_pos);
		if (i >= p->write_high)
			hole = 0; /* nothing valid beyond: an underrun after all */
	}
	if (!hole && now_us - p->last_bump_us >= UNDERRUN_BUMP_US) {
		/* an underrun, not a loss: the target was too small for this
		 * path (jitter the window has not seen yet, or reads that do not
		 * align with packets); one packet more, now, and the arrival
		 * statistics catch up */
		uint32_t old = p->target_ms;
		p->target_ms = old + p->cfg.ptime_ms > p->cfg.max_delay_ms ? p->cfg.max_delay_ms : old + p->cfg.ptime_ms;
		p->last_bump_us = now_us;
		if (p->target_ms != old) {
			p->st.target_ms = p->target_ms;
			emit(p, "target", (int32_t)old, (int32_t)p->target_ms);
		}
	}
	expand(p, out + done, sampc - done);
	remember(p, out + done, sampc - done);
	if (hole) {
		/* a loss: the concealed stretch stands in for the missing audio */
		size_t skip = hole < sampc - done ? hole : sampc - done;
		consume(p, p->read_pos, skip);
		p->read_pos += (int64_t)skip;
	}
}

void playout_stats(const struct playout *p, struct playout_stats *st)
{
	if (!p || !st)
		return;
	pthread_mutex_lock((pthread_mutex_t *)&p->lock);
	*st = p->st;
	st->level_ms = samp_to_ms(p, p->write_high - p->read_pos);
	st->target_ms = p->target_ms;
	pthread_mutex_unlock((pthread_mutex_t *)&p->lock);
}
