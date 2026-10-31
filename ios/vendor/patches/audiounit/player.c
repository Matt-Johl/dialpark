/**
 * @file audiounit/player.c  AudioUnit output player
 *
 * Copyright (C) 2010 Alfred E. Heggestad
 *
 * Dialler patch (manual audio, see sess.c): while the host holds the
 * audio, alloc does not touch CoreAudio at all — under CallKit, creating
 * or initialising a unit on a deactivated session fails with '!pri'
 * (insufficient priority). The unit is created, configured, initialised
 * and started when the host releases the audio.
 */
#include <AudioUnit/AudioUnit.h>
#include <AudioToolbox/AudioToolbox.h>
#include <re.h>
#include <rem.h>
#include <baresip.h>
#include "audiounit.h"


struct auplay_st {
	struct audiosess_st *sess;
	struct auplay_prm prm;
	AudioUnit au;            /* NULL until set up */
	mtx_t mutex;
	uint32_t sampsz;
	auplay_write_h *wh;
	void *arg;
	/* Dialler lab: audio continuity events (render timeline) */
	uint64_t cb_count;
	double last_end;        /* mSampleTime where the previous buffer ended */
	uint64_t last_cb_us;
};


static void auplay_destructor(void *arg)
{
	struct auplay_st *st = arg;

	mtx_lock(&st->mutex);
	st->wh = NULL;
	mtx_unlock(&st->mutex);

	if (st->au) {
		AudioOutputUnitStop(st->au);
		AudioUnitUninitialize(st->au);
		AudioComponentInstanceDispose(st->au);
	}

	mem_deref(st->sess);

	mtx_destroy(&st->mutex);
}


static OSStatus output_callback(void *inRefCon,
				AudioUnitRenderActionFlags *ioActionFlags,
				const AudioTimeStamp *inTimeStamp,
				UInt32 inBusNumber,
				UInt32 inNumberFrames,
				AudioBufferList *ioData)
{
	struct auplay_st *st = inRefCon;
	auplay_write_h *wh;
	void *arg;
	uint32_t i;

	(void)ioActionFlags;
	(void)inTimeStamp;
	(void)inBusNumber;
	(void)inNumberFrames;

	mtx_lock(&st->mutex);
	wh  = st->wh;
	arg = st->arg;
	mtx_unlock(&st->mutex);

	if (!wh)
		return 0;

	/* Dialler lab: the render timeline as CoreAudio drives it. A jump in
	 * mSampleTime is audio the output skipped or repeated; a late callback
	 * is the unit starved by the system. */
	{
		uint64_t now = tmr_jiffies_usec();
		double t = inTimeStamp->mSampleTime;
		if (!st->cb_count) {
			au_ev_push(AU_EV_RENDER_FIRST, (int32_t)inNumberFrames, (int32_t)st->prm.srate);
		}
		else {
			uint64_t nominal = (uint64_t)inNumberFrames * 1000000 / (st->prm.srate ? st->prm.srate : 48000);
			uint64_t dt = now - st->last_cb_us;
			if (t > st->last_end + 0.5)
				au_ev_push(AU_EV_RENDER_GAP, (int32_t)(t - st->last_end), (int32_t)inNumberFrames);
			else if (t < st->last_end - 0.5)
				au_ev_push(AU_EV_RENDER_DUP, (int32_t)(st->last_end - t), (int32_t)inNumberFrames);
			if (dt > nominal * 2)
				au_ev_push(AU_EV_RENDER_LATE, (int32_t)(dt / 1000), (int32_t)(nominal / 1000));
		}
		st->last_end = t + inNumberFrames;
		st->last_cb_us = now;
		st->cb_count++;
	}

	audiosess_count(true, inNumberFrames);

	for (i = 0; i < ioData->mNumberBuffers; ++i) {

		AudioBuffer *ab = &ioData->mBuffers[i];
		struct auframe af;
		uint64_t ts;

		auframe_init(&af, st->prm.fmt, ab->mData,
			     ab->mDataByteSize / st->sampsz, st->prm.srate,
			     st->prm.ch);

		ts = AUDIO_TIMEBASE * inTimeStamp->mSampleTime / st->prm.srate;

		af.timestamp = ts;

		wh(&af, arg);

		/* Dialler: energy of what is about to be played, so a test
		 * can tell "tone audible" from "rendering silence". */
		if (st->prm.fmt == AUFMT_S16LE) {
			const int16_t *s = ab->mData;
			size_t n = ab->mDataByteSize / sizeof(int16_t);
			uint64_t acc = 0;
			for (size_t k = 0; k < n; k++)
				acc += (uint64_t)(s[k] < 0 ? -s[k] : s[k]);
			audiosess_count_energy(acc);
		}
	}

	return 0;
}


/* Create, configure and initialise the output unit. Only called while the
 * host has the audio released (session active). */
