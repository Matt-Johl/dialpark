/**
 * @file audiounit/recorder.c  AudioUnit input recorder
 *
 * Copyright (C) 2010 Alfred E. Heggestad
 *
 * Dialler patch (manual audio, see sess.c): while the host holds the
 * audio, alloc does not touch CoreAudio at all — under CallKit, creating
 * or initialising a unit on a deactivated session fails with '!pri'
 * (insufficient priority). The units are created, configured, initialised
 * and started when the host releases the audio.
 *
 * Prepared units (2026-11-02, see player.c): the voice-processing input
 * unit is created and initialised apart from binding it to a client
 * (recorder_bind, which also builds the cheap format converter), so
 * sess.c can prepare it ahead of the call and alloc adopts it.
 */
#include <AudioUnit/AudioUnit.h>
#include <AudioToolbox/AudioToolbox.h>
#include <TargetConditionals.h>
#include <re.h>
#include <rem.h>
#include <baresip.h>
#include "audiounit.h"


struct ausrc_st {
	struct audiosess_st *sess;
	AudioUnit au_in;         /* NULL until set up */
	AudioUnit au_conv;       /* NULL until set up */
	mtx_t mutex;
	struct ausrc_prm prm;
	int ch;
	uint32_t sampsz;
	int fmt;
	double sampc_ratio;
	AudioBufferList *abl;
	ausrc_read_h *rh;
	struct conv_buf *buf;
	void *arg;
};


static void ausrc_destructor(void *arg)
{
	struct ausrc_st *st = arg;

	mtx_lock(&st->mutex);
	st->rh = NULL;
	mtx_unlock(&st->mutex);

	if (st->au_in) {
		AudioOutputUnitStop(st->au_in);
		AudioUnitUninitialize(st->au_in);
		AudioComponentInstanceDispose(st->au_in);
	}

	if (st->au_conv) {
		AudioOutputUnitStop(st->au_conv);
		AudioUnitUninitialize(st->au_conv);
		AudioComponentInstanceDispose(st->au_conv);
	}

	mem_deref(st->sess);
	mem_deref(st->buf);

	mtx_destroy(&st->mutex);
}


static OSStatus input_callback(void *inRefCon,
			       AudioUnitRenderActionFlags *ioActionFlags,
			       const AudioTimeStamp *inTimeStamp,
			       UInt32 inBusNumber,
			       UInt32 inNumberFrames,
			       AudioBufferList *ioData)
{
	struct ausrc_st *st = inRefCon;
	AudioBufferList abl_in, abl_conv;
	uint32_t nb_frames, nb_frames_max;
	size_t framesz;
	OSStatus ret;
	int err;
	ausrc_read_h *rh;
	void *arg;

	(void)ioData;

	mtx_lock(&st->mutex);
	rh  = st->rh;
	arg = st->arg;
	mtx_unlock(&st->mutex);

	if (!rh)
		return 0;

	framesz = st->sampsz * st->ch;
	st->abl = &abl_in;

	abl_in.mNumberBuffers = 1;
	abl_in.mBuffers[0].mNumberChannels = st->ch;
	abl_in.mBuffers[0].mDataByteSize = inNumberFrames * (UInt32)framesz;

	ret = init_data_write(st->buf, &abl_in.mBuffers[0].mData,
			      framesz, inNumberFrames);
	if (ret != noErr)
		return ret;

	ret = AudioUnitRender(st->au_in,
			      ioActionFlags,
			      inTimeStamp,
			      inBusNumber,
			      inNumberFrames,
			      &abl_in);
	if (ret) {
		debug("audiounit: record: AudioUnitRender input error (%d)\n",
		      ret);
		return ret;
	}

	audiosess_count(false, inNumberFrames);

	while (1) {
		struct auframe af;
		uint64_t ts;

		err = get_nb_frames(st->buf, &nb_frames);
		if (err)
			return kAudioUnitErr_InvalidParameter;

		/* Maximum number of resampled frames which can be delivered
		   by the converter */
		nb_frames_max = nb_frames * st->sampc_ratio;
		if (inNumberFrames > nb_frames_max)
			return noErr;

		abl_conv.mNumberBuffers = 1;
		abl_conv.mBuffers[0].mNumberChannels = st->ch;
		abl_conv.mBuffers[0].mData = NULL;

		ret = AudioUnitRender(st->au_conv,
				      ioActionFlags,
				      inTimeStamp,
				      0,
				      inNumberFrames,
				      &abl_conv);
		if (ret) {
			debug("audiounit: record: "
			      "AudioUnitRender convert error (%d)\n", ret);
			return ret;
		}

		ts  = AUDIO_TIMEBASE*inTimeStamp->mSampleTime / st->prm.srate;
		ts *= st->sampc_ratio;

		auframe_init(&af, st->prm.fmt, abl_conv.mBuffers[0].mData,
			     abl_conv.mBuffers[0].mDataByteSize / st->sampsz,
			     st->prm.srate, st->prm.ch);
		af.timestamp = ts;

		rh(&af, arg);
	}

	return noErr;
}


