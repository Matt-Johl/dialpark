// CBaresip implementation.
//
// Threading model (the one libre expects): libre/baresip are initialised,
// run and torn down on one loop thread. Every public call from another
// thread is marshalled onto that thread through an mqueue — a pipe the loop
// polls, so pushing wakes it — and waits for the result. Calls made from the
// loop thread itself (from inside an event callback) run directly, which
// avoids self-deadlock. re_cancel() only clears a flag, so stopping is also
// an mqueue op: the loop wakes, cancels itself, and re_main returns.
//
// Initialising on the loop thread is not cosmetic: libre_init() binds the
// libre context to the calling thread (thread-local, freed by a thread-exit
// destructor, and re_global for everyone else). Initialising on the caller's
// thread and only polling here worked until the caller was a GCD worker
// thread — libdispatch retires those when idle, the destructor freed the
// context the loop was polling, and re_main() returned "unasked" (err=0 or
// EINVAL, with "re_unlock error") seconds after a (re)start from a queue.
#include "include/cbaresip.h"

#include <errno.h>
#include <execinfo.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <re.h>
#include <rem.h> /* enum aufmt for the test devices */
#define DEBUG_MODULE "cbaresip" /* re_dbg.h expects the including module to name itself */
#define DEBUG_LEVEL 5
#include <re_dbg.h> /* not in re.h's umbrella: libre's debug channel */
#include <baresip.h>

#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

/* libre exports this (re/src/tls/openssl/tls.c) but re_tls.h does not
 * declare it: the OpenSSL context behind a struct tls. */
SSL_CTX *tls_ssl_ctx(const struct tls *tls);

/* The SIP leg's server-certificate trust (cb_set_tls_trust). Written from
 * any thread, read by the loop thread in each handshake. */
static struct {
    pthread_mutex_t mu;
    bool has_pin;
    uint8_t pin[32];
    bool accept_any;
} g_trust = { .mu = PTHREAD_MUTEX_INITIALIZER, .accept_any = true };

/* Loop-thread liveness. libre's re_main() returns on re_cancel (our
 * OP_STOP) — or on a poll error it treats as fatal. Then the thread is
 * gone, no op can ever run, and cb_alive() tells the engine to rebuild the
 * stack. A backstop: with the stack owned by the loop thread this is not
 * expected to happen any more. */
static _Atomic int g_stopping;  /* OP_STOP asked the loop to end */
static _Atomic int g_loop_dead; /* re_main returned without being asked */

enum op_type {
    OP_UA_ALLOC = 1,
    OP_UA_REGISTER,
    OP_ANSWER,
    OP_HANGUP,
    OP_UA_FREE,
    OP_STOP,
    OP_AUDIO_INTERRUPT_BEGIN,
    OP_AUDIO_INTERRUPT_END,
    OP_AUDIO_TEST_ALLOC,
    OP_AUDIO_TEST_FREE,
    OP_MEDIA_STATS,
    OP_DIAL,
    OP_MUTE,
    OP_HOLD,
    OP_TRANSFER,
    OP_TRANSP_RESET,
    OP_REJECT
};

static cb_media_stats_t media_stats; /* filled by OP_MEDIA_STATS on the loop thread */

/* net_if_apply handler: put one current interface address back into
 * baresip's list, under its configured interface/family filter (the same
 * test baresip applies at start). */
static bool readd_laddr(const char *ifname, const struct sa *sa, void *arg)
{
    struct network *net = arg;
    if (net_ifaddr_filter(net, ifname, sa))
        (void)net_add_address_ifname(net, sa, ifname);
    return false; /* keep going */
}

/* From the (patched) audiounit module — modules/audiounit/audiounit.h is
 * not part of baresip.h. See ios/vendor/patches/README.md. */
void audiosess_interrupt(bool hold);
void audiosess_stats(uint64_t *play, uint64_t *rec, uint64_t *energy);

/* Test devices (audio-probe). */
static struct auplay_st *test_play;
static struct ausrc_st *test_src;
static void test_write_h(struct auframe *af, void *arg) { (void)af; (void)arg; }
static void test_read_h(struct auframe *af, void *arg) { (void)af; (void)arg; }
static void test_error_h(int err, const char *str, void *arg) { (void)err; (void)str; (void)arg; }

struct op {
    enum op_type type;
    const char *id;  /* the call (SIP Call-ID) an op is about; NULL = n/a */
    const char *aor; /* account line, the URI to dial/transfer to, or a reject reason */
    bool flag;       /* mute / hold on-off */
    uint16_t scode;  /* reject status */
    char *out;       /* OP_DIAL: where the new call's id goes */
    size_t outlen;
    int err;
    bool done;
    pthread_mutex_t mu;
    pthread_cond_t cv;
};

static struct {
    pthread_t thread;
    bool running;
    cb_event_cb cb;
    void *ctx;
    struct mqueue *mq;
    struct ua *ua;
    bool registered;
} g;

/* The header the server puts on every INVITE it sends us: its own call id,
 * the one the same call's wake carries (PROTOCOL.md §6). */
#define DIALLER_CALL_ID_HDR "X-Dialler-Call-ID"

/* The call with this SIP Call-ID, or NULL. Calls live in the UA's list;
 * baresip's uag_call_find searches every UA. */
static struct call *find_call(const char *id)
{
    if (!id || !*id)
        return NULL;
    return uag_call_find(id);
}

