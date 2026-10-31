// CBaresip: a minimal C surface over libre/baresip for the Swift engine.
// It owns the libre main loop thread and serialises API calls onto it.
#ifndef CBARESIP_H
#define CBARESIP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    CB_EVENT_REGISTER_OK = 1,
    CB_EVENT_REGISTER_FAIL,
    CB_EVENT_CALL_INCOMING,
    CB_EVENT_CALL_RINGING,
    CB_EVENT_CALL_ESTABLISHED,
    CB_EVENT_CALL_CLOSED,
    /// Our outgoing INVITE was sent / the far end is ringing (180) or
    /// sending early media (183).
    CB_EVENT_CALL_OUTGOING,
    CB_EVENT_CALL_PROGRESS,
    /// Our REFER was rejected or the transfer target failed; `text` has the
    /// status. The call continues.
    CB_EVENT_CALL_TRANSFER_FAILED,
    CB_EVENT_OTHER,
    /// A line from libre/baresip's own log; `text` is the message.
    CB_EVENT_LOG
} cb_event_t;

/// What an event is about. Strings are valid for the callback's duration
/// only; "" when not applicable.
typedef struct {
    /// The call's SIP Call-ID: the handle every per-call operation below
    /// takes, unique for the life of the stack. "" for non-call events.
    const char *call_id;
    /// The remote URI for call events.
    const char *peer;
    /// baresip's event text (reason, error) — except for
    /// CB_EVENT_CALL_INCOMING, where it is the caller's From display name
    /// ("" if the caller sent none), so the app can name the call from it.
    const char *text;
    /// CB_EVENT_CALL_INCOMING only: the server's call id from the INVITE's
    /// X-Dialler-Call-ID header ("" if absent) — the id the same call's
    /// wake carries, so the app can match the two without guessing.
    const char *dialler_call_id;
    /// CB_EVENT_CALL_CLOSED: the SIP status that closed the call (486, 480,
    /// 603 …), or 0 when no response carried one — a BYE, a local error, or
    /// our own hangup. The app picks the busy / congestion tone from it
    /// rather than parsing baresip's reason text.
    /// CB_EVENT_LOG: 1 when the stack wrote the line at warning severity or
    /// worse, else 0. The app must never drop a warning from its log,
    /// whatever the wording (see emit_line).
    uint16_t scode;
} cb_event_info;

typedef void (*cb_event_cb)(void *ctx, cb_event_t event, const cb_event_info *info);

/// Initialise libre + baresip with the given config text (baresip `config`
/// file syntax) and start the main loop on a background thread.
/// Returns 0 or a negative errno.
int cb_start(const char *config, cb_event_cb cb, void *ctx);

/// Stop the main loop, tear everything down. Safe to call twice.
void cb_stop(void);
/// True while the stack runs AND its loop thread is alive. libre ends the
/// loop on a poll error (seen on Darwin after a connection reset); then
/// every op fails with -ENOTCONN and the engine must cb_stop()+cb_start().
bool cb_alive(void);

/// Create the user agent for `aor` (baresip account line, e.g.
/// "<sip:201@dialler;transport=tls>;outbound=\"sip:10.0.0.5:5061;transport=tls\";regint=300;answermode=manual")
/// and start registering, replacing the previous user agent — unless that
/// one holds a call, in which case -EBUSY and nothing changes (see
/// cb_ua_free). Returns 0 or a negative errno.
int cb_ua_alloc(const char *aor);

/// Send a fresh REGISTER for the existing user agent now (new flow if the
/// old connection is dead). Returns 0, or a negative errno; -ENOENT if no
/// user agent exists.
int cb_ua_register(void);

/// Calls are addressed by the SIP Call-ID the events carry (`call_id`).
/// Several calls may exist at once (call waiting: one active, one held);
/// every operation names the one it means. -ENOENT for an unknown id.

/// Answer the incoming call `call_id`.
int cb_answer(const char *call_id);

/// Place an outgoing call to `uri` (full SIP URI) from the user agent and
/// return its call id in `call_id_out` (at least 128 bytes). Progress
/// arrives as CB_EVENT_CALL_OUTGOING / RINGING / PROGRESS / ESTABLISHED /
/// CLOSED with that id. Returns 0 or a negative errno.
int cb_dial(const char *uri, char *call_id_out, size_t call_id_len);

/// Mute / unmute the microphone. One microphone, every call: a muted user
/// stays muted across a swap.
void cb_mute(bool muted);

/// Put `call_id` on hold / resume it (re-INVITE). Returns 0 or a negative
/// errno.
int cb_hold(const char *call_id, bool hold);

/// Blind transfer: REFER the far end of `call_id` to `uri` (the server, as
/// B2BUA, connects the other party there and ends our call). Returns 0 or
/// a negative errno.
int cb_transfer(const char *call_id, const char *uri);

/// Hang up `call_id`; NULL hangs up every call (teardown).
void cb_hangup(const char *call_id);

