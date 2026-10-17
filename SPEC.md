# Dialpark — Project Specification & Architecture

> Status: planning / feasibility draft. Native iOS softphone with on-prem
> wakeups via Local Push Connectivity (no APNS), designed for test-first,
> component-by-component development.

> **Names.** *Dialpark* is the system: the call server (`dialpark-server`), the
> operator console (`dialpark-admin`), the licence and the harness in its
> server role. *Dialler* is the iOS app that enrols to a Dialpark server. The
> app keeps its name, bundle identifiers, URL scheme (`dialler://`) and SIP
> headers (`X-Dialler-Call-ID`); everything that acts as or describes the
> server is Dialpark. Renamed 2026-10-05; older narrative below may still say
> "the light server" or "the call server" for Dialpark.

## 1. Goal

A native iOS SIP softphone that receives incoming-call wakeups **on-premises
without Apple's Push Notification Service (APNS)**, so that calls are not missed
when the app is backgrounded/killed and even when the site has no internet
access. It interoperates with existing PBXs **and can also place calls directly
between app instances on different devices through the light server with no PBX
present**, maintains a server-synced address book, and supports hold/transfer.
Off-prem (remote) users, video and IM are not scheduled — see §6 "Much later".

## 2. Core mechanism (the load-bearing decision)

Wakeups use Apple's **Local Push Connectivity (LPC)** via the Network Extension
framework: an **App Push Provider** extension (`NEAppPushProvider`, managed by
`NEAppPushManager`) maintains a persistent TLS connection to an on-prem server
and reports incoming calls directly to **CallKit**. This is the only
Apple-sanctioned wakeup that does not route through APNS.

### Hard constraints this imposes
- **Wi-Fi-network-bound.** The push provider only runs while the device is
  joined to a designated Wi-Fi SSID (`matchSSIDs`, a list, so multi-SSID
  sites are fine; the app takes them comma-separated since 2026-09-13).
  A handoff between two listed SSIDs is a network change: the provider
  stops (`NEProviderStopReason` 3, no network) and restarts on the new
  one, and the app registers again from its new address. A call placed
  in that window is dialled to the registration the server holds at the
  moment, which may be the old address — so the server watches the
  registry while a callee's INVITE is in flight and re-dials the new
  route the instant a registration from elsewhere arrives
  (`registry.WaitRouteChange`, `retargetError` in `internal/b2bua`, at
  most 3 re-targets per call); before that, every such call ran into
  Timer B (32 s) and died (2026-09-13 two-SSID test). An INVITE on a
  route that has given no response is abandoned at once when the caller
  hangs up, the callee moves or the wake is declined (sipgo's forced
  cancel; with a response, the normal CANCEL/487 runs) — sipgo otherwise
  waits for Timer B before it will cancel, and the wake_cancel came 20–30
  s after the caller had gone, so the app rang for nobody. The wake sent
  on the old, dead extension connection is replayed to whichever session
  of the device connects next within the ring window; the client itself
  reconnects the moment Network.framework reports a better path for its
  connection (`betterPathUpdateHandler` in `LANSocketTransport`, Apple's
  own migration guidance), which is what a handoff to a new address
  produces. The SIP stack must learn the new address too: baresip lists
  its interface addresses once at start (the netroam module, not loaded
  here, is what would refresh them), so the shim re-reads them before
  every transport reset — with the stale list the rebuilt transport and
  every call's media socket bound the old address and the app answered
  each INVITE with 500 Call Error (2026-09-13, the second SSID test:
  "unavailable" on the caller's phone, a few seconds of CallKit on the
  iPhone). Off that network there are no wakeups and the phone is
  unreachable for incoming calls: this is the accepted product scope, not a
  bug. It matches the on-prem goal ("works even if internet is down, as long
  as local Wi-Fi is up"). Remote reach (cellular / home Wi-Fi) is unscheduled
  — see §6 "Much later". LPC is the **only** wake path; there is no APNS
  fallback (§9 risk 1).
- **App Store distribution.** SSID configuration is done in-app through
  `NEAppPushManager` (no MDM). Requires the Network Extension entitlement
  (`com.apple.developer.networking.networkextension` → `app-push-provider`).
  App Review will scrutinize Network Extension usage; justify the on-prem use
  case clearly.
- **Extension is resource-limited.** Keep the extension to signaling only — no
  media. Media runs in the main app once foregrounded by CallKit.
- **The extension must reconnect on its own, fast, for ever.** iOS only
  restarts the provider on a network change and calls its timer rarely, so
  a server restart or any dropped connection would otherwise leave the
  device unreachable until Wi-Fi is toggled (seen 2026-09-11). The provider
  runs the same `GatewaySession` keeper as the app, permanently active:
  backoff 1, 2, 3, then 5 s for ever, and an attempt parked in
  Network.framework's "waiting" (server not yet listening) is abandoned
  after 3 s. The system timer only kicks the keeper. A fatal gateway error
  (rejected enrolment) stops the fast retry; the timer retries those.

### LPC is only the background-survival path
This is the single most important framing for testability. The wake transport is
**not** special when the app is running:

- **App alive (foreground):** the app holds a **direct LAN socket** (WebSocket /
  TLS) to the on-prem server. No LPC, no APNS involved. This is real production
  behaviour, not a test stand-in.
- **App dead / backgrounded:** the `NEAppPushProvider` extension holds that
  *same* socket and reports incoming calls to CallKit.

Both speak the **same wire protocol to the same server**, and the app and
extension **share the protocol code** (App Group framework). Therefore LPC is a
thin background-delivery sibling of the foreground LAN socket — which is what
lets ~everything be validated with no device (see §7).

## 3. Decisions (locked)

| Area | Decision |
|---|---|
| SIP + media stack | **baresip / libre / librem** (BSD-3), **Opus** (BSD) app↔app; **G.722** (public-domain implementation, WebRTC's copy — §8) and **G.711** on PBX calls — fully permissive, commercializable, no license fee |
| PBX target | **Asterisk** for dev/test; compatible with **Cisco CUCM** and general SIP exchanges → server is a standard SIP element, PBX-agnostic. **PBX is optional** — the server also routes app↔app calls directly with no PBX present |
| Exchange model | **Own exchange.** The light server is the call controller. A PBX is reached one of two ways, chosen per deployment at start-up (`-pbx-mode`, §6 item 3c): as a **SIP trunk peer** trusted by address, or as a **registrar the server registers to on behalf of devices** — one third-party SIP line per device, credentials held by the server. Never both at once. **The app never registers to a PBX, in dev or prod** (§4.4 rule 1), and never holds a PBX credential |
| App↔server leg | **SIP (baresip) under a strict private profile** (§4.4). This is the long-term design (§4.5); the `CallEngine` seam remains as ordinary structure, no replacement is scheduled |
| Wire framing | **Length-prefixed JSON over TLS 1.3** (port 7443) for every signal transport: foreground LAN socket, LPC extension socket, public edge. No WebSocket — raw TLS is the natural `NWConnection` fit for the extension. Frozen in [protocol/PROTOCOL.md](protocol/PROTOCOL.md) with golden fixtures shared by Go and Swift |
| Server language | **Go**, standard library only (no external modules) |
| Coverage | **Wi-Fi-only (LPC).** Remote app users (cellular / home Wi-Fi) are **unscheduled** (§6 "Much later"). The wake transport stays abstracted so an APNS sibling could be added without a rework, but none is planned |
| Distribution | **Public App Store**; the LPC configuration (the office SSIDs) is **set by the administrator per device and pushed to the app** (§6 item 8b), no longer typed into it |
| Directory ownership | **One directory per device.** The server is the source of truth for contacts; the admin (CSV) and the user (in-app) edit the same list, favourites included. No shared or global list (§6 item 7) |
| Management plane | **Separate process, `dialpark-admin`** (Go, stdlib, server-rendered HTML, embedded assets) speaking only to the call server's admin API. The call server gains additive JSON endpoints and nothing else; an admin action never interrupts a call and affects only the device it names (§4.8). Call history is device-local — the server keeps no call records |
| Device onboarding | **Short-lived enrolment code**, delivered as a QR (`dialler://enrol…`) or typed with the server address; the claim rotates the device credential and pins the server certificate (§4.8, §6 item 8) |
| Video / IM | **Not scheduled** (§6 "Much later") |
| Product licence | **Vendor-signed, offline, bound to the server's install id, verified on the server and on the phone** (§4.9, decided 2026-10-03): X devices until a date; enrolment refused past X; a device that loses its seat is suspended; expiry is a hard stop; no licence is 0 seats. A one-off online check-in at application is a later, optional addition; there are no regular check-ins |

## 4. Architecture

```
┌──────────────────────── iOS device (on-prem Wi-Fi) ─────────────────────────┐
│                                                                              │
│  Main App (SwiftUI)               App Push Provider Extension (NE target)     │
│  ├─ CallEngine  (SIP/RTP)         ├─ PushTransport (persistent TLS → server)  │
│  ├─ CallKit control               ├─ reports incoming call → CallKit          │
│  ├─ AddressBookStore              └─ foregrounds main app on answer           │
│  ├─ DirectorySync                                                             │
│  └─ AudioSession (Opus/G.722/G.711) Shared framework (App Group):            │
│                                    protocol models, keychain, config          │
└─────────────────────────────────────┬────────────────────────────────────────┘
                                       │ TLS, transport-agnostic wake/signal
                                       ▼
                    ┌─────────────────────────────────────┐
                    │  Light Server (on-prem, Go or Rust)  │
                    │  ├─ Wake gateway (LPC conns)         │
                    │  ├─ SIP B2BUA / registrar  ◄── core  │
                    │  ├─ Media relay (app-leg RTP)        │
                    │  ├─ local routing (app↔app, no PBX)  │
                    │  ├─ PBX event adapter (AMI/ESL) ◄─── │
                    │  │   OPTIONAL, dev-only              │
                    │  └─ Directory API (address book)     │
                    └──────────────┬──────────────────────┘
                                   │ standard SIP (trunk/registration)
                                   ▼   — OPTIONAL when calling app↔app —
                  Existing PBX — Asterisk (dev) / Cisco CUCM / general
```

### Standalone mode: app-to-app calls with no PBX
The light server is a full SIP element in its own right, so it can route calls
**directly between two registered app instances without any PBX**:

- Each app registers its SIP account to the light server, which keeps an
  internal registration/location table of online endpoints (and the
  wake-routable identity for offline ones).
- An outbound call to another known user is routed by the server itself: if the
  callee's app is online it forwards the INVITE; if offline it fires a **wake**
  (LPC), waits for the app to register, then bridges the legs as a B2BUA — the
  same wake path used for PBX-originated calls.
- The PBX is therefore **optional**. With no PBX configured, the server is a
  self-contained on-prem call controller for the app fleet. With a PBX
  configured, the server additionally trunks/registers to it for external reach.

Routing decision (server): destination resolves to a **local endpoint** →
route internally; otherwise → hand off to the configured `PBXAdapter` trunk
(if any). Address-book entries carry which mode applies, so the app UI is
identical for both. This reuses the wake + B2BUA machinery — app↔app is not a
separate code path, just a routing target with no PBX leg.

### Why the server is a SIP B2BUA, not an AMI/ESL listener
A killed/backgrounded app cannot hold a SIP registration, so the PBX would have
nowhere to send the INVITE. The light server solves this **and** stays
PBX-agnostic by being the SIP endpoint the app registers to:

1. The app's SIP account points at the **light server** (acting as outbound
   proxy / registrar / B2BUA).
2. The light server maintains a registration/trunk toward the real PBX
   (Asterisk, CUCM, …) so the PBX always considers the line reachable.
3. Inbound INVITE arrives at the light server → it sends a **wake** over LPC →
   the extension reports to CallKit → on answer the app registers SIP → the
   server bridges the legs (B2BUA).

This depends only on standard SIP, so it ports from Asterisk to CUCM and other
exchanges. AMI (Asterisk) / ESL (FreeSWITCH) are kept only as **optional
dev/test adapters**, never as the backbone. (CUCM exposes no such API, so the
core flow must not need one. Note CUCM requires third-party SIP devices to be
provisioned appropriately — this is a server↔PBX integration concern, isolated
from the app.)

### 4.4 App-leg profile (locked)
The app↔server leg is SIP, but **not generic SIP**. It is a private profile
between two components we own. These are MUST rules from Phase 0; each is cheap
now and expensive to retrofit once a B2BUA has shipped with UDP or direct-media
assumptions baked in. Several were originally justified by remote users (§6
"Much later"); they stand on their own for a shared office Wi-Fi, where TLS-only
signalling, relayed media and SRTP are the right answer regardless, and they
are already implemented — do not remove them because remote reach is deferred.

1. The app registers **only to the light server**. Never to a PBX — including
   Asterisk in dev.
2. App-leg SIP is **TLS over TCP only**. No UDP listener exists on the
   app-facing side. Every REGISTER and initial INVITE on it is authenticated
   with **SIP Digest using the device's enrolment credential** (username =
   device id, password = token; the server stores only H(A1)), and the SIP
   user must be the one the device is enrolled for. In-dialog requests and
   the trunk (rule 7) are not challenged. The Digest realm is the SIP
   domain (`-local-domain`), so renaming the domain invalidates every
   stored credential until devices are re-enrolled; treat the domain as
   permanent (README, "The SIP domain").
3. App-leg media **always relays through the server**. ICE/TURN may be added
   later as an optimisation; the relay path is the baseline and must exist from
   Phase 0.
4. **SRTP mandatory.** *Done 2026-09-13 (plan Phase F):* SDES SRTP
   (AES_CM_128_HMAC_SHA1_80) on every app-leg media session — the server
   offers and answers RTP/SAVP with `a=crypto` on the TLS transport
   (`MediaSRTP: 1`), the app's account carries `mediaenc=srtp-mand`
   (baresip's `srtp` module), and the harness phones the same on TLS. The
   trunk leg stays plain RTP and follows the PBX (`media_encryption=sdes`
   on the Asterisk endpoint would extend it; not required). The relay is
   unchanged: it copies encoded payload between the legs and each leg's
   media session applies its own keys, so a trunk call is SRTP app↔server
   and RTP server↔PBX with one codec end to end. The server logs
   `caller_srtp`/`callee_srtp` on `bridged` (and `srtp` on `echo:
   answered`); `make harness-call` fails unless both app legs are `on`.
   Vendored diago change: the caller's SDP is applied to the callee's
   session for codec filtering only (`OriginatorCodecs`), never as its
   remote side — otherwise an app caller's key became the trunk leg's
   context (`server/vendor/PATCHES.md`).
   Codecs: Opus primary app↔app; G.722 primary and
   G.711 fallback when a leg is the PBX trunk. Both legs of a call always
   share one codec — the relay copies encoded audio and never transcodes;
   a transfer whose new far leg takes another codec moves the remaining
   leg to it by re-INVITE.
5. Wake, directory and presence travel on the **wire-protocol channel**.
   SIP carries call setup and media only.
5a. **QoS on every hop** (Phase E, 2026-09-13): media is marked DSCP EF
   (46) and signalling CS3 (24) by the app, the server and the PBX. App:
   baresip `rtp_tos 184` / `sip_tos 96`, and a libre patch that also sets
   Apple's `SO_NET_SERVICE_TYPE` (voice / signalling — what iOS maps to
   the Wi-Fi WMM access category; the DSCP byte alone does not) and
   `IPV6_TCLASS`; the wire-protocol socket uses `NWParameters.serviceClass
   = .signaling`. Server: RTP/RTCP sockets EF and the SIP and wire-protocol
   listeners CS3 through `net.ListenConfig` Control hooks (`internal/qos`,
   vendored `media.ListenConfig` / `sipgo.ListenConfig`), accepted TLS
   connections inheriting the listener's mark. PBX: `tos_audio=ef`,
   `cos_audio=5` on endpoints and `tos=cs3`, `cos=3` on transports.
   Gate: `make harness-qos` captures the server's egress and requires
   every RTP packet EF and every SIP/TLS packet CS3.
6. **REFER (transfer) is handled by the server** as B2BUA, never proxied
   through to the far leg. When the remaining party and the target are both
   on the PBX, the server re-issues the transfer to the PBX (its own REFER
   on the trunk leg) so the PBX completes it and this server leaves the
   media path; if the PBX refuses, the server completes the transfer
   itself. The app's leg is unaffected either way.
7. The `PBXAdapter` speaks **standard SIP towards the PBX and nothing
   else** — trunk peering, or the line registrations of item 3c. AMI/ESL
   remain dev-only. Widened 2026-09-22 from "trunk SIP and nothing else":
   registering as a third-party SIP device is still ordinary SIP a
   standard exchange understands, and it stays behind this seam.
6a. **A blind transfer hands over the moment the target rings**
   (2026-09-15). The referrer is released on the target's first 18x — not
   on its answer — so pressing Transfer frees them immediately instead of
   tying them to a phone ringing somewhere else; until then they cannot
   even dial (`CallController.startCall` refuses a second call). The
   waiting party hears music while the target is resolved and woken, then
   **ring-back** from the instant it alerts, then the bridge. The rule is
   `handsOver`: 18x only. **100 Trying is not alerting** — releasing on it
   would free the referrer a moment before a 404 and leave the waiting
   party with nobody, having told the referrer it worked.
   The split that follows is the point: a refusal **before** it rings
   (486/480/404) never happened as a hand-off, so the referrer keeps the
   call and is told why. A failure **after** it rings has no one to go back
   to, so the waiting party gets busy tone for `busyBeforeHangup` and the
   call ends — the ordinary end of a blind transfer nobody answered. That
   is the trade: once released, the referrer cannot be put back, which is
   what attended transfer (§6 near-term item 2) is for.
   This also removes an inconsistency rather than adding a mode: a transfer
   offloaded to the PBX already released the referrer at once, so the same
   button behaved differently depending on where the target happened to
   live. `wait()` needs `awaitHandover` for it — the referrer's BYE now
   arrives while the call is very much alive. Asserted by
   `make harness-hold-music`: harness extension 700 alerts then fails
   (ring-back → release → busy → end, with the referrer's own call proven
   terminated) and 701 rejects at once (no release, call stays, referrer
   told `486`).
7a. **The PBX refuses its own extensions** (2026-09-15). Whether a PBX
   extension is registered is the PBX's knowledge, and this server keeps
   none of it — that is rule 7. So an extension that is off or unregistered
   must come back as a SIP status *from the PBX* (480 Temporarily
   Unavailable), which the server relays like any other response. Two
   things are needed on the PBX for that, and neither is a default:
   a `dial-status` context every dialling context includes, mapping
   `Dial()`'s DIALSTATUS to a hangup cause (CHANUNAVAIL → 20 → 480, BUSY →
   17 → 486, CONGESTION → 34 → 503) instead of falling through to a bare
   `Hangup()`; and `qualify_frequency` + `remove_unavailable=yes` on every
   AOR, so a phone switched off without unregistering has its stale contact
   dropped rather than rung for the full 30 s. Without the second, calling a
   phone that had lost power rang until the caller gave up — with no final
   response at all, which the server logs as `context canceled`. Asserted by
   `make harness-pbx-unavailable` (never registered; registered and
   answering; switched off with its contact still on file). Detection still
   costs up to `qualify_frequency + qualify_timeout` after the phone goes:
   a call in that window rings, and nothing on our side can shorten it.
7b. **180 Ringing means something is alerting** (2026-09-15). The server
   used to send it the moment an INVITE arrived, before dialling anything,
   so every call rang instantly whatever the destination — harmless while
   nothing made a sound, and wrong the day the app began playing ring-back
   from it (rule 8a): a call to a phone that was switched off rang for the
   full ring timeout. `serveDialog` now sends 100 Trying and arms a
   one-shot `ringer`; 180 follows from whichever comes first — an 18x from
   the callee's route (forwarded for every callee, trunk included, with 183
   relayed as 180, since early media cannot cross a leg we have not
   answered), or the wake reaching a device, which is what makes the phone
   ring on the wake path. An unreachable destination therefore goes
   100 → 480 with no 180 at all and the caller plays congestion at once.
   Asserted by `make harness-pbx-unavailable` (the caller must see 100 then
   480, never a 180); that a real ringing callee still produces one is
   `OUTBOUND=212 make sim-call`.
8b. **Hold music comes from this server** (plan Phase K, 2026-09-15). Hold
   means the holder has stopped sending — that is what `a=sendonly` says —
   so without us the other party hears nothing and assumes the call
   dropped. The treatment therefore comes from the call server on the side
   of whoever pressed hold, which is the rule every PBX follows and the
   reason Asterisk ships `moh_passthrough=no`: the remote party may be
   another PBX, a carrier or the PSTN, and none of them will play music on
   your behalf. (It is why the app already hears music when **101** holds —
   that is Asterisk doing exactly this, from its side.)
   Two consequences make it robust. **Nothing is signalled**: the held
   party's call carries on untouched, so this works whatever is at the far
   end and however it is configured — no re-INVITE, no glare, no 491, no
   dependency on somebody else's `musiconhold.conf`. And **nothing is
   encoded**: this server is a copy relay with no codecs and is not getting
   any (`CGO_ENABLED=0`, std lib only), so the music is pre-encoded once
   per codec a leg can be held on — PCMU, PCMA, G.722, Opus — by
   `tools/gen_moh.py`, and `server/internal/moh` embeds the frames. The
   relay puts them on the held party's own stream: same SSRC, same sequence
   space, same SRTP context, same payload type, timestamps continuing from
   the last relayed packet, paced by our own 20 ms ticker against a
   monotonic deadline (nothing arrives to pace us any more). So no
   renegotiation, and the far end's jitter buffer sees the audio carry on
   rather than a new stream start. The signal that a leg went on hold is
   the direction it settled on (`MediaSession.NegotiatedMode`, a vendored
   accessor): the app offers sendonly, we answer recvonly, and that is the
   only notice there ever is. One known artifact: G.722 is ADPCM and its
   decoder is stateful, so the splice costs a few tens of milliseconds
   while the far end's predictor reconverges; Opus packets are
   self-contained and G.711 is stateless. **Resume has to rebase the
   relayed stream.** The music moved our sequence numbers and timestamps
   on; the party that was holding knows nothing about that and carries on
   from its own, so the next relayed packet is treated as a new source and
   rebased onto what the music left behind. Without it the outbound stream
   jumps *backwards* by the length of the hold and the far end drops every
   packet as stale — on a device, the caller's microphone simply gone after
   resume, with the relay counters still rising and no error logged
   (2026-09-15). `TestResumeAfterHoldMusicNeverGoesBackwards` pins it; the
   end-to-end check has to compare the far end's level before the hold with
   after the resume, because a PBX in the middle re-originates RTP and
   turns a silent failure into a merely degraded one. The music is generated, not
   sampled, so `server/internal/moh` carries no licence or attribution
   (§8); swapping in a real track is `gen_moh.py --wav`, and its licence
   would have to be recorded there. The same music covers the other
   silence of its kind: a party waiting through a **transfer** while the
   target is resolved, woken and rung (§6 near-term item 2). One mechanism,
   differing only in why — and a transfer is routinely preceded by a hold,
   so starting music always stops whatever was playing first. While it
   plays, relayed packets from the other side are dropped rather than mixed
   into the same stream: during a transfer the party being replaced is
   still sending. Asserted by `make harness-hold-music` on four paths — a
   trunk call on G.722 with Asterisk in the middle, an app-to-app call on
   Opus with no PBX anywhere, a resume, and a refused transfer — with the
   caller silent wherever the music itself is being measured, so anything
   the other phone records can only be ours.