/* ---- logging → app --------------------------------------------------------- */

static void emit_info(cb_event_t ev, const cb_event_info *info)
{
    if (g.cb)
        g.cb(g.ctx, ev, info);
}

static void emit(cb_event_t ev, const char *peer, const char *text)
{
    cb_event_info info = { .call_id = "", .peer = peer ? peer : "", .text = text ? text : "", .dialler_call_id = "", .scode = 0 };
    emit_info(ev, &info);
}

/* A call event: carries the call's id and, for an INVITE, the server's id
 * from the filtered X-Dialler-Call-ID header. */
static void emit_call(cb_event_t ev, struct call *call, const char *text)
{
    char dialler_id[128] = "";
    if (ev == CB_EVENT_CALL_INCOMING && call) {
        const struct list *hdrs = call_get_custom_hdrs(call);
        struct le *le;
        for (le = hdrs ? list_head(hdrs) : NULL; le; le = le->next) {
            const struct sip_hdr *h = le->data;
            if (0 == pl_strcasecmp(&h->name, DIALLER_CALL_ID_HDR)) {
                (void)pl_strcpy(&h->val, dialler_id, sizeof dialler_id);
                break;
            }
        }
    }
    cb_event_info info = {
        .call_id = call ? call_id(call) : "",
        .peer = call ? call_peeruri(call) : "",
        .text = text ? text : "",
        .dialler_call_id = dialler_id,
        .scode = call ? call_scode(call) : 0,
    };
    emit_info(ev, &info);
}

/* A libre/baresip log line. `warning` says whether the stack wrote it at
 * warning severity or worse; it rides in `scode`, which CB_EVENT_LOG has no
 * other use for. The Swift side keeps a keyword filter on ordinary chatter
 * but must never drop a warning — the SIP connection lifecycle lines added
 * at libre patch level 5 went missing from every capture on 2026-09-25
 * because "transp:" was not a word on that list. */
static void emit_line(const char *p, size_t n, bool warning)
{
    char buf[512];
    if (!p)
        return;
    if (n >= sizeof(buf))
        n = sizeof(buf) - 1;
    memcpy(buf, p, n);
    while (n && (buf[n - 1] == '\n' || buf[n - 1] == '\r'))
        n--;
    buf[n] = 0;
    if (!n)
        return;
    cb_event_info info = { .call_id = "", .peer = "", .text = buf, .dialler_call_id = "", .scode = warning ? 1 : 0 };
    emit_info(CB_EVENT_LOG, &info);
}

/* baresip's own logger: LEVEL_DEBUG < INFO < WARN < ERROR. */
static void log_handler(uint32_t level, const char *msg)
{
    if (msg)
        emit_line(msg, strlen(msg), level >= LEVEL_WARN);
}
static struct log log_entry = { .h = log_handler };

/* libre's debug printer: syslog order, DBG_EMERG(0) … DBG_WARNING(4) …
 * DBG_DEBUG(7) — lower is more severe. */
static void dbg_print(int level, const char *p, size_t len, void *arg)
{
    (void)arg;
    emit_line(p, len, level <= DBG_WARNING);
}

/* ---- baresip events (loop thread) ------------------------------------------ */

static void event_handler(enum ua_event ev, struct bevent *event, void *arg)
{
    (void)arg;
    struct call *call = bevent_get_call(event);
    const char *txt = bevent_get_text(event);
    const char *peer = call ? call_peeruri(call) : "";

    switch (ev) {
    case UA_EVENT_REGISTER_OK:
        g.registered = true;
        emit(CB_EVENT_REGISTER_OK, "", txt);
        break;
    case UA_EVENT_REGISTER_FAIL:
        g.registered = false;
        emit(CB_EVENT_REGISTER_FAIL, "", txt);
        break;
    case UA_EVENT_UNREGISTERING:
        g.registered = false;
        emit(CB_EVENT_OTHER, "", "unregistering");
        break;
    case UA_EVENT_CALL_INCOMING:
        /* text = the caller's From display name (may be empty), not the
         * event text: the app names the call from it (directory first). */
        au_ev_reset(); /* lab: the audio timeline starts with the call */
        emit_call(CB_EVENT_CALL_INCOMING, call, call ? call_peername(call) : "");
        break;
    case UA_EVENT_CALL_OUTGOING:
        emit_call(CB_EVENT_CALL_OUTGOING, call, txt);
        break;
    case UA_EVENT_CALL_RINGING:
        emit_call(CB_EVENT_CALL_RINGING, call, txt);
        break;
    case UA_EVENT_CALL_PROGRESS:
        emit_call(CB_EVENT_CALL_PROGRESS, call, txt);
        break;
    case UA_EVENT_CALL_TRANSFER_FAILED:
        emit_call(CB_EVENT_CALL_TRANSFER_FAILED, call, txt);
        break;
    case UA_EVENT_CALL_ESTABLISHED:
        emit_call(CB_EVENT_CALL_ESTABLISHED, call, txt);
        break;
    case UA_EVENT_CALL_CLOSED:
        emit_call(CB_EVENT_CALL_CLOSED, call, txt);
        break;
    default:
        emit(CB_EVENT_OTHER, peer, txt);
        break;
    }
}

/* ---- operations (always executed on the loop thread) ----------------------- */

