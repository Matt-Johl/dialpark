/**
 * @file audiounit.h  AudioUnit sound driver -- Internal interface
 *
 * Copyright (C) 2010 Alfred E. Heggestad
 *
 * Dialler patch (manual audio): see sess.c.
 */

#if __MAC_OS_X_VERSION_MAX_ALLOWED < 120000
#define kAudioObjectPropertyElementMain (kAudioObjectPropertyElementMaster)
#endif

AudioComponent audiounit_comp_io;
AudioComponent audiounit_comp_conv;


struct audiosess;
struct audiosess_st;
struct conv_buf;


typedef void (audiosess_int_h)(bool start, void *arg);

int  audiosess_alloc(struct audiosess_st **stp,
		     audiosess_int_h *inth, void *arg);
void audiosess_interrupt(bool hold);
bool audiosess_interrupted(void);
void audiosess_request_start(void);
void audiosess_close(void);
void audiosess_count(bool play, size_t frames);
void audiosess_count_energy(uint64_t abs_sum);
void audiosess_stats(uint64_t *play, uint64_t *rec, uint64_t *energy);


int conv_buf_alloc(struct conv_buf **bufp, size_t framesz);
int  get_nb_frames(struct conv_buf *buf, uint32_t *nb_frames);
OSStatus init_data_write(struct conv_buf *buf, void **data,
			 size_t framesz, uint32_t nb_frames);
OSStatus init_data_read(struct conv_buf *buf, void **data,
			size_t framesz, uint32_t nb_frames);


int audiounit_player_alloc(struct auplay_st **stp, const struct auplay *ap,
			   struct auplay_prm *prm, const char *device,
			   auplay_write_h *wh, void *arg);
int audiounit_recorder_alloc(struct ausrc_st **stp, const struct ausrc *as,
			     struct ausrc_prm *prm, const char *device,
			     ausrc_read_h *rh, ausrc_error_h *errh, void *arg);


/* Dialler (prepared units, see sess.c): the expensive part of a unit —
 * creating and initialising the voice-processing I/O — is separate from
 * binding it to a client, so it can be done ahead of the call. */
struct audiounit_fmt {
	uint32_t srate;
	uint32_t ch;
	enum aufmt fmt;
};

bool audiounit_fmt_equal(const struct audiounit_fmt *a,
			 const struct audiounit_fmt *b);
OSStatus audiounit_player_create(const struct audiounit_fmt *fmt,
				 AudioUnit *aup);
OSStatus audiounit_recorder_create(const struct audiounit_fmt *fmt,
				   AudioUnit *aup);
void audiounit_unit_dispose(AudioUnit au);

bool audiosess_take_player(const struct audiounit_fmt *fmt, AudioUnit *aup);
bool audiosess_take_recorder(const struct audiounit_fmt *fmt, AudioUnit *aup);
uint64_t audiounit_now_us(void);


uint32_t audiounit_aufmt_to_formatflags(enum aufmt fmt);