8c. **The in-call screen says what the call is doing** (2026-09-15).
   CallKit's own UI reads "calling" until a call ends, whatever happened,
   so the app's screen said "Calling…" while the earpiece was already
   playing congestion at the user. `CallProgress` (DiallerCore) is the
   vocabulary — Calling… / Ringing… / Busy / Declined / No answer /
   Unavailable / Unknown number / Call failed — mapped from the same SIP
   status the tone is (`CallProgress.forFailure`, beside
   `CallTones.failure`, with a test that the two never disagree: anything
   that plays a tone has words). The controller reports it through
   `CallUI.callProgress`, and a refusal is reported *before* the end, so
   the reason is on screen for as long as its tone lasts. "Ringing…" is
   only truthful because of rule 7b — before that, 180 arrived before the
   INVITE went anywhere. The words live in DiallerCore, not the view,
   because the app target has no tests (the `TonePolicy` lesson).
   A **refused transfer** uses the same words, on a transient line on the
   in-call screen ("Transfer failed — Busy"): the call simply carries on,
   so nothing else there would ever say it failed, and it had been going to
   the debug log alone. Only a transfer refused *before* the target rang
   reaches the app at all — after that the call has been handed over and is
   no longer ours to report on (rule 6a). Transfers are also the one place
   the status is not a number: baresip passes the far end's NOTIFY sipfrag
   through verbatim (`"486 Busy Here"`) and leaves `call_scode` alone,
   because that belongs to the referring call, so
   `CallProgress.forTransferFailure` parses it — and returns nil for a
   local failure, which carries an errno and no status, rather than
   inventing a reason.
   *What is reachable today:* `callerStatus` relays 486/600/603 as-is and
   collapses everything else to 480, so a phone shows Busy, Declined,
   Unavailable — never Unknown number or No answer, even when the PBX said
   404 or 408. Widening that is a trunk-visible change (a PBX's
   forward-on-unavailable rules key off it), so it is a deliberate decision,
   not a side effect.