/* Calls the user agent holds right now — ringing, dialling or up. Decided
 * HERE, on the loop thread, because that is the only place the answer
 * cannot change under the op: the host's "is a call up?" check runs on
 * another thread, and an INVITE queued behind the REGISTER's 200 OK is
 * read by this thread between that check and the op it guarded. On
 * 2026-09-18 15:12 that window was 0.3 ms wide and the registration reset
 * freed a user agent whose INVITE had just arrived — 486 to the caller,
 * "call failed" on the phone that dialled. The ops that would take a live
 * call down with them (free the UA, replace it, drop its connections)
 * refuse with EBUSY instead and the host leaves the call alone. */
static const char *busy_with_calls(const char *what)
{
    if (!g.ua || !list_head(ua_calls(g.ua)))
        return NULL;
    info("cbaresip: %s: refused, %u call(s) up\n", what, list_count(ua_calls(g.ua)));
    return what;
}

static int do_op(struct op *op)
{
    int err = 0;
    switch (op->type) {
    case OP_UA_ALLOC:
        if (busy_with_calls("ua_alloc")) {
            err = EBUSY; /* the previous user agent keeps its calls */
            break;
        }
        if (g.ua) {
            info("cbaresip: ua_alloc: freeing the previous user agent\n");
            g.ua = mem_deref(g.ua);
        }
        info("cbaresip: ua_alloc: creating\n");
        err = ua_alloc(&g.ua, op->aor);
        info("cbaresip: ua_alloc: created (err=%d); registering\n", err);
        /* Keep the server's call id from each INVITE (see emit_call). */
        if (!err)
            (void)ua_add_xhdr_filter(g.ua, DIALLER_CALL_ID_HDR);
        if (!err)
            err = ua_register(g.ua); /* ua_alloc only prepares the register clients */
        info("cbaresip: ua_alloc: register requested (err=%d)\n", err);
        break;
    case OP_UA_REGISTER:
        if (!g.ua) {
            err = ENOENT;
            break;
        }
        /* ua_register() on a registered UA replaces its sipreg clients, and
         * libre's old client sends an un-REGISTER for the same contact as it
         * is destroyed — AFTER the new REGISTER, leaving the server with no
         * binding (found by `make sim-call`). ua_refresh_register (vendor
         * patch) re-sends on the existing client instead; only when there
         * is none yet do we start registration. */
        err = ua_refresh_register(g.ua);
        if (err == ENOENT)
            err = ua_register(g.ua);
        break;
    case OP_ANSWER: {
        struct call *call = find_call(op->id);
        if (!g.ua || !call)
            err = ENOENT;
        else
            err = ua_answer(g.ua, call, VIDMODE_OFF);
        break;
    }
    case OP_DIAL: {
        struct call *call = NULL;
        if (!g.ua) {
            err = ENOENT;
            break;
        }
        au_ev_reset(); /* lab: the audio timeline starts with the call */
        err = ua_connect(g.ua, &call, NULL, op->aor, VIDMODE_OFF);
        if (!err && call && op->out && op->outlen)
            str_ncpy(op->out, call_id(call), op->outlen);
        break;
    }
    case OP_MUTE: {
        /* One microphone: every call's audio follows the mute state. */
        struct le *le;
        for (le = g.ua ? list_head(ua_calls(g.ua)) : NULL; le; le = le->next) {
            struct audio *au = call_audio(le->data);
            if (au)
                audio_mute(au, op->flag);
        }
        break;
    }
    case OP_HOLD: {
        struct call *call = find_call(op->id);
        if (!call) {
            err = ENOENT;
            break;
        }
        /* One microphone, one earpiece: a held call owns no audio units.
         * Hold is sendonly on the wire (RFC 3264 §8.4, what the server and
         * PBXs expect), and baresip would keep the held call's source
         * running for it — on iOS a second VoiceProcessingIO input is
         * refused (kAudioUnitErr_MultipleVoiceProcessors, -66635), so the
         * call answered next had no microphone (device, 2026-09-14). The
         * audio hold flag stops start_source from re-creating the source
         * when the hold re-INVITE is answered; audio_stop releases both
         * units now, before the other call takes them (CallKit performs
         * the hold before the answer, in one transaction). Resume clears
         * the flag; the answer to the resume re-INVITE restarts audio. */
        audio_set_hold(call_audio(call), op->flag);
        if (op->flag)
            audio_stop(call_audio(call));
        err = call_hold(call, op->flag);
        break;
    }
    case OP_TRANSFER: {
        struct call *call = find_call(op->id);
        err = call ? call_transfer(call, op->aor) : ENOENT;
        break;
    }
    case OP_REJECT: {
        struct call *call = find_call(op->id);
        if (!call) {
            err = ENOENT;
            break;
        }
        /* call_hangup on an incoming call sends the final response; the
         * CLOSED event follows from baresip like any other end. */
        call_hangup(call, op->scode, op->aor);
        bevent_call_emit(UA_EVENT_CALL_CLOSED, call, "rejected %u %s", op->scode, op->aor ? op->aor : "");
        mem_deref(call);
        break;
    }
    case OP_HANGUP:
        if (!g.ua)
            break;
        if (op->id) {
            struct call *call = find_call(op->id);
            if (call)
                ua_hangup(g.ua, call, 0, NULL);
        } else {
            /* Every call (teardown): ua_hangup takes one; repeat from the
             * head until the list is empty. */
            struct le *le;
            while ((le = list_head(ua_calls(g.ua))) != NULL)
                ua_hangup(g.ua, le->data, 0, NULL);
        }
        break;
    case OP_TRANSP_RESET:
        if (busy_with_calls("transports reset")) {
            err = EBUSY; /* a call's signalling connection is among them */
            break;
        }
        /* libre keeps SIP TCP/TLS connections cached per destination and
         * sends on a cached one synchronously. After iOS has torn the
         * app's sockets down (suspension), that cached connection is dead
         * and every send on it fails at once with EPROTO — seen as
         * "ua_alloc -100" on every registration attempt, since nothing
         * evicts the connection until the loop happens to read its EOF.
         * baresip's network-change reset flushes the cache and rebuilds
         * the transports on the current addresses; registration is ours. */
        /* First re-read the interface addresses. baresip enumerates them
         * once at start and never again (that is the netroam module's
         * job, which we do not load); after a Wi-Fi handoff to a new
         * address the stale list makes the transport rebuild bind the old
         * address ("SIP Transport failed: Can't assign requested address
         * [49]") and every call's media socket fail the same way — the
         * app answered each INVITE with 500 Call Error (2026-09-13). */
        net_flush_addresses(baresip_network());
        net_if_apply(readd_laddr, baresip_network());
        info("cbaresip: resetting SIP transports (dropping cached connections)\n");
        err = uag_reset_transp(false, false);
        info("cbaresip: transports reset (err=%d)\n", err);
        break;
    case OP_UA_FREE:
        if (busy_with_calls("ua_free")) {
            err = EBUSY; /* freeing it would hang them up (486) */
            break;
        }
        if (g.ua) {
            info("cbaresip: ua_free: freeing the user agent\n");
            g.ua = mem_deref(g.ua);
            info("cbaresip: ua_free: done\n");
        }
        g.registered = false;
        break;
    case OP_STOP:
        atomic_store(&g_stopping, 1);
        if (g.ua) {
            struct le *le;
            while ((le = list_head(ua_calls(g.ua))) != NULL)
                ua_hangup(g.ua, le->data, 0, NULL);
            g.ua = mem_deref(g.ua);
        }
        bevent_unregister(event_handler);
        re_cancel(); /* takes effect as soon as this handler returns to the loop */
        break;
    case OP_AUDIO_INTERRUPT_BEGIN:
        audiosess_interrupt(true);
        break;
    case OP_AUDIO_INTERRUPT_END:
        audiosess_interrupt(false);
        break;
    case OP_AUDIO_TEST_ALLOC: {
        struct auplay_prm pp = { .srate = 48000, .ch = 1, .ptime = 20, .fmt = AUFMT_S16LE };
        struct ausrc_prm sp = { .srate = 48000, .ch = 1, .ptime = 20, .fmt = AUFMT_S16LE, .duration = 0 };
        test_play = mem_deref(test_play);
        test_src = mem_deref(test_src);
        err = auplay_alloc(&test_play, baresip_auplayl(), "audiounit", &pp, "default", test_write_h, NULL);
        if (!err)
            err = ausrc_alloc(&test_src, baresip_ausrcl(), "audiounit", &sp, "default", test_read_h, test_error_h, NULL);
        break;
    }
    case OP_AUDIO_TEST_FREE:
        test_src = mem_deref(test_src);
        test_play = mem_deref(test_play);
        break;
    case OP_MEDIA_STATS: {
        struct call *call = find_call(op->id);
        struct audio *au = call ? call_audio(call) : NULL;
        struct stream *s = au ? audio_strm(au) : NULL;
        memset(&media_stats, 0, sizeof(media_stats));
        if (s) {
            const struct rtcp_stats *rs = stream_rtcp_stats(s);
            struct jbuf_stat jb;
            media_stats.tx_packets = stream_metric_get_tx_n_packets(s);
            media_stats.rx_packets = stream_metric_get_rx_n_packets(s);
            media_stats.rx_errors = stream_metric_get_rx_n_err(s);
            if (rs) {
                media_stats.rx_lost = rs->rx.lost;
                media_stats.rx_jitter_us = rs->rx.jit;
            }
            if (0 == stream_jbuf_stats(s, &jb)) {
                media_stats.jb_late = jb.n_late;
                media_stats.jb_lost = jb.n_lost;
                media_stats.jb_underflow = jb.n_underflow;
                media_stats.jb_overflow = jb.n_overflow;
            }
        }
        break;
    }
    }
    return err;
}