static OSStatus convert_callback(void *inRefCon,
				 AudioUnitRenderActionFlags *ioActionFlags,
				 const AudioTimeStamp *inTimeStamp,
				 UInt32 inBusNumber,
				 UInt32 inNumberFrames,
				 AudioBufferList *ioData)
{
	struct ausrc_st *st = inRefCon;
	size_t framesz;
	OSStatus ret = noErr;
	(void)ioActionFlags;
	(void)inTimeStamp;
	(void)inBusNumber;

	framesz = st->sampsz * st->ch;
	ret = init_data_read(st->buf, &ioData->mBuffers[0].mData,
			     framesz, inNumberFrames);

	return ret;
}


/* The hardware stream format for fmt at hw_srate. */
static AudioStreamBasicDescription recorder_asbd(const struct audiounit_fmt *f,
						 Float64 hw_srate)
{
	AudioStreamBasicDescription fmt;
	uint32_t sampsz = (uint32_t)aufmt_sample_size(f->fmt);

	fmt.mSampleRate       = hw_srate;
	fmt.mFormatID         = kAudioFormatLinearPCM;
#if TARGET_OS_IPHONE
	fmt.mFormatFlags      = audiounit_aufmt_to_formatflags(f->fmt)
		| kAudioFormatFlagsNativeEndian
		| kAudioFormatFlagIsPacked;
#else
	fmt.mFormatFlags      = audiounit_aufmt_to_formatflags(f->fmt)
		| kLinearPCMFormatFlagIsPacked;
#endif
	fmt.mBitsPerChannel   = 8 * sampsz;
	fmt.mChannelsPerFrame = f->ch;
	fmt.mBytesPerFrame    = sampsz * f->ch;
	fmt.mFramesPerPacket  = 1;
	fmt.mBytesPerPacket   = sampsz * f->ch;
	fmt.mReserved         = 0;
	return fmt;
}


/* The input unit's hardware rate: the requested rate on iOS (the voice
 * processing unit runs at the session's rate, which the app sets to the
 * same value), the device's own rate on macOS. */
static OSStatus recorder_hw_srate(AudioUnit au, const struct audiounit_fmt *f,
				  Float64 *hw_srate)
{
#if TARGET_OS_IPHONE
	(void)au;
	*hw_srate = f->srate;
	return noErr;
#else
	const AudioUnitElement inputBus = 1;
	UInt32 hw_size = sizeof(*hw_srate);
	(void)f;
	return AudioUnitGetProperty(au, kAudioUnitProperty_SampleRate,
				    kAudioUnitScope_Input, inputBus,
				    hw_srate, &hw_size);
#endif
}


/* Create, configure and initialise an input unit for fmt, bound to no
 * client. The expensive step (voice processing I/O). Only while the host
 * has the audio released (session active). */