8. **Call waiting** (plan Phase I, 2026-09-14): an app holds up to two
   calls, one active and one on hold — the handset norm and what CallKit's
   own UI models (two call groups of one call, `supportsHolding` on every
   call; the second call's answer UI and the swap are CallKit's, the
   call-waiting tone is the app's). Every layer addresses calls by id:
   baresip's SIP Call-ID through the shim and engine, the server's
   `X-Dialler-Call-ID` header to pair an INVITE with its wake, the
   controller's ids for CallKit; nothing is matched by "the call that is
   ringing". Answering a second call holds the first; when the call in
   progress ends and the only call left is on hold, the controller asks
   the system to resume it (a hold action of its own, so CallKit's state
   follows) — the phone is at the user's ear, so they are back in that
   call without touching the screen; a call the user held on purpose is
   left alone when a merely ringing second call is declined. Switching is the
   system's control (iOS 26's swap banner, shown over the app while a call
   is held), so the in-call screen only names the held party and hides
   Hold — on iOS 17/18, which show no such banner, Hold reads Swap. Ending
   the held call is swap, then End. A third caller, or any second
   caller while Settings › Call waiting is off, is refused with 486 (the
   INVITE) or `wake_ack{busy}` (the wake) and the PBX applies its busy
   rule. Deferred to a follow-up: a second *outgoing* call while on a
   call, and attended transfer built on two calls. Gate: `make
   sim-call-cw` (in `sim-call-all`); device items in §7.3.
   *What the device runs of 2026-09-14 settled, and how iOS decides the
   second call's UI.* CallKit needs **two call groups of one call each**
   — `maximumCallGroups = 2`, `maximumCallsPerCallGroup = 1`. A *group* is
   a conference; configured the other way round (one group of two calls)
   iOS offered only "End & Accept". The rule behind that is iOS's own,
   read from `-[TUCallCenter isHoldAndAnswerAllowed]` in the iOS 26.5
   runtime's TelephonyUtilities: for two calls of the *same* provider,
   hold-and-answer is allowed exactly when the provider's
   `maximumCallGroups` exceeds one; a call's `supportsHolding` is
   consulted only between different providers. On iOS 26 the second
   call is then presented with the ordinary **Accept / Decline** — there
   is no "Hold & Accept" label any more — and Accept runs
   `holdAndAnswerIfNeeded`: a hold for the current call and the answer
   for the new one, delivered to the app as `CXSetHeldCallAction` +
   `CXAnswerCallAction` (the same pair `make sim-call-cw` drives).
   **Confirmed on the device, 2026-09-15**, by a `callservicesd` console
   capture during a second incoming call: the system logged
   `isHoldAndAnswerAllowed: callsSupportHoldAndAnswer: YES` with every
   disqualifier (CDMA mix, hosted mix, RTT/TTY, a call still dialling,
   screening, SharePlay) `NO`, and on Accept it logged `Performing hold
   active calls and answer ringing call`. So the app satisfies every
   condition iOS checks and iOS performs hold-and-accept; only the button
   label differs, and that choice is made inside Apple's in-call UI app
   (`com.apple.InCallService`, launched for the call in the same log),
   which ships on devices only and logs nothing about its buttons. The
   two "advertise as holdable" work-arounds tried on the way were
   reverted; nothing further is configurable from the app, and the only
   remaining route to the labelled buttons is a Feedback report to Apple. *A held call owns no audio units.* Hold stays `sendonly` on
   the wire, but the shim stops the held call's audio at once and sets
   baresip's audio-hold flag so the hold re-INVITE's answer does not
   re-create its source: iOS refuses a second VoiceProcessingIO input
   (`kAudioUnitErr_MultipleVoiceProcessors`, −66635), and with the held
   call's recorder still running the call answered next had no
   microphone (device, 2026-09-14). The resume re-INVITE's answer restarts
   audio for the resumed call; CallKit always holds before it answers or
   resumes, so the one microphone follows the active call. And iOS plays
   **no tone** for a VoIP app's second call — it
   suppresses the ringtone and shows its answer UI, nothing more — so the
   app plays the call-waiting beep itself into the call's audio session
   (`CallTones`, `TonePlayer`; two 100 ms bursts at 425 Hz every 5 s,
   quiet because the phone is at someone's ear). That is the first piece
   of the tone plan (Phase J).
8a. **Call-progress tones are the app's** (plan Phase J, 2026-09-15). iOS
   plays none of them for a VoIP app, and this server answers an outgoing
   call with a bare 180, so without the app there is silence from the
   moment the user dials until the far end answers — and silence again
   when the call is refused. `CallTones` (DiallerCore) is the plan: 425 Hz
   ETSI cadences as data, rendered to PCM by pure, unit-tested code, so a
   country plan is a different table and not different code. `TonePlayer`
   (the app) plays one on the session CallKit has already activated for
   the call, mixing with baresip's audio unit — a second player inside
   baresip would fight it for the one VoiceProcessingIO instance. **Which
   tone and when is the controller's**, because it is a SIP question, and
   reaches the app through `CallUI.playTone`: ring-back (1 s / 4 s) while
   our outgoing call is alerted by a 180, **never on a 183** — early media
   is the far end's own ring-back and a tone over it is the classic double
   ring-back; busy (0.5 / 0.5) on 486, 600 and 603; congestion (0.25 /
   0.25) on any other refusal, which includes the 480 this server returns
   when nothing can be woken. Nothing is played for a call that merely
   ended or for the 487 answering the user's own cancel. Two consequences
   worth keeping: a failure tone **holds back the end report** for its own
   length (busy 4 s, congestion 3 s) because CallKit takes the audio
   session away with the call, so a tone started after the end is cut off
   — hanging up on it, or a new call arriving, ends the call at once; and
   a tone goes into the same ear as any conversation, so answering another
   call stops whatever was playing. The SIP status that chooses the tone
   comes up from the shim (`cb_event_info.scode`, baresip's
   `call_scode()`), never from parsing reason text.
   **A tone is never what activates the audio session.** Ring-back is
   asked for when the 180 arrives, and that beats CallKit's `didActivate`
   (measured 154 ms, `make sim-call`); `AVAudioPlayer.play()` activates the
   shared session itself when it is not already active, which takes the
   session out of CallKit's hands — the same fault as the audio driver
   building its CoreAudio units ahead of activation in Phase 1, and it cost
   the app its audio on every call the day Phase J landed (2026-09-15). The
   rule is `TonePolicy` in DiallerCore, a pure value the app's `TonePlayer`
   obeys: a tone asked for before activation is *held*, released by
   `didActivate` and dropped by `didDeactivate`. It lives there, not in the
   player, because the app target has no tests and a rule kept there is a
   rule nobody checks — which is exactly how it shipped broken. Headless on the real
   engine: `OUTBOUND=212 make sim-call` asserts the ring-back starts on the
   180 and stops on the answer, and `make sim-call-refused` asserts a
   refused call plays its tone and is reported ended only after it (both in
   `sim-call-all`). That second test is why the tone's timer runs on a
   queue of its own: on the main queue the held-back end never fired at all
   where nothing services a main run loop.

### 4.5 Why SIP on the app leg
SIP is kept on the app leg because baresip supplies SDP negotiation, codecs,
SRTP, jitter buffer, hold, and transfer for free; because the headless
baresip ↔ server ↔ baresip harness (§7.2) depends on both ends speaking SIP;
and because the B2BUA stays symmetric — one SIP stack for both legs.

This is the **long-term design**. The two events that would once have
prompted a switch to WebRTC — video (libwebrtc arriving anyway) and remote
users' Wi-Fi → cellular handoff quality — are both unscheduled (§6 "Much
later"), so no replacement is planned. The app still sees the leg only through
the `CallEngine` protocol and the server terminates it in the B2BUA; that seam
stays as ordinary good structure, not as a migration path.

Consequence: baresip plus the vendored `audiounit` driver patches
(`ios/vendor/patches/`, full-file replacements that implement the CallKit
manual-audio contract) are permanent, maintained code. Those patches are
fragile against upstream baresip changes, so a baresip upgrade is a deliberate
task (re-apply, rebuild, re-run `make audio-probe-sim` and `make sim-call`),
never a routine bump.

### 4.6 Remote users (off-prem app users)
Deferred, unscheduled — see §6 "Much later", which keeps the design notes. The
per-device enrolment credential that section calls for already exists for the
wire-protocol gateway (`server/internal/enroll`).

## 5. Test-first component contracts

Everything sits behind a protocol so the app logic is testable without real SIP,
real LPC, or a real PBX. Built and verified in dependency order:

| # | Component | Interface (Swift) / artifact | How it's tested independently |
|---|---|---|---|
| 1 | **Wire protocol** | versioned message schema (length-prefixed JSON or protobuf) | round-trip / golden-file tests, no platform dep |
| 2 | **Wake gateway** (server) | connection + auth + fan-out | mock client + mock event source, unit + integration |
| 3 | **SIP B2BUA/registrar** (server) | SIP in/out | **dockerized Asterisk** + **SIPp** scenarios; profile conformance: SIPp asserts UDP and plain-TCP are refused and direct-media SDP is rewritten to the relay (§4.4) |
| 3a | **Media relay** (server) | RTP/SRTP relay between legs | headless baresip pair; assert no direct media path exists |
| 4 | **Directory API** (server) | REST + sync semantics | HTTP-level tests |
| 5 | **`PushTransport`** (Swift) | `connect / receiveWake / send` | in-process fake server implementing the frozen protocol |
| 6 | **`CallEngine`** (Swift) | `register / dial / answer / hold / transfer / events` | mock for unit tests; dockerized Asterisk for integration |
| 7 | **CallKit layer** | thin adapter over CallEngine/PushTransport | driven by the two mocks |
| 8 | **`AddressBookStore` + `DirectorySync`** | local store + reconcile | persistence + sync-conflict tests |
| 9 | **`AudioSession` / media** | Opus/G.722/G.711 capture/playback | integration / manual call tests |
| 10 | **Device enrolment / auth** (server + Swift) | issue / verify / revoke device credential | HTTP-level + keychain tests |
| 11 | **`RecentsStore`** (Swift, DiallerCore) | append / list / delete / fold the extension's pending records; outcome classification | persistence tests against a temp App Group directory, a classification table test, no CallKit |
| 12 | **Enrolment code** (server) + **`EnrolmentClient`** (Swift) | mint / claim / expire / rotate | `ServeHTTP` tests (expiry, single use, rate limit, rotation revokes the old token, other devices untouched); the Swift client against a stubbed `URLProtocol` |
| 13 | **`dialpark-admin`** | handlers over an in-process fake of the admin API; CSV ↔ contact list; QR encoder | handler tests, CSV round-trip incl. quoting and UTF-8, QR golden vectors (decoded on a phone once) |

Key abstractions to keep future-proofing cheap (see §7 for how each is tested
without a device):
- `SignalTransport` protocol with two impls: `LANSocketTransport` (foreground
  LAN socket + automated-test sibling) and `LPCTransport` (`NEAppPushProvider`,
  background survival). The app/server treat a delivered message identically
  regardless of impl; an `APNSTransport` sibling is the much-later addition the
  seam permits (§6).
- `CallEngine` protocol isolates `libbaresip` so the stack is swappable and
  mockable.
- `AudioIO` seam: the iOS CoreAudio/`AVAudioSession` backend has a non-Apple
  sibling (baresip `aufile`/portaudio) used for automated WAV-based media tests.
- `PBXAdapter` on the server isolates Asterisk-specific bits from the SIP core.

## 6. Build phases

Everything is built and validated on `LANSocketTransport` first (which is also
the real foreground transport), then LPC is verified in isolation and switched
on by config — see §7.4.

- **Phase 0** — Freeze wire protocol; Go server skeleton (signal gateway + SIP
  B2BUA/registrar + routing + media relay); docker harness (Asterisk + SIPp +
  headless baresip). All headless. **B2BUA engine spike: DECIDED — sipgo +
  diago** (both BSD-2 / MPL-2.0, commercializable; builds with `CGO_ENABLED=0`).
  diago provides dialog control, a media-forking bridge (the app-leg relay),
  and REFER; the registrar stays ours because diago handles INVITE but not
  REGISTER. **Proven headless** (`make spike-call`): baresip 201 → B2BUA →
  baresip 202 over TLS 1.3, Opus, media bridged through the server and
  asserted on the callee's recording. Two lessons baked in: diago must set
  `TLSURINoSIPS` (libre cannot route a `sips:` Contact), and the harness
  builds baresip 3.x from source (Debian's 1.x has no WAV player). CUCM
  third-party registration is deferred to the PBX phase. The hand-written
  `internal/sip` + `internal/relay` become the fallback/model, not the call
  path.
- **Phase 1** — **App↔app call end-to-end over `LANSocketTransport`** (no PBX):
  wake → CallKit → answer → audio. Validated in simulator + headless baresip.
  *Server half done 2026-09-05:* `internal/b2bua` (sipgo + diago) is the
  app-leg element; `make harness-call` proves a bridged 201→202 call with
  media through the server; unregistered callee → gateway wake →
  `registry.WaitRegistered` → bridge, or fast 480 when no connection can be
  woken. `make harness-wake` proves the wake path headless: callee with no
  UA → wake over the gateway → fake app registers it (~50 ms) → bridged →
  audio asserted. *iOS signalling + CallKit cut done 2026-09-05:*
  `ios/DiallerCore` (transport, session machine, call controller; 12 tests)
  and `ios/Dialler` (app + `NEAppPushProvider` extension) type-check against
  the iOS SDK. *2026-09-06:* rings on a real iPhone; Local Push
  configuration saves (a stale NE config had to be removed first);
  `ios/vendor/build-baresip.sh` cross-compiles libre/baresip 3.15 + Opus +
  OpenSSL to XCFrameworks and `ios/DiallerEngine` wraps them as the
  `CallEngine`, building for device and simulator. Remaining: the first real
  device call with audio, and the killed-app wake through the extension.
- **Phase 2** — Outbound + hold + transfer; PBX leg via Asterisk. *Call
  waiting done 2026-09-14* (rule 8): a second incoming call rings over the
  current one and can be taken with Hold & Accept, swapped and ended on its
  own.
  *2026-09-07:* Phase 1 closed on a real iPhone (first and subsequent calls,
  killed-app wake via the Local Push extension, lock screen); the root
  causes were the audio driver creating CoreAudio units before CallKit's
  activation (`!pri`), the B2BUA answering the caller before dialling the
  callee, and a registration-refresh race. Outbound calls done: keypad and
  directory share one dial path (`sip:<target>@<domain>`), CallKit start
  action, in-call screen with mute/speaker/end. PBX leg done: `-trunk`
  makes the server a SIP trunk peer (UDP/TCP/TLS), non-local destinations
  route to it, G.722 (or G.711) on both legs of a trunk call (no transcoding), both
  directions proven headless by `make harness-trunk`. Headless loop for the
  app path: `make sim-call` runs the real engine on the iOS simulator
  against the harness and asserts RTP + rendered audio energy. Hold/resume
  done (re-INVITE through the bridge; media stops and restarts, asserted
  headless). Blind transfer done: REFER is consumed by the server, the
  target routed like a fresh call (local, wake, trunk, echo), the remaining
  party re-bridged, the transferor released with a final NOTIFY; asserted
  headless. *2026-09-09:* a transfer whose remaining party and target are
  both on the PBX is handed to the PBX (REFER offload on the trunk leg,
  server-side fallback if refused), so the server drops out of the media
  path instead of hairpinning the PBX; `make harness-trunk` asserts it.
  Echo self-test destinations: `echo` (server) and `600` (PBX).
  Remaining in Phase 2: attended transfer; ring-back or hold music for the
  party waiting during a transfer (codec renegotiation on transfer to the
  trunk done 2026-09-12, near-term item 2).
- **Phase 3** — Address book store + server-driven directory sync. *Built:*
  delta sync with tombstones (`DirectoryClient` / `AddressBook`), server-side
  de-duplication by URI (a re-seeded directory collapses duplicates), and
  incoming-caller naming from the directory (directory name → caller's own
  display name → bare number; a synchronous in-memory lookup, no call delay).
- **Phase 4** — `LPCTransport`: device-verify against the transport conformance
  suite, then flip background wakes to LPC. *Proven on device 2026-09-07:*
  killed-app wake through the `NEAppPushProvider` extension and answer from
  the lock screen. *2026-09-10, session resilience:* iOS kills the app's
  sockets while it is suspended; the app used to stay "disconnected
  (ECONNABORTED)" and unable to dial until relaunched. `GatewaySession`
  (DiallerCore) now reconnects with backoff while the app is active,
  reconnects at once on return to the foreground, abandons an attempt stuck
  in Network.framework's "waiting", and the engine rebuilds its SIP
  registration on the new welcome (retrying failed registrations itself).
  The SIP stack also used to die after such a restart: libre binds its
  loop context to the thread that initialises it, and the shim initialised
  on the caller's thread, which after a reconnect is a GCD worker that
  libdispatch retires when idle. The shim now owns the whole stack on its
  loop thread (see `ios/vendor/patches/README.md`), with a watchdog and
  stack rebuild as the backstop. The server forgets a pending wake once its
  call has been answered and ended, so a reconnect is never rung for a
  finished call (it was, within the 30 s expiry). The client treats a
  gateway drop as no call event at all: a ringing wake may have come via
  the extension and its INVITE arrives through SIP, so ending wake-only
  calls on a drop broke the background wake (caught by
  `testSessionDropDoesNotEndAnExtensionDeliveredWake`).
  *2026-09-11, "ua_alloc -100" after every unlock:* libre caches SIP TLS
  connections and sends on a cached one synchronously; after a suspension
  that connection is dead and the write fails with EPROTO, and nothing
  evicts it. The engine now resets the SIP transports (baresip's
  network-change reset) whenever it has reason to doubt its flow: after a
  gateway drop, before a doubted re-REGISTER, and before each retry.
  Headless: `RESTART_SERVER=1 make sim-call` (in `sim-call-all`).
- **Remaining near-term (on-prem softphone completion)**, in rough priority:
  1. **App-leg authentication.** *Done 2026-09-10:* SIP Digest on REGISTER
     and initial INVITE (`internal/sipauth`), username = device id, password
     = enrolment token, realm = the SIP domain; the server keeps only H(A1)
     (`enroll.Store.DigestSecret`) and refuses a SIP user other than the
     device's enrolled one, so an enrolled phone cannot register or call as
     another. Trunk and in-dialog requests are not challenged. The
     directory/admin API moved to TLS on the same certificate (the device
     token no longer crosses the LAN in clear). Harness phones, SIPp, the
     wake test and the simulator loop carry the fixed dev credentials, and
     `make harness-test` includes a refused unenrolled registration.
  2. *Done 2026-09-12:* codec renegotiation when an Opus app call is
     transferred to the trunk — the remaining app leg is moved to the codec
     the trunk took (G.722) by re-INVITE (`renegotiateCodec` in
     `internal/b2bua/transfer.go`; the vendored diago `ReInvite` now applies
     the answer's SDP), 488 only if the remaining party refuses; proven by
     `DIRECTION=xfer-app make harness-trunk`. *Hold music for the party
     waiting through a transfer done 2026-09-15* (rule 8b): the same
     pre-encoded music a hold plays, on the leg that is waiting, for as
     long as the target is being resolved, woken and rung. A refused
     transfer falls back to ordinary hold music rather than silence,
     because whoever asked for it is usually still holding — most phones,
     baresip included, hold before they REFER. Still open: attended
     transfer.
  3. Real PBX interop beyond Asterisk (CUCM third-party SIP device
     provisioning, §9 risk 4). *Check on the live CUCM:* inbound calls
     to the app negotiate G.722 (on the Grandstream + Asterisk bench,
     2026-09-14, inbound calls land on PCMU because the PBX's INVITE
     lists PCMU first — the phone's own offer order — while outbound
     calls get G.722; the server follows the caller's order by design).

     **Two CUCM trunk settings to get right before blaming the code**
     (2026-09-17, from reading our own SDP handling — neither is yet
     tested against a live CUCM):
     - **Tick "Early Offer support for voice and video calls (insert MTP
       if needed)" on the SIP trunk.** Without it CUCM sends a
       *delayed-offer* INVITE — no SDP at all — and expects our 200 OK to
       carry the offer. We cannot do that: diago refuses with "no sdp
       present in INVITE" (`dialog_server_session.go`), and the whole
       bridge narrows the callee's offer from the caller's SDP
       (`Originator`), so with no caller SDP there is nothing to narrow.
       It is unchecked by default on many CUCM versions, so the first
       symptom is every inbound call from CUCM failing at once. The cost
       of ticking it is CUCM inserting an MTP when it cannot build an
       early offer natively, which consumes media resources. Supporting
       delayed offer properly is ours to do and is listed under "Much
       later"; the checkbox is the deployment work-around.
       *Superseded 2026-10-17:* the server now answers a delayed offer
       (the "Much later" entry, done — item 3c's CUCM bench forced it,
       since a third-party SIP line has no such tick box). The tick box is
       no longer required on the trunk either, and only costs an MTP.
     - **Check the region codec preference for the trunk.** We offer
       G.722, PCMU and PCMA and have **no G.729**. CUCM deployments
       commonly set inter-region bandwidth to G.729, and a region pairing
       that permits only G.729 cannot negotiate with us at all.
       `-trunk-codecs` can narrow what we offer but cannot add a codec we
       do not have.
     - **A secure trunk needs CUCM's SIP Trunk Security Profile, not just
       our flags** (item 3b). Set its device security mode to Encrypted,
       transport TLS, incoming port 5061, and **X.509 Subject Name to the
       CN in the certificate we present** — CUCM matches the name on the
       certificate against that field, not against the source address, and
       a mismatch is refused at the handshake with nothing useful in our
       log. Upload our CA to CUCM as a CallManager-trust certificate and
       give `-trunk-tls-ca` CUCM's, since neither side's chain is public.
       CUCM's secure trunks are generally **TLS 1.2**, which is why
       `-trunk-tls-min-version` defaults there rather than to the app leg's
       1.3. Encrypted mode also implies SRTP on the media, so this pairs
       with `-trunk-srtp=sdes` (item 3a) rather than replacing it.
     *Already confirmed to work:* CUCM polls a trunk with SIP `OPTIONS`
     and marks it down if unanswered — diago replies 200 with `Allow` and
     `Accept`, so the trunk comes up. Worth checking first when CUCM
     simply never sends us a call.
  3a. **Trunk-leg SRTP.** *Done 2026-09-16.* `-trunk-srtp off|sdes`
     (default `off`): the trunk transport takes diago's `MediaSRTP` like the
     app leg, so offers carry RTP/SAVP + `a=crypto` (RFC 4568) and inbound
     offers are mirrored. `sdes` also refuses a leg that did not end up
     encrypted — checked **after** the leg is answered, because a session is
     only secure once both crypto contexts exist and ours is created by our
     own answer; asking at INVITE time calls every inbound call insecure.
     **Use it with a TLS trunk.** SDES carries the media keys in the SDP, so
     over unencrypted signalling anyone who can read the INVITE can read the
     keys and the media is not really protected (RFC 4568 §7.1); the server
     warns at startup if the trunk is not TLS.
     There is deliberately **no best-effort mode**. The offer is SAVP only
     (one m-line, one profile) and RFC 3264 §6 makes an answer keep the
     offer's profile, so "answered in the clear" is malformed rather than a
     downgrade — a PBX that cannot do SDES sends 488 instead. An earlier
     three-mode design (`off|offer|require`) was collapsed for this reason:
     its two secure modes differed only for a malformed peer, and the
     permissive one would have encrypted to a far end unable to decrypt.
     The non-standard work-arounds are under "Much later". And Alpine's
     `asterisk` package **does not include `res_srtp.so`** — it is the
     separate `asterisk-srtp` package, and without it an endpoint with
     `media_encryption=sdes` refuses every call with 488, which looks
     exactly like a malformed offer from us. Asserted by
     `make harness-trunk-srtp` (both directions, with the PBX built
     `media_encryption=sdes`); the default plain-RTP path stays covered by
     `make harness-trunk`.
  3b. **Trunk-leg TLS.** *Done 2026-09-17.* `-trunk=...;transport=tls` plus
     `-trunk-tls-cert` / `-trunk-tls-key` (presented in **both**
     directions — we are the TLS server for calls the PBX places and the
     TLS client for the ones we place, and CUCM's secure trunks demand a
     client certificate), `-trunk-tls-ca` (what we verify the PBX against;
     empty means the system roots, wrong for the private CA most
     deployments run), `-trunk-tls-insecure` (dev only, warned about) and
     `-trunk-tls-min-version` (**1.2** by default). The app leg keeps its
     TLS 1.3 floor — we own both ends of it — while the trunk cannot: CUCM
     secure trunks are generally TLS 1.2, so pinning 1.3 there would refuse
     the exchange this exists for. Our Contact is
     `sip:…;transport=tls`, not `sips:`: both Asterisk and CUCM emit the
     former, and RFC 5630 §3.3 reads `sips:` as a promise about the whole
     remaining path, which past a B2BUA no leg can make about the other.
     A TLS trunk defaults to binding **:5062**, not the conventional 5061 —
     that is the app leg's, and two SIP listeners on one address cannot
     share a port, so the server refuses a collision rather than failing
     inside the SIP stack with a bare "address in use". A plain UDP/TCP
     trunk still defaults to 5060. The cost is one field on the PBX (the
     AOR contact on Asterisk, *Destination Port* on a CUCM trunk) and
     nothing outbound, where we dial the PBX's own port; our Contact always
     carries an explicit port, so no in-dialog request can fall back to a
     scheme default. `-trunk-addr` moves it for a deployment that wants the
     trunk on 5061, which then needs the app leg moved (`-sip-addr` plus
     `-public-sip-port`) or the two legs on separate addresses.
     Two listeners on one protocol turned out to be new ground for the
     stack, and both `vendor/PATCHES.md` entries come from it: diago matched
     an inbound INVITE to the *first* transport with the right protocol, so
     with a TLS trunk configured every app call was answered with the
     trunk's media settings and failed; and its REFER handling fell back to
     UDP for a `Refer-To` without a transport, which on a UDP-less stack
     made blind transfer silently do nothing. Legs are now dialled out of a
     named transport (`app`/`trunk`) rather than by protocol.
     Asserted by `make harness-trunk-tls` (all four trunk scenarios over a
     mutually authenticated trunk — the PBX is configured
     `require_client_cert=yes`, so it will not even qualify us without a
     valid certificate) and `make harness-trunk-secure` (with SDES on top,
     which also asserts the item-3a warning is *absent*). Certificates come
     from `harness/tls/gen_certs.sh`, generated and gitignored;
     `TRUNK_TLS=1 harness/asterisk-native/install-ubuntu.sh` sets the same
     thing up on the LAN box.
  3c. **Registering to the PBX as third-party SIP lines (planned
     2026-09-22; before item 9).** A trunk carries calls, but it cannot
     make an app user a *thing the exchange knows about*: on a trunk our
     extensions are route patterns pointing at an IP peer, so there is no
     per-user CSS or partition, no call-forward configuration, no
     voicemail or MWI, no hunt-group or shared-line membership, no CDR
     attributed to a user, and no corporate-directory entry. Identity is
     by source address, which is also why most CUCM teams will not route
     an internal DN range to an unauthenticated peer. So a deployment may
     instead present each device to the PBX as a **third-party SIP
     device**: a line (DN) that REGISTERs and answers a digest challenge —
     CUCM's "Third-party SIP Device (Basic/Advanced)", an End User with
     Digest Credentials named as the device's Digest User. Each such
     device consumes a CUCM licence; that cost is known and accepted.
     **The server registers, never the app.** This is §4.4 rule 1 and it
     is load-bearing: a phone holding the PBX credential would be the
     registered endpoint, so the PBX would send its INVITE to a contact
     that does not exist the moment iOS suspends the app — exactly the
     problem this product exists to solve — and it would put a PBX
     credential inside a public App Store binary. From the exchange's
     point of view this server is therefore a set of third-party SIP
     devices, one registration per device, **held around the clock**
     whether the phone is awake, asleep or in a drawer. The INVITE always
     lands somewhere alive and the wake path is unchanged. **The app leg
     does not change at all**: same enrolment digest, same welcome, same
     `sip{user,domain,…}`, no new wire field, no protocol bump, no app
     release. Nothing about the PBX credential is ever pushed to a device.
     *Mode is exclusive and chosen at start-up*, `-pbx-mode=trunk|lines`
     (default `trunk`). `-trunk` still names the peer — host, port,
     transport — and `-pbx-mode` says how we present ourselves to it:
     empty `-trunk` with `trunk` is standalone; `-trunk` with `trunk` is
     today's IP-trusted peer, unchanged; `-trunk` with `lines` registers;
     and empty `-trunk` with `lines` is a start-up error. Never both at
     once, which is not tidiness: CUCM matches inbound SIP against trunk
     devices by source IP **and incoming port**, so a cluster with a trunk
     pointing at us would treat our line INVITEs as trunk traffic and
     bypass the registration entirely. One mode per deployment removes
     that class of fault instead of working around it. In `trunk` mode the
     line manager is never constructed and every call path that consults
     it is `nil`-guarded, so the existing trunk is untouched by
     construction rather than by care.
     *Server.* A new `internal/pbxline` holds one `Line{user, dn,
     digest_user, secret}` per configured device, each with its own
     registration state machine: register → refresh at 0.75 × the granted
     expiry → jittered backoff on a transient failure → **latch "refused"
     after a 401/403 retry**, so a wrong password logs once instead of
     hammering the exchange, and start-up is jittered so fifty lines do
     not stampede one node. The refresh deadline is a time of day, watched
     by one 10 s sweep for all lines, because the timer it sleeps on counts
     only time the machine is awake while the exchange's lease counts the
     clock: an 18-minute clamshell sleep on the dev Mac left line 201 with
     no contact on the PBX for three minutes and two calls refused there
     with nothing in our log (2026-10-02 15:21). After a wake the overdue
     lines re-register within one tick, a lease found already lapsed is
     logged as such, and the catch-up is scattered as a start is. The SIP
     send is an injected seam, as
     `trunkQualifier`'s probe is, so the whole machine unit-tests with no
     SIP stack. The REGISTER client is ours (sipgo's client plus the
     vendored `icholy/digest`) rather than diago's `RegisterTransaction`,
     which cannot set a per-line From/To/Contact user, mutates its
     `Origin` on unregister, and gives up on 401 — about 150 lines against
     a vendor patch, with `internal/sip/registrar.go` as the precedent.
     Lines can be added, changed and removed at runtime: §4.8's rule
     holds, an admin edit never restarts anything.
     *Data.* The device record gains `pbx_line{dn, digest_user,
     secret_enc}`, `dn` defaulting to the device's user — one user, one
     device, one line (§4.8) — with an override for a deployment whose
     CUCM DN differs from the extension the app dials as. The secret is
     AES-256-GCM at rest under `<data-dir>/pbx.key` (0600, minted on first
     use, std lib). That protects a copied `devices.json` — a backup, an
     export, a support bundle — and not someone who can read the whole
     data directory; it is worth saying which of the two it is. Storing
     only HA1 (`MD5(user:realm:pass)`) would be stronger still, and is
     deliberately deferred: it pins us to MD5 and needs the realm known
     before the first challenge. `GET`/`PUT`/`DELETE
     /v1/admin/devices/{id}/pbx-line` (§4.8), 404 for an unknown device or
     until set, and the secret is **never returned** — `GET` answers
     `{dn, digest_user, configured}`. This is the route item 9's Device
     page needs, and the reason 3c is ordered before it: shipping the
     admin UI first means reopening it immediately.
     *Calls.* Inbound is unchanged — the INVITE arrives on the same
     listener at our registered Contact with the DN in `To`, `routing`
     resolves it to the local user, and a sleeping phone is woken exactly
     as today. Outbound in lines mode sends `From: sip:<caller's
     DN>@<pbx-domain>` and answers a 401/407 on the INVITE with that
     line's credentials (sipgo's `AnswerOptions` already does this; no
     vendor patch). A caller with no line — a transfer target, an echo leg
     — uses `-pbx-default-line`, or the call is refused if none is set.
     App↔app calls **stay local**: both parties resolve to `Local` and
     this server bridges them, so the PBX sees no call and applies no
     forwarding, recording or CDR to it. That is the "own exchange"
     decision of §3 and it keeps app↔app working through a PBX outage;
     hairpinning them through the exchange is a future option, not a
     default. One consequence to state rather than discover: a line is
     registered around the clock, so the exchange never sees it
     unregistered and a "forward on unregistered" rule will never fire.
     Forward-on-no-answer is unaffected — CUCM's timer fires well inside
     our 30 s ring.
     *Caller ID on the trunk is left exactly as it is*, and it is worth
     saying precisely what that is, because it is not uniform. A bridged
     call to the PBX already carries the **app caller's own From** —
     diago copies the originator's header — so an ordinary trunk call
     goes out as `sip:<extension>@<our SIP domain>`, with our domain as
     the host rather than the PBX's. A **transfer** dialled towards the
     trunk has no originator and falls back to the user agent's own name,
     `sip:dialpark@<external host>`. Lines mode replaces both with the
     line's DN at the PBX domain, because the exchange will not accept
     anything else. Trunk mode keeps both, because they work and four
     harness gates cover them; making the trunk's identity configurable
     (`-trunk-caller-id=peer|caller`) is its own change, its own branch
     and its own bench run, and is unscheduled.
     *Validation — Asterisk is the bench; there is no CUCM.* Asterisk
     proves the substance: registering N lines with digest, refresh,
     re-registration after the PBX restarts, a PBX-originated call to a
     registered line reaching the right device through the wake, an
     outbound call **challenged on the INVITE** (an endpoint with `auth=`
     challenges us, the same exchange CUCM makes) arriving as the right
     identity, a wrong password latching refused, and one line failing
     without disturbing another's call. `make harness-pbx-lines`.
     What it cannot prove, and what therefore stays open until a CUCM
     exists: that CUCM matches a registration to a third-party device by
     digest user and DN; ~~its realm and challenge shape~~ (*answered
     2026-10-17:* realm `ccmsipline`, MD5, no qop — and one nonce handed
     to every line that registers in the same instant, so the second to
     answer it is re-challenged with a new nonce and no `stale=true`;
     the REGISTER client answers a new nonce and calls only a repeated
     one a refusal, `sipreg_challenge_test.go`); ~~line-side early
     offer~~ (*answered 2026-10-17:* CUCM sends a line a **delayed** offer,
     no SDP at all, which the server now answers — the "Much later"
     delayed-offer entry, done — and it also sends each line an
     unsolicited message-summary NOTIFY on every REGISTER, now answered
     200 instead of 400); whether it ticks *MTP Required* and what that
     does to DTMF (we offer `telephone-event/8000` at PT 101 on both legs
     and the relay copies payload verbatim, so a PT mismatch across the
     bridge is the thing to watch); whether it accepts REFER from a
     third-party device (if not, the server completes the transfer itself
     — the fallback already exists); and cluster nodes as INVITE sources.
     Two things keep that from being merely a list of unknowns. **Nothing
     CUCM-specific is hard-coded** — the realm comes from the challenge,
     the From/To/Contact forms are configuration, the trusted peers are a
     list (`-pbx-peers`, which also widens the TLS source check that today
     compares against a single trunk host) — so adapting should be
     configuration, not a rewrite. And the parts Asterisk will not
     exercise get **table-driven tests against synthetic CUCM-shaped
     challenges**: `qop=auth` with and without cnonce, MD5, 401 against
     407, `Expires` as a header against a Contact parameter, a realm that
     is not the peer host. The bench checklist for the day a CUCM appears
     is §7.3 item 10, written now rather than reconstructed later.
     *The trunk must not move.* `make harness-regression` is the merge
     gate and must be green at every commit on the branch:
     `harness-test`, `harness-call`, `harness-wake`, `harness-qos`,
     `harness-trunk` (plus `NARROWBAND=1` and `DIRECTION=xfer-app`),
     `harness-trunk-srtp`, `-tls`, `-secure`, `-stall`,
     `harness-pbx-hold`, `harness-pbx-unavailable`, `harness-hold-music`
     and `harness-cancel-before-answer`. Under it, a golden test on the
     outbound trunk INVITE (start line, From, To, Contact, transport) so
     an accidental identity change fails a unit test long before the
     harness, and a test that `-pbx-mode=trunk` constructs no line manager
     and emits no REGISTER.
  4. Before release: third-party acknowledgements screen and the App Store
     export-compliance declaration (see `ios/README.md`).
  4a. **Volume and tone balancing.** Every level in the app was chosen by
     arithmetic, not by ear: the tone amplitude in `CallTones.wav` (0.2),
     the hold music's normalisation in `tools/gen_moh.py` (0.7 peak), and
     how all of them sit against speech on a live call. They need judging
     on a device, because nothing headless can: the call-waiting beep into
     the ear of someone mid-conversation, ring-back and congestion before
     the audio session settles, and hold music at the far end, each on the
     earpiece, on speaker and over Bluetooth, where the routes have very
     different gain. Expect the tone table and the music's level to change;
     both are data (a constant and a generator flag), so this is tuning,
     not rework.
  4b. **UI beautification.** The in-call screen, keypad, directory and
     settings are laid out for function and have never had a design pass.
     Known rough edges: the in-call screen's status line and the held-call
     label sit awkwardly at small widths, the keypad is plain, and the
     settings screen is a debug surface with the diagnostics controls in
     it. None of it is call-path work, so it can land whenever — but it
     wants doing before anyone outside the team sees the app. *Scope
     widened 2026-09-21:* the pass also covers the Recents tab (item 6),
     the directory's edit forms, favourites and search (item 7), the
     onboarding screens and the hidden Status page (item 8); the tab bar
     it designs for is **Recents / Directory / Keypad / Settings**, with
     Status gone from it.
     *Built 2026-09-27, merged 2026-09-28 (branch
     `feature/ui-beautification`):* the design canvas's "Hairline" look (near-white ground,
     near-black ink, hairline rules, outlined circles; a dark counterpart
     for every colour) in SF Pro with Dynamic Type, across onboarding,
     Recents, Keypad, Directory and its editor, Settings and the in-call
     screen. Decided in the building: the tab order is the canvas's,
     **Recents / Keypad / Directory / Settings**; the canvas's Status tab
     is not built — its connection summary (line, Connected / Not
     Connected, background calls) heads Settings, and the hidden Status
     page stays behind the five-second press. Nothing the app does not
     have is drawn (the canvas's presence, teams, Do Not Disturb,
     forwarding, voicemail and ringtone). Wording follows Apple's: Title
     Case for buttons, rows and titles, sentence case with contractions
     for explanations, "Sign Out" for Log out; the app names itself from
     `CFBundleDisplayName` (Dialler), permission prompts included.
     Revised with Matt on 2026-09-28: the landing page is the admin
     console's mark (no tile) with rings that expand and fade, the name
     and the two buttons, nothing else; the in-call screen's rings move
     the same way (both still under Reduce Motion); switches are the
     system's, green when on; confirmation dialogs hang from the button
     that raised them (iOS 26 points the popover at its anchor); a
     completed call placed from the keypad clears the number, any other
     outcome keeps it; the hidden Status page takes the same look and
     wording.
  5. Mouth-to-ear latency measurement on the echo path and jitter-buffer
     tuning (parked 2026-09-07). *2026-09-10:* the "received audio 0–2 s
     late, varying per call" symptom was the media relay, not the app: the
     library's RTP writer paces one packet per 20 ms, so a relay built on
     it could never drain a backlog and every burst (call-start ordering, a
     Wi-Fi stall) became permanent delay. The relay now forwards each
     packet at once carrying the source's own timestamps (`pump.forward`),
     and its 2 s log line reports arrival skew (`early_max_ms` /
     `late_max_ms`) so the delay is visible numerically. Unit tests drive a
     50-packet burst through the real reader/writer in <1 ms (was 1.0 s).
     *2026-09-12 (audio-quality plan, phases B and A done):* measured
     first. The harness now reports mouth-to-ear delay and gaps
     (`assert_audio.py --reference`, §7.2) and can impair the server's
     egress (2 % loss, 30 ± 10 ms jitter). Baseline in docker: 120 ms on
     both echo paths, no gaps; impaired: 160 ms and one audible gap per
     lost packet. Three defects behind that, all fixed: baresip 3.15 never
     called the codec's concealment on receive (vendored patch in
     `ios/vendor/patches/apply-baresip.sh`, applied in the harness phone
     too); the server's SDP told every phone `useinbandfec=0` (vendored
     diago patch, `sdp.OpusFmtp`: FEC on, mono, 32 kbit/s); and baresip's
     Opus module only produces or decodes FEC with `opus_packet_loss` set.
     App profile (`BaresipCallEngine.stackConfig`, pinned by
     `StackConfigTests`, mirrored in `harness/baresip/config`): adaptive
     jitter buffer 40–160 ms, play buffer 40–160 ms adaptive, Opus voip /
     FEC / 32 kbit/s mono / complexity 6, RTP stats on, dead-media timeout
     30 s, EF marking. Result on the impaired server echo: 120–130 ms,
     single losses recovered from FEC, at most one 20–40 ms gap per call
     from a double loss (the jitter buffer withholds the next packet after
     a loss until it refills; concealing at the missed slot rather than on
     the next arrival would close it — plan Phase D). Two gotchas worth
     keeping: mono Opus is listed as `opus/48000/1` in the account
     (baresip names it by audio channels; `/2` silently falls back to
     PCMU), and Opus stereo at this bitrate is CELT mode, which has no FEC.
     *2026-09-12 (Phase C done):* G.722 wideband end to end on PBX calls,
     never transcoded. The trunk is offered `g722,pcmu,pcma` (server flag
     `-trunk-codecs`; `pcmu,pcma` for a narrowband-only PBX) and the app
     leg Opus, G.722, G.711, so a call that touches the trunk lands on
     G.722 on both legs and app↔app stays Opus. The app's `g722` module is
     built from WebRTC's public-domain G.722 (baresip's own needs spandsp,
     LGPL — `ios/vendor/patches/g722`, provenance in §8); the vendored
     server SDP knows static PT 9; Asterisk allows g722 first. Asserted by
     `make harness-trunk` (`codec=G722` on both legs, both directions, gap-
     free recordings) and the app↔app→trunk transfer above. Fallback is
     proven too: `NARROWBAND=1 make harness-trunk` builds the harness PBX
     with ulaw/alaw only and every scenario must land on PCMU. That test
     exists because the first device run failed: the vendored diago
     narrowed a bridged callee's offer to the caller's *first* common codec
     (fine while that was always PCMU), so a G.711-only PBX was offered
     G.722 alone and the INVITE failed — the offer now carries every common
     codec, in the caller's order (`server/vendor/PATCHES.md`).
     *2026-09-12 (Phase D done):* honest loss and concealment. The relay
     now rebases the source's RTP sequence numbers onto its own instead of
     renumbering every packet (vendored `WriteSamplesSeq`), so a packet
     lost upstream stays missing on the way out and the far end's jitter
     buffer and concealment see it; before, a loss became a silent hole in
     a seamlessly numbered stream that no decoder could conceal. G.711 and
     G.722 got packet-loss concealment in the app — baresip only had it
     for Opus — as our own unit (`ios/vendor/patches/plc`: pitch-period
     repetition with overlap-add and a fade, after ITU-T G.711 Appendix I,
     no third-party code; `make plc-test`), compiled into both modules and
     into the harness phone. Measured on the impaired PBX loop (2 % loss,
     30 ± 10 ms jitter, 12–18 drops): 7 gaps of 40 ms before; after, one
     or two dips of 20–40 ms per call (three runs: 1×20, 1×20, 2×40 ms);
     the gate is now ≤ 2 gaps ≤ 40 ms on both loops. The residual is
     baresip's jitter buffer refilling after a loss (`jbuf_get` withholds
     while `nf <= wish`; concealment runs only when the next packet is
     pulled, so the player underruns for a frame first). Counting the
     missing packets as frames so the next one is released on time was
     tried and reverted the same day: it drained the buffer and made
     things worse (4–13 gaps). Closing the last 20–40 ms needs concealment
     driven from the playout timeline (decode on a timer when a slot's
     packet has not arrived), a receive-path redesign — left open.
     Escalation if concealment on G.722/G.711 cannot meet the loss target
     on the real WLAN: an app-leg Opus transcoder in the server, kept out
     on purpose (latency, tandem coding, breaks the copy-relay and the
     std-lib-only server).

  *Items 6–9 added 2026-09-21.* They are ordered by call-path risk, lowest
  first, and that is also the build order: the app-only work lands before
  anything touches the server, and the one real server change (per-device
  directories, item 7) lands before the process that depends on it (item
  9). *Amended 2026-09-22:* **item 3c lands before item 9** for the same
  reason — it gives a device a PBX line, and the admin UI's Device page
  would otherwise ship without anywhere to set one. Decisions behind them are in §3 (directory ownership, management
  plane, device onboarding) and the mechanism in §4.8. The governing rule
  throughout: **the existing call server stays stable** — everything that
  can live outside `dialpark-server` does, and what must go in is additive.

  6. **Recents (app only; no server change).** A list of the device's
     calls: answered ones with their duration, missed ones, and dialled
     ones with either a duration or why they failed. DiallerCore gains
     `CallRecord { callID, direction, counterpart{displayName, uri},
     startedAt, connectedAt?, endedAt, outcome }` with `outcome` one of
     `completed | missed | declined | busy | noAnswer | unknownNumber |
     unavailable | failed | answeredElsewhere` and the duration derived.
     Classification is a table, unit-tested: incoming, never connected,
     ended by the caller or the ring timeout → `missed`; incoming and
     refused by the user → `declined`; incoming and cancelled
     `answered_elsewhere` → `answeredElsewhere` (kept, but not in the
     Missed filter); outgoing and connected → `completed`; outgoing and
     never connected → whatever `CallProgress.forFailure` made of the SIP
     status (busy, no answer, unknown number, unavailable, failed). The
     record is written at `AppModel.callEnded`, which already has the
     tracked call's title, direction and `connectedAt`, fed by the status
     `CallController.handle(sipEnded:)` alone sees.
     *Storage:* `RecentsStore` in the App Group container (the `FileLog`
     directory is the precedent): `recents.json`, newest first, capped at
     500, written atomically. The extension never writes that file; for a
     wake it reported (and any `wake_cancel` it saw) it drops a sidecar
     `recents/pending/<call_id>.json`, and the app folds those in at
     launch, on foreground and at each call end, upserting by call id
     with its own record winning — so a call the app never ran for still
     shows as missed, and two processes never write one file.
     *UI:* a **Recents** tab takes Status's place, and the tab order
     becomes Recents / Directory / Keypad / Settings with Recents the
     launch tab. Filter All / Missed; each row shows the name (a directory
     lookup at render time, the stored name as fallback), the URI, a
     direction glyph, a relative time, and the duration or the outcome
     label; a tap redials; swipe to delete; Clear all. Missed calls badge
     the tab until it is viewed. iOS's own Recents keep working
     (`includesCallsInRecents` stays on). *Headless:* `make sim-call`,
     `sim-call-refused` and `sim-call-cw` each assert the record they
     should leave. *Device:* §7.3 item 8.
     *Built 2026-09-21 (branch `feature/recents`, awaiting approval):* as
     above, with three things decided in the building. A `cancelled`
     outcome was added for an outgoing call the user hangs up before the
     answer (and for the 487 that answers our own CANCEL), which the table
     had no word for. A wake the app refuses (call waiting off, no room)
     or finds expired is recorded as missed: the caller heard busy and the
     user saw nothing. And the Status tab stays, last in the bar, until
     item 8 gives its contents a home — so the bar is Recents / Directory
     / Keypad / Settings / Status for now. The record is emitted from
     `CallController` at every exit from its table (eight of them; each
     unit-tested in `CallRecordEmissionTests`), the extension's sidecars
     and the fold are `RecentsStore` (`RecentsTests`), and
     `harness/sim_call.sh` now fails unless every call leaves exactly one
     record of the outcome its mode expects.

  7. **Per-device directories, favourites, search, and in-app editing
     (server: additive, plus one migration).** Today one global list with
     one version counter is pushed to every device. From here each device
     owns a directory: `<data-dir>/directories/<device_id>.json`, each
     with its own version counter and tombstones, `directory.Store` keyed
     by device. *Migration,* run once at start-up when the legacy
     `directory.json` exists: copy its live contacts into every enrolled,
     non-revoked device's directory, then rename the file
     `directory.json.migrated`; tested against a fixture of the current
     file shape. A downgrade loses per-device edits and nothing else.
     *Push:* `gateway.NotifyDirectory(deviceID, version)` reaches only
     that device's sessions, and `welcome.directory_version` is that
     device's version — the "unique directory load per app instance".
     The wire bodies are unchanged; PROTOCOL.md carries a one-sentence
     semantic note, no version bump.
     *Device-facing API:* `GET /v1/directory?since=` is unchanged (already
     scoped by `X-Device-ID`); `POST /v1/directory`, `PUT` and `DELETE
     /v1/directory/{id}` become **device-authenticated** writes to the
     caller's own directory, with the same de-duplication by URI. The
     admin-token verbs move to `/v1/admin/devices/{id}/directory…`
     (§4.8) and `harness/provision.sh` follows. Edits are online-only —
     no offline queue; a write returns the new version and the app
     applies it as a delta, so `AddressBook.apply` needs no change.
     *Favourites:* `Contact` gains `favourite` (JSON `favourite`, omitted
     when false), versioned and synced like every other field, so a
     toggle is an ordinary `PUT` and reaches the admin UI and the CSV
     alike. The app pins a **Favourites** section above the full list,
     puts a star on each row and in the edit form, and offers
     swipe-to-favourite; the star is optimistic and reverts if the write
     fails. *Search:* a search field over the directory (`.searchable`)
     matching any substring of the display name or of the URI's user part
     (the extension), case- and diacritic-insensitive, applied locally to
     the in-memory book so it is instant and works offline, across both
     sections. *App:* `AddressBook` is persisted in the App Group
     container so the cursor survives a launch (and the extension can
     name callers from it); `DirectoryClient` gains create / update /
     delete; the Directory tab gains add (name, number, mode defaulting
     by the routing rule of §4 "Standalone mode", favourite), edit and
     swipe-to-delete.
     *Built 2026-09-21 (branch `feature/per-device-directory`, awaiting
     approval):* as above, in two commits, server then app. Decided in
     the building: the migration keeps a star a device had already given
     a number (the global list never had one, so preferring the device's
     loses nothing); an identical replace-all is a no-op — no version
     bump, no notification — so re-uploading an unchanged CSV disturbs
     nobody; the admin's routes are 404 for an unknown device, so a typo
     cannot create a directory nobody reads. `harness/provision.sh`
     seeds each dev device by POST (the in-network helper is busybox,
     which has no PUT). Server tests cover the migration against a
     fixture of the old file, per-device isolation of files, versions
     and notifications, and replace-all as one delta; DiallerCore tests
     cover the persisted book, the search and the client's writes.
     *Same day, on the device:* saves, adds and deletes all reached the
     server and none showed in the app. The app's cursor was the old
     global directory's 702; the migrated per-device directory counts
     from 1 (it was at 24), so "everything newer than 702" was always
     empty. Persisting the book made a latent rule visible: a server
     version behind the cursor means the server was reset, and the
     client must clear the book and sync from zero
     (`DirectoryClient.sync`, `testSyncResetsWhenTheServerIsBehindTheCursor`).

  8. **First-run enrolment, and Status hidden behind a gesture (app, plus
     the enrolment-code routes of §4.8).** *Gate:* while
     `AppConfig.isComplete` is false the app shows a full-screen
     onboarding view instead of the tabs, with two ways in: **Scan QR**
     (VisionKit `DataScannerViewController`; `NSCameraUsageDescription`
     added to the app's Info.plist) and **Enter manually** (server
     address and code; port defaults to 8080). Both end in
     `EnrolmentClient.claim(host:port:code:)` (DiallerCore, testable), then
     `AppConfig` is saved (token in the keychain, as now) and the app
     connects. `onOpenURL` takes a `dialler://enrol…` link from the iOS
     Camera app down the same path. Settings gains **Log out**, which
     wipes the credential, removes the Local Push configuration and
     returns to onboarding.
     *Status (decided 2026-09-21, replacing an earlier keypad gesture):*
     the tab is removed. The Status page is reached by a **five-second
     press on the Settings title** at the top of the Settings tab, which
     pushes it onto that tab's navigation; **Back** pops it, and so does
     **any tap on the tab bar**, the Settings tab's own button included —
     nothing a user does by accident opens it, and nothing they do
     normally leaves it open. It holds what the tab held: gateway,
     session and engine state, connect / disconnect, the in-memory log
     and send diagnostics. Once enrolment lands, the dev-only fields —
     host, port, device id and token entered directly, and
     accept-any-certificate — leave Settings for this page too, and
     Settings keeps only what a user should see: server address and
     device id (read-only), call waiting, Local Push SSIDs, log out,
     and the version and acknowledgements screen of item 4. Until then
     Settings keeps its fields, since they are the only way in.
     *Dev path:* `make dev-server` and `harness/provision.sh` print an
     enrolment code per fixed device so the simulator onboards through
     the real flow (it has no camera, so manual entry); direct entry on
     the Status page remains the fallback.
     *Built 2026-09-21 (branch `feature/enrolment`, the Status half):*
     the tab is gone, the bar is Recents / Directory / Keypad /
     Settings, and Status is pushed by the five-second press on the
     Settings title. The title is drawn as a toolbar item because a
     large navigation title takes no gesture, so Settings shows an
     inline title. The tab-bar rule is the selection binding's setter,
     which SwiftUI runs on every tab-bar tap including the current
     tab's, and which empties the Settings navigation path.
     *Built 2026-09-21 (same branch, the enrolment half; awaiting
     approval):* server and app as specified in §4.8, in two commits.
     Decided in the building: adding a device always mints its code and
     link, and a fixture `token` in the same request also issues that
     credential, so the harness is unchanged and gets codes for free; a
     device created without a token holds no credential at all until its
     claim (an empty token hash never authenticates); a claim un-revokes;
     a claim or a revoke drops that device's gateway sessions with
     `unauthorized` (`gateway.Disconnect`) and no other's. Typed codes
     are normalised on both ends (case, dashes, I/L → 1, O → 0). On the
     app the pin lives on `GatewayEndpoint.certSHA256` and, when set,
     overrides the dev toggle on the signal socket and every HTTPS
     session (`CertificatePin`, `EndpointTrust`); the manual path trusts
     the first connection and refuses to continue if the certificate it
     saw is not the one the reply names. Log out clears the credential,
     the directory book and the Local Push configuration. **Not done,
     and worth knowing:** the SIP
     leg still accepts any certificate (`BaresipCallEngine` passes
     `acceptAnyCertificate: true` to the stack); pinning there means
     handing baresip the fingerprint or a CA file (`sip_cafile` /
     `sip_verify_server`), a separate change. The dev fields moved from
     Settings to the Status page, which onboarding also reaches by a
     five-second press on its icon. The simulator has no camera:
     `DataScannerViewController.isAvailable` is false there, so the QR
     button is disabled and manual entry is the way in.
     *Found on the harness the same day:* the dev server generated a new
     self-signed certificate at every start, so a QR minted before a
     restart named a certificate that no longer existed, and every
     enrolled phone would have been stranded by each `make dev-server`.
     The certificate is now kept under `<data-dir>/tls` and reused
     (`tlsutil.LoadOrKeep`; `TestLoadOrKeepReusesTheSelfSignedCertificate`),
     proven by minting a code, restarting the container and minting
     again: one fingerprint. A production `-tls-cert` was never affected.

  8b. **Server-managed device settings: the office SSIDs (decided
     2026-09-21).** The Wi-Fi networks a phone wakes on were typed into
     the app; they are now set per device by the administrator, stored on
     the server, pushed to the app, and pushed again on every change.
     *Server:* the device record carries `ssids` and a `config_version`
     that rises with each write; `GET`/`PUT /v1/admin/devices/{id}/config`
     (§4.8), 404 for an unknown device or until set. *Wire:* the welcome
     gains an optional `config{version, ssids[]}` and a `config` message
     carries the same body on change, to that device's sessions only —
     both additive, no bump (PROTOCOL.md, golden fixtures on both sides).
     *App:* `LocalPushPolicy` (DiallerCore, tested) turns the received
     settings and the provider's saved list into leave / save / remove,
     and the model performs it on `NEAppPushManager`. Three rules: a
     phone the administrator has never configured is **left alone** (no
     `config` in its welcome), so existing phones keep working across
     the upgrade; a configuration is saved **only when the list differs**
     from what the provider holds, because re-saving an identical one can
     restart the provider and drop its connection; an empty list at
     version ≥ 1 **removes** the configuration — no background wakes. Only
     the app can save the provider, so the extension ignores the message
     and a phone whose app is not running picks the change up at its next
     launch, from the welcome. Enrolment now finishes the job: a fresh
     phone connects, receives its list, and has background calls with no
     Settings visit. Settings shows the list read-only; typing SSIDs by
     hand survives on the Status page for a server with no settings for
     the device (the harness). `harness/provision.sh` takes
     `DEV_A_SSIDS="Office,Office-5G"`. *Harness check:* set dev-hb's list
     through the admin route while `fake-app` holds its connection and
     see the `config` frame arrive there and not on another device.
     *Built 2026-09-21 (branch `feature/device-config`, awaiting
     approval):* as above; `PUT` and `POST` both set (busybox wget has no
     PUT). Tests: store versioning, persistence and isolation; the admin
     routes; welcome and push in the gateway to one device; the policy
     table; the session machine; both golden suites.
     *Same day, on the phone:* no calls at all after a dev-server
     restart, foreground included, which looked like the pinned
     certificate changing. It had not (both starts logged the same
     fingerprint): the phone had enrolled by code, which rotates the
     token, and `make dev-server` re-runs `harness/provision.sh` at every
     start, which re-issued dev-a's fixed token over it. `provision.sh`
     now leaves an enrolled dev-a's credential alone and only mints it a
     fresh code; the fixed token is issued only into a fresh data
     directory. Settings › Log out (not a reinstall) is the recovery for
     a phone whose credential the server no longer holds.

  *Item 9 split into 9a/9b/9c on 2026-09-23.* It was one item covering a
  contract, a hardened API and a web UI, which are three different kinds
  of work with three different risks. The order is deliberate: the API is
  the part that touches the call server, so it must be specified before
  it is built and hardened before anything depends on it, while the UI is
  replaceable — someone may well want a CLI or their own provisioning
  system against the same API. **The `internal/qr` encoder (9c) depends
  on none of it and can start at any time**: it is the piece most likely
  to send us to its own fallback, so finding that out early is worth more
  than doing it in order.

  9a. **The admin contract — define it exhaustively before building it.**
     The deliverable is writing, not code. *Reframed 2026-09-25:* the
     contract is **not a set of pages**. It is, first, the inventory of
     every configurable an operator needs to run and maintain the server
     and the system — what each is, where it lives, how it changes and
     when the change takes effect — and, second, the server API that
     inventory requires, so that 9b builds and tests exactly that API and
     9c is written afterwards against it. The pages below survive as the
     seed of the inventory, not its bound.
     *Written 2026-09-25 (this branch); approved 2026-09-25:*
     [protocol/ADMIN-API.md](protocol/ADMIN-API.md). Its inventory sorts
     configurables into three classes — deployment (the startup flags,
     read-only through the API), per device (the API's whole writable
     surface), and a single runtime, non-persisted class (log level and
     SIP trace) — and the API gains, beyond §4.8's routes: `whoami`,
     `server`, `status`, `events` (a bounded in-memory ring), `log`,
     `calls` (list only; nothing ends a call), per-device `diag` (list, download,
     delete, with a `-diag-retain` sweeper), `PATCH` for the description
     (the device's `label` field is renamed `description`),
     `DELETE …/enrol-code`, `?dry_run=1` on the replace-all, a JSON error
     envelope, optional `If-Match` on every versioned write, and a
     separate `-admin-addr` listener. It settles the open questions
     below (everything listed, no pagination, 500-device ceiling;
     `If-Match` with 412; `user` immutable; revoked is an authentication
     state and every admin route works on a revoked device; a re-POST of
     an existing id without a token is 409, with a token replaces only
     the credential) and records what it does not do (certificate
     rotation strands every phone; live trunk settings stay flags).
     *Load isolation (added 2026-09-25, §4.7 of the contract):* the admin
     API cannot degrade a call under any load. Calls and the app leg are
     the highest priority in the process and the admin API the lowest,
     enforced by hard bounds (64 connections, 4 requests in flight,
     per-source and global rate limits, server timeouts), no disk I/O
     under any lock the call path takes, one-second cached snapshots for
     status and calls, and a mandatory revert timer on debug logging. A
     harness gate floods the admin listener while a call is bridged and
     a third phone registers and dials; the audio gate must hold and the
     third phone's REGISTER and INVITE latency must stay within twice
     its idle baseline.
     *Carried over from the original item 9,* as the seed rather than the
     answer. **Pages: Devices** — label, user, generated id (read-only,
     copyable), app and extension online, SIP registered, revoked; add a
     device (label + user) and be shown its code, expiry and QR; per row
     revoke, new code. **Device** — the directory as a table with inline
     add / edit / delete and a favourite star, **Download CSV**, **Upload
     CSV** (replace-all, with the counts of rows added, changed and
     removed shown before it applies), **Copy directory to…** other
     devices, and in `lines` mode the device's PBX line: DN, digest user,
     a write-only secret field, and the registration's live state beside
     it (item 3c). **Server** — healthz, version, trunk qualify state,
     and the fleet's line registrations at a glance, since one refused
     line is the failure an operator needs to see without reading a log.
     *Remove* is the existing revoke — the directory is kept, so
     re-enrolling the same device restores it — and a separate *Purge*
     deletes record and directory. *CSV format* is in §4.8.
     *What 9a must settle and nobody has yet*, each of which changes the
     API rather than the page:
     — **Scale.** Pagination and search once a fleet is 200 devices, or
     an explicit decision that the admin lists everything and the browser
     copes. `GET /v1/admin/devices` returns all of them today.
     — **The call server being unreachable.** What each page does when
     the API does not answer: what degrades, what refuses, and what the
     operator is told. A UI that shows stale state while a credential
     write failed is worse than one that says so.
     — **Who "the admin" is — settled 2026-09-23, and recorded so it is
     not reopened.** There are two authentications here and they are easy
     to conflate: the operator's password into `dialpark-admin` (human →
     UI, §4.8's `-password-file`), and the credential `dialpark-admin`
     presents to the call server (machine → machine, 9b). **No operator
     identity is passed to the call server, and the admin API keeps no
     audit trail.** Its job is to keep unauthorised callers out, not to
     record who did what. If an audit trail is ever wanted it belongs in
     `dialpark-admin`, which is the only process that knows a human was
     involved.
     — **Session lifetime**, and what expiry does to a half-filled form.
     — **A half-applied bulk action.** A CSV upload is one replace-all on
     one device, but "copy directory to…" is N of them: what the operator
     sees when the third of five fails.
     — **Concurrency.** Two operators on one device, or one operator in
     two tabs. Last-write-wins is an acceptable answer; losing the other
     edit silently is not.

  9b. **The admin API on the call server, hardened (needs 9a).** Additive
     handlers only; nothing that exists changes shape. Two routes are
     missing outright: **`GET /v1/admin/status`** (§4.8 — per device,
     including the line state whose supplier `pbxline.Manager.Statuses()`
     is already written, unit-tested and has no caller) and **purge**
     (`DELETE /v1/admin/devices/{id}?purge=1`, deleting record and
     directory where a plain delete revokes).
     *How `dialpark-admin` authenticates.* **What it is for is settled
     (2026-09-23): keep unauthorised callers out of the admin API, and
     nothing more.** The call server authenticates the *caller*, not the
     person — no operator identity crosses this boundary and there is no
     audit trail through it. Who pressed the button is `dialpark-admin`'s
     own business, behind its operator password.
     The mechanism stays what it already is, a **bearer token over TLS**.
     The weakness is not the token: it is that the admin API shares a
     listener with the device API. `-http-addr` defaults to loopback, but
     a deployment must publish it on the LAN for phones to reach
     `/v1/directory`, `/v1/diag` and `/v1/enrol` — and that exposes every
     admin route to the whole office Wi-Fi, with no rate limit (only
     `/v1/enrol` has one). Two changes:
     — **A second listener on its own port.** `-admin-addr`, default
     **`127.0.0.1:8081`**, carrying `/v1/admin/` alone, while the device
     API keeps `-http-addr`. *Production runs both processes on one VM*,
     so loopback is the right default and the admin API is then
     unreachable from the network at all. The address is a flag rather
     than a constant because **testing may put the two on different
     machines**, which must keep working: bind it wider and the token
     over TLS is what protects it, exactly as it protects the device API.
     — **Take the token out of argv.** `-admin-token-file`, matching the
     `-password-file` pattern §4.8 uses for the operator password:
     `-admin-token` is readable by every local user in `ps`, and
     `make dev-server` passes it literally.
     Rate-limit the admin listener as `/v1/enrol` is rate-limited.
     *Deliberately not decided:* mutual TLS, where `dialpark-admin` also
     presents a certificate the call server verifies, so no shared secret
     crosses the wire. `tlsutil.PeerConfig` already does this on the
     trunk leg, so it is cheap to add later; it is recorded as an option
     for a deployment that wants it, not as work.
     *Strictness, in the standard library.* **No ORM**: there is no
     database to map — persistence is per-device JSON files written
     atomically — and §3 pins this server to the standard library. The
     guarantee wanted (no malformed request interrupts operation or
     corrupts data) lives at the HTTP boundary and the write path, which
     is precisely where an ORM is not:
     — **One typed request struct per endpoint**, decoded with
     `DisallowUnknownFields` and a bounded body, so an unknown or
     mistyped field is a 400 with a reason rather than a silent partial
     apply. Today there are **six decoders and no `DisallowUnknownFields`
     anywhere**, so `{"ssids":["Office"],"nonsense":true}` is accepted
     without comment.
     — **Validate before mutate.** Every handler returns its error before
     the store is touched, so nothing half-writes.
     — **Atomic writes and a single writer**, already the pattern (temp
     file + rename, a mutex per store); stated here so it is not lost.
     — **A schema version** on each stored file, so a later format change
     is detectable rather than silently misread.
     — **Round-trip properties**: anything written reads back identical.
     *Adversarial testing is the acceptance criterion, not a garnish.*
     Go's native fuzzing (`go test -fuzz`, standard library) against
     every admin endpoint: **never panic, never write a document that
     will not round-trip, never leave a store unreadable.** A panic in a
     handler takes the call server down with it, which is the whole
     reason this matters. Beside the fuzzer, a written adversarial suite:
     wrong types, missing and unknown fields, duplicate JSON keys,
     enormous bodies and arrays, deep nesting, NUL bytes and invalid
     UTF-8, numbers that overflow, path traversal in `{id}` and `{cid}`,
     and concurrent writes to one device from two callers.
     **The gate that matters: run all of it while a call is bridged, and
     the call must survive** — audio continues, no session closes, no
     re-INVITE, no `directory_changed`. That is §4.8's isolation rule
     turned into a test, and it is what protects the product. There are
     **no fuzz tests in the repository today**.
     *Plan (2026-09-25, from the approved contract
     [protocol/ADMIN-API.md](protocol/ADMIN-API.md)).* Ten steps on
     `feature/admin-api`, each a commit that leaves `go test ./...` and
     `make harness-test` green, in this order because each is tested
     through the one before it. The contract's section numbers are given
     so nothing here is a second source of truth.
     1. **The admin listener** (contract §4.1, §4.6, §4.7 bounds).
        `-admin-addr` (default `127.0.0.1:8081`) and `-admin-token-file`;
        `/v1/admin/` moves there and is 404 on `-http-addr`; a
        connection-limiting listener (64), an in-flight semaphore (4,
        503 `busy` after 2 s), per-source and global token buckets,
        `http.Server` timeouts on both listeners; `GET /healthz` and
        `GET /v1/admin/whoami`. Harness: `docker-compose.yml` publishes
        8081, `provision.sh`, `set_pbx_line.sh`, `wake_test.sh` and both
        READMEs point admin calls at it, and `provision.sh` line 73
        becomes an `enrol-code` mint. Tests: the limiter and semaphore
        in isolation; a 65th connection waits; a flood gets 429 and 503,
        never a hang.
     2. **Strict decoding and the error envelope** (§4.2–§4.4). One
        request struct per endpoint, `DisallowUnknownFields`, duplicate
        keys detected by a token walk (the standard decoder accepts
        them), trailing data refused, identifier grammar checked before
        any store call, JSON errors with the stable codes. The fuzz
        targets start here, one per write route, and run in CI for a
        fixed budget. Nothing in this step changes a success body.
     3. **The device store** (§6.2, §4.7 lock discipline, §5.1
        semantics). Schema version and `updated_at` on the record;
        `label` renamed `description` with the read-old-write-new
        migration; a write mutates memory under the store lock and
        serialises to disk under a separate writer mutex, so a digest
        verification never waits on an fsync; round-trip property tests
        on every store; the p99-under-one-millisecond digest-read test
        under a continuous replace. Same rewrite for the directory
        store. Then the semantics the contract fixes: revoked is an
        authentication state and every admin route works on a revoked
        record; re-POST of an existing id is 409 without a token and a
        credential-only replace with one; an identical settings write is
        a no-op.
     4. **Device routes** (§5.1, §5.2). `GET …/{id}`, `PATCH …/{id}`
        for the description, `DELETE …?purge=1` removing record,
        directory, line and diagnostics, `DELETE …/enrol-code`, and
        `If-Match` on the record's `updated_at`.
     5. **Directory routes** (§5.5). `?dry_run=1`, the limits (5,000
        contacts, field lengths, duplicate URI in one request named by
        index), `If-Match` on the directory version.
     6. **Live state** (§3, §5.6–§5.8). The gateway keeps `since`,
        remote address and `app_version` per session and gains a
        snapshot method; the trunk qualifier exposes up / down / off
        with `since` and last error; the B2BUA gains a registry of live
        calls with their legs, state and pump counters; the line manager
        is passed to the handler. Then `GET /v1/admin/status`, `/calls`
        and `/server` (with `-X main.version` in the Makefile and
        `-version`), served from a one-second cached snapshot. Tests: a
        snapshot under concurrent registrations and a bridged call in
        the b2bua test rig; the cache coalesces concurrent callers.
     7. **Events** (§5.9). The bounded ring, its `since` / `limit` /
        `truncated` contract, non-blocking append with a drop counter,
        and an emitter at each of the sites that only log today:
        presence, registration, line, trunk, call start and end, wake,
        enrolment, every admin write.
     8. **Log level** (§5.10). A `slog.LevelVar` for the process, the SIP
        trace global behind it, the revert timer, `for_seconds` required
        for `debug` and for the trace.
     9. **Diagnostics** (§5.11). List, download with the name grammar and
        no symlink following, delete one and all, `-diag-retain` with
        the hourly per-device sweeper that yields between files.
     10. **The gates** (contract §4.7 and §7). In `make harness-test`:
        the isolation check (revoke dev-s, replace dev-a's directory,
        mint dev-a a code, set the log level, read status, events and
        calls while dev-ha ↔ dev-hb is bridged, and nothing reaches
        either phone); the load gate (sixty seconds of the four floods
        while the call is bridged and dev-s registers and dials every
        five seconds, with the audio gate holding and dev-s's REGISTER
        and INVITE latency within twice its idle baseline); and the
        adversarial suite run against the live server rather than a
        test mux. Then the README's admin examples move to 8081.
     *Not in 9b:* mutual TLS, certificate rollover, live trunk settings
     (contract §10). *After 9b:* 9c builds `dialpark-admin` against this
     API and nothing else.
     *Built 2026-09-25 (this branch, awaiting approval):* steps 1–9 as
     planned, one commit each (steps 6–9 together), `go test ./...`
     green throughout, with fuzz targets on every admin write route and
     the sub-millisecond digest-read test under continuous writes.
     Step 10 is `harness/admin_test.sh`, `make harness-admin`, in
     `harness-regression`. *Verified the same day, once Docker was
     restarted:* `make harness-regression` end to end (SIPp conformance,
     call, wake, qos, every trunk variant, stall, PBX hold and
     unavailable, hold music, cancel-before-answer, the admin gate, the
     narrowband and xfer-app trunk runs), then flow-gone, peer-gone,
     hold-music-srtp, echo (server and PBX) and pbx-lines — all pass on
     the branch, so the port move to 8081 and every 9b change hold under
     the whole suite. In the admin gate the flood was refused 11–21
     thousand times by the rate limit, nothing was refused as busy, no
     event was dropped, the call's audio passed the gate and the server
     grew by under 50 MiB and returned. One harness script changed
     outside the contract's scope, and only for the environment:
     `wake_test.sh` now runs `fake-app` from the compose image tag
     because Docker Desktop's image store, after the restart, refused the
     sha id it used to look up (the server's wake path is untouched).
     *Two gaps closed the same day:* the gate now measures a third
     party's latency — SIPp as dev-hc/213 (an identity no phone uses)
     REGISTERs and INVITEs dev-hd/214 (a user with no phone, answered 480
     by the wake path) six times idle and then every five seconds
     through the flood; the loaded median must stay within twice the
     idle median, with a 10 ms floor because SIPp reports whole
     milliseconds and idle is about one. Measured: REGISTER 0–1 ms idle
     and 1 ms loaded, INVITE→480 0 ms idle and 1 ms loaded. And every
     directory write names its writer (`directory.By`: admin, device or
     server), so `directory_changed` events carry `by`; the gate asserts
     it. Decided in the building:
     the `calls` view lists calls waiting on a wake with only their id
     and start time, since nothing else is known before the INVITE; a
     call's end reason is `bye`, `peer_gone` or `failed` (the wake and
     ring timeouts end a call before it is bridged, so they never
     appear); `for_seconds` is required whenever the *resulting* level
     is debug or the trace is on, so "extend" is `{"for_seconds": N}`
     and "turn off" is `{"level": "info"}`.

  9c. **`dialpark-admin`, the web UI (needs 9a and 9b).**
     `server/cmd/dialpark-admin`, the same Go module, standard library
     only, templates and CSS through `embed`. Flags: `-listen`,
     `-server`, `-admin-token-file`, `-server-ca` or `-insecure`,
     `-password-file`, `-tls-cert`/`-tls-key` (self-signed when absent);
     `make admin` and `make dev-admin`. One operator password, a session
     cookie, a CSRF token on every form, no roles. It never touches SIP,
     media or the wake gateway, and can crash, restart or be redeployed
     with no effect on a call.
     *QR:* an in-tree encoder (`internal/qr`: byte mode,
     error-correction M, versions 1–10) rendered as inline SVG, so the
     binary stays standard-library-only and builds offline; golden tests
     plus one scan on a real phone, since a code that scans on one camera
     and not another is the failure mode. If it proves slow to write, the
     fallback is a vendored single-file JavaScript encoder (a one-off
     download outside the sandbox). **Independent of 9a and 9b — start it
     whenever.**
     *Built 2026-09-25 (branch `feature/admin-ui`, awaiting approval):*
     `internal/qr` first — byte mode, level M, versions 1–10, all eight
     masks scored by the standard's rules — checked by unit vectors, by an
     independent decoder in its own tests run on every length 0–213, and
     by a one-off oracle: fifteen codes through zbar in Docker, every one
     decoded byte-exact; those matrices are the goldens. The fallback was
     not needed. Then `dialpark-admin` as specified: the typed client over
     the server's own types, one password, a twelve-hour session refreshed
     on use, CSRF on every form, and the contract's §9 answers built in
     (a form submitted on an expired session is stashed and applied after
     the re-login; one banner and every write disabled when the server
     does not answer, with the last read and its time; If-Match on every
     edit and a 412 explained; copy-to as one request per device with a
     per-device result; CSV previewed through the dry run then one
     replace-all). Pages, in this order: **Server**, **Clients** (the
     name, by decision, for what the API calls devices), **Calls**,
     **Diagnostics** (server logging, the files phones uploaded, recent
     events). Adding a client is its own page, and enrolment its own
     page: the QR, the code and three steps, shown once. `make admin`, `make dev-admin`. Tests drive
     the UI over an in-memory fake of the API; `make harness-admin-ui`
     runs the real binary against the real server in compose, driven
     with curl, and is in `harness-regression`. Decided in the building:
     bare numbers in a CSV or the add-contact form get the server's SIP
     domain in the UI (the store does not normalise them); an uploaded
     file cannot ride a stashed form, so after a re-login the operator
     re-attaches it; the enrolment code and QR are shown once, on the
     page that minted them, and never stored. *Not yet done:* one scan of
     a real code on a phone camera (Matt offered; sample PNGs are in
     `data/qr-samples/`), and a look at the pages in a browser.
     *Isolation:* the rule of §4.8 applies in full — every admin action
     touches one device's entry and one device's file, notifies one
     device, and never restarts, reloads or re-binds anything. `make
     harness-test` gains the check: with a dev-ha ↔ dev-hb call bridged,
     revoke dev-s, upload a CSV to dev-a and mint a code for dev-a; the
     call's audio continues, and neither dev-ha nor dev-hb sees a session
     close, a re-INVITE or a `directory_changed`.
   10. **Per-destination codec on the PBX leg (scheduled; later in
     priority, decided 2026-09-27).** The server offers the PBX one global
     codec order (`-trunk-codecs`, default G.722 first). For a phone that
     only does G.711 that makes Asterisk transcode on the server's leg, and
     Asterisk 20.6 loses the phone's audio after some hold/resume cycles on
     exactly that transcoded leg (GitHub issue 11: trunk capture, Asterisk's
     own `rtp set debug` and the relay counters agree; PCMU on both legs
     never fails; `musiconhold.conf format=ulaw` did not help). The
     interim is PCMU first on the PBX leg. The item: the server chooses the
     offer per destination — the phone's own codec for a directory entry
     that names one, or what the PBX answered last time for that number —
     so the PBX never transcodes for a narrowband phone while wideband peers
     keep G.722. Needs a codec field on the directory entry (admin contract
     addition, 9a) and a harness scenario with a G.711-only phone leg.
   11. **The server owns its number range; trunk mode never loops a call
     (scheduled; next, decided 2026-10-02).** Today `routing.Resolve`
     sends any number that is not a local user to the trunk when one is
     configured, including a call that arrived *from* the trunk. So if the
     PBX routes a range to this server (CUCM: route pattern `3XX` on the
     trunk) and only 300–350 are provisioned, a call to 355 goes PBX →
     server → PBX → server, each pass a new B2BUA call with a fresh
     `Max-Forwards`, until the PBX runs out of call capacity or the caller
     hangs up; a Dialler user dialling 355 starts the same loop from the
     other end. Found by reading the code; not reproduced. The interim is
     deployment advice: the PBX routes only the provisioned extensions,
     not a range. The item:
     - **An owned range.** A server flag (`-local-range 3XX`, or
       `300-399`) names the numbers this server owns. A number inside it
       that is not provisioned resolves to a new `routing.NotFound` and is
       answered 404, from either direction, and never reaches the trunk;
       a number outside it routes as today. The PBX and the server then
       agree on one range: CUCM needs a single route pattern, and adding
       user 351 needs no PBX change. Shown on the admin UI's Server page
       (and the status contract, 9a).
     - **A backstop.** A call that arrived from the trunk is never routed
       back to it: a trunk caller whose destination resolves to `Trunk`
       gets 404. Nothing legitimate needs it in trunk mode, and it keeps a
       missing or mismatched range from bringing the loop back. Transfers
       place their trunk leg on a separate path; confirm it is untouched.
     - **Lines mode.** An unprovisioned number inside the range is 404
       there too. The backstop needs checking against lines mode, where a
       PBX call arrives at a registered line rather than from a trunk peer.
     - **Tests.** Routing table tests for the range (inside provisioned,
       inside unprovisioned, outside, no range set) and for the backstop;
       a harness scenario dialling an unprovisioned number in the range
       from each side against Asterisk, asserting 404 and exactly one
       INVITE on the trunk; and `make harness-regression` green.
   12. **Product licence (scheduled; decided 2026-10-03, §4.9).** X app
     devices until a date, vendor-signed, bound to the server's install
     id, verified on the server and on the phone, seats enforced at
     enrolment and every door for a device that loses one. Built on
     `feature/licence` in this order, each phase tests first and green
     under the race detector before the next, nothing in the admin UI or
     the app until the server is proven: (A) `internal/licence` and the
     `dialpark-licence` tool; (B) seats in the device store with
     `seat_since`; (C) gateway refusal with the reason, welcome `licence`,
     seat-loss reconcile (gateway disconnect, SIP unregister, line drop);
     (D1) `GET`/`PUT /v1/admin/licence`; (E) the harness licence and
     `harness/licence_test.sh` in `make harness-test`; (D2) the
     `dialpark-admin` Licence page and seat counts; (F) the app's verifier,
     refusal copy, 7-day banner and the enrolment 403 copy; (G) PROTOCOL,
     ADMIN-API, README. Every API call and every condition in §4.9 has a
     test before D2 or F starts. The one-off online check-in is a later
     item of its own.
   13. **No "office" wording in the app (noted 2026-10-06).** The app
     still says "office" in its own copy, which shows in the App Store
     screenshots (Settings, 05):
     - `SettingsView.swift`: the "Office Wi-Fi" row and its three
       footers ("on office Wi-Fi", "only on office Wi-Fi", "hasn’t set up
       office Wi-Fi");
     - `StatusView.swift` (Debug only): "The office Wi-Fi networks…";
     - `DirectoryView.swift`, the contact editor: "your office’s phone
       system (PBX)";
     - `Info.plist`, the Local Network prompt: "on the office network".
     New wording for each, then Matt's Xcode build, then screenshot 05
     retaken at both sizes.

### Much later (not scheduled)

Kept here so the design intent is not lost and so existing references to the
old phase labels still resolve. None of this is on the roadmap.

- **Focus/Sleep-filtered call rings through (decided 2026-09-19).** A phone
  in Do Not Disturb / Sleep / a Focus schedule must ring through to the
  caller exactly as an unanswered phone does behind any PBX (Cisco CUCM's
  DND "Ringer Off" default; iOS's own native Focus behaviour) — the caller
  keeps its ringback to the ring timeout, then 480. It must NOT be able to
  tell DND from an unanswered phone. This reverses two earlier "fast-fail
  the caller" behaviours, both dropped for that consistency:
  - When CallKit refuses the report (`FilteredByDoNotDisturb`) and the app
    stays alive long enough to ack the wake `busy`, the server treats that
    `busy` as an unanswered ring, not a 486. A user's active *decline* is
    the only case that still fast-fails with 486; `busy` (system filter)
    and `decline` (user) are split at both points that inspect the wake
    cause (`wakeAndWaitFrom`, `bridge`), and the busy cause is recorded up
    front so it wins over the app's simultaneous SIP 486.
  - When the app is instead suspended by iOS and its SIP connection dies
    mid-ring (the common case — CallKit never presents, so nothing keeps
    the app alive), the server no longer answers the caller 480 within
    ~2 s. The `watchFlow` watcher that did so was **removed**: a dead
    callee connection is indistinguishable from a momentarily unreachable
    phone, so the caller rings on to the ring timeout, then 480. The cost:
    a genuinely crashed/unreachable app also rings the caller for the full
    timeout — accepted, as that is what a PBX does with a registered phone
    it cannot reach. Retarget still applies: if the app comes back on a new
    connection it re-registers and `WaitRouteChange` sends a fresh INVITE.
  All server-side; no app change. (`errCalleeFlowGone`, `watchFlow` and the
  `harness-ringing-callee-dies` test were removed with the watcher.)
- **Mid-call address change (audio plan Phase G; optional, 2026-09-14).**
  A call that spans a Wi-Fi handoff between two listed SSIDs keeps its
  media on the old address until it drops; the handoff itself (the
  re-registration, wakes, the SIP stack's address refresh) is handled, so
  only a call in progress at that moment is affected. If wanted: after
  the transport reset the shim calls `call_modify()` so baresip re-INVITEs
  with the new media address; the server's media update already
  re-targets the relay.
- **Registration failover across a CUCM cluster (was item 3d; moved here
  2026-09-22).** A third-party SIP device gets no TFTP configuration, so the
  CM group has to be given to us: register to the primary, fall back on
  failure, come back when it returns. Deliberately never in 3c — it cannot
  be verified on Asterisk, and it is better designed against a real
  cluster's behaviour than guessed at. §7.3 item 10 asks which node an
  INVITE arrives from, which is the input to it.
- **Encryption on the line leg (was item 3e; moved here 2026-09-22).**
  *The app leg is unaffected and always encrypted* — TLS 1.3 and mandatory
  SRTP, rules 2 and 4 — in either PBX mode. This is only about the leg
  between this server and the exchange, which in lines mode is plain UDP
  and is refused the trunk's TLS/SRTP flags rather than left to look secure
  without having been tested.
  It sits here rather than on the roadmap because the research says it is
  not needed for an ordinary deployment: the documented configuration for a
  **Third-Party SIP Device (Basic/Advanced)** is the **Standard SIP
  Non-Secure Profile with Digest Authentication**, so item 3c as built is
  the mainstream CUCM setup for that device type rather than something we
  are getting away with. The unencrypted hop is inside the customer's own
  data centre, alongside the non-secure SIP their desk phones already
  speak, and the leg carrying a user's voice to their phone is encrypted
  regardless.
  *The question that shaped this* was whether a certificate must be per
  **device**, which for one server holding N lines would mean a connection
  per line — N transports, N source ports (our Contact has to name where
  each line is reachable), N certificates — instead of the single pooled
  connection everything uses now. It does not. Cisco documents **two**
  modes for secure third-party phones: a per-device certificate, and a
  **shared certificate** — one certificate for many phones, carrying a
  **DNS-type Subject Alternative Name**, where *the Phone Security
  Profile's name must match that SAN exactly or security is not enabled*.
  The shared mode is precisely our shape, so one connection carrying many
  registrations is a configuration Cisco anticipated, and per-line
  transports are a fallback for a deployment that insists on per-device
  certificates rather than the expected design. It is also the ordinary
  industry pattern — an SBC registering a site's accounts towards a core
  does the same — because SIP binds identity to the credential in each
  transaction, not to the socket.
  *The real constraint is the device type.* The shared-certificate
  mechanism is documented for **Secure Preferred Vendor** phones, which
  reach the CUCM database through a **COP file** — a Cisco partner
  onboarding step, not something a deployment switches on. The generic
  third-party profile is limited by comparison, and the type Cisco
  documents as supporting TLS and SRTP is the **Third-Party AS-SIP
  Endpoint** (below).
  *What this server would need is probably little*: the registrar already
  sends through the trunk transport's client and takes its Contact and
  registrar URIs from `-trunk`, so `transport=tls` with the existing
  `-trunk-tls-*` flags should carry the REGISTERs and INVITEs, and
  `-trunk-srtp=sdes` should encrypt the media as it does on a trunk. None
  of that has been run. Moving a line to TLS also makes `-pbx-peers`
  load-bearing rather than optional: the source check in `isTrunkSource`
  only applies over TLS, so every node that originates calls must be named
  or its INVITEs are challenged like an app's and fail. If it is ever
  picked up, the first step is to prove our half on Asterisk, which can
  require TLS with a client certificate on a line endpoint and do SDES —
  registration, challenged INVITE and media all encrypted, many lines over
  one connection — leaving CUCM's device-type policy as the only open
  question rather than our code.
- **AS-SIP as the device type (researched 2026-09-22, not scheduled).**
  **Third-Party AS-SIP Endpoint** is the one third-party device type Cisco
  documents as supporting TLS and SRTP without the preferred-vendor COP
  file, so it is the route to an encrypted line leg if one is ever
  required. AS-SIP (Assured Services SIP) is the US government's UCR
  profile of SIP: endpoints are expected to be "compliant with MLPP, DSCP,
  TLS/SRTP, and IPv6 requirements", plus V.150.1 modem relay and a
  conference factory. We already do the DSCP half (rule 5a) and TLS/SRTP
  on the app leg; MLPP precedence, IPv6-only and the rest we do not, and
  **whether a cluster will register an AS-SIP endpoint that never sends a
  Resource-Priority header is the thing to test** — nothing in the public
  documentation says it will, and precedence is used per call rather than
  at registration, so it is plausible rather than known.
  One finding from it applies to item 3c as built, and is the reason to
  keep this note whether or not AS-SIP is ever used: **"You can assign
  each user ID to only one third-party phone. If the same user ID is
  assigned as the Digest User for multiple phones, the third-party phones
  to which they are assigned will not successfully register."** So a
  single shared service account for the whole fleet is not merely untidy,
  it does not work. One End User with its own digest credential per
  device, which is what the per-device `pbx-line` already provides.
- **Remote users (was Phase 4b).** Staff away from the site, on cellular or
  home Wi-Fi. Each item maps to an existing seam; none changes the call logic:
  - *Wake:* `APNSTransport` (PushKit VoIP push) via the `SignalTransport`
    seam. Must report to CallKit immediately on receipt or iOS penalises the
    app. Same wire-protocol payload as LPC.
  - *Public edge:* a SIP/TLS listener + media relay exposed to the internet —
    a session-border-controller role in the same binary. The PBX stays behind
    it and is never exposed. Needs rate limiting, auth-before-INVITE, no UDP.
  - *Device auth:* the per-device enrolment credential already used by the
    gateway, extended to the SIP leg (which near-term item 1 delivers anyway).
  - *Reconnect / resume:* a `resume_token` in `welcome` (PROTOCOL.md §7, v1.1
    additive) so a device leaving the SSID re-attaches over cellular; SIP
    re-registers and re-INVITEs for in-progress calls.
  - *Known weakness to measure first:* mid-call Wi-Fi → cellular handoff on
    the SIP leg is re-register + re-INVITE, clunkier than a WebRTC ICE
    restart, and drops a second or two of audio. If unacceptable, that is the
    one reason to revisit §4.5.
  - The APNS sibling would also have to pass the §7.1 transport conformance
    suite on-device.
- **Delayed-offer INVITEs on the PBX leg.** *Done 2026-10-17
  (`feature/delayed-offer-mwi`).* An INVITE with no SDP, where the answerer
  makes the offer in its 200 OK and the caller answers in the ACK (RFC 3261
  §13.2.1). This entry used to say we refuse them, because the B2BUA would
  have to make an offer before knowing what the callee takes — the
  tandem-coding problem the copy-relay exists to avoid. That was the wrong
  order of events. The callee is dialled first and answers with its codec,
  and only then is the caller answered: so the late offer leads with the
  codec the callee took, and the relay never transcodes. It is **not** that
  one codec alone — the first cut was, and CUCM answered a G.722-only
  offer with an ACK carrying no SDP and a BYE a few milliseconds later
  (10:53 the same day), while taking PCMU from a G.722-first list. So the
  200 OK offers the callee's codec first and the rest of `-trunk-codecs`
  behind it, and when the exchange picks one of the others the callee is
  moved onto it by re-INVITE before the bridge starts — the same move a
  transfer makes (`renegotiateCodec`), one extra round trip on the app
  leg and only when the exchange disagrees. A deployment whose cluster
  always picks G.711 avoids even that by ordering `-trunk-codecs`
  `pcmu,pcma,g722`. With no caller SDP to narrow from, the callee is
  offered the PBX codec set. What made it stop being
  optional: CUCM sends a delayed offer to every third-party SIP line (item
  3c), and a line has no Early Offer tick box — on the 2026-10-17 CUCM
  bench every inbound call rang the app and died the moment it was
  answered ("no sdp present in INVITE"). The change is in diago's
  `AnswerOptions` and `ReadAck` (`vendor/PATCHES.md`) and one check in the
  bridge; the early-offer path is untouched by construction, since the
  same "INVITE has no body" test chooses between them in both places.
  Proof: `make harness-delayed-offer` (SIPp plays the PBX, as Asterisk
  never sends one) and the in-process tests in `b2bua/delayed_offer_test.go`,
  which drive a real B2BUA on loopback through both paths; the gate runs
  the call twice, the PBX answering G.722 and then PCMU, and asserts the
  re-INVITE in the second. A callee that will not move (its re-INVITE
  refused) ends the call with both codecs named rather than bridge silence.
- **Message-waiting indicator in the app.** CUCM tells every registered
  line about its mailbox with an unsolicited message-summary NOTIFY (RFC
  3842) on each REGISTER and on each change; Asterisk does the same once
  an endpoint has a mailbox. Since 2026-10-17 the server answers it 200 OK
  and logs the state (it answered 400 before, which CUCM logged against
  the line). Showing it on the phone needs a wire field, a protocol bump
  and an app release. Not scheduled.
- **Best-effort SRTP on the trunk (optional).** `-trunk-srtp=sdes` is
  all-or-nothing by design (item 3a): a PBX without SDES refuses the SAVP
  offer with 488, because RFC 4568 puts crypto on a secure m-line and there
  is no standard way to offer secure and insecure at once. Every way round
  that is a vendor extension, and each would be a deliberate choice to leave
  the standard:
  - *Optimistic / opportunistic SRTP* — put `a=crypto` on a plain `RTP/AVP`
    m-line and use it only if the answer echoes it. Asterisk's
    `media_encryption_optimistic`, Cisco's "Best-Effort SRTP". Widely
    tolerated, explicitly not RFC 4568 (which requires SAVP). Needs diago to
    emit crypto on an AVP m-line, which it does not do today.
  - *Dual m-lines* — offer SAVP and AVP as separate audio streams and let
    the answerer pick. Legal SDP; many endpoints mishandle a second audio
    stream, and the relay would have to follow whichever was accepted.
  - *488-and-retry* — re-offer in the clear after a refusal, as SBCs often
    do. Simplest for us and the easiest to reason about, at the cost of a
    failed INVITE per call and an easy downgrade for anyone able to inject a
    488.
  None is scheduled. The first question for any of them is whether a call
  that silently drops to plain RTP is one this product should place at all.
- **Video (was Phase 5).** WebRTC/BSD + VideoToolbox. If it ever happens,
  libwebrtc could carry audio too and retire baresip; that is the second
  reason to revisit §4.5.
- **IM (was Phase 6).** SIP MESSAGE/SIMPLE or XMPP, riding the wire-protocol
  channel like presence does.

### 4.7 Liveness is the server's job, not the device's

The wire protocol's heartbeat runs **server → device** (PROTOCOL.md §5).
That is not a detail: a Local Push provider exists to sit idle until data
arrives, and iOS is under no obligation to schedule it in between — so a
heartbeat the *device* must send can silently stop, and a server that reads
that silence as death will close a perfectly good connection. It did: 246
reconnects in one night (2026-09-15/16) on an extension that was awake and
answering wakes in 1.3 s throughout, with gaps of 76 s, 170 s and 9 minutes
that no timer-based theory explained.

Apple's own sample (`example/`, SimplePushKit) is built the other way from
where we started: `HeartbeatCoordinator` (sending) runs on the **server**,
`HeartbeatMonitor` (listening) on the **device**, and the provider evaluates
staleness from `handleTimerEvent()` — the system's own callback — rather
than a timer of its own. It sets no TCP keepalive either; with the server
driving, none is needed.

The fix was almost entirely server-side because the client already answered
a ping with a pong, and that pong resets the server's read deadline. So the
deadline now measures *"does the far end answer when spoken to"* — which is
the question worth asking — instead of *"has the far end had CPU lately"*,
which we cannot expect it to satisfy. `TestAnsweringClientIsNeverTimedOut`
pins it: a client that only ever answers must never be closed.

Done from that comparison (2026-09-16): the client's send-timer is retired
(`evaluateLiveness()` reads the clock and sends nothing), the extension
drives the check from `handleTimerEvent()` via `GatewaySession.checkLiveness`,
and the interval is 10 s with a 30 s deadline.

**A spurious reconnect after a suspension is not a bug to design around.**
The app reads no frames while iOS has it suspended, so on returning to the
foreground the idle rule fires and the session is rebuilt — half a second,
end to end, and correct (device, 2026-09-16). Apple's sample behaves the
same way and does not guard against it: `HeartbeatMonitor.evaluate()`
compares wall-clock times with no allowance for not having been running.
A guard was written for this and reverted the same day: it bought a handful
of avoided half-second reconnects, and cost an interval of *slower*
detection of a genuinely dead link, which is the wrong way round. If this
ever looks worth revisiting, price it against that.

### 4.8 Management plane and enrolment (decided 2026-09-21)

Two processes. `dialpark-server` is the call element and keeps exactly the
responsibilities it has: gateway, registrar, B2BUA, relay, directory store,
device credentials. `dialpark-admin` is the operator's web UI: a second Go
binary in the same module (stdlib only, templates and CSS embedded), holding
the admin token and a login of its own, speaking to the call server's admin
API over HTTPS and to nothing else. It never touches SIP, media or the wake
gateway; it can crash, restart or be redeployed with no effect on a call.
Typically both run on the same box (`-server https://127.0.0.1:8081`). The
admin verifies the call server's certificate (`-server-ca`, or `-insecure`
against the self-signed dev certificate) and serves its own pages over TLS
through the same `tlsutil` pattern, behind a single operator password
(`-password-file`), a session cookie and a CSRF token on every form. No
roles.

**Rule: an admin action never interrupts the call server, and affects only
the device it names.** Every admin request is an ordinary handler call that
takes the store lock, changes one device's entry and rewrites that device's
file atomically. There is no reload, restart, listener re-bind or global
re-read, and no file is shared between devices, so a half-written file for
one device cannot damage another's. Effects are scoped: adding a device
provisions one registry entry; revoking or rotating a credential closes that
device's gateway sessions (`error/unauthorized`) and drops its registration
— a call it is on runs to its natural end, since in-dialog requests are not
challenged, but it cannot re-register; a directory write notifies that device
alone; an enrolment code binds to one device. `make harness-test` proves it
(§7.2, §6 item 9).

**Identifiers.** The **device id** (`dev-a`) is the credential username of
one phone install: the `X-Device-ID` header, `hello.device_id` and the SIP
Digest username. The **user** (`201`) is the extension the device registers
as and what other people dial; one user has at most one device. The operator
never invents an id: the server generates one (`dev_` + six base32
characters) when a device is added without one — `POST /v1/admin/devices`
still honours an explicit `device_id`, which the harness fixtures rely on —
and the device record carries an optional human `label` ("Matt's iPhone",
"Warehouse 3") so the operator thinks in extension and label. The **contact
id** (`ct_…`) is the server's stable key for one directory entry, so a
rename is an update rather than a delete and an add, and a tombstone can name
what went; the app never shows it and CSV omits it (the reconcile matches on
URI).

**Enrolment code.** Adding a device (or "new code" on an existing one) mints
an eight-character code from the Crockford base32 alphabet without I, L, O
and U, valid for fifteen minutes, single use, stored as a hash beside the
credential in `devices.json`. Claiming it issues a fresh token and revokes
the previous one, so re-enrolment is credential rotation, and a lost phone is
handled by minting a code for its replacement. The claim route, `POST
/v1/enrol {code}`, is the server's only unauthenticated write and is treated
as such: constant-time comparison; an invalid or expired code answers 404
after a fixed 500 ms; a source address gets five attempts a minute. The reply
is `{device_id, user, token, signal_port, sip_domain, cert_sha256}`.
A valid code that cannot take a licence seat (§4.9) answers 403
`{"error":"no_seats"}` after the same fixed 500 ms, and the code is not
spent, so it can be claimed once a seat frees. That reply tells a guesser
that a code is valid without consuming it; the five-attempts-a-minute limit
and the 32⁸ code space keep that from being a practical attack, and hiding
it behind a 404 would mislead the legitimate user, whose problem is seats,
not the code.

**QR and manual entry.** The QR encodes
`dialler://enrol?h=<host>&p=<https port>&c=<code>&f=<certificate SHA-256,
base64url>`. The app registers the `dialler` URL scheme, so the iOS Camera
app opens it directly and the in-app scanner reads the same URL. Manual entry
is the host and the code (port defaults to 8080). After the claim the app
**pins** the server certificate's SHA-256 — from the QR, or
trust-on-first-use from the claim reply on the manual path — for both the
signal socket and HTTPS, replacing today's "accept any certificate";
`LANSocketTransport`'s verify block and `DirectoryClient`'s session take a
pin instead of a boolean. The dev toggle survives on the hidden diagnostics
sheet only (§6 item 8).

**Admin API the frontend depends on** — all additive, admin bearer, new
handlers; nothing that exists changes shape:

- `GET /v1/admin/status` — per device: label, user, revoked, app and
  extension sessions online, SIP registered and contact expiry; **the
  device's line on the PBX when the server registers on its behalf** —
  its state (pending, registered, retrying, refused), the realm the
  exchange challenged with, when the binding lapses, and why it last
  failed, never the secret; trunk qualify state. Read-only views of what
  `gateway`, `registry`, `pbx` and `pbxline` already hold in memory.
  The line half is `pbxline.Manager.Statuses()`, which is written and
  unit-tested but **has no route until this endpoint is built**: §6 item
  3c left it that way on purpose rather than adding a second status
  endpoint that would have to be folded into this one later. Until then a
  line's state is visible only in the server log, which is the gap this
  endpoint closes — an operator whose line will not register should be
  able to ask, not grep.
- `POST /v1/admin/devices/{id}/enrol-code` → `{code, expires_at, url}`.
- `GET /v1/admin/devices/{id}/directory` (the full list) and `PUT`
  (replace-all: the server reconciles by URI — upsert what changed,
  tombstone what is missing — and bumps that device's version once).
- `POST /v1/admin/devices/{id}/directory`, and `PUT` / `DELETE`
  `…/directory/{cid}` per contact. The admin verbs on `/v1/directory` move
  here; that path's write verbs become the device's own (§6 item 7).
- `DELETE /v1/admin/devices/{id}` stays a revoke; `?purge=1` also deletes
  the record and the directory.
- `GET` / `PUT /v1/admin/devices/{id}/config` — the device's server-managed
  settings, `{"ssids": […]}` today (§6 item 8b): versioned on the device
  record, 404 until set, and pushed to that device's live sessions as a
  `config` message on every write (the same body rides in its welcome).
- `GET` / `PUT` / `DELETE /v1/admin/devices/{id}/pbx-line` — the device's
  line on the PBX when the server registers on its behalf (§6 item 3c):
  `{dn, digest_user, secret}` in, `{dn, digest_user, configured}` out.
  The secret is write-only and never leaves the server — it is not pushed
  to the device, and no read returns it. 404 for an unknown device or
  until set; a write re-registers that one line and touches no other.

CSV lives in `dialpark-admin`, not in the call server:
`display_name,uri,mode,favourite` with a header row, UTF-8, RFC 4180
quoting; `uri` may be a bare number, which the server normalises to
`sip:<n>@<domain>`; `favourite` is `true`/`false`, and a missing column means
false. The harness keeps issuing its fixed tokens through `POST
/v1/admin/devices` and additionally prints an enrolment code per device, so
onboarding can be exercised against it.

### 4.9 Product licence (decided 2026-10-03)

The server runs on the customer's hardware and must enforce a licence for
**X app devices until a date D** without any internet dependency.

**The licence.** A vendor-signed Ed25519 document,
`DP1.<base64url payload>.<base64url signature>`, payload
`{v, id, customer, install_id, seats, issued_at, valid_until}`. The vendor
private key stays offline with the vendor; the public key is compiled into
both `dialpark-server` and the app. The payload is readable, not encrypted:
what makes it a licence is that nobody without the private key can produce
a signature over it, and changing one character of it breaks the signature.
`server/cmd/dialpark-licence` (`keygen`, `issue`, `inspect`) is the vendor's
tool; `server/internal/licence` parses, verifies and holds the licence.

**Binding.** At first start the server mints a random install id and keeps
it in `<data-dir>/install.id`, never rewritten; the admin UI shows it, the
operator sends it to the vendor, and the licence names it. A licence for
another install id is refused with both ids in the message. The licence is
stored at `<data-dir>/licence`, written only through the admin API; this is
the one server-wide setting the API persists (ADMIN-API rules 2 and 3 carry
the exception: it is data, not start-up configuration, and a change touches
exactly the devices whose seat flips, never a call). `install.id` joins the
backup set; without it the licence stops matching.

**Seats.** An enrolled, non-revoked device holds one seat. Claiming an
enrolment code, or issuing a fixture token, when no seat is free is refused
(403 `no_seats`, 409 `no_seats` on the admin route); creating a device
record without a credential and minting its code are always allowed, so
phones can be staged ahead of a licence. Re-claiming a device that holds a
seat keeps it; revoking frees it. When there are more holders than seats
(a licence shrunk, replaced, or expired, which is 0 seats), the first N by
`seat_since`, the time a device last entered the seat-holding state, stay
licensed and the rest are **suspended, not deleted**: refused at the
gateway hello (`unauthorized`, message `no licence seat`, `licence expired`
or `no licence`; no new error code, since an app cannot decode an unknown
one), refused for SIP (digest secret withheld, 403), 401 on the device HTTP
API, their SIP binding dropped, and in lines mode their PBX line
unregistered so the exchange never rings a dead line. A call in progress at
seat loss runs to its end, as on revoke. No licence installed is 0 seats.

| Door | Trunk mode | Lines mode |
|---|---|---|
| Claim with no free seat | 403 `no_seats`; app: "The server has no free licence seats. Ask your administrator." | same |
| Gateway hello | fatal `unauthorized` with the reason; app shows it in Settings, stops retrying until foregrounded | same |
| SIP REGISTER / INVITE | 403; an existing binding is unregistered on seat loss | same |
| Inbound call to the device | wake undeliverable → 480 to the PBX | additionally the PBX line is not registered, so the exchange treats the number as offline |
| Call in progress at seat loss | runs to its end | same |

**Expiry.** A hard stop at `valid_until`: 0 seats, every holder suspended.
The server log and the admin UI warn from 30 days out (once a day in the
log); the app shows a banner in the last 7 days. Renewal is pasting a new
licence; devices resume at once.

**The app verifies too, and that is the load-bearing part.** The welcome
carries the licence string. The app and the extension verify the signature
with the compiled-in public key and `valid_until` against the phone's own
clock, and treat failure exactly as `unauthorized` ("This server's licence
has expired", "This server has no licence, or needs updating"). The server
binary is in the customer's hands and can be patched or have its clock set
back; the App Store build cannot. Authenticity and expiry are therefore
enforced where the customer cannot reach, and seat counting is enforced on
the server. The licence string reaches the phone over the pinned TLS
session, is held in memory only, and is neither shown nor logged there.

**What this does not prevent, accepted 2026-10-03.** A modified server
binary can over-enrol. A copied data directory (`devices.json`,
`install.id`, `licence`) runs a second server under the same licence, which
no offline scheme can stop: whatever identifies the installation is data
on the customer's disk. It is made unattractive rather than impossible: the
theft needs the victim's administrator to leak two secrets, the thief's
admin pages say "Licensed to <victim>" with the victim's seat count, and
the vendor's register of licence id, customer and install id catches a
mismatch at renewal or support. Phones cannot check `install_id`, so a
patched server can present any genuinely signed, unexpired licence; expiry
still holds on the phone. A phone with a badly wrong clock may refuse a
valid licence.

**Later, optional: a one-off online check-in at licence application.**
Decided as a later addition, not part of the first build, and never a
regular check-in. When a licence without the vendor-set `offline` flag is
applied through the admin API, the server reports `{licence_id,
install_id, server version}` to a vendor service once, which records the
key as in use on that install id and answers with a vendor-signed receipt:
`valid`, or `no longer valid` if that key was applied before, which the
server refuses with that reason. "Once" is exactly once: a reinstall that
re-applies the key needs a reissue; a restore that keeps the data directory
never re-applies. A server that cannot reach the service cannot apply a
non-offline key, and does not fall back, since that would be the bypass.
It stops a key being pasted into a second server; it does not catch a
copied data directory, which never applies anything.

**Dev and harness.** One real vendor key; the harness commits a fixed
`install.id` and a long-lived licence issued for it (and a 2-seat one for
the shrink test), baked into the harness image and applied by
`provision.sh`; the native `make dev-server` seeds the same `install.id`.
Unit tests inject a test key.

## 7. Validation strategy: maximise automation, bound the human touch

Principle: **every Apple-hardware dependency is hidden behind a seam that has a
non-Apple sibling**, and both siblings pass the *same* conformance suite. The
non-Apple sibling runs in CI / headless; the Apple sibling runs the identical
suite once on-device. Switching siblings changes delivery, not behaviour.

### 7.1 The three seams
| Seam | Automated sibling (no human) | Apple sibling (device) | Conformance suite proves |
|---|---|---|---|
| Signal transport | `LANSocketTransport` (LAN) | `LPCTransport` (`NEAppPushProvider`) | message semantics, ordering, reconnect, auth |
| Audio I/O | baresip `aufile`/portaudio (WAV in/out) | CoreAudio + `AVAudioSession` | SIP + Opus + jitter buffer (assert on recorded WAV) |
| Call UI | headless call-state observer | CallKit (`CXProvider`) | ring/answer/hold/transfer/end transitions |

### 7.2 Fully automated, zero human (most of the system)
- Wire protocol round-trip + golden fixtures.
- Go server: signal gateway, app↔app + PBX B2BUA routing, directory sync.
- **Real SIP + real media, headless**: `baresip-A` ↔ Go server ↔ `baresip-B`
  (+ Asterisk for the PBX leg) in docker-compose; place calls, hold/transfer,
  and validate RTP/Opus by playing a known WAV from A and asserting on B's
  recording. The iOS app wraps the *same* `libbaresip`; only the audio backend
  differs (seam #2). *Audio-quality gates (2026-09-12):* the WAV is an
  aperiodic tone pattern, so a recording can be correlated against it —
  `harness/spike/assert_audio.py --reference` reports the mouth-to-ear delay
  of the path and every gap inside a tone burst. `make harness-echo` bounds
  both (≤ 150 ms on the server echo, ≤ 200 ms through the PBX, no gaps;
  built-in earpiece/speaker only — a Bluetooth HFP headset adds
  50–100 ms each way of its own and is excluded, see `ios/README.md`
  "Audio routes");
  `IMPAIR=1` adds 2 % loss and 30 ± 10 ms jitter to everything the server
  sends (`harness/netem`) and judges what the phone's decoder conceals. The
  relay logs `lost`/`reordered`/`jitter_ms` per leg from the sequence numbers
  and timing it sees, and `sim-call` fails on any loss in a clean run.
- `LANSocketTransport` end-to-end: server wake → transport → the exact app code
  path that handles an incoming call.
- Swift logic modules via `swift test` (CI; or locally if the sandbox grant is
  added — optional, not on the critical path).
- Simulator: full app + CallKit control flow over `LANSocketTransport`, via
  XCTest in CI.
- Admin isolation (§4.8): `make harness-test` revokes, re-directories and
  re-codes other devices while a call is bridged and asserts the call and
  its parties are untouched (§6 item 9). Enrolment codes, per-device
  directory sync and the CSV round-trip are `ServeHTTP`-level tests
  (§5 rows 11–13).

### 7.3 Irreducible human-touch list (the entire manual surface)
1. Extension launches on matched-SSID join and survives app kill / background.
2. `reportIncomingCall` from the extension shows CallKit and cold-launches the
   app on answer.
3. Real bidirectional audio + route changes (earpiece/speaker/Bluetooth/CarPlay):
   the checklist in `ios/README.md` "Audio routes" (switch routes mid-call,
   Bluetooth connect/disconnect mid-call, start on the headset, CarPlay, a
   cellular interruption); the restart path itself is headless in
   `make audio-probe` (scenarios C and D). Plan Phase H, 2026-09-14.
4. `LPCTransport` passes the transport conformance suite on-device.
5. Call waiting (rule 8; plan Phase I, 2026-09-14): on a call with 101,
   call the app from 100 — the call-waiting tone plays; **Accept** on the
   second call (iOS 26 shows plain Accept / Decline, see rule 8) holds 101
   and takes 100 — the app log must show one transaction
   `SetHeldCallAction(<call 1> hold),AnswerCallAction(<call 2>)` and the
   desk phone shows hold and the app's screen reads "101 on hold" with no
   banner of its own; Swap twice from iOS's banner, the microphone follows
   the active call each time; end the active call → the held one resumes
   by itself (log: "is the only call left and on hold; resuming it", then
   the system's hold=false); Decline → 100 hears busy at once; 100 hangs up
   while waiting → the call with 101 is untouched; Settings › Call waiting
   off → 100 hears busy immediately. Each once with the phone unlocked
   and once locked (the second call arrives by INVITE on the held session
   and by wake; both must match by the INVITE's X-Dialler-Call-ID).
   Done so far (2026-09-14): the tone, and both orders of arrival ring
   the second call; Accept itself not yet pressed on a device. Headless
   twin: `make sim-call-cw`.

6. Call-progress tones (rule 8a; plan Phase J, 2026-09-15). *Which* tone
   and *when* is headless — unit tests for the decision, `OUTBOUND=212
   make sim-call` and `make sim-call-refused` for it on the real engine.
   What no harness can judge is the one thing that matters: whether the
   tone is **audible in the earpiece, mixed under baresip's audio unit**,
   at a level that is neither lost nor painful against a call. So: call
   101 and hear ring-back until it answers; call 101 while it is on
   another call and hear busy, then the call disappear by itself; call an
   extension the PBX does not know and hear congestion; hang up on a busy
   tone and confirm the call goes at once. Then the one case the harness
   cannot stage, because our server never sends it: a PBX destination
   answering with 183 and its own ring-back (Asterisk `Progress()`) must
   give **one** ring-back, not two.

7. Enrolment (§6 item 8; plan 2026-09-21): enrol a fresh install from the
   QR `dialpark-admin` shows — once through the iOS Camera app, once through
   the in-app scanner, once by typing host and code — and confirm the pin
   holds: swap the server certificate and the app must refuse to connect
   with a message that says why.

8. Recents (§6 item 6): with the app killed, ring the phone and let it
   time out; open the app — one Missed row, the right name and time, and a
   tap redials. Then one answered call and one dialled call that is
   declined: a duration on the first, "Declined" on the second.

9. The hidden gesture (§6 item 8): a five-second press on the Settings
   title opens Status; a tap or a two-second press does not. Back returns
   to Settings; with Status open, tapping any tab-bar button — Settings'
   own included — returns to that tab with Status closed, and coming back
   to Settings finds it closed.

10. **CUCM lines, the day a CUCM exists (§6 item 3c).** Written now so it
    is not reconstructed later; nothing here can be staged on Asterisk.
    Provision one End User with Digest Credentials, one Third-party SIP
    Device (Basic) naming that user as its Digest User, and one DN
    matching the device's extension. Then, with `-pbx-mode=lines`:
    (a) the line reaches **Registered** on the CUCM device page, and
    survives a re-registration cycle; (b) a CUCM phone calls it — the app
    rings through the wake, with the caller's name from CUCM; (c) the app
    calls that phone — it arrives as the DN, not as "dialpark", and CUCM's
    INVITE challenge is answered; (d) **DTMF both ways** (the digits reach
    an IVR or a phone's display), noting whether CUCM inserted an MTP;
    (e) hold and blind transfer to a CUCM extension — if REFER is refused,
    the server must complete it and the call must survive; (f) ~~whether
    CUCM's inbound INVITE carries SDP~~ — *answered 2026-10-17:* it does
    not (delayed offer) and the server answers it; check instead that the
    200 OK offers the app's one codec and the call has audio both ways;
    (g) a deliberately
    wrong digest password — the line latches refused, logs once, and no
    other line is disturbed; (h) if the cluster has more than one node,
    which node the INVITEs arrive from, which is the input to the
    cluster-failover item under §6 "Much later".

Each is a short checklist backed by structured os_log/signpost output — not an
open-ended "test the app".

### 7.4 Rollout: confirm on WebSocket, then switch to LPC
1. Build and fully validate everything on `LANSocketTransport` (headless + CI +
   simulator). Not throwaway — it is the production foreground transport.
2. Build `LPCTransport` and device-verify it in isolation against the transport
   conformance suite + items 7.3.1–2. No call-logic changes are in scope.
3. Flip config so background wakes use LPC; re-run the 7.3 device smoke. Identical
   behaviour by construction.

## 8. Licensing (all commercializable)

| Component | License | Notes |
|---|---|---|
| baresip / libre 3.15 | BSD-3 | SIP + RTP, modular C, production-grade (verified from the licence files in `ios/vendor/src`) |
| Opus 1.5 | BSD-3 | primary audio codec; royalty-free IPR declarations at the IETF |
| OpenSSL 3.3 | Apache-2.0 | TLS + SRTP crypto; the largest licence surface in the app (3.x only — 1.x carried the old OpenSSL/SSLeay licence) |
| G.722 (WebRTC's copy of Steve Underwood's implementation) | public domain; WebRTC's edits BSD-3 | wideband codec on PBX calls, compiled into the app's `g722` module instead of spandsp (LGPL, which baresip's upstream module needs). Source revision, licence check and SHA-256 recorded in `ios/vendor/patches/README.md` |
| G.711 | royalty-free (baresip's own module) | narrowband fallback |
| Packet-loss concealment (G.711/G.722) | own code, `ios/vendor/patches/plc` | written from the ITU-T G.711 Appendix I description; no spandsp or other third-party PLC |
| G.729 | patents expired (~2017) | optional |
| sipgo / diago (server) | BSD-2 / MPL-2.0 | **decided** in Phase 0; vendored, builds with `CGO_ENABLED=0` |
| Server runtime (Go) | permissive stdlib + vendored deps | — |
| WebRTC / libwebrtc | BSD-3 | video, **much later** (§6) |

All permissive and fine to link statically into a closed-source App Store app.
Both BSD and Apache-2.0 still require the copyright notices, licence texts and
warranty disclaimers to be reproduced in a binary distribution: an
acknowledgements screen (or bundled licence file) is pending — see
`ios/README.md`, which also covers the export-compliance declaration.

Explicitly avoided: PJSIP / Linphone (GPL-or-paid; GPL conflicts with closed
App Store distribution). Kamailio, rtpengine, and Asterisk as *embedded*
engines (GPL) — Asterisk stays as the dev/test PBX peer, which is fine because
it is neither linked nor redistributed.

## 9. Top risks to validate early

1. **LPC entitlement + App Review — now the single, unmitigated dependency.**
   LPC is the only wake path (APNS is unscheduled, §6 "Much later"), so an
   ungranted or rejected `app-push-provider` entitlement has no fallback.
   Validate earliest: request the entitlement and put an external TestFlight
   build through review before investing further in the on-device flow.
2. **Unauthenticated app leg** — closed 2026-09-10 (§6 near-term item 1:
   Digest bound to the enrolled device on REGISTER and INVITE; directory
   API on TLS). Residual: a nonce may be reused within its 5-minute window
   (no nonce-count tracking), acceptable on a LAN app leg over TLS.
3. **Extension longevity/resource limits** holding a persistent connection.
4. **CUCM SIP interop** quirks vs. Asterisk (third-party SIP device
   provisioning, registration behaviour) — isolate behind `PBXAdapter`. Now on
   the core path: the PBX leg is the product, not an edge case.
   *2026-09-22:* the provisioning half is now scheduled work, not an
   unknown — §6 item 3c builds line registration behind that seam and
   proves it on Asterisk. The residual risk is precisely the part no
   Asterisk can stand in for, and it is enumerated rather than left
   vague: 3c's "what it cannot prove" list, with the bench checklist in
   §7.3 item 10. Nothing CUCM-specific is hard-coded, so the expected
   cost of a surprise there is configuration, not a rewrite.
5. **baresip ↔ CallKit ↔ AVAudioSession** lifecycle on answer (cold launch from
   extension) — resolved on device 2026-09-07 via the vendored audiounit
   patches (§4.5); the residual risk is keeping those patches working across
   baresip upgrades.
6. **B2BUA completeness.** Attended transfer across two legs, re-INVITE glare,
   transfer-to-trunk codec renegotiation (§6 near-term item 2).
7. **OPEN, under observation — wakes to a suspended app killed by iOS
   (2026-09-11; fixed the same day, working on device since; keep open
   until it has held for a while).** Reports `Dialler-2026-09-11-161148/161222/172336.ips`: `SIGKILL`,
   FrontBoard `0xBAADCA11` from callservicesd, main thread idle. Device
   console: every push that *launched* the app was reported to CallKit
   within 250 ms; every push into an *existing* process (suspended or
   backgrounded) reached no handler at all, and callservicesd killed the
   app 7 s after granting its VoIP assertion. First fix (synchronous
   `reportNewIncomingCall` in the PushKit delegate, a real defect per
   Apple DTS FB16655952) was on the phone for the 17:23 kill and did not
   suffice. Actual cause: Local Push Connectivity delivers an incoming call
   to the app's `NEAppPushDelegate`
   (`appPushManager(_:didReceiveIncomingCallWithUserInfo:)`, main queue)
   whenever the app process exists, and only launches a dead app through
   PushKit. The app never set that delegate, so for a live process the
   call went nowhere. Fixed: `AppModel` keeps the loaded `NEAppPushManager`
   and attaches `LocalPushDelegate` at every launch and after every save;
   both paths end in `handleExtensionWake`, which reports synchronously.
   Verified on device the same evening: (a) app in foreground, call from
   101; (b) use the app, lock, wait a minute, call; (c) close the app,
   restart the server, call — all ring. If it resurfaces: Analytics report
   `Dialler-…ips` with 0xBAADCA11, then a device console capture; the
   signatures to look for are in the iOS app notes.
   *Recurred 2026-09-13 00:51:24 (server time), narrower shape:* the app
   had been backgrounded six seconds earlier (`app: will resign active`
   is its last line) and was still resident; the extension acknowledged
   the wake, and the suspended process was killed with 0xBAADCA11 (its
   MetricKit crash report, pid 644, arrived by the diagnostics pipeline)
   without any of our code running — no `wake via extension`, no PushKit
   line. The three wakes that followed each launched a fresh process,
   which reported to CallKit within 100 ms and rang. So the delegate fix
   holds for a launch and for a long-suspended app (last week's test),
   and fails for a just-suspended one. Also seen that minute: CallKit
   refusing a report with `incomingcall error 3` (filtered by Do Not
   Disturb / Focus) — a system decision, logged as a 486 by the app.
   *Closed the same night from the device console:* callservicesd
   resumed the process and delivered the payload, and inside the app the
   framework logged `NEAppPushManager app has not set the delegate to
   receive the incoming call payload`; 7 s later `Killing VoIP app …
   because it failed to post an incoming call in time`. The delegate had
   been set — on the manager object the app itself created and saved when
   Local Push was re-enabled at 00:50:23. Deliveries go to the delegate of
   the instance the framework LOADS from preferences; the app's own saved
   object is not it. Every later process loaded the manager at launch and
   rang. Fix: after every save, reload from preferences and attach the
   delegate to the loaded instances (all of them, kept alive), and
   re-attach on `willResignActive`, the moment a delivery to a suspended
   process starts to matter. The phone's clock ran ~33 s ahead of the Mac's.
   *Two more from the same night's uploads (01:31–01:32), both fixed:*
   (a) ringing after the caller hung up on a locked phone — the server's
   `wake_cancel` went out at 01:31:01 to the only live connection (the
   extension), and the app's own session came up at 01:31:06; a cancel is
   now remembered until the wake's expiry plus 30 s and replayed to any
   session of that device that connects later (gateway `cancelled`,
   PROTOCOL.md §7, `TestCancelIssuedBeforeTheAppConnectedIsReplayed`), and
   the app resolves a cancel through a merged wake id when the call rang
   from its INVITE first; (b) one SIP call reported to CallKit twice —
   the INVITE's report was queued for the main thread from the SIP loop
   when the wake arrived on the main thread, found no CallKit entry yet,
   and reported again, so the caller's hangup ended only one of the two
   and the other rang until the user ended it. `CallKitBridge` now tracks
   queued reports: a reaffirm during that window counts as satisfied, and
   a queued report finds the call already reported and steps aside.
   *05:52 the same morning, two more:* (c) with the app in the foreground,
   the wake (gateway thread) and the INVITE (SIP loop) landed in the same
   millisecond; the INVITE path checked for a ringing call and inserted
   its own entry in two separate critical sections, so both passed their
   check first and one call rang twice — the check-and-insert is now one
   locked step; (d) the extension had been disconnected from 02:00 to
   05:52 while iOS reported it active, so every call found "callee
   offline, wake undeliverable"; its own log was lost because the app's
   launch upload deleted the shared file while the extension held it open
   (FileLog now reopens after a drain), and the extension's system timer
   now rebuilds the session from scratch whenever it finds itself
   disconnected. The server had not restarted (same instance, same
   session id prefix): the Mac was unreachable for those hours and came
   back, and the extension did not reconnect in the minutes after. The
   keeper's only hole for that: a connect attempt that reports nothing
   (no connected/waiting/disconnected) armed no timer, so one such attempt
   left it down for good. Every attempt now has a 10 s deadline
   (`GatewaySession.attemptTimeout`), after which it is torn down and the
   backoff continues; `testASilentAttemptIsAbandonedAtTheDeadlineAndRetried`.
   *Ring-after-hangup, the lasting cause (2026-09-13 17:02, third
   sighting):* the app's keeper deliberately holds no gateway session in
   the background, but a call the extension wakes rings in the
   background — so the caller's hangup (a wake_cancel on the app's
   socket, or its replay on connect) had nowhere to arrive, and neither
   did the app's own decline ack. The extension received every cancel
   within 1.5 s; the app only learned of them when the user opened it.
   Fix: the app holds a session for exactly as long as a call is tracked
   (`holdSessionWhileCallTracked` on the wake, `callEnded` releases it
   when the last call is gone and the app is not on screen); CallKit
   keeps the process running for that span. No new channel, no timer.
   *Confirmed the same day, 06:21, when the extension's log survived:* it
   logged `gateway error idle_timeout fatal=true` and nothing more for
   twelve minutes, until iOS stopped it for lack of a network. The
   server's fatal error frame was handled by `SessionMachine` as
   "emit the error, close the transport" — without a `.disconnected`,
   and `didClose` is a no-op once the state is closed — so the keeper
   never learned the connection was gone and never reconnected. Every
   fatal error is now a drop (`.protocolError` then `.disconnected`),
   the keeper retries the transient ones and stops on the refusals
   (`unauthorized`, `unsupported_version`, `superseded`) until the next
   foreground; and the machine mirrors the server's liveness rule: no
   frame from the server within 3 × heartbeat (a healthy link carries a
   pong per ping) closes the connection so a link the network silently
   lost is not held until TCP gives up. `testFatalErrorWhileLiveIsADrop`,
   `testASilentServerIsDroppedAfterThreeHeartbeats`,
   `testAFatalIdleTimeoutIsRetried`, `testARefusalStopsTheBackoffUntilTheNextForeground`.
   Why the extension's pings stopped reaching the server for 75 s on a
   locked phone still on Wi-Fi is not known (the frame it then received
   proves the downlink worked); the reconnect now covers it either way.
   *Same afternoon, two SSIDs on the list (§2):* moving between them
   does not restart the provider (both match), the phone's address
   changes, and the extension's connection dies without either side's
   TCP noticing. The server kept sending wakes into the old session
   until its 75 s idle close, and the extension only reconnected when
   its own 75 s liveness rule fired — every call placed in that window
   was lost. (A server-side ping was tried and reverted: it cannot reach
   a dead connection.) The fix is on the client and needs no timer: an
   NWConnection reports when the path under it is gone (viability) and
   when a better path exists; a handoff to a new address is exactly a
   better path, and the transport closes on it so the keeper reconnects
   at once over the new network (PROTOCOL.md §5).
   *2026-09-18 15:12, "the caller was told call failed, then the app woke
   and rang anyway":* not a wake failure — the wake, the app's resume and
   its REGISTER all worked, and the INVITE reached the stack 76 ms after
   the REGISTER. The app then answered it **486 Busy** itself, 0.3 ms
   later: the gateway session had come back at the same moment and the
   app's "session came back → drop the registration and its dead
   connection" path ran. Its guard ("not while a call is up") read the
   engine's `state` on the main thread and saw no call; the free was then
   queued to the libre loop thread, which read the INVITE off the socket
   (it was queued behind the REGISTER's 200 OK) *before* draining the
   queue — so `ua_free` found a ringing call and hung it up. The caller
   heard busy; the phone rang because the server replayed the wake onto
   the app's new session (`gateway.go sendWake`) and the wake_cancel for
   the failed call followed a second later. Fix: the decision moved to
   the only thread where it cannot go stale. `cb_ua_free`,
   `cb_ua_alloc` (which frees the previous UA) and `cb_reset_transports`
   refuse with `EBUSY` when the UA holds a call, checked on the loop
   thread against the UA's own call list; the engine leaves the call and
   its registration alone (`registration reset refused by the stack`)
   and, for a refused re-alloc, retries after the call. The Swift-side
   `state` check is gone: one guard, in the right place. Reproduced and
   asserted by `make sim-call-ring-reset` (the reset issued while the
   simulated phone rings; the stack must refuse it and the call must be
   answered as in the plain run).
8. **FIXED 2026-09-27 (libre patch level 7), confirmed on device the same day — SIP
   loop thread spinning at 100 % CPU: a UDP socket iOS defuncted under the
   suspended app, level-triggered and never dropped from the poll set
   (first seen 2026-09-12; spin contained the same day).** Report
   `Dialler.cpu_resource_fatal-2026-09-12-141400.ips` (iOS 26.6.2, the
   Phase C build): iOS killed the app after 48 s at 99 % CPU while in the
   background ("Non-Frontmost App"). Heaviest stack: the engine's loop
   thread → libre `re_main` → a kernel syscall, in a loop; 2 of 16 samples
   inside malloc from the same loop (the warning formatter). Reading:
   `fd_poll` was failing with `EBADF` — libre's Darwin "workaround"
   (`if (EBADF == err) continue;`) then retries forever without running
   timers or sleeping. `kevent` returns EBADF only when the kqueue
   descriptor itself is invalid. Consequences seen the same day: the
   shim's "loop died → rebuild" recovery could not fire (`re_main` never
   returned), every engine call from the app waited its 10 s timeout, the
   UI froze ("app won't even start" on a relaunch that hit the same
   state), and the server saw the app's registration go stale and a
   phone → app INVITE die on it (17:14 log; the stale-route case is
   closed since 2026-09-13 by the mid-ring re-target, §2). *Contained:*
   `ios/vendor/patches/apply-re.sh` bounds the retry (8 × 10 ms, with a
   warning naming `kqfd`/`nfds`) and returns EBADF; the loop thread marks
   itself dead and the engine rebuilds the stack. *Unknown:* what
   invalidated the kqueue descriptor. Two hypotheses, distinguishable by
   the new warning's `kqfd` value: (a) `kqfd=-1` — libre's own context
   was torn down under the running loop (`poll_close` via
   `re_thread_close`/`libre_close` on the loop thread from inside a
   handler, or the tss destructor); look at every `libre_close`/`stack_close`
   call site in `cbaresip.c` and at anything calling libre from a thread
   other than the loop; (b) `kqfd>=0` — some other code closed a
   descriptor number it did not own (a double `close()` — CoreAudio /
   audiounit teardown, Network.framework, or a baresip socket closed
   twice after a transport reset) and the kqueue's number was hit; look
   for the previous owner of that number in the console around the
   warning. Timing clue: the report started 114 s after the device woke
   and while the app was backgrounded, i.e. right after the wake/transport
   reset path (`resetRegistration` → `cb_reset_transports` →
   `uag_reset_transp`) ran. *Next time:* collect (1) the `Dialler…ips`
   from Analytics Data, (2) the app log / console lines containing
   `fd_poll EBADF` (the `kqfd` value decides between (a) and (b)) and
   `re_main returned` from the shim, (3) the server log around the same
   minute (a stale registration dialled, `context canceled`), (4) whether
   the app had just come back from a lock/unlock or a call end. With a
   symbolicated stack (keep the build's dSYM this time — the 42689BEC…
   image in the report could not be symbolicated because Xcode had
   already rebuilt), the frame above `re_main` names the caller.
   *Second episode, 2026-09-13 00:35–00:40 (with the diagnostics
   pipeline in place):* two normal calls, `app: will resign active`, then
   the process's gateway socket closed two minutes later with no log line;
   the launches that followed wrote nothing at all — not even the app's
   first log line — until the phone was rebooted. So those launches hung
   before the app's own code ran, in a startup step that talks to a
   system daemon (CallKit provider registration, the audio session, the
   Local Push manager, or the SIP stack's audio unit), and a wedged daemon
   is the common factor with the loop spin. No MetricKit report had
   arrived by the next launch. Added: launch breadcrumbs around each of
   those steps (`Breadcrumb.drop`, in the uploaded log), a 20 s bound on
   the SIP stack start (`cb_start` returns ETIMEDOUT instead of freezing
   the app), and `active=` (NEAppPushManager.isActive) in the Local Push
   line — the extension had not connected all evening, which is why the
   incoming call at 00:37 found "callee offline, wake undeliverable".
   Next time: the last `launch:` breadcrumb in `data/diag/` names the
   hanging step; an Analytics `.ips` with `0x8badf00d` (launch watchdog)
   would show the blocked call directly.
   *Third episode, 2026-09-18 08:45 (MetricKit
   `20260918T064557.700Z-metrickit.json`, symbolicated):* the same
   signature — iOS CPU-resource kill, 48 s of CPU in the 49 s window, all
   16 samples on the loop thread: 14 in kernel calls under `re_main`
   (`kevent` returning at once), 2 in `udp_read_handler → mbuf_alloc`.
   This time mid-call, in the background (the call had been answered from
   the lock screen and audio was flowing normally throughout — the loop
   still served packets while it spun). Not the EBADF path: the level-1
   guard would have logged `fd_poll EBADF` and ended the loop, and nothing
   of the kind is in the log. The one flush in that run was at 08:44:25,
   on a socket iOS had aborted (`tls: SSL_write: 5` right before it) —
   the first day the libre patch level 3 (close-before-flush) was on the
   device, which made it the obvious suspect; but this item predates
   level 3 by a week with the identical stack, the simulator shows no
   spin after flushing live or dead connections (engine CPU meter in
   `sim-call`), and closing a connection from outside a TCP event is what
   libre's own idle timeout does. Level 3 stays. What the samples say
   without saying which descriptor: a level-triggered readiness nobody
   drains. *Added:* the engine watchdog now samples the loop thread's CPU
   (`thread_info`) every 500 ms and, at ≥80 % for 5 s, prints the loop's
   own backtrace to the app log (`LOOP THREAD BUSY`, at most once a
   minute) — the same SIGUSR1 dump a stall gets. *Next time:* that
   backtrace names the handler and, through it, the descriptor; collect
   it with the server log for the same minute. Also seen in that call
   and separate from the spin: the garbled audio, which is item 11.
   *Fourth episode, 2026-09-20 10:24 (MetricKit
   `20260920T082439.221Z-metrickit.json`):* the same signature again —
   48 s of CPU in a 49 s window, 13/16 samples in `kevent` under
   `re_main`, 2 in `udp_read_handler → mbuf_alloc`, audio flowing
   throughout; mid-call (`35a1f0fa`, a call with three PBX-side
   hold/resume rebases), beginning ~12 s after the wake's transport reset
   and ~3 s after the first rebase — the previous episode was also a
   PBX-hold call. iOS killed the process; the app relaunched. The busy
   watchdog almost certainly fired (49 s ≫ its 5 s) and its dump was
   lost: `stall_dump`/`wd_say` write to `stderr`, and nothing routed
   `stderr` into the uploaded log — the one artefact that names the
   spinning handler went to a descriptor nobody read. Two changes, both
   principled, neither a bandaid: (1) `FileLog` now `dup2`s its file onto
   `stderr` on every open, so watchdog dumps, libre warnings and Swift
   runtime output land in `data/diag/`; (2) libre patch level 4 —
   `fd_poll()` dispatched an event only `if (fhs && fhs->fh)` and
   otherwise *ignored* it while the registration stayed, and kqueue is
   level-triggered, so `kevent()` returned that descriptor at once on
   every call: exactly "readiness nobody drains". A registered descriptor
   with no handler is a leak by definition (`fd_close` clears both
   together); the patch drops it from the kqueue where seen and warns
   with its number. A self-heal (cancel the loop after N s of saturation
   and rebuild the stack) was considered and rejected as masking the
   cause. *Next time:* the `LOOP THREAD BUSY` backtrace and any
   `fd_poll: fd N ready … with no handler` line are in the app log.
   *Fifth and sixth episodes, 2026-09-27 12:49 and 12:56, and the root
   cause:* `Dialler.cpu_resource_fatal-2026-09-27-124907.ips` and
   `…-125627.ips`, both 48 s of CPU in 49 s, both exactly 48 s into an
   incoming call answered from the lock screen (the background CPU budget
   is 80 % over 60 s; a foreground spin is never killed, which is why the
   kills are always mid-call with the screen off). Heaviest stack both
   times: `loop_thread → re_main → udp_read_handler → mbuf_alloc /
   mem_deref`, i.e. a full read cycle per loop iteration with no receive
   handler ever reached: recvfrom failing. The discriminator was in the
   day's 13 app logs: every run that spun (`LOOP THREAD BUSY`) had been
   suspended first (`did not run for N ms`), and no run that had not been
   suspended ever spun — 13/13. Mechanism: iOS defuncts a suspended app's
   sockets; a defunct socket fails every read at once with ENOTCONN (the
   `Socket is not connected [57]` the TLS socket logs on each resume) and
   kqueue, level-triggered, reports it readable on every call. libre's
   `udp_read()` returned on the error and left the descriptor registered,
   so the loop never blocked again — the UDP twin of the TCP case fixed as
   patch level 6 on 09-25. Which socket: the SIP UDP transport is destroyed
   and re-created by `uag_reset_transp` on every resume, so not that; the
   DNS client's two sockets (`dnsc_alloc`, no error handler, never
   re-created) live for the life of the stack, and are the ones. *Fixed:*
   libre patch level 7 (`ios/vendor/patches/apply-re.sh`, README) —
   `udp_read()` treats ENOTCONN/EBADF/ENOTSOCK/EPIPE as the end of the
   descriptor, drops it from the poll set before telling the owner, and
   warns with its number (`Dialler: udp fd N dead (…); dropping it from the
   poll set`); a streak of 64 transient errors is announced once so an
   unknown permanent errno names itself; the DNS client installs error
   handlers and reopens a socket that died (`Dialler: dns client socket …
   reopened`), so resolution outlives a suspension. *Pinned:* `make
   re-udp-dead-probe` (a pipe with no writer dup2'd over a UDP socket's
   descriptor — the sandbox refuses bind and SO_DEFUNCTIT — readable for
   ever, ENOTSOCK for ever): level 6 burns 0.999 s of CPU per second and
   calls the error handler 2.4 million times; level 7 uses 0.000 s and
   calls it once. *Device confirmation still owed:* engine start line says
   `libre patch level 7`; after a lock of ≥ 5 min, the first resume logs the
   two lines above and no `LOOP THREAD BUSY`; a call answered from the lock
   screen runs past 60 s without `cpu_resource_fatal`. *Confirmed on
   device 2026-09-27 13:50–14:08 (diag uploads 115414 and 120839):* three
   resumes from suspension (62 s, 45 s, 494 s), each logging both DNS
   sockets dead with ENOTCONN and reopened within 1 ms, then three calls
   answered from the lock screen of 2:23, 0:40 and 4:09 — zero `LOOP
   THREAD BUSY` in 24 minutes of runs on level 7 against one per call on
   level 6, and no kill. Not the same as
   issue 6 (the Foundation string matching on the same thread), which
   stays open on its own merits. The MetricKit CPU exception from 12:29
   (144 s) is this too.
9. **CLOSED — "app silent after a wake, then launches that hang and cannot
   be killed" (2026-09-13 06:13 SAST; same shape as the 00:37 episode and
   the 2026-09-12 "restart needed a reboot"): the app was running under
   Xcode's debugger.** The device log archive settled it: the process
   carried `debug:asserted` from the start and `debugserver` held the
   adjacent pid (1228/1229, a Wi-Fi debug session). At 06:13:08 the
   extension's wake reached the system, callservicesd launched the app
   to deliver it (`Successfully launched application`), SpringBoard
   forwarded the scene event with a 30 s watchdog — and the process never
   ran a thread: watchdogd reported "Impacted by suspension of Dialler",
   "Best option is process being debugged". A debuggee stopped by lldb
   (breakpoint, signal, EXC_RESOURCE — a CPU-limit exception goes to the
   debugger first, which is what the 2026-09-12 loop spin would have
   produced under Xcode) has its task suspended: its main thread cannot
   take the PushKit delivery, so callservicesd killed it at 06:13:16 with
   0xBAADCA11 — `terminate_with_reason() success`, yet a suspended task
   does not exit until it is resumed, so pid 1228 stayed. The user's tap
   at 06:13:29 foregrounded the frozen process (FrontBoard: "Ignoring
   watchdog … process is being debugged", "Not terminating … process is
   being debugged"); two swipe-kills at 06:13:44 and 06:13:57 were
   accepted and never completed ("Still waiting on exit context after
   19.1 seconds"). The process finally disappeared at 06:36:36, the
   moment debugserver 1229 exited (its connection to the Mac reset).
   Nothing of ours could log any of this, and no crash report is written
   for a debugged process, which is why every launch "left no trace".
   *Not determined:* what stopped the debuggee at ~06:12; Xcode's debug
   console at the time would have said (an EXC_RESOURCE from the loop
   spin, item 8, is the one candidate with prior evidence — the build's
   patch level, now printed by `cb_version()`, will say whether the guard
   was present). *Rule for field testing:* never leave a device run under
   the debugger. Install with Xcode, stop, launch from the home screen,
   or untick "Debug executable" in the scheme's Run action; a debugged
   app cannot be woken by CallKit once stopped and cannot be killed
   without a reboot or a dead debug link. *Checklist item:* a log
   archive's `debug:asserted` on the app's process state, or FrontBoard's
   "process is being debugged", ends the investigation before it starts.
   Seen beside it on every wake, successful ones included:
   nesessionmanager "failed to report incoming call to CallKit … Code=4099
   com.apple.callkit.networkextension.messagecontrollerhost was
   invalidated" — callservicesd still launches the app; treated as noise.

10. **CLOSED — "a ringing call dies after a few seconds with `Connection
    reset by peer [54]`" (2026-09-14, 10:43 and 10:52) was NOT a fault.**
    libre answers a received BYE with 200 OK and then terminates the
    session with `ECONNRESET` (`re/src/sipsess/listen.c` `bye_handler`;
    `accept.c` does the same for a CANCEL), which baresip renders through
    `strerror` as "Connection reset by peer". It is the ordinary far-end
    hangup wearing the name of a network failure, and the evidence was in
    the same logs all along: the extension recorded `wake cancelled …
    caller_hangup` in the same tenth of a second, and on 2026-09-15 the
    server logged `call ended` for both calls with no error at all while
    the app's SIP connection stayed up for another ten seconds. Two days
    were spent chasing it. `BaresipCallEngine.closeReason` now translates
    both misleading strings ("far end hung up (BYE)", "hung up here") and
    keeps the raw text in brackets; `StackConfigTests` pins it. **The
    investigation did turn up one real defect,** fixed 2026-09-15 and
    worth keeping on its own merits: the app is
    backgrounded whenever iOS puts its own call screen in front, which it
    does for every second incoming call, and the background handler set
    the gateway session inactive unconditionally — cancelling the
    reconnect `holdSessionWhileCallTracked` had just requested. The server
    marked the device offline within a fraction of a second of the app
    resigning active, and the wake and the caller's hangup both had to go
    through the push extension. It is the same class as the ring-after-
    hangup bug the hold was added to prevent, so the session is now held
    while any call is tracked. A gateway drop also logged nothing at all,
    leaving such an incident legible only from the server's side; it now
    logs the reason, the tracked call count and the app state.
    **Lesson for the next incident:** align the app log against
    `data/logs/dev-server.log` by *events*, never by timestamps — the
    phone's clock ran 37 s ahead of the Mac's on 2026-09-15, enough to
    invert the apparent order of cause and effect.
11. **FIXED 2026-09-18 — garbled audio, then silence, after the PBX
    phone's own hold/resume (08:45; reproduced 18:31).** 101, on a call
    with the app, put it on hold (call waiting on the desk phone) and
    resumed. Across the resume the trunk leg's RTP timeline went **31 s
    backwards in one step, within the same SSRC, with packets still
    arriving every 20 ms** (server relay: `skew_ms` stepping to 31267 and
    staying, `read_2s=100` throughout). The relay only re-based a stream
    on an SSRC change or after its own hold music (`pump.forward`,
    `newStream`), so it forwarded the step verbatim. On the app, baresip's
    `timestamp_wrap` accepts a step that size as a normal timestamp
    (`wrap=0`), the jitter buffer is sequence-ordered and unaffected (its
    counters stayed clean), but the playout buffer `aubuf` is **ordered
    by timestamp**: every frame after the step sorted behind what had
    already been played and was dropped as old — `RENDERING SILENCE` for
    the rest of the call. The 18:31 repeat had two smaller steps (4.7 s
    and 5.5 s); the adaptive buffer reset its time base and audio came
    back with audible gaps. Legal per RFC 3550 for a sender, but a B2BUA
    that normalises every other discontinuity must normalise this one.
    *Fix:* in `forward`, within one SSRC the source's timestamps are
    trusted only while they advance with the packets' arrival; when the
    two disagree by more than `pumpTimelineBreak` (2 s) between one
    packet and the next — a timestamp jumping ahead or back, or freezing
    while packets keep coming — the packet starts a new stream: re-based
    one frame on from what we last sent, marker bit set, so the far end
    sees one monotonic stream as it already does across hold music and
    transfers. The rule is asymmetric: forward and frozen deviations
    need the 2 s limit (to stay clear of bursts and stalls), but a
    timestamp that goes **back** while the sequence number goes forward
    is never legitimate within one SSRC (a reordered packet moves both
    back together) and re-bases at any size beyond a frame — even a
    short step back costs the far end the same drop for its length. An
    honest gap (no packets, then timestamps that account for the time)
    keeps arrival and timeline together and passes untouched. Assumes
    the source's RTP clock is the destination codec's, true while the
    relay forwards payloads verbatim; a transcoding path would have to
    measure in the source clock. Each rebase is logged (`relay: source timeline broke
    within one SSRC; rebased onto ours`, with `jump_ms`). Same code path
    both directions, so a break from the app side is covered too.
    `TestRelayRebasesATimelineThatBreaksWithinOneSSRC` drives the five
    shapes (31 s back, 60 ms back, 31 s ahead, frozen, honest gap);
    `make harness-pbx-hold` has the docker desk phone hold and resume
    and asserts the app still hears it (docker Asterisk keeps the
    timeline continuous, so that guards the outcome, not the rebase).
12. **FIXED 2026-09-19 — outbound trunk calls stall on a silently dead
    pooled connection after a network blip (13:09).** The server keeps
    its TCP/TLS connection to the PBX pooled and reuses it for every
    outbound INVITE. After the Mac had been unreachable for ~2 min, that
    socket was still open here but delivering nothing: two app→101 calls
    sat on it to Timer B (32 s), and Asterisk's `100/180/486` for both
    arrived in one burst 60 s later — the INVITEs had finally got through
    and rang the desk phone after the callers had gone. Inbound calls
    were unaffected (the PBX opens its own connections). A failed call
    does not clear it: sipgo's transaction timeout only drops a
    reference, the pooled connection stays, and every outbound call
    reuses it until TCP itself gives up — retransmit backoff (~60 s on
    macOS, up to 120 s on Linux) or keepalive (~2½ min on a silent peer).
    Not a laptop artefact: any silent path loss on either side (switch
    blip, PBX power loss, firewall state) does it in production too.
    *Fix (server only, `bridge`):* for a trunk callee over TCP/TLS, no
    response at all — not even 100 Trying, which a live PBX sends within
    milliseconds — within `trunkResponseTimeout` (3 s) proves the
    connection defunct: the INVITE is dropped (forced cancel; a CANCEL
    would go down the same dead socket), the pooled connection is closed
    (`dropTrunkConnection`, which also discards the unsent INVITE — no
    late ghost ring), and `serveDialog` redials once on a fresh
    connection; a second failure answers the caller 480. UDP is left to
    its own retransmissions and Timer B. Transfers dial the trunk through
    their own path and are not watched (a dead connection evicted by any
    call helps them too). That watchdog alone still costs the first call
    after a blip its 3 s, so the second half is the OPTIONS qualify every
    PBX runs against its peers (`qualify.go`, `-trunk-qualify`, default
    10 s, 0 = off): an OPTIONS every interval over the pooled connection
    itself (sipgo pools by destination; sent out of the trunk transport
    via a vendored `Diago.Client(id)`), and one unanswered for the same
    3 s drops the connection — so it is gone before anyone dials and the
    next call dials fresh and rings at once. A silent death can only be
    found by probing or by trying, so the interval is the window in which
    a call can still fall to the watchdog (≤ 13 s after the socket died);
    during an outage every probe fails and evicts, so when the path comes
    back nothing stale is left. Nothing is needed on the PBX: Asterisk and
    CUCM answer inbound OPTIONS for a known peer. *Test:*
    `make harness-trunk-stall` — TLS trunk; phase A with the qualify off:
    warm call, then a `tc` filter in the server's namespace black-holes
    its packets to the PBX, and the next call must be answered within
    seconds with the dead connection logged, dropped and redialled, then
    bridge afresh once the hole is lifted; phase B with the qualify on:
    with nobody dialling, the qualify alone must log and drop the dead
    connection within one interval, and the call placed right after the
    hole is lifted must bridge within seconds with no watchdog line.
    Unit: `qualify_test.go` (drops on timeout and on a send error, on
    every probe while dead, never while answering).
13. **OPEN — inbound audio to the app dies after the PBX phone's own
    hold/resume on an app-originated call (2026-09-20 10:22, call
    `968c465d`, app 201 → 101 over the TLS+SDES trunk).** What the
    server relay saw on the trunk leg (`callee→caller`, Asterisk → us),
    two-second counters: 100/2 s until 10:22:19; at 10:22:20 101 held —
    60 in that window, then **0**: Asterisk sent nothing during the hold
    (no MOH on that PBX) and no SIP at all (a desk phone's hold is not
    propagated to the trunk, as item "Focus/DND rings through" §6 notes
    for the other direction); at 10:22:38–40, 101 resumed — Asterisk sent
    **74 packets (≈1.5 s)** — then **0 again until the hangup** at
    10:22:49. Our audio *to* Asterisk flowed throughout
    (`caller→callee written_2s=100, write_errs=0`); the app decoded
    exactly what arrived (its `rx` counter rises with those 74 packets
    and stops with them). Also in that window, twice, the app held and
    resumed from its own side (10:21:54, 10:22:33) — the server plays
    music to 101 for that without signalling the trunk, so Asterisk did
    not see those either. Ruled out on our side: diago's RTP source lock
    (off — any source is read), SRTP decrypt failures (they return an
    error that ends the pump with `RELAY STOPPED`; the reader stayed
    alive and simply received nothing), the timeline re-base (item 11;
    it never fired here). *Not reproduced:* `TRUNK_TLS=1 TRUNK_SRTP=sdes
    DIALPARK_SIP_TRACE=true make harness-pbx-hold` — docker Asterisk keeps
    RTP flowing straight through the desk phone's hold/resume and audio
    after the resume passes. So it is specific to the LAN PBX or the 101
    phone's unhold: Asterisk stopped sending to us 1.5 s after the resume
    (or sent elsewhere), which our logs cannot see. Two artefacts of the
    same call worth noting: `RTP session RTCP writer stopped with error:
    write udp … i/o timeout` on the *app* leg exactly 5 s after each app
    resume — *fixed the same day*: diago's `RTPSession.close` stamped a
    past deadline on both sides of the RTCP socket to unblock its reader,
    but a re-INVITE keeps that socket for the replacement fork, whose
    writer then failed at its first 5 s tick and stopped for the call;
    now read side only (`server/vendor/PATCHES.md`); RTP was never
    affected — and the CPU spin of item 8 in the *next* call. *Next time, on one
    repro (app → 101, 101 holds ~10 s, resumes):* on the Pi
    `asterisk -rvvv` with `rtp set debug on` and `pjsip set logger on`;
    on the Mac `tcpdump -i en0 host 10.18.0.5 and udp`; server with
    `DEV_SERVER_FLAGS="-log-level debug -sip-trace"`. Together those show
    whether Asterisk emits RTP after the resume, to which port and SSRC,
    with what crypto, and whether the phone's own stream stopped. The fix
    is then either a PBX setting on the trunk endpoint (`moh_passthrough`,
    `rtp_symmetric`, MOH class) or a specific re-INVITE/SSRC handling in
    diago — different work, so nothing is changed until that is seen.
14. **An unauthenticated write on the LAN-exposed server (planned, §4.8).**
    `POST /v1/enrol` is the first route that writes without a credential:
    a claimed code rotates a device's token. Mitigations are part of the
    design — a single-use eight-character code that expires in fifteen
    minutes, stored hashed, compared in constant time, a fixed delay on a
    miss and five attempts a minute per source address — and every other
    admin verb stays behind the admin token, on a separate process.
    Residual: someone on the LAN who sees the QR before the phone does;
    the expiry and single use bound it, and the operator sees the device
    come online under the wrong address in `dialpark-admin`. Validate the
    rate limit and the "other devices untouched" property in the
    `ServeHTTP` tests before the route ships.
15. **Licence circumvention (accepted residual, §4.9).** The server binary
    and its data directory are the customer's: a patched binary can
    over-enrol, and a copied data directory runs a second server under one
    licence, which no offline scheme prevents. Expiry and authenticity are
    enforced on the phone, where the customer cannot patch; seats on the
    server. Made visible rather than impossible: the victim's name on the
    thief's admin pages, the vendor's register, and later the one-off
    application check-in. Revisit if a customer base makes it worth more.

Retired to §6 "Much later" with their features: Wi-Fi → cellular handoff on
the SIP leg, and public-edge exposure to internet scanners.