static void mq_handler(int id, void *data, void *arg)
{
    (void)id;
    (void)arg;
    struct op *op = data;
    int err = do_op(op);
    pthread_mutex_lock(&op->mu);
    op->err = err;
    op->done = true;
    pthread_cond_broadcast(&op->cv);
    pthread_mutex_unlock(&op->mu);
}

static bool on_loop_thread(void)
{
    return g.running && pthread_equal(pthread_self(), g.thread);
}

/* Run an op on the loop thread and wait (bounded) for its result. */
static int run_full(struct op *opp)
{
    if (!g.running || !g.mq)
        return -ENOTCONN;
    if (atomic_load(&g_loop_dead))
        return -ENOTCONN; /* nobody will ever run it; do not wait 10 s */

    struct op op = *opp;
    if (on_loop_thread())
        return -do_op(&op);

    pthread_mutex_init(&op.mu, NULL);
    pthread_cond_init(&op.cv, NULL);

    int err = mqueue_push(g.mq, (int)op.type, &op);
    if (err)
        goto out;

    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 10;
    pthread_mutex_lock(&op.mu);
    while (!op.done) {
        if (pthread_cond_timedwait(&op.cv, &op.mu, &deadline) == ETIMEDOUT) {
            err = ETIMEDOUT;
            break;
        }
    }
    if (op.done)
        err = op.err;
    pthread_mutex_unlock(&op.mu);

out:
    pthread_cond_destroy(&op.cv);
    pthread_mutex_destroy(&op.mu);
    return -err;
}

