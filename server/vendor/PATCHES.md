# Local changes to vendored modules

The server vendors its dependencies (`go mod vendor` is not run in the
sandbox; the module proxy is unreachable). The files below differ from the
upstream release named in `modules.txt`; re-apply when bumping.

## github.com/emiago/diago v0.32.0

- `dialog_client_session.go`: `func (d *DialogClientSession) SetCodecs([]media.Codec)`
  — per-dialog codec offer for an outgoing leg. Used by `internal/b2bua` to
  offer only G.711 towards the PBX trunk, so the raw relay never needs to
  transcode (the app leg is answered with the codec the trunk leg took).
- `media/sdp/utils.go` + `media/media_session.go`: the Opus `a=fmtp:96`
  line comes from `sdp.OpusFmtp` instead of a fixed `useinbandfec=0`.
  Upstream's value told every phone's encoder to disable in-band FEC
  (baresip configures its encoder from the peer's fmtp), so no app leg
  carried FEC and every lost packet was an audible gap. Ours asks for FEC,
  mono and 32 kbit/s (2026-09-12, audio-quality plan Phase A; measured on
  the impaired echo path).
- `media/codec.go`, `media/sdp/formats.go`, `media/media_session.go`,
  `media/sdp/utils.go`: G.722 (`CodecAudioG722`, static PT 9, RTP clock
  8000 per RFC 3551 though the audio is 16 kHz) is known to the codec
  table, parsed from an offer with or without its rtpmap, and emitted as
  `a=rtpmap:9 G722/8000`. The server only offers, matches and relays it
  (plan Phase C, wideband on PBX calls without transcoding).
- `media/media_session.go` (`MediaSession.SetCodecs`), `dialog_media.go`
  (`DialogMedia.SetCodecs`, `applyReInviteAnswer`),
  `dialog_client_session.go` + `dialog_server_session.go` (`ReInvite` applies
  the answer's SDP): a re-INVITE can move an established leg onto another
  codec. Upstream's ReInvite re-sent the current SDP and ignored the
  answer's body (fine for hold, not for a codec change). The B2BUA uses it
  when a transfer target answers with a codec the remaining leg does not
  have — an app on Opus transferred to the PBX — instead of failing the
  transfer with 488 (plan Phase C).
- `dialog_client_session.go` (`invite`, originator handling): the callee
  is offered every audio codec common to the originator and the dialog
  (originator order), not only the first one. Upstream's single-codec
  offer gave the far end no fallback: with G.722 preferred, a G.711-only
  PBX was offered G.722 alone and the call failed ("no supported codecs
  found", user's Asterisk, 2026-09-12). Both legs still end on one common
  codec — the caller is answered with whatever the callee took.
- `media/rtp_packet_writer.go`: `RTPPacketWriter.WriteSamplesSeq` — like
  `WriteSamples` with the sequence number chosen by the caller (and the
  writer's sequencer moved to it). The relay rebases the source's sequence
  numbers onto its own instead of renumbering every packet, so upstream
  loss and reordering reach the far end's jitter buffer and concealment
  (plan Phase D; before, a lost packet became a silent hole in a
  seamlessly numbered stream that no decoder could conceal).
- `media/media_session.go` (`NegotiatedMode`) — exposes the direction a
  session settled on (`s.mode`, which the reader and writer already gate on
  but nothing could read). Hold has no signal of its own: the app offers
  `sendonly`, we answer `recvonly`, and that negotiated direction is how the
  B2BUA knows to start hold music toward the other leg (plan Phase K,
  SPEC §4.4 rule 8b).
- `media/media_session.go` (`media.ListenConfig`) — QoS: RTP/RTCP sockets
  are opened through a package-level `net.ListenConfig` so the B2BUA can
  mark them DSCP EF from its Control hook (plan Phase E; std lib only).

- `media/media_session.go` (`OriginatorCodecs`, `SecureRTPActive`) and
  `dialog_client_session.go` (`invite`, originator handling) — SRTP on the
  app leg (plan Phase F): the originator's SDP is applied to the callee's
  session for codec filtering only. Upstream ran it through `RemoteSDP`,
  which also took the originator's address, direction and SDES key: an app
  caller on RTP/SAVP made a plain trunk callee fail ("remote requested
  secure RTP, but no context is created") and planted the caller's key as
  the callee's remote context. `SecureRTPActive` is what the B2BUA logs per
  leg (`caller_srtp`/`callee_srtp`).
- `media/media_session.go` (`Fork`, `LocalSDP`, `RemoteSDP`) — SRTP across
  re-INVITEs: `Fork` (the session after any re-INVITE: hold, a codec
  change, the peer's own re-INVITE) now carries the SRTP configuration,
  both contexts and the key material; upstream dropped them, so the forked
  session refused the peer's RTP/SAVP answer ("remote requested secure RTP,
  but no context is created" — the transfer-to-trunk codec change failed).
  `LocalSDP` re-offers the session's existing local key instead of
  generating a new one per call, and `RemoteSDP` keeps the remote context
  when the peer's inline key is unchanged: SRTP contexts hold the rollover
  counter, and a fresh context on an unchanged key fails after the first
  sequence wrap (~22 min of audio).

- `diago.go` (`transportForRequest`, used by `OnInvite`) — an inbound INVITE
  is matched to the transport it arrived on, by the port, instead of to the
  first transport with the same protocol name. Upstream's `getTransport`
  takes only the protocol (its own comment: "What if multiple server
  transports?"), which is fine until two listeners share one — a TLS app
  leg and a TLS trunk (SPEC §6 item 3b). Every app INVITE then picked up
  the trunk's settings: `MediaSRTP` 0, so the server answered an app's
  RTP/SAVP offer with no crypto context ("remote requested secure RTP, but
  no context is created") and every app-originated call failed the moment
  a TLS trunk was configured. Needs `sip.Message.ReceivedOn` below. Covers
  `OnInvite`, which is the only inbound path that resolves a transport; the
  three remaining `getTransport` callers are outbound (`InviteBridge`,
  `RegisterTransaction`, `ReferTransaction.Accept`) and carry the same
  latent ambiguity, but none is on our call path.
- `dialog_session.go` (`dialogReferInvite`) — the dialog diago builds for an
  incoming REFER uses the transport the REFER arrived on when the Refer-To
  URI names none, instead of falling through to UDP. On a stack with no UDP
  transport at all (TLS app leg + TLS trunk) `NewDialog` then failed with
  "transport does not exists" *before* `OnRefer` was called: the REFER was
  answered 202 and nothing else happened, so a blind transfer silently did
  nothing. The B2BUA routes the target itself and only reads the Refer-To
  off this dialog, but it has to be reached to do so.
- `dialog_server_session.go` (`AnswerOptions`, `answerLateSession`,
  `AnswerLate`, `ReadAck`) — delayed offer (RFC 3261 §13.2.1): an INVITE
  with no body is answered with our offer in the 200 OK and the answer is
  taken from the ACK. Upstream's `AnswerOptions` refused it ("no sdp
  present in INVITE"); its `AnswerLate` carried none of the options
  (codecs, RTPNAT, the REFER and media callbacks) and never checked that
  an answer arrived; and `ReadAck` swallowed a `Finalize` error, leaving a
  confirmed dialog with no media. CUCM sends a delayed offer to every
  third-party SIP line (SPEC §6 item 3c, bench 2026-10-17). The B2BUA
  offers the callee's codec first and the rest of the PBX set behind it,
  and re-INVITEs the callee when the exchange picks one of the others.

- `media/media_session.go` (`updateRemoteCodecs`, `sameCodecKind`) — codec
  identity for negotiation is name, clock rate and channels, not the
  payload type, and the negotiated list carries the REMOTE's codec with
  the number it chose. Upstream compared whole structs: CUCM answers an
  Opus offered at 96 with Opus at 114, which matched nothing, so the
  session fell back to its own first codec and the relay sent the phone
  Opus marked 96 — silence from the app to the phone while the phone's
  own 114 was rewritten to 96 for the app and worked (lines bench
  2026-10-17 13:24).
- `media/rtp_session.go` (`WriteRTP`) — the sender-report clock is looked
  up in the negotiated codec list first, then ours, and falls back to the
  session's audio codec instead of returning an error for a payload type
  it does not know. The packet had already been written when upstream
  returned that error, and the relay read it as a failed write and
  stopped the stream — the other half of the 114 case above. `ReadRTP`
  likewise: a received payload type is looked up in the negotiated list
  first, and one in neither list is accounted under the session's audio
  codec and passed on; upstream dropped every such packet with a warning.

- `dialog_media.go` (`handleMediaUpdate`, `applyLateReInviteAnswerUnsafe`,
  `pendingReOffer`), `dialog_server_session.go` (`ReadAck`),
  `dialog_client_session.go` (`handleReInviteACK`) — a re-INVITE with no
  SDP asks us for the offer, and that offer states OUR direction: it comes
  from a fresh fork (no negotiated direction, a new SDP version), and the
  ACK's answer is applied to that fork and swapped in as a media update,
  with the application told. Upstream answered a bodiless re-INVITE with
  the current session's SDP, whose direction was the one last negotiated:
  after CUCM's hold (inactive) its resume — a bodiless re-INVITE — got
  inactive back and the call never came back (lines bench 2026-10-17
  14:07). `make harness-cucm-hold`.

## github.com/emiago/sipgo

- `dialog_client.go` (`inviteCancel`) — cancelling an INVITE watches the
  INVITE's own responses while the CANCEL is out, and bounds the CANCEL's
  wait (64*T1). Upstream sent the CANCEL and blocked on its response with
  `context.Background()`, only then reading the INVITE's responses. A
  callee whose own final response crosses the CANCEL — an app declining
  from its UI sends 486 as the server, told of the decline, cancels — and
  which never answers the CANCEL (the iPhone app, suspended by iOS a few
  seconds after declining) left the caller ringing until the callee's
  connection died (9.7 s, device 2026-09-17 17:30; the other declines
  that session won the race and took 7 ms). RFC 3261 §9.1: a final
  response settles the INVITE regardless of the CANCEL.
- `server.go` (`sipgo.ListenConfig`, `listenUDP/TCP/TLS`) — QoS: every SIP
  listener is opened through a package-level `net.ListenConfig` so the
  B2BUA can mark them DSCP CS3; accepted connections inherit it.
- `sip/message.go` (`Message.ReceivedOn`/`SetReceivedOn`) and
  `sip/transport_tcp.go` (`parseStream` takes the local address) — records
  the local `host:port` an inbound message was read from. Upstream keeps
  only the source and the protocol, so nothing downstream can tell two
  listeners on the same protocol apart; diago's `transportForRequest` above
  needs it. Deliberately a new field rather than `SetDestination`:
  `dest` is where a message is to be *sent* and the transport layer routes
  on it, so filling it in on receive would have the server answering
  itself. TCP only (TLS embeds it); UDP and WS are untouched and leave it
  empty, which the diago side treats as "fall back to the protocol match".

- `diago.go` (`Diago.Client(transportID)`) — returns the per-transport SIP
  client diago builds for each named transport, so the B2BUA can send a
  request outside any dialog out of a chosen transport (the trunk's
  OPTIONS keep-alive, `internal/b2bua/qualify.go`) with that transport's
  Via, Contact and bind address. Upstream exposes the clients only through
  `NewDialog`/`Invite`/`Register`.
- `media/rtp_session.go` (`RTPSession.close`) — `SetReadDeadline(now)`
  instead of `SetDeadline(now)` on the RTCP socket. The deadline exists to
  unblock the RTCP reader so `MonitorClose` can wait for it; the socket is
  kept open "for a replacement fork" (a re-INVITE forks a new session on
  the same sockets, `mediaUpdateUnsafe`). Stamping the *write* side too
  poisons the fork: its RTCP writer's first tick, 5 s later, fails with
  `i/o timeout` and the writer exits for the rest of the call (`RTP session
  RTCP writer stopped with error`, 5.000 s after every app-leg resume,
  2026-09-20). The reader clears its own read deadline on start; nothing
  ever cleared the write one. UDP writes never block, so the read deadline
  is the whole of what was needed.
