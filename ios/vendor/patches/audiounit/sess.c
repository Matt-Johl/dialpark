/**
 * @file sess.c  AudioUnit sound driver - session
 *
 * Copyright (C) 2010 Alfred E. Heggestad
 *
 * Dialler patch (manual audio, see ios/vendor/patches/README.md):
 *
 *  - Units are never started inside the alloc functions. Every allocated
 *    unit is started in ONE step, after the current allocation chain has
 *    returned to the libre loop (so player and recorder are both fully
 *    initialised before either starts), and only when the host has not
 *    put the audio on hold.
 *  - The host's hold (CallKit: hold until didActivate, hold again on
 *    didDeactivate) is remembered even while no units exist.
 *  - Frame counters on both callbacks, so a probe or the app can assert
 *    that CoreAudio is actually delivering audio.
 *  - Prepared units (2026-11-02): when the host releases the audio while
 *    no client exists — an outgoing call, where CallKit activates the
 *    session at dial time and the far end is still ringing — a player
 *    and a record unit are created and initialised then, so the answer
 *    only binds and starts them. Creating the voice-processing units
 *    took ~200 ms inside the 200 OK's handling, during which the loop
 *    read no RTP and the far end's opening queued (SPEC §4.4 rule 3). A
 *    hold discards them (the session is going away); a client whose
 *    format differs sets up afresh and the prepared unit is discarded.
 */
#include <AudioUnit/AudioUnit.h>
#include <stdatomic.h>
#include <re.h>
#include <rem.h>
#include <baresip.h>
#include "audiounit.h"


struct audiosess {
	struct list sessl;
};


struct audiosess_st {
	struct audiosess *as;
	struct le le;
	audiosess_int_h *inth;
	void *arg;
};


static struct audiosess *gas;

/* Dialler: host hold state, deferred-start timer, frame counters. */
static bool audiosess_hold = false;
static struct tmr start_tmr;

/* Prepared units: created and initialised, bound to nobody, not started. */
static struct {
	AudioUnit play;
	AudioUnit rec;
	struct audiounit_fmt fmt;
} prepared;
static atomic_uint_least64_t play_frames;
static atomic_uint_least64_t rec_frames;
static atomic_uint_least64_t play_energy; /* sum |sample| of rendered S16 audio */


static void sess_destructor(void *arg)
{
	struct audiosess_st *st = arg;

	list_unlink(&st->le);
	mem_deref(st->as);
}


static void destructor(void *arg)
{
	struct audiosess *as = arg;

	list_flush(&as->sessl);

	gas = NULL;
}


int audiosess_alloc(struct audiosess_st **stp,
		    audiosess_int_h *inth, void *arg)
{
	struct audiosess_st *st = NULL;
	struct audiosess *as = NULL;
	int err = 0;
	bool created = false;

	if (!stp)
		return EINVAL;


	if (gas)
		goto makesess;

	as = mem_zalloc(sizeof(*as), destructor);
	if (!as)
		return ENOMEM;

	gas = as;
	created = true;

 makesess:
	st = mem_zalloc(sizeof(*st), sess_destructor);
	if (!st) {
		err = ENOMEM;
		goto out;
	}
	st->inth = inth;
	st->arg = arg;
	st->as = created ? gas : mem_ref(gas);

	list_append(&gas->sessl, &st->le, st);

 out:
	if (err) {
		mem_deref(as);
		mem_deref(st);
	}
	else {
		*stp = st;
	}

	return err;
}


static void start_all(void *arg)
{
	struct le *le;
	uint64_t t0 = audiounit_now_us();
	(void)arg;

	if (audiosess_hold || !gas)
		return;

	for (le = gas->sessl.head; le; le = le->next) {

		struct audiosess_st *st = le->data;

		if (st->inth)
			st->inth(false, st->arg);
	}

	info("audiounit: started %u unit(s) in %llu ms\n",
	     list_count(&gas->sessl),
	     (unsigned long long)((audiounit_now_us() - t0) / 1000));
}


static bool have_clients(void)
{
	return gas && list_count(&gas->sessl) > 0;
}


/* The format a call will ask for: the device rates and channels the
 * configuration pins, else what the app's codecs produce (48 kHz mono). */
static struct audiounit_fmt call_fmt(bool play)
{
	const struct config_audio *a = &conf_config()->audio;
	struct audiounit_fmt f;

	f.srate = play ? a->srate_play : a->srate_src;
	f.ch    = play ? a->channels_play : a->channels_src;
	f.fmt   = play ? a->play_fmt : a->src_fmt;
	if (!f.srate)
		f.srate = 48000;
	if (!f.ch)
		f.ch = 1;
	return f;
}