static int run_op_flag(enum op_type type, const char *aor, bool flag)
{
    struct op op = { .type = type, .aor = aor, .flag = flag };
    return run_full(&op);
}

static int run_op(enum op_type type, const char *aor)
{
    return run_op_flag(type, aor, false);
}

/* An op about one call. */
static int run_call_op(enum op_type type, const char *id, const char *aor, bool flag)
{
    struct op op = { .type = type, .id = id, .aor = aor, .flag = flag };
    return run_full(&op);
}

/* ---- lifecycle ------------------------------------------------------------- */

/* ---- loop-thread stall watchdog (diagnostics, always on) ------------------
 * A 1 s libre timer on the loop thread stamps a heartbeat. A detached
 * thread watches it and, if the loop has not beaten for 3 s, sends the loop
 * thread SIGUSR1 so it prints its own stack to stderr. A stuck loop is
 * otherwise invisible: every operation just times out (-ETIMEDOUT) and the
 * app "does nothing". Cheap enough to leave in. */
static _Atomic uint64_t g_loop_beat;
static struct tmr g_beat_tmr;
static pthread_t g_loop_pthread;
static _Atomic int g_watchdog_run;
static _Atomic int g_stall_reported;
/* The other failure a loop can have: not stuck, but spinning — kevent()
 * returning at once, over and over, because a descriptor reports readiness
 * that no handler drains. iOS killed the app for that on 2026-09-18 08:45
 * (48 s of CPU in 49 s, all on the loop thread, mid-call; MetricKit's 16
 * samples said only "kevent and a udp read"). The watchdog samples the
 * loop thread's CPU; sustained saturation gets the same stack dump a stall
 * does, so the next occurrence names the descriptor and handler itself. */
static _Atomic int g_busy_dump;      /* stall_dump: say "busy", not "stalled" */
static uint64_t g_busy_last_report;  /* watchdog thread only: mono_ms */
#define LOOP_BUSY_PCT 80             /* of one core, over LOOP_BUSY_SAMPLES */
#define LOOP_BUSY_SAMPLES 10         /* × 500 ms watchdog period = 5 s */
#define LOOP_BUSY_REPORT_MS 60000    /* one dump a minute while it lasts */
/* When iOS suspends the app it freezes every thread in the process, this
 * watchdog included, while CLOCK_MONOTONIC runs on. On resume the heartbeat
 * is as old as the suspension and says nothing whatever about the loop
 * thread's health — but the naive age check reads it as a multi-minute
 * stall and dumps a stack of wherever the loop happened to be parked. Two
 * of those on 2026-09-23 (459794 ms and 335884 ms) were taken for a
 * blocking SSL_write; the durations turned out to match the gaps in the
 * gateway log exactly, and libre's sockets are non-blocking (re tcp.c), so
 * that write could not have blocked at all. An instrument that cries wolf
 * every time the phone is pocketed is worse than none: SPEC §4.7 makes the
 * same point about the gateway's own idle rule.
 *
 * The tell is the watchdog's own period: it slept 500 ms, so a much larger
 * elapsed wall time means the whole process was off the CPU, not that the
 * loop thread is stuck. Stall age is then measured from the resume rather
 * than from the pre-suspension heartbeat, so a loop that really is wedged
 * is still caught 3 s later — with an honest duration. */
#define WD_PERIOD_MS 500
#define WD_FROZEN_MS 2000            /* > period + scheduling jitter, < stall */
static uint64_t g_wd_resumed_at;     /* watchdog thread only: mono_ms */

/* CPU time (user+system, µs) the loop thread has consumed, from the kernel. */
static uint64_t loop_cpu_us(void)
{
    thread_basic_info_data_t info;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    mach_port_t t = pthread_mach_thread_np(g_loop_pthread);
    if (thread_info(t, THREAD_BASIC_INFO, (thread_info_t)&info, &count) != KERN_SUCCESS)
        return 0;
    return (uint64_t)info.user_time.seconds * 1000000 + (uint64_t)info.user_time.microseconds +
           (uint64_t)info.system_time.seconds * 1000000 + (uint64_t)info.system_time.microseconds;
}

static uint64_t mono_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static void beat_handler(void *arg)
{
    (void)arg;
    atomic_store(&g_loop_beat, mono_ms());
    tmr_start(&g_beat_tmr, 1000, beat_handler, NULL);
}

static void stall_dump(int sig)
{
    void *bt[64];
    int n;
    static const char stalled[] =
        "cbaresip: LOOP THREAD STALLED (no heartbeat for 3 s); its stack:\n";
    static const char busy[] =
        "cbaresip: LOOP THREAD BUSY (saturating a core for 5 s); its stack:\n";
    (void)sig;
    n = backtrace(bt, 64);
    /* Async-signal-safe: one atomic read, two static strings, write(2). */
    if (atomic_load(&g_busy_dump))
        (void)!write(STDERR_FILENO, busy, sizeof(busy) - 1);
    else
        (void)!write(STDERR_FILENO, stalled, sizeof(stalled) - 1);
    backtrace_symbols_fd(bt, n, STDERR_FILENO);
}