OSStatus audiounit_recorder_create(const struct audiounit_fmt *f, AudioUnit *aup)
{
	AudioStreamBasicDescription fmt;
	const AudioUnitElement inputBus = 1;
	const UInt32 enable = 1;
#if ! TARGET_OS_IPHONE
	const AudioUnitElement outputBus = 0;
	const UInt32 disable = 0;
	UInt32 ausize = sizeof(AudioDeviceID);
	AudioDeviceID inputDevice;
	AudioObjectPropertyAddress auAddress = {
		kAudioHardwarePropertyDefaultInputDevice,
		kAudioObjectPropertyScopeGlobal,
		kAudioObjectPropertyElementMain };
#endif
	Float64 hw_srate = 0.0;
	AudioUnit au = NULL;
	OSStatus ret;

	ret = AudioComponentInstanceNew(audiounit_comp_io, &au);
	if (ret)
		return ret;

	ret = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
				   kAudioUnitScope_Input, inputBus,
				   &enable, sizeof(enable));
	if (ret)
		goto fail;

#if ! TARGET_OS_IPHONE
	ret = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
				   kAudioUnitScope_Output, outputBus,
				   &disable, sizeof(disable));
	if (ret)
		goto fail;

	ret = AudioObjectGetPropertyData(kAudioObjectSystemObject,
			&auAddress, 0, NULL, &ausize, &inputDevice);
	if (ret)
		goto fail;

	ret = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
				   kAudioUnitScope_Global, 0,
				   &inputDevice, sizeof(inputDevice));
	if (ret)
		goto fail;
#endif

	ret = recorder_hw_srate(au, f, &hw_srate);
	if (ret)
		goto fail;

	debug("audiounit: record hardware sample rate is now at %f Hz\n",
	      hw_srate);

	fmt = recorder_asbd(f, hw_srate);
	ret = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
				   kAudioUnitScope_Output, inputBus,
				   &fmt, sizeof(fmt));
	if (ret)
		goto fail;

	/* NOTE: done after desc */
	ret = AudioUnitInitialize(au);
	if (ret)
		goto fail;

	*aup = au;
	return noErr;

 fail:
	AudioComponentInstanceDispose(au);
	return ret;
}


/* Bind the client to its (created) input unit and build its format
 * converter: cheap, no hardware. */
static OSStatus recorder_bind(struct ausrc_st *st)
{
	struct audiounit_fmt f = { st->prm.srate, st->prm.ch, st->prm.fmt };
	AudioStreamBasicDescription fmt, fmt_app;
	const AudioUnitElement inputBus = 1;
	const AudioUnitElement defaultBus = 0;
	AURenderCallbackStruct cb_in, cb_conv;
	Float64 hw_srate = 0.0;
	OSStatus ret;

	ret = recorder_hw_srate(st->au_in, &f, &hw_srate);
	if (ret)
		return ret;
	st->sampc_ratio = st->prm.srate / hw_srate;

	cb_in.inputProc = input_callback;
	cb_in.inputProcRefCon = st;
	ret = AudioUnitSetProperty(st->au_in,
				   kAudioOutputUnitProperty_SetInputCallback,
				   kAudioUnitScope_Global, inputBus,
				   &cb_in, sizeof(cb_in));
	if (ret)
		return ret;

	fmt = recorder_asbd(&f, hw_srate);
	fmt_app = fmt;
	fmt_app.mSampleRate = st->prm.srate;

	ret = AudioComponentInstanceNew(audiounit_comp_conv, &st->au_conv);
	if (ret) {
		warning("audiounit: record: AudioConverter failed (%d)\n",
			ret);
		return ret;
	}

	info("audiounit: record: enable resampler %.1f -> %u Hz\n",
	     hw_srate, st->prm.srate);

	ret = AudioUnitSetProperty(st->au_conv, kAudioUnitProperty_StreamFormat,
				   kAudioUnitScope_Input, defaultBus,
				   &fmt, sizeof(fmt));
	if (ret)
		goto fail;

	ret = AudioUnitSetProperty(st->au_conv, kAudioUnitProperty_StreamFormat,
				   kAudioUnitScope_Output, defaultBus,
				   &fmt_app, sizeof(fmt_app));
	if (ret)
		goto fail;

	cb_conv.inputProc = convert_callback;
	cb_conv.inputProcRefCon = st;
	ret = AudioUnitSetProperty(st->au_conv,
				   kAudioUnitProperty_SetRenderCallback,
				   kAudioUnitScope_Input, defaultBus,
				   &cb_conv, sizeof(cb_conv));
	if (ret)
		goto fail;

	ret = AudioUnitInitialize(st->au_conv);
	if (ret)
		goto fail;

	return noErr;

 fail:
	AudioComponentInstanceDispose(st->au_conv);
	st->au_conv = NULL;
	return ret;
}