/// Refuse the incoming call `call_id` with a final response, e.g. 486
/// "Busy Here" for a caller the app will not take (call waiting off, or a
/// third call). Returns 0 or a negative errno.
int cb_reject(const char *call_id, uint16_t status, const char *reason);

/// Unregister and free the user agent. Refused with -EBUSY while it holds
/// a call (ringing, dialling or up): freeing it would hang the call up.
/// The check is made on the loop thread, where an INVITE cannot slip in
/// between it and the free — the host's own view of "a call is up" is a
/// thread away and was 0.3 ms stale on 2026-09-18 (486 to the caller).
/// Returns 0 or a negative errno.
int cb_ua_free(void);

/// Drop every cached SIP TCP/TLS connection and rebuild the transports on
/// the current local addresses (baresip's network-change reset, without
/// re-registering). Call it whenever the SIP flow may be dead without the
/// stack having noticed — after iOS suspended the app, on a new gateway
/// session — since a send on a dead cached connection fails at once
/// (EPROTO, "ua_alloc -100") and nothing else evicts it. Refused with
/// -EBUSY while a call is up (as cb_ua_free): it would drop the call's
/// signalling connection too. Returns 0 or a negative errno.
int cb_reset_transports(void);

/// Which server certificate the SIP TLS connection accepts (SPEC §4.8).
/// With `sha256` (32 bytes, the SHA-256 of the certificate's DER — the
/// fingerprint enrolment pinned): that certificate and no other, whoever
/// issued it and whatever its dates, as the gateway connection does.
/// Without it: any certificate when `accept_any` (the dev path), otherwise
/// none. Takes effect from the next TLS handshake; may be called from any
/// thread, before or after cb_start, and outlives cb_stop.
void cb_set_tls_trust(const uint8_t *sha256, bool accept_any);

/// Whether the UA holds a live registration.
bool cb_registered(void);

/// Manual audio hold from the host (CallKit): begin=true holds — running
/// units stop and units allocated later are initialised but not started;
/// begin=false releases — all units start. The (patched) audiounit module
/// never starts audio on its own; see ios/vendor/patches/README.md.
void cb_audio_interrupt(bool begin);

/// Frames delivered by CoreAudio through the driver's callbacks since the
/// stack started (play = output rendered, rec = input captured), and the
/// summed |sample| energy of rendered output — zero energy with frames
/// flowing means the far end is silent (or we are decoding nothing).
void cb_audio_stats(uint64_t *play_frames, uint64_t *rec_frames, uint64_t *play_energy);

/// Media-path counters for `call_id`'s audio stream (all zero when there
/// is no such call). Together with cb_audio_stats this locates a silent
/// or glitchy call: units rendering but rx=0 is the media path, not audio;
/// rx flowing with lost/late/underflow climbing is jitter or loss upstream.
typedef struct {
    uint32_t tx_packets;   ///< RTP sent
    uint32_t rx_packets;   ///< RTP received
    uint32_t rx_errors;    ///< receive errors (decode/parse)
    int32_t  rx_lost;      ///< packets lost on the way to us (RTCP)
    uint32_t rx_jitter_us; ///< inter-arrival jitter (RTCP)
    uint32_t jb_late;      ///< jitter buffer: frames arriving too late
    uint32_t jb_lost;      ///< jitter buffer: frames lost
    uint32_t jb_underflow; ///< jitter buffer: player starved (an audible gap)
    uint32_t jb_overflow;  ///< jitter buffer: dropped as too many queued
} cb_media_stats_t;
void cb_media_stats(const char *call_id, cb_media_stats_t *out);

/// Lab (lab/audio-continuity): every event that removed or padded audio on
/// the play path since the last reset — the vendored aubuf/jbuf/audiounit
/// hooks (ios/vendor/patches/apply-re.sh, apply-baresip.sh). t_us counts
/// from the reset, which the shim does when a call is dialled or arrives.
/// kind is `enum au_ev_kind` in libre's re_tmr.h; name it with
/// cb_audio_event_name. Thread-safe, no loop hop.
typedef struct {
    uint64_t t_us;
    uint32_t kind;
    int32_t a;
    int32_t b;
} cb_audio_event_t;
void cb_audio_events_reset(void);
size_t cb_audio_event_count(void);
size_t cb_audio_events(cb_audio_event_t *out, size_t max);
const char *cb_audio_event_name(uint32_t kind);
/// A mark from the host in the same timeline: 1 = CallKit didActivate,
/// 2 = call established.
void cb_audio_mark(int32_t what);

/// Test hooks (audio-probe): allocate / free a player + source through
/// baresip's device layer without a SIP call, so the driver's start/hold
/// behaviour can be asserted directly. 48 kHz mono 20 ms S16LE.
int cb_audio_test_alloc(void);
void cb_audio_test_free(void);

/// libre/baresip version string, for logs.
const char *cb_version(void);

#ifdef __cplusplus
}
#endif

#endif