static void wd_say(const char *fmt, uint64_t v)
{
    char buf[128];
    int n = snprintf(buf, sizeof(buf), fmt, (unsigned long long)v);
    if (n > 0)
        (void)!write(STDERR_FILENO, buf, (size_t)n);
}

static void *watchdog_thread(void *arg)
{
    uint64_t cpu_prev = 0, wall_prev = 0;
    int busy_run = 0;
    (void)arg;
    while (g.running) {
        usleep(WD_PERIOD_MS * 1000);
        uint64_t beat = atomic_load(&g_loop_beat);
        if (!beat)
            continue;
        uint64_t now = mono_ms();
        /* Far more wall time than we slept: the process was frozen (iOS
         * suspension), so nothing that follows can be blamed on the loop
         * thread. Re-base the stall check on the resume. */
        if (wall_prev && now - wall_prev > WD_FROZEN_MS) {
            g_wd_resumed_at = now;
            wd_say("cbaresip: watchdog: the process did not run for %llu ms "
                   "(suspended); not a loop stall\n",
                   (unsigned long long)(now - wall_prev));
        }
        /* Spinning: loop CPU over the last period, as a percentage of one
         * core. Sustained for LOOP_BUSY_SAMPLES periods → one stack dump,
         * repeated at most once a minute while it lasts. */
        uint64_t cpu = loop_cpu_us();
        if (cpu && wall_prev) {
            uint64_t dwall = now - wall_prev;
            uint64_t pct = dwall ? (cpu - cpu_prev) / 10 / dwall : 0; /* µs/ms/10 = % */
            busy_run = pct >= LOOP_BUSY_PCT ? busy_run + 1 : 0;
            if (busy_run >= LOOP_BUSY_SAMPLES && now - g_busy_last_report >= LOOP_BUSY_REPORT_MS) {
                g_busy_last_report = now;
                wd_say("cbaresip: watchdog: loop thread at %llu%% CPU for 5 s "
                       "(spinning, not stalled); asking it for its stack\n", pct);
                atomic_store(&g_busy_dump, 1);
                pthread_kill(g_loop_pthread, SIGUSR1);
                usleep(100000); /* let the handler print before the flag flips back */
                atomic_store(&g_busy_dump, 0);
            }
        }
        cpu_prev = cpu;
        wall_prev = now;
        /* Age from the later of the last heartbeat and the last resume: a
         * heartbeat older than a suspension we sat through proves nothing,
         * but a loop that does not beat within 3 s of resuming is wedged. */
        uint64_t since = beat > g_wd_resumed_at ? beat : g_wd_resumed_at;
        uint64_t age = now > since ? now - since : 0;
        if (age > 3000) {
            if (!atomic_exchange(&g_stall_reported, 1)) {
                wd_say("cbaresip: watchdog: loop heartbeat stalled %llu ms; "
                       "asking the loop thread for its stack\n", age);
                pthread_kill(g_loop_pthread, SIGUSR1);
            }
        }
        else {
            atomic_store(&g_stall_reported, 0);
        }
    }
    atomic_store(&g_watchdog_run, 0);
    return NULL;
}

/* The SIP connection's whole certificate check, in place of OpenSSL's chain
 * building (SSL_CTX_set_cert_verify_callback): the presented leaf must be
 * the pinned certificate. Issuer, dates and name are not consulted — the
 * server's certificate is usually self-signed, and the pin is the identity,
 * exactly as for the gateway connection (CertificatePin in DiallerCore). */
static int verify_server_cert(X509_STORE_CTX *store, void *arg)
{
    (void)arg;
    bool has_pin, accept_any;
    uint8_t pin[32];

    pthread_mutex_lock(&g_trust.mu);
    has_pin = g_trust.has_pin;
    accept_any = g_trust.accept_any;
    memcpy(pin, g_trust.pin, sizeof(pin));
    pthread_mutex_unlock(&g_trust.mu);

    if (has_pin) {
        X509 *leaf = X509_STORE_CTX_get0_cert(store);
        uint8_t md[EVP_MAX_MD_SIZE];
        unsigned int n = 0;
        if (leaf && X509_digest(leaf, EVP_sha256(), md, &n) && n == sizeof(pin)
            && CRYPTO_memcmp(md, pin, sizeof(pin)) == 0)
            return 1;
        warning("cbaresip: tls: SIP server certificate is not the one pinned at enrolment; refused\n");
        X509_STORE_CTX_set_error(store, X509_V_ERR_CERT_REJECTED);
        return 0;
    }
    if (accept_any)
        return 1;
    warning("cbaresip: tls: no certificate pinned for the SIP server; refused\n");
    X509_STORE_CTX_set_error(store, X509_V_ERR_CERT_REJECTED);
    return 0;
}

void cb_set_tls_trust(const uint8_t *sha256, bool accept_any)
{
    pthread_mutex_lock(&g_trust.mu);
    g_trust.has_pin = sha256 != NULL;
    if (sha256)
        memcpy(g_trust.pin, sha256, sizeof(g_trust.pin));
    else
        memset(g_trust.pin, 0, sizeof(g_trust.pin));
    g_trust.accept_any = accept_any;
    pthread_mutex_unlock(&g_trust.mu);
}