static void discard_prepared(const char *why)
{
	if (!prepared.play && !prepared.rec)
		return;

	audiounit_unit_dispose(prepared.play);
	audiounit_unit_dispose(prepared.rec);
	prepared.play = prepared.rec = NULL;
	info("audiounit: prepared units discarded (%s)\n", why);
}


/* The session is active and no call is up: build the units a call will
 * need, so its answer only binds and starts them. */
static void prepare(void)
{
	struct audiounit_fmt pf = call_fmt(true), rf = call_fmt(false);
	uint64_t t0 = audiounit_now_us();
	OSStatus ret;

	if (prepared.play || prepared.rec)
		return;
	if (!audiounit_fmt_equal(&pf, &rf)) {
		info("audiounit: player and record formats differ; "
		     "not preparing units\n");
		return;
	}

	ret = audiounit_player_create(&pf, &prepared.play);
	if (!ret)
		ret = audiounit_recorder_create(&rf, &prepared.rec);
	if (ret) {
		/* The session can be live and in flux at the same instant
		 * (CallKit swapping calls); the call sets up afresh then. */
		warning("audiounit: preparing units failed: %d (%c%c%c%c); "
			"the call will set up afresh\n", ret,
			ret>>24, ret>>16, ret>>8, ret);
		audiounit_unit_dispose(prepared.play);
		prepared.play = NULL;
		return;
	}
	prepared.fmt = pf;
	info("audiounit: prepared player and record units in %llu ms "
	     "(%u Hz, %u ch; session active, no call yet)\n",
	     (unsigned long long)((audiounit_now_us() - t0) / 1000),
	     pf.srate, pf.ch);
}


static bool take(AudioUnit *slot, const char *what,
		 const struct audiounit_fmt *f, AudioUnit *aup)
{
	if (!*slot)
		return false;
	if (!audiounit_fmt_equal(f, &prepared.fmt)) {
		info("audiounit: prepared %s unit is %u Hz %u ch, the call "
		     "wants %u Hz %u ch; discarded\n", what,
		     prepared.fmt.srate, prepared.fmt.ch, f->srate, f->ch);
		audiounit_unit_dispose(*slot);
		*slot = NULL;
		return false;
	}
	*aup = *slot;
	*slot = NULL;
	return true;
}


bool audiosess_take_player(const struct audiounit_fmt *f, AudioUnit *aup)
{
	return take(&prepared.play, "player", f, aup);
}


bool audiosess_take_recorder(const struct audiounit_fmt *f, AudioUnit *aup)
{
	return take(&prepared.rec, "record", f, aup);
}


bool audiosess_interrupted(void)
{
	return audiosess_hold;
}


/**
 * Called by player/recorder alloc instead of starting the unit: start
 * every allocated unit once the allocation chain has returned to the loop.
 */
void audiosess_request_start(void)
{
	if (audiosess_hold) {
		info("audiounit: unit ready; start held until the audio "
		     "session is active\n");
		return;
	}

	tmr_start(&start_tmr, 0, start_all, NULL);
}


void audiosess_interrupt(bool hold)
{
	struct le *le;

	audiosess_hold = hold;

	if (hold) {
		tmr_cancel(&start_tmr);
		discard_prepared("audio held");

		if (!gas)
			return;

		for (le = gas->sessl.head; le; le = le->next) {

			struct audiosess_st *st = le->data;

			if (st->inth)
				st->inth(true, st->arg);
		}
		return;
	}

	if (have_clients())
		start_all(NULL);
	else
		prepare();
}


void audiosess_close(void)
{
	tmr_cancel(&start_tmr);
	discard_prepared("module close");
}


void audiosess_count(bool play, size_t frames)
{
	if (play)
		atomic_fetch_add_explicit(&play_frames, frames,
					  memory_order_relaxed);
	else
		atomic_fetch_add_explicit(&rec_frames, frames,
					  memory_order_relaxed);
}


void audiosess_count_energy(uint64_t abs_sum)
{
	atomic_fetch_add_explicit(&play_energy, abs_sum, memory_order_relaxed);
}


void audiosess_stats(uint64_t *play, uint64_t *rec, uint64_t *energy)
{
	if (play)
		*play = atomic_load_explicit(&play_frames, memory_order_relaxed);
	if (rec)
		*rec = atomic_load_explicit(&rec_frames, memory_order_relaxed);
	if (energy)
		*energy = atomic_load_explicit(&play_energy, memory_order_relaxed);
}