/* Give the client an input unit: the prepared one when its format
 * matches, otherwise a fresh one; then bind. Only while the host has the
 * audio released (session active). */
static OSStatus recorder_setup(struct ausrc_st *st)
{
	struct audiounit_fmt f = { st->prm.srate, st->prm.ch, st->prm.fmt };
	uint64_t t0 = audiounit_now_us();
	bool adopted = audiosess_take_recorder(&f, &st->au_in);
	OSStatus ret;

	if (!adopted) {
		ret = audiounit_recorder_create(&f, &st->au_in);
		if (ret)
			return ret;
	}

	ret = recorder_bind(st);
	if (ret) {
		audiounit_unit_dispose(st->au_in);
		st->au_in = NULL;
		return ret;
	}

	info("audiounit: record %s in %llu ms\n",
	     adopted ? "adopted the prepared unit" : "set up afresh",
	     (unsigned long long)((audiounit_now_us() - t0) / 1000));
	return noErr;
}


static void interrupt_handler(bool interrupted, void *arg)
{
	struct ausrc_st *st = arg;
	OSStatus ret;

	if (interrupted) {
		if (st->au_in)
			AudioOutputUnitStop(st->au_in);
		return;
	}

	if (!st->au_in) {
		ret = recorder_setup(st);
		if (ret) {
			warning("audiounit: record setup on release failed:"
				" %d (%c%c%c%c)\n", ret,
				ret>>24, ret>>16, ret>>8, ret);
			return;
		}
		info("audiounit: record set up on release\n");
	}

	ret = AudioOutputUnitStart(st->au_in);
	if (ret)
		warning("audiounit: record start failed: %d\n", ret);
}


int audiounit_recorder_alloc(struct ausrc_st **stp, const struct ausrc *as,
			     struct ausrc_prm *prm, const char *device,
			     ausrc_read_h *rh, ausrc_error_h *errh, void *arg)
{
	struct ausrc_st *st;
	size_t framesz;
	OSStatus ret = 0;
	int err;

	(void)device;
	(void)errh;

	if (!stp || !as || !prm)
		return EINVAL;

	st = mem_zalloc(sizeof(*st), ausrc_destructor);
	if (!st)
		return ENOMEM;

	st->rh  = rh;
	st->arg = arg;
	st->ch  = prm->ch;

	st->sampsz = (uint32_t)aufmt_sample_size(prm->fmt);
	if (!st->sampsz) {
		err = ENOTSUP;
		goto out;
	}
	st->fmt = prm->fmt;
	st->prm = *prm;
	st->sampc_ratio = 1.0;

	framesz = st->sampsz * st->ch;
	err = conv_buf_alloc(&st->buf, framesz);
	if (err)
		goto out;

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
		info("audiounit: record created; CoreAudio setup deferred "
		     "until the audio session is active\n");
	}
	else {
		ret = recorder_setup(st);
		if (ret) {
			/* See player.c: the session is in flux while CallKit
			 * swaps calls ("End & Accept"), CoreAudio refuses a
			 * new unit, and failing here left the answered call
			 * with no microphone (rtp tx=0). The release path
			 * sets it up and starts it. */
			warning("audiounit: record setup deferred after a "
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
		warning("audiounit: record failed: %d (%c%c%c%c)\n", ret,
			ret>>24, ret>>16, ret>>8, ret);
		err = ENODEV;
	}

	if (err)
		mem_deref(st);
	else
		*stp = st;

	return err;
}