/* Loop thread only: bring libre/baresip up. Everything created here is
 * bound to this thread's libre context, which lives as long as the loop. */
static int stack_open(const char *config)
{
    int err = libre_init();
    if (err)
        return err;

    dbg_init(DBG_INFO, DBG_NONE);
    dbg_handler_set(dbg_print, NULL);
    log_register_handler(&log_entry);
    log_enable_debug(true);
    log_enable_info(true);

    err = conf_configure_buf((const uint8_t *)config, strlen(config));
    if (!err)
        err = baresip_init(conf_config());
    if (!err)
        err = ua_init("Dialler", false, true, true); /* udp=off, tcp, tls */
    if (!err) {
        /* ua_init built the SIP TLS context, once for the life of the
         * stack (transport resets reuse it), and every connection's SSL
         * inherits it. The cert-verify callback replaces the chain check
         * itself, so it decides whatever libre sets per connection
         * (sip_verify_server only adds a hostname check inside the chain
         * check this replaces). */
        SSL_CTX *ctx = tls_ssl_ctx(uag_tls());
        if (ctx) {
            SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
            SSL_CTX_set_cert_verify_callback(ctx, verify_server_cert, NULL);
        }
        else {
            warning("cbaresip: tls: no SIP TLS context to pin\n");
        }
    }
    if (!err)
        err = conf_modules();
    if (!err)
        err = bevent_register(event_handler, NULL);
    /* The queue's pipe is registered with this thread's loop; pushes from
     * any thread wake it. */
    if (!err)
        err = mqueue_alloc(&g.mq, mq_handler, NULL);
    return err;
}

/* Loop thread only: the reverse of stack_open(), safe after a partial open. */
static void stack_close(void)
{
    g.mq = mem_deref(g.mq);
    log_unregister_handler(&log_entry);
    ua_close();
    baresip_close();
    dbg_handler_set(NULL, NULL);
    libre_close(); /* releases this thread's libre context */
}

#define CB_START_TIMEOUT_S 20 /* stack_open normally takes well under a second */

struct start_args {
    const char *config; /* valid until we signal done, not after */
    int err;
    bool done;
    bool abandoned; /* cb_start gave up waiting: the loop thread frees this */
    pthread_mutex_t mu;
    pthread_cond_t cv;
};

static void *loop_thread(void *arg)
{
    struct start_args *a = arg;
    struct sigaction sa;
    pthread_t wd;
    int err;

    g.thread = pthread_self(); /* on_loop_thread() is right from the first line */
    err = stack_open(a->config);
    if (err)
        stack_close();

    pthread_mutex_lock(&a->mu);
    a->err = err;
    a->done = true;
    bool abandoned = a->abandoned;
    pthread_cond_broadcast(&a->cv);
    pthread_mutex_unlock(&a->mu);
    if (abandoned) {
        /* cb_start timed out and returned; nobody else will free this. */
        pthread_cond_destroy(&a->cv);
        pthread_mutex_destroy(&a->mu);
        free(a);
        a = NULL;
    }
    if (err)
        return NULL; /* untouched from here on either way */

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = stall_dump;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGUSR1, &sa, NULL);

    g_loop_pthread = pthread_self();
    tmr_init(&g_beat_tmr);
    beat_handler(NULL);
    if (!atomic_exchange(&g_watchdog_run, 1)) {
        if (pthread_create(&wd, NULL, watchdog_thread, NULL) == 0)
            pthread_detach(wd);
        else
            atomic_store(&g_watchdog_run, 0);
    }

    err = re_main(NULL);
    if (!atomic_load(&g_stopping)) {
        /* Nobody asked: libre gave up on a poll error. Re-entering re_main
         * here corrupts its lock state (tried: a flood of "re_unlock
         * error"), so the stack comes down and the engine rebuilds it
         * (cb_alive() → false). */
        wd_say("cbaresip: re_main returned err=%llu unasked: the SIP "
               "loop is dead until the engine restarts the stack\n",
               (uint64_t)err);
        atomic_store(&g_loop_dead, 1);
    }

    tmr_cancel(&g_beat_tmr);
    atomic_store(&g_loop_beat, 0);
    stack_close();
    return NULL;
}

bool cb_alive(void)
{
    return g.running && !atomic_load(&g_loop_dead);
}