static OSStatus player_setup(struct auplay_st *st)
{
	AudioStreamBasicDescription fmt;
	const AudioUnitElement outputBus = 0;
	AURenderCallbackStruct cb;
	const UInt32 enable = 1;
	OSStatus ret;
	Float64 hw_srate = 0.0;
	UInt32 hw_size = sizeof(hw_srate);

	ret = AudioComponentInstanceNew(audiounit_comp_io, &st->au);
	if (ret)
		return ret;

	ret = AudioUnitSetProperty(st->au, kAudioOutputUnitProperty_EnableIO,
				   kAudioUnitScope_Output, outputBus,
				   &enable, sizeof(enable));
	if (ret) {
		warning("audiounit: EnableIO failed (%d)\n", ret);
		goto fail;
	}

	fmt.mSampleRate       = st->prm.srate;
	fmt.mFormatID         = kAudioFormatLinearPCM;
#if TARGET_OS_IPHONE
	fmt.mFormatFlags      = audiounit_aufmt_to_formatflags(st->prm.fmt)
		| kAudioFormatFlagsNativeEndian
		| kAudioFormatFlagIsPacked;
#else
	fmt.mFormatFlags      = audiounit_aufmt_to_formatflags(st->prm.fmt)
		| kAudioFormatFlagIsPacked;
#endif
	fmt.mBitsPerChannel   = 8 * st->sampsz;
	fmt.mChannelsPerFrame = st->prm.ch;
	fmt.mBytesPerFrame    = st->sampsz * st->prm.ch;
	fmt.mFramesPerPacket  = 1;
	fmt.mBytesPerPacket   = st->sampsz * st->prm.ch;

	ret = AudioUnitInitialize(st->au);
	if (ret)
		goto fail;

	ret = AudioUnitSetProperty(st->au, kAudioUnitProperty_StreamFormat,
				   kAudioUnitScope_Input, outputBus,
				   &fmt, sizeof(fmt));
	if (ret)
		goto fail;

	cb.inputProc = output_callback;
	cb.inputProcRefCon = st;
	ret = AudioUnitSetProperty(st->au,
				   kAudioUnitProperty_SetRenderCallback,
				   kAudioUnitScope_Input, outputBus,
				   &cb, sizeof(cb));
	if (ret)
		goto fail;

	if (0 == AudioUnitGetProperty(st->au, kAudioUnitProperty_SampleRate,
				      kAudioUnitScope_Output, outputBus,
				      &hw_srate, &hw_size)) {
		debug("audiounit: player hardware sample rate is now at %f Hz\n",
		      hw_srate);
	}

	return noErr;

 fail:
	AudioComponentInstanceDispose(st->au);
	st->au = NULL;
	return ret;
}


static void interrupt_handler(bool interrupted, void *arg)
{
	struct auplay_st *st = arg;
	OSStatus ret;

	if (interrupted) {
		if (st->au)
			AudioOutputUnitStop(st->au);
		return;
	}

	if (!st->au) {
		ret = player_setup(st);
		if (ret) {
			warning("audiounit: player setup on release failed:"
				" %d (%c%c%c%c)\n", ret,
				ret>>24, ret>>16, ret>>8, ret);
			return;
		}
		info("audiounit: player set up on release\n");
	}

	ret = AudioOutputUnitStart(st->au);
	if (ret)
		warning("audiounit: player start failed: %d\n", ret);
}


int audiounit_player_alloc(struct auplay_st **stp, const struct auplay *ap,
			   struct auplay_prm *prm, const char *device,
			   auplay_write_h *wh, void *arg)
{
	struct auplay_st *st;
	OSStatus ret = 0;
	int err;

	(void)device;

	if (!stp || !ap || !prm)
		return EINVAL;

	st = mem_zalloc(sizeof(*st), auplay_destructor);
	if (!st)
		return ENOMEM;

	st->wh  = wh;
	st->arg = arg;

	st->prm = *prm;

	st->sampsz = (uint32_t)aufmt_sample_size(prm->fmt);
	if (!st->sampsz) {
		err = ENOTSUP;
		goto out;
	}

	err = mtx_init(&st->mutex, mtx_plain) != thrd_success;
	if (err) {
		err = ENOMEM;
		goto out;
	}

	err = audiosess_alloc(&st->sess, interrupt_handler, st);
	if (err)
		goto out;

	if (audiosess_interrupted()) {
		/* Held: no CoreAudio until the host releases (see sess.c). */
		info("audiounit: player created; CoreAudio setup deferred "
		     "until the audio session is active\n");
	}
	else {
		ret = player_setup(st);
		if (ret) {
			/* The session can be live for one call and in flux at
			 * the same instant — CallKit ending call A while we
			 * answer call B ("End & Accept") deactivates and
			 * reactivates it within ~150 ms, and CoreAudio
			 * refuses a new unit in that window. Failing here
			 * left baresip with no audio at all for the answered
			 * call (2026-09-14: "start_player failed … [19]",
			 * then UNITS DEAD, rtp tx=0). Defer instead: the
			 * release path sets the unit up and starts it, which
			 * it already knows how to do. */
			warning("audiounit: player setup deferred after a "
				"failed attempt: %d (%c%c%c%c)\n", ret,
				ret>>24, ret>>16, ret>>8, ret);
			ret = 0;
		}
	}

	/* Never started here: all units start together, after the whole
	 * allocation chain has run, and only when the host has released
	 * the audio (see sess.c). */
	audiosess_request_start();

 out:
	if (ret) {
		warning("audiounit: player failed: %d (%c%c%c%c)\n", ret,
			ret>>24, ret>>16, ret>>8, ret);
		err = ENODEV;
	}

	if (err)
		mem_deref(st);
	else
		*stp = st;

	return err;
}