int cb_start(const char *config, cb_event_cb cb, void *ctx)
{
    /* Heap-allocated: if the stack takes too long to come up (a wedged
     * audio or network daemon — seen as an app that "never starts" until
     * the phone is rebooted), cb_start gives up after CB_START_TIMEOUT_S
     * and the loop thread frees the args when it eventually finishes. */
    struct start_args *ap = calloc(1, sizeof(*ap));
    if (!ap)
        return -ENOMEM;
    ap->config = config;
    if (g.running) {
        free(ap);
        return -EALREADY;
    }

    memset(&g, 0, sizeof(g));
    atomic_store(&g_loop_dead, 0);
    atomic_store(&g_stopping, 0);
    g.cb = cb;
    g.ctx = ctx;

    pthread_mutex_init(&ap->mu, NULL);
    pthread_cond_init(&ap->cv, NULL);
    g.running = true; /* before the thread exists: on_loop_thread() needs it */
    if (pthread_create(&g.thread, NULL, loop_thread, ap) != 0) {
        memset(&g, 0, sizeof(g));
        pthread_cond_destroy(&ap->cv);
        pthread_mutex_destroy(&ap->mu);
        free(ap);
        return -EAGAIN;
    }

    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += CB_START_TIMEOUT_S;
    pthread_mutex_lock(&ap->mu);
    while (!ap->done) {
        if (pthread_cond_timedwait(&ap->cv, &ap->mu, &deadline) == ETIMEDOUT && !ap->done) {
            ap->abandoned = true;
            pthread_mutex_unlock(&ap->mu);
            wd_say("cbaresip: stack start did not finish in %llu s; giving up on it "
                   "(the loop thread keeps going and frees the args)\n", (uint64_t)CB_START_TIMEOUT_S);
            return -ETIMEDOUT;
        }
    }
    int err = ap->err;
    pthread_mutex_unlock(&ap->mu);
    pthread_cond_destroy(&ap->cv);
    pthread_mutex_destroy(&ap->mu);
    free(ap);

    if (err) {
        pthread_join(g.thread, NULL);
        memset(&g, 0, sizeof(g));
        return -err;
    }
    return 0;
}

void cb_stop(void)
{
    if (!g.running)
        return;

    if (!atomic_load(&g_loop_dead))
        run_op(OP_STOP, NULL);  /* loop thread: hang up, cancel */
    if (!on_loop_thread())
        pthread_join(g.thread, NULL); /* it tears the stack down before it ends */
    /* From the loop thread (a callback stopping the engine) the teardown
     * runs after this handler returns; g is cleared now either way, and
     * cb_start() resets the atomics. */
    memset(&g, 0, sizeof(g));
}

int cb_ua_alloc(const char *aor)
{
    return run_op(OP_UA_ALLOC, aor);
}

int cb_ua_register(void)
{
    return run_op(OP_UA_REGISTER, NULL);
}

int cb_answer(const char *call_id)
{
    return run_call_op(OP_ANSWER, call_id, NULL, false);
}

int cb_dial(const char *uri, char *call_id_out, size_t call_id_len)
{
    if (call_id_out && call_id_len)
        call_id_out[0] = 0;
    struct op op = { .type = OP_DIAL, .aor = uri, .out = call_id_out, .outlen = call_id_len };
    return run_full(&op);
}

void cb_mute(bool muted)
{
    run_op_flag(OP_MUTE, NULL, muted);
}

int cb_hold(const char *call_id, bool hold)
{
    return run_call_op(OP_HOLD, call_id, NULL, hold);
}

int cb_transfer(const char *call_id, const char *uri)
{
    return run_call_op(OP_TRANSFER, call_id, uri, false);
}

void cb_hangup(const char *call_id)
{
    run_call_op(OP_HANGUP, call_id, NULL, false);
}

int cb_reject(const char *call_id, uint16_t status, const char *reason)
{
    struct op op = { .type = OP_REJECT, .id = call_id, .aor = reason, .scode = status };
    return run_full(&op);
}

int cb_ua_free(void)
{
    return run_op(OP_UA_FREE, NULL);
}

int cb_reset_transports(void)
{
    return run_op(OP_TRANSP_RESET, NULL);
}

bool cb_registered(void)
{
    return g.registered;
}

void cb_audio_interrupt(bool begin)
{
    run_op(begin ? OP_AUDIO_INTERRUPT_BEGIN : OP_AUDIO_INTERRUPT_END, NULL);
}

void cb_audio_stats(uint64_t *play_frames, uint64_t *rec_frames, uint64_t *play_energy)
{
    audiosess_stats(play_frames, rec_frames, play_energy);
}

void cb_media_stats(const char *call_id, cb_media_stats_t *out)
{
    if (!out)
        return;
    if (run_call_op(OP_MEDIA_STATS, call_id, NULL, false) != 0)
        memset(&media_stats, 0, sizeof(media_stats));
    *out = media_stats;
}

/* Lab: the audio continuity event ring lives in libre (re_tmr.h); these
 * are thin wrappers, safe from any thread. */
void cb_audio_events_reset(void) { au_ev_reset(); }
size_t cb_audio_event_count(void) { return au_ev_count(); }
size_t cb_audio_events(cb_audio_event_t *out, size_t max)
{
    return au_ev_read((struct au_ev *)out, max);
}
const char *cb_audio_event_name(uint32_t kind) { return au_ev_name(kind); }
void cb_audio_mark(int32_t what) { au_ev_push(AU_EV_MARK, what, 0); }

int cb_audio_test_alloc(void)
{
    return run_op(OP_AUDIO_TEST_ALLOC, NULL);
}

void cb_audio_test_free(void)
{
    run_op(OP_AUDIO_TEST_FREE, NULL);
}

/* From the patched libre (ios/vendor/patches/apply-re.sh): which set of
 * Dialler patches the linked XCFramework carries. Not weak on purpose: an
 * app built against an XCFramework older than the patch fails to link
 * instead of silently shipping without the fixes (2026-09-12: a build from
 * between an XCFramework rebuild and a codec fix cost an afternoon). */
int re_dialler_patchlevel(void);

const char *cb_version(void)
{
    static char v[64];
    snprintf(v, sizeof v, "baresip " BARESIP_VERSION " (libre patch level %d)", re_dialler_patchlevel());
    return v;
}
