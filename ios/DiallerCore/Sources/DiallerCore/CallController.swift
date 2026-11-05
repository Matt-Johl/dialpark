import DiallerProtocol
import Foundation

/// The system call UI as the controller sees it. Implemented by the CallKit
/// adapter in the app and by a fake in tests (SPEC §7.1 call-UI seam).
public protocol CallUI: AnyObject {
    /// Show an incoming call. Must be fast; on iOS it maps to
    /// `CXProvider.reportNewIncomingCall`.
    func reportIncoming(callID: String, displayName: String, handle: String, completion: @escaping (Error?) -> Void)
    /// A better caller name became known while the call is still ringing
    /// (the wake arrived after the INVITE had already rung it). On iOS it
    /// maps to `CXProvider.reportCall(with:updated:)`. Optional.
    func updateIncoming(callID: String, displayName: String)
    /// Remove a ringing/active call from the system UI.
    func end(callID: String, reason: CallEndReason)
    /// Ask the system to start an outgoing call to `handle` (a number or a
    /// SIP user). The system calls back through `CallController.userStarted`
    /// once it has approved the call (CallKit: CXStartCallAction).
    func startOutgoing(callID: String, handle: String, displayName: String)
    /// The far end is being alerted / has answered our outgoing call.
    func outgoingConnecting(callID: String)
    func outgoingConnected(callID: String)
    /// Play a call-progress tone into the call's audio session, or stop the
    /// one playing when `tone` is nil (plan Phase J). On iOS it is an
    /// `AVAudioPlayer` on the session CallKit already activated for the
    /// call; the controller decides *which* tone and *when*, because that
    /// is SIP, not audio. Optional: the default plays nothing.
    func playTone(_ tone: CallTones.Tone?)
    /// How an outgoing call is progressing, for the app's own in-call
    /// screen — CallKit's UI says "calling" until the call ends, whatever
    /// happened. Optional; the default shows nothing.
    func callProgress(callID: String, _ progress: CallProgress)
    /// Take a held call off hold on the controller's initiative (the call
    /// in progress ended and this is the only one left). On iOS it maps to
    /// a `CXSetHeldCallAction`, so the system performs the resume and calls
    /// back through `CallController.setHeld` like any other hold change.
    func resume(callID: String)
}

public enum CallEndReason: Equatable, Sendable {
    case remoteEnded
    case answeredElsewhere
    case unanswered
    case failed
}

/// What the app would do with the SIP stack once the user answers. Phase 1
/// (signalling + CallKit) logs; the baresip-backed engine plugs in here.
public protocol CallEngine: AnyObject {
    /// An INVITE arrived at the SIP stack. `engineCallID` is the stack's
    /// handle for it (every per-call operation below takes it), `peer` the
    /// caller's URI, `displayName` the From display name if the caller sent
    /// one, and `diallerCallID` the server's call id from the INVITE's
    /// X-Dialler-Call-ID header — the id the same call's wake carries. The
    /// controller decides whether it belongs to a call already ringing
    /// (from a wake) or must ring the system UI itself.
    var onIncomingCall: ((_ engineCallID: String, _ peer: String, _ displayName: String?, _ diallerCallID: String?) -> Void)? { get set }
    /// The SIP call ended (remote hangup, failure); `reason` is free text
    /// and `status` the SIP status that closed it — 0 for a BYE, a local
    /// error, or anything else that carried no response. The controller
    /// picks the failure tone from it (`CallTones.failure(status:)`).
    var onCallEnded: ((_ engineCallID: String, _ reason: String, _ status: Int) -> Void)? { get set }
    /// Our outgoing call is being alerted. `earlyMedia` distinguishes a 183
    /// with SDP — the far end is already sending audio, so the app must not
    /// lay its own ring-back over it — from a plain 180, which carries none.
    var onOutgoingRinging: ((_ engineCallID: String, _ earlyMedia: Bool) -> Void)? { get set }
    var onCallEstablished: ((_ engineCallID: String) -> Void)? { get set }
    /// A transfer we asked for was refused; `reason` is the SIP status. The
    /// call continues.
    var onTransferFailed: ((_ engineCallID: String, _ reason: String) -> Void)? { get set }
    /// The device's enrolment credential, presented as SIP Digest username /
    /// password on the app leg (username = device id, password = token). The
    /// server refuses registrations and calls without it.
    func setCredentials(username: String, password: String)
    /// Which server certificate the SIP leg accepts: the one pinned at
    /// enrolment (base64url SHA-256 of its DER, as `CertificatePin`), else
    /// any certificate when `acceptAnyCertificate` (the dev path), else
    /// none. The gateway connection applies the same rule.
    func setServerTrust(pin: String?, acceptAnyCertificate: Bool)
    /// Register `user` (e.g. "201@dialler") to `sip` and stay registered, so
    /// calls reach this app directly while it runs. Idempotent.
    func register(user: String, sip: SIPTarget)
    /// Drop the current registration and its connection so the next
    /// `register` starts a fresh one: the gateway session came back after a
    /// drop, and the SIP connection died in the same suspension. A no-op
    /// during a call, ringing included.
    func resetRegistration()
    /// Answer the incoming call `engineCallID` (its INVITE has arrived).
    /// Answer the incoming call `engineCallID`, returning whether the 200 OK
    /// actually went out. It can fail: the dialog is bound to the TLS
    /// connection its INVITE arrived on, and after a suspension that
    /// connection can be dead with the stack yet to notice, so the write
    /// fails with EPROTO (2026-09-23). The caller must not leave CallKit
    /// showing a connected call when it does — there is no conversation
    /// behind it and the far end is still ringing.
    @discardableResult
    func answer(engineCallID: String) -> Bool
    /// Refuse the incoming call `engineCallID` with 486 Busy Here, so the
    /// PBX applies its busy rule: a caller the app will not take (call
    /// waiting off, or a third call).
    func reject(engineCallID: String)
    /// Place a call to `target`: a full SIP URI, "user@domain", or a bare
    /// user / number, which the engine completes with the account's domain.
    /// Returns the stack's id for the new call, nil if it could not start.
    @discardableResult
    func dial(callID: String, to target: String) -> String?
    func hangup(engineCallID: String)
    /// One microphone: mute applies to every call.
    func setMuted(_ muted: Bool)
    /// Hold (re-INVITE sendonly, audio stopped) / resume one call.
    func setHeld(engineCallID: String, _ held: Bool)
    /// Blind transfer: ask the server to connect the far end to `target`
    /// and end our call (REFER; the server routes the target like a call).
    func transfer(engineCallID: String, to target: String)
    /// The system audio session became available / was taken away (CallKit
    /// didActivate / didDeactivate, AVAudioSession interruptions). Engines
    /// with their own audio units restart or stop them here.
    func audioSessionActivated()
    func audioSessionDeactivated()
}

public extension CallEngine {
    func setCredentials(username _: String, password _: String) {}
    func setServerTrust(pin _: String?, acceptAnyCertificate _: Bool) {}
    func resetRegistration() {}
    func audioSessionActivated() {}
    func audioSessionDeactivated() {}
    func setMuted(_: Bool) {}
    func setHeld(engineCallID _: String, _: Bool) {}
    func transfer(engineCallID _: String, to _: String) {}
    func reject(engineCallID _: String) {}
}

public extension CallUI {
    func updateIncoming(callID _: String, displayName _: String) {}
    func playTone(_: CallTones.Tone?) {}
    func callProgress(callID _: String, _: CallProgress) {}
}

/// One ringing or active call as the controller tracks it.
public struct TrackedCall: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case ringing, answered, ended }
    public enum Direction: Equatable, Sendable { case incoming, outgoing }
    public var wake: Wake
    public var phase: Phase
    /// The INVITE for this call has reached the SIP stack.
    public var sipArrived: Bool = false
    /// The call really is up: our 200 OK went out (incoming) or the far end
    /// answered ours (outgoing). Distinct from `phase == .answered`, which
    /// only says the user pressed answer — on the wake path CallKit commits
    /// to a call before the SIP stack has one, and the answer itself can
    /// fail to send. A call that was never connected carried no
    /// conversation, whatever ended it.
    public var connected: Bool = false
    /// The caller name last given to the system UI for this call.
    public var reportedName: String = ""
    /// The server's call id from the wake, if one arrived: the id a decline
    /// or busy ack must carry. Nil for a call that rang from the INVITE
    /// alone (synthetic "sip-N" id), which the server never issued a wake
    /// for and would refuse an ack about.
    public var wakeCallID: String? = nil
    public var direction: Direction = .incoming
    /// Outgoing only: what the user asked to call.
    public var target: String = ""
    /// The SIP stack's handle for this call, once its INVITE has arrived
    /// (incoming) or been sent (outgoing). Every engine operation names it.
    public var engineCallID: String? = nil
    /// The server's call id carried by the INVITE (X-Dialler-Call-ID): the
    /// id the same call's wake carries, so wake and INVITE meet exactly.
    public var diallerCallID: String? = nil
    /// The user answered before the INVITE arrived (wake path): answer the
    /// moment it does.
    public var answerWhenInvite: Bool = false
    /// On hold (re-INVITE sendonly). The other call is the active one.
    public var held: Bool = false
    /// When the call started ringing (either direction), for its record.
    public var startedAt: Date = .distantPast
    /// When the conversation began; nil until answered.
    public var connectedAt: Date? = nil
}

/// Turns gateway events into system-call-UI actions and acks, and user UI
/// actions into engine calls. Transport-agnostic: the same controller runs
/// behind the foreground socket, the extension socket, or a PushKit payload.
public final class CallController {
    private let ui: CallUI
    private let engine: CallEngine?
    private let lock = NSLock()
    private var calls: [String: TrackedCall] = [:]
    private var transport: SignalTransport?
    private var account: (user: String, sip: SIPTarget)?
    private var sipCallSeq = 0
    private let now: () -> Date
    private let log: (String) -> Void

    /// Call waiting: a second incoming call rings (CallKit offers Hold &
    /// Accept / End & Accept / Decline) while one is up. Off, a second
    /// caller is refused with 486 at once and hears busy. A third caller is
    /// always refused: `maxCalls` is what CallKit and the SIP stack are
    /// configured for (one active, one held).
    public var callWaitingEnabled = true
    public static let maxCalls = 2

    /// Plan Phase J. A failed outgoing call whose tone is still playing: the
    /// call is out of the table already and only its end report is held
    /// back, so the caller hears busy or congestion before the system UI
    /// takes the call (and its audio session) away. `toneEndSeq` makes the
    /// scheduled report a no-op once anything else has ended the call.
    private var toneEnd: (callID: String, reason: CallEndReason)?
    private var toneEndSeq = 0

    /// The call whose progress tone is playing, if any. Tones are stopped
    /// *by owner*, never blanket: the app has one player and the
    /// call-waiting beep — which belongs to CallKit's view of the calls,
    /// not to this controller — shares it, so a call that never had a tone
    /// must not be able to silence another call's.
    private var toneCall: String?

    /// Runs `work` after `seconds`. A seam, not a setting: tests replace it
    /// so a four-second busy tone does not cost four seconds.
    ///
    /// Its own queue, deliberately. The main queue looked like the obvious
    /// home — the app's CallKit work ends up there anyway — but this
    /// controller also runs where nothing services a main run loop (the
    /// headless `sim-call` tool, where the main thread sits in a wait
    /// loop), and there the held-back end of a failed call never fired at
    /// all: the call stayed on screen until the deadline
    /// (`make sim-call-refused`, which is why that test exists).
    private static let timerQueue = DispatchQueue(label: "dialler.calltone")
    var schedule: (_ seconds: Double, _ work: @escaping () -> Void) -> Void = { seconds, work in
        CallController.timerQueue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    public init(ui: CallUI, engine: CallEngine? = nil, now: @escaping () -> Date = Date.init, log: @escaping (String) -> Void = { _ in }) {
        self.ui = ui
        self.engine = engine
        self.now = now
        self.log = log
        engine?.onIncomingCall = { [weak self] id, peer, name, dialler in self?.handle(sipIncoming: peer, displayName: name, engineCallID: id, diallerCallID: dialler) }
        engine?.onCallEnded = { [weak self] id, reason, status in self?.handle(sipEnded: reason, engineCallID: id, status: status) }
        engine?.onOutgoingRinging = { [weak self] id, early in self?.handle(outgoingRinging: id, earlyMedia: early) }
        engine?.onCallEstablished = { [weak self] id in self?.handle(established: id) }
        engine?.onTransferFailed = { [weak self] _, reason in
            self?.log("transfer refused: \(reason); the call continues")
            self?.onTransferFailed?(reason, CallProgress.forTransferFailure(reason: reason))
        }
    }

    /// The tracked call the stack knows as `engineCallID`.
    private func trackedID(forEngineCallID engineCallID: String) -> String? {
        lock.withLock { calls.first { $0.value.engineCallID == engineCallID }?.key }
    }

    /// The app is told when a transfer it asked for was refused: the far
    /// end's reason verbatim, and the same words the in-call screen uses
    /// for a refused call (nil when the failure carried no SIP status).
    /// Only a transfer refused *before* the target rang gets here — once it
    /// rings the call has been handed over and is no longer ours to report
    /// on (SPEC §4.4 rule 6a).
    public var onTransferFailed: ((_ reason: String, _ progress: CallProgress?) -> Void)?

    /// A call has left the table, with what became of it, for the Recents
    /// list (SPEC §6 item 6). Fired on every exit — answered or not, ended
    /// by either side, refused, expired or never started — exactly once per
    /// call. The app persists it; the headless tools log it.
    public var onCallEnded: ((CallRecord) -> Void)?

    /// Build and emit the record for `c`, tracked as `id`, which `ending`
    /// has just removed from the table.
    private func record(_ c: TrackedCall, id: String, ending: CallRecord.Ending) {
        let direction: CallRecord.Direction = c.direction == .outgoing ? .outgoing : .incoming
        // "The user pressed answer" is not "the call connected": on the wake
        // path CallKit commits before the SIP dialog exists, and the answer
        // itself can fail to send. Either way no conversation happened, so
        // it is a failure — not a completed call whose duration measures how
        // long the user waited in silence, and equally not "missed" or
        // "declined", since they did answer it.
        let outcome: CallRecord.Outcome = c.phase == .answered && !c.connected
            ? .failed
            : CallRecord.outcome(direction: direction, answered: c.connected, ending: ending)
        var party = c.direction == .outgoing ? c.wake.to : c.wake.from
        // The name the banner showed (directory → caller's own → number) is
        // the best one known; keep it where the party carried none.
        if party.displayName?.isEmpty != false, !c.reportedName.isEmpty { party.displayName = c.reportedName }
        let ended = now()
        // The server's id, when the call was tracked under another: a
        // sidecar the extension wrote for the same wake must match it.
        let serverID = c.wakeCallID ?? c.diallerCallID
        let r = CallRecord(id: id, wakeCallID: serverID == id ? nil : serverID, direction: direction, counterpart: party,
                           startedAt: c.startedAt == .distantPast ? ended : c.startedAt, connectedAt: c.connected ? c.connectedAt : nil,
                           endedAt: ended, outcome: outcome)
        log("recents: \(outcome.rawValue) \(direction.rawValue) \(party.uri) \(r.duration.map { CallRecord.durationText($0) } ?? "-")")
        onCallEnded?(r)
    }

    /// Resolves the friendly name to show for an incoming caller. The app
    /// layer sets this to look the caller up in the directory (which it owns);
    /// it is given the caller's URI and any display name the wake carried, and
    /// returns the name to display, or nil to keep the wake's own. Left nil,
    /// the caller's own display name (then the URI's user) is used.
    public var resolveDisplayName: ((_ uri: String, _ provided: String?) -> String?)?

    /// The name shown for a caller, on every ring path: the directory's (via
    /// `resolveDisplayName`), else the caller's own display name, else the
    /// bare number.
    private func callerName(for party: Party) -> String {
        let provided = party.displayName?.isEmpty == false ? party.displayName : nil
        return resolveDisplayName?(party.uri, provided) ?? provided ?? Self.numberPart(of: party.uri)
    }

    /// Blind transfer of an answered call to `target` (number, user or URI).
    /// On success the server ends our call once the target answers.
    public func transfer(callID: String, to target: String) {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let engineID: String? = lock.withLock { calls[callID].flatMap { $0.phase == .answered ? $0.engineCallID : nil } }
        guard let engineID, !t.isEmpty else {
            log("transfer of \(callID) to \(t) ignored: not an answered call")
            return
        }
        log("\(callID): transferring to \(t)")
        engine?.transfer(engineCallID: engineID, to: t)
    }

    // MARK: Outgoing calls

    /// The user wants to call `handle` (number, user, or SIP URI). Returns
    /// the call id; the system UI approves the call and calls back
    /// `userStarted`, which is when the engine dials.
    @discardableResult
    public func startCall(to handle: String, displayName: String? = nil) -> String? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let account = lock.withLock({ self.account }) else {
            log("cannot call \(trimmed): no SIP account yet")
            return nil
        }
        let busy: Bool = lock.withLock { calls.contains { $0.value.phase != .ended } }
        if busy {
            log("cannot call \(trimmed): a call is already in progress")
            return nil
        }
        let id: String = lock.withLock { sipCallSeq += 1; return "out-\(sipCallSeq)" }
        let wake = Wake(callID: id, from: Party(uri: "sip:\(account.user)"), to: Party(displayName: displayName, uri: trimmed),
                        sip: account.sip, expiresAt: now().addingTimeInterval(120))
        lock.withLock { calls[id] = TrackedCall(wake: wake, phase: .ringing, sipArrived: true, direction: .outgoing, target: trimmed, startedAt: now()) }
        log("calling \(trimmed) as \(id)")
        ui.startOutgoing(callID: id, handle: trimmed, displayName: displayName ?? trimmed)
        return id
    }

    /// The system UI approved the outgoing call: dial now.
    public func userStarted(callID: String) {
        guard let call: TrackedCall = lock.withLock({ calls[callID] }), call.direction == .outgoing else { return }
        guard let engine else { return }
        if let engineID = engine.dial(callID: callID, to: call.target) {
            lock.withLock { calls[callID]?.engineCallID = engineID }
        } else {
            lock.withLock { calls[callID] = nil }
            log("call \(callID) to \(call.target) could not be started")
            record(call, id: callID, ending: .failed)
            ui.end(callID: callID, reason: .failed)
        }
    }

    /// The system UI could not start the call (CallKit refused the action).
    public func startFailed(callID: String) {
        let call: TrackedCall? = lock.withLock {
            defer { calls[callID] = nil }
            return calls[callID]
        }
        log("outgoing call \(callID) refused by the system")
        if let call { record(call, id: callID, ending: .failed) }
    }

    public func setMuted(_ muted: Bool) {
        engine?.setMuted(muted)
    }

    /// System UI held / resumed one call (CallKit CXSetHeldCallAction). A
    /// swap is two of these from CallKit: hold the active, resume the held.
    public func setHeld(callID: String, _ held: Bool) {
        let engineID: String? = lock.withLock {
            guard let c = calls[callID], c.phase == .answered, let e = c.engineCallID else { return nil }
            calls[callID]?.held = held
            return e
        }
        guard let engineID else {
            log("hold=\(held) for \(callID) ignored: not an answered call")
            return
        }
        log("\(callID): \(held ? "hold" : "resume")")
        engine?.setHeld(engineCallID: engineID, held)
    }

    private func handle(outgoingRinging engineCallID: String, earlyMedia: Bool) {
        guard let id = trackedID(forEngineCallID: engineCallID) else { return }
        log("\(id): far end \(earlyMedia ? "sending early media" : "ringing")")
        ui.outgoingConnecting(callID: id)
        // Ring-back (plan Phase J). Early media replaces it — and a 183 that
        // follows a 180 stops the tone already playing, which is the usual
        // order when the call reaches a PBX that plays its own. Never over
        // another call: the tone goes into the same ear as the conversation.
        ui.callProgress(callID: id, .ringing)
        if earlyMedia || otherCallInProgress(than: id) {
            stopTone(for: id)
        } else {
            playTone(CallTones.ringback, for: id)
        }
    }

    private func handle(established engineCallID: String) {
        guard let id = trackedID(forEngineCallID: engineCallID) else { return }
        lock.withLock {
            calls[id]?.phase = .answered
            calls[id]?.connectedAt = now()
            calls[id]?.connected = true
        }
        log("\(id): connected")
        stopTone(for: id) // answered: ring-back stops
        ui.outgoingConnected(callID: id)
    }

    /// Another call is up (answered, held or not). Progress tones for a
    /// second call must not be laid over it.
    private func otherCallInProgress(than id: String) -> Bool {
        lock.withLock { calls.contains { $0.key != id && $0.value.phase == .answered } }
    }

    /// Start `tone` on behalf of `id`, which then owns the player.
    private func playTone(_ tone: CallTones.Tone, for id: String) {
        lock.withLock { toneCall = id }
        ui.playTone(tone)
    }

    /// Stop the tone if `id` owns it — or whoever does, for `nil`, when
    /// something has taken over the ear (an answer, a new call ringing).
    private func stopTone(for id: String?) {
        let owned: Bool = lock.withLock {
            guard let owner = toneCall, id == nil || owner == id else { return false }
            toneCall = nil
            return true
        }
        if owned { ui.playTone(nil) }
    }

    public var activeCalls: [TrackedCall] { lock.withLock { Array(calls.values) } }

    /// Binds a transport so acks can be sent back on it.
    public func attach(transport: SignalTransport) {
        lock.withLock { self.transport = transport }
    }

    /// The server told us (in welcome) which SIP user this device is:
    /// register now so calls reach us directly while the app runs.
    public func setAccount(user: String, sip: SIPTarget) {
        lock.withLock { account = (user, sip) }
        log("SIP account \(user) via \(sip.host):\(sip.port); registering")
        engine?.register(user: user, sip: sip)
    }

    // MARK: SIP stack → UI

    /// Whether one more incoming call may ring, given what is tracked.
    /// Caller holds the lock.
    private func admitsAnotherCallLocked() -> Bool {
        let live = calls.values.filter { $0.phase != .ended }.count
        if live == 0 { return true }
        return callWaitingEnabled && live < Self.maxCalls
    }

    /// An INVITE reached the SIP stack. If a wake already rang for this
    /// call, just note it; otherwise ring the system UI from the INVITE —
    /// or refuse it when the app will not take another call.
    public func handle(sipIncoming peer: String, displayName: String? = nil, engineCallID: String, diallerCallID: String? = nil) {
        // Same naming as the wake path (directory → caller's own display name
        // → bare number), so the banner does not depend on which of the two
        // arrives first. The caller's own name is kept on the synthetic wake
        // for the in-call title.
        let from = Party(displayName: displayName?.isEmpty == false ? displayName : nil, uri: peer)
        let name = callerName(for: from)
        // Check-and-insert under ONE lock: the wake (gateway thread) and the
        // INVITE (SIP loop) can land in the same millisecond, and with the
        // check and the insert as separate critical sections both passed
        // their check before either inserted — one call rang twice
        // (2026-09-13 05:52:58, f512… and sip-4 reported 10 ms apart).
        enum Outcome { case merged(String, TrackedCall), created(String), refused, noAccount }
        let outcome: Outcome = lock.withLock {
            // The wake for this call rang first: the INVITE carries the
            // server's id (X-Dialler-Call-ID), which the wake was keyed by.
            // Without the header (a peer that is not our server), the one
            // wake-only ringing call is the match.
            let match: String? = diallerCallID.flatMap { d in
                calls[d] != nil ? d : calls.first { $0.value.wakeCallID == d }?.key
            } ?? {
                let ringing = calls.filter { $0.value.phase == .ringing && $0.value.direction == .incoming && !$0.value.sipArrived }
                return ringing.count == 1 ? ringing.keys.first : nil
            }()
            if let id = match, var c = calls[id] {
                c.sipArrived = true
                c.engineCallID = engineCallID
                c.diallerCallID = diallerCallID
                calls[id] = c
                return .merged(id, c)
            }
            guard let account else { return .noAccount }
            guard admitsAnotherCallLocked() else { return .refused }
            sipCallSeq += 1
            let id = "sip-\(sipCallSeq)"
            let wake = Wake(callID: id, from: from, to: Party(uri: "sip:\(account.user)"),
                            sip: account.sip, expiresAt: now().addingTimeInterval(60))
            calls[id] = TrackedCall(wake: wake, phase: .ringing, sipArrived: true, reportedName: name,
                                    engineCallID: engineCallID, diallerCallID: diallerCallID, startedAt: now())
            return .created(id)
        }
        let id: String
        switch outcome {
        case .merged(let mergedID, let call):
            log("INVITE from \(peer) for call \(mergedID) (already \(call.phase))")
            if call.phase == .answered || call.answerWhenInvite {
                // The user answered on the wake before the INVITE got here.
                lock.withLock { calls[mergedID]?.answerWhenInvite = false }
                answerSIP(callID: mergedID, engineCallID: engineCallID)
            }
            return
        case .refused:
            log("INVITE from \(peer) refused with 486: \(callWaitingEnabled ? "no room for another call" : "call waiting is off")")
            engine?.reject(engineCallID: engineCallID)
            return
        case .noAccount:
            log("INVITE from \(peer) but no SIP account is known; ignoring")
            return
        case .created(let newID):
            id = newID
        }
        log("incoming SIP call \(id) from \(name) (no wake)")
        // A tone still sounding from the last call is not allowed to play
        // over this one (plan Phase J).
        stopFailureTone(forCallID: nil)
        stopTone(for: nil)
        ui.reportIncoming(callID: id, displayName: name, handle: peer) { [weak self] err in
            guard let self, let err else { return }
            self.log("CallKit refused SIP call \(id): \(err)")
            let call: TrackedCall? = self.lock.withLock {
                defer { self.calls[id] = nil }
                return self.calls[id]
            }
            self.engine?.hangup(engineCallID: engineCallID)
            if let call { self.record(call, id: id, ending: .failed) }
        }
    }

    /// A SIP call ended on the far side (or failed).
    public func handle(sipEnded reason: String, engineCallID: String, status: Int = 0) {
        let (ended, call): (String?, TrackedCall?) = lock.withLock {
            guard let (id, c) = calls.first(where: { $0.value.engineCallID == engineCallID }) else { return (nil, nil) }
            calls[id] = nil
            return (id, c)
        }
        guard let ended, let call else { return } // a call we never tracked (e.g. one we refused)
        let wasAnswered = call.phase == .answered, wasOutgoing = call.direction == .outgoing
        log("call \(ended) ended by SIP: \(reason)")
        record(call, id: ended, ending: .sip(status: status))
        stopTone(for: ended) // this call's own ring-back, if it had one
        // Plan Phase J: an outgoing call the far end refused. The caller
        // hears busy or congestion first, as on a desk phone — which means
        // the end cannot be reported yet, because CallKit takes the audio
        // session away with the call and the tone would be cut off. Only
        // for a call of our own that never connected, and only when it is
        // the only one: a tone goes into the same ear as any conversation.
        if !wasAnswered, wasOutgoing, !otherCallInProgress(than: ended), let tone = CallTones.failure(status: status) {
            // The screen keeps saying "Calling…" otherwise, while the
            // earpiece is already playing busy at the user (2026-09-15).
            if let progress = CallProgress.forFailure(status: status) {
                ui.callProgress(callID: ended, progress)
            }
            endAfterTone(ended, tone: tone, status: status)
            return
        }
        ui.end(callID: ended, reason: .remoteEnded)
        if wasAnswered { resumeLoneHeldCall() }
    }

    /// Play `tone` and report the end when it has run its course. The user
    /// hanging up on it ends the call at once (`userEnded`) — nothing else
    /// can, the call is already out of the table.
    private func endAfterTone(_ id: String, tone: CallTones.Tone, status: Int) {
        let seconds = tone.maxSeconds ?? tone.duration
        let seq: Int = lock.withLock {
            toneEndSeq += 1
            toneEnd = (id, .failed)
            return toneEndSeq
        }
        log("\(id): refused with \(status); \(seconds)s of tone before the call disappears")
        playTone(tone, for: id)
        schedule(seconds) { [weak self] in self?.finishToneEnd(seq) }
    }

    /// Report the held-back end of a failed call, once. A stale `seq` means
    /// something got there first.
    private func finishToneEnd(_ seq: Int) {
        let pending: (callID: String, reason: CallEndReason)? = lock.withLock {
            guard toneEndSeq == seq, let p = toneEnd else { return nil }
            toneEnd = nil
            return p
        }
        guard let pending else { return }
        stopTone(for: pending.callID)
        ui.end(callID: pending.callID, reason: pending.reason)
    }

    /// Cut a failure tone short. Returns true when `id` was the call it
    /// belonged to (nil = any call, for a tone that must stop because
    /// something else now owns the ear).
    @discardableResult
    private func stopFailureTone(forCallID id: String?) -> Bool {
        let seq: Int? = lock.withLock {
            guard let p = toneEnd, id == nil || p.callID == id else { return nil }
            return toneEndSeq
        }
        guard let seq else { return false }
        finishToneEnd(seq)
        return true
    }

    /// The conversation just ended and the only call left is on hold: take
    /// it off hold, so the user is back in that call without touching the
    /// screen (product decision, 2026-09-14; the phone is at their ear).
    /// Only after an *answered* call ends — declining a ringing second call
    /// leaves a call the user held on purpose as it is.
    private func resumeLoneHeldCall() {
        let survivor: String? = lock.withLock {
            guard calls.count == 1, let (id, c) = calls.first, c.phase == .answered, c.held else { return nil }
            return id
        }
        guard let survivor else { return }
        log("\(survivor) is the only call left and on hold; resuming it")
        ui.resume(callID: survivor)
    }

    // MARK: Gateway → UI

    /// Handle one signal event. Non-call events are ignored here.
    public func handle(_ event: SignalEvent) {
        switch event {
        case .wake(let w):
            handle(wake: w)
        case .wakeCancel(let c):
            // The server names the wake's id. A call that rang from its
            // INVITE first is tracked under a synthetic id with the wake's id
            // merged in, so resolve through that too — otherwise the cancel
            // is dropped as unknown and the phone rings on.
            let id: String = lock.withLock {
                calls[c.callID] != nil ? c.callID : (calls.first { $0.value.wakeCallID == c.callID }?.key ?? c.callID)
            }
            end(callID: id, reason: c.reason == .answeredElsewhere ? .answeredElsewhere : (c.reason == .timeout ? .unanswered : .remoteEnded))
        default:
            // A gateway drop (.disconnected) is deliberately NOT a call
            // event. A ringing wake does not depend on the session that
            // carried it: the extension's session may have delivered it
            // (PushKit), and the INVITE comes from the SIP registration the
            // engine makes on answer. Ending wake-only calls here killed the
            // background wake — the app's own stale session reports its
            // drop as it resumes for the PushKit wake, before the user has
            // answered (testSessionDropDoesNotEndAnExtensionDeliveredWake).
            break
        }
    }

    /// What a wake did, so the delivery path (socket or PushKit) can meet
    /// its own obligations: a PushKit delivery must always be answered with
    /// a CallKit report, even when the call is already ringing.
    public enum WakeOutcome: Equatable, Sendable {
        /// Rang the system UI for `callID`.
        case rang
        /// Already ringing (or answered) under `callID` — the same wake by
        /// another path, or the INVITE that arrived first.
        case duplicate(of: String)
        /// Past its expiry; nothing rang.
        case expired
        /// Refused: the app will not take another call (call waiting off,
        /// or already at its limit). The server was told busy.
        case refused
    }

    /// Entry point shared by the transport path and the PushKit path.
    @discardableResult
    public func handle(wake w: Wake) -> WakeOutcome {
        let name = callerName(for: w.from)
        enum Found { case existing(id: String, reported: String), created, refused }
        let found: Found = lock.withLock {
            if let c = calls[w.callID] { return .existing(id: w.callID, reported: c.reportedName) }
            // The INVITE for this call may already be ringing under a
            // synthetic id (registered app, wake arrived second): it carried
            // the server's id, which is this wake's. The INVITE knew only
            // the peer URI; the wake carries the caller's display name, so
            // keep the richer identity for the in-call title.
            let byHeader = calls.first { $0.value.diallerCallID == w.callID && $0.value.phase != .ended }
            // Without the header (a peer that is not our server) the one
            // INVITE-first ringing call that no wake has claimed is the match.
            let unclaimed = calls.filter { $0.value.sipArrived && $0.value.phase == .ringing && $0.value.direction == .incoming && $0.value.diallerCallID == nil && $0.value.wakeCallID == nil }
            if let (id, c) = byHeader ?? (unclaimed.count == 1 ? unclaimed.first : nil) {
                var merged = c
                if merged.wake.from.displayName?.isEmpty != false { merged.wake.from.displayName = w.from.displayName }
                merged.wakeCallID = w.callID
                calls[id] = merged
                return .existing(id: id, reported: c.reportedName)
            }
            guard admitsAnotherCallLocked() else { return .refused }
            calls[w.callID] = TrackedCall(wake: w, phase: .ringing, reportedName: name, wakeCallID: w.callID, startedAt: now())
            return .created
        }
        if case .refused = found {
            log("wake \(w.callID) refused: \(callWaitingEnabled ? "no room for another call" : "call waiting is off")")
            transport?.send(.wakeAck(WakeAck(callID: w.callID, action: .busy)))
            // The caller heard busy and the user saw nothing: a missed call.
            record(TrackedCall(wake: w, phase: .ringing, reportedName: name, wakeCallID: w.callID, startedAt: now()), id: w.callID, ending: .refused)
            return .refused
        }
        if case .existing(let id, let reported) = found { // de-duplicated across app + extension delivery
            let existing = (id: id, reported: reported)
            // A wake that resolves to a better name than the INVITE managed
            // corrects the banner while the call is still ringing.
            if name != existing.reported {
                lock.withLock { calls[existing.id]?.reportedName = name }
                log("call \(existing.id): caller now known as \(name)")
                ui.updateIncoming(callID: existing.id, displayName: name)
            }
            return .duplicate(of: existing.id)
        }
        if w.expiresAt <= now() {
            let call: TrackedCall? = lock.withLock {
                defer { calls[w.callID] = nil }
                return calls[w.callID]
            }
            log("wake \(w.callID) already expired; ignoring")
            // The caller gave up before the app could ring: missed.
            if let call { record(call, id: w.callID, ending: .refused) }
            return .expired
        }
        log("incoming call \(w.callID) from \(name)")
        stopFailureTone(forCallID: nil)
        stopTone(for: nil)
        ui.reportIncoming(callID: w.callID, displayName: name, handle: w.from.uri) { [weak self] err in
            guard let self else { return }
            if let err {
                self.log("CallKit refused call \(w.callID): \(err)")
                // The INVITE may have reached the stack while the report
                // was out (it usually has: the server dials as soon as the
                // wake's registration lands). Dropping only our record left
                // that SIP call ringing inside the engine with nothing to
                // ever answer or cancel it — the engine stayed "ringing",
                // deferred every registration reset, and no later call
                // reached the phone until it timed out (2026-09-17 13:22).
                let call: TrackedCall? = self.lock.withLock {
                    defer { self.calls[w.callID] = nil }
                    return self.calls[w.callID]
                }
                if let engineID = call?.engineCallID { self.engine?.hangup(engineCallID: engineID) }
                self.transport?.send(.wakeAck(WakeAck(callID: w.callID, action: .busy)))
                if let call { self.record(call, id: w.callID, ending: .failed) }
                return
            }
            // Reported to the system UI before any network work (PROTOCOL.md §6).
            self.transport?.send(.wakeAck(WakeAck(callID: w.callID, action: .willAnswer)))
        }
        return .rang
    }

    // MARK: UI → engine

    /// User accepted the call in the system UI. Any other call that is up
    /// goes on hold first (CallKit's Hold & Accept sends the hold action
    /// itself; this makes the order certain either way), then the INVITE is
    /// answered — now if it has arrived, else the moment it does (wake
    /// path: register so the server dials us).
    public func userAnswered(callID: String) {
        let (call, others): (TrackedCall?, [String]) = lock.withLock {
            guard var c = calls[callID], c.phase == .ringing else { return (nil, []) }
            c.phase = .answered
            c.connectedAt = now()
            c.answerWhenInvite = c.engineCallID == nil
            calls[callID] = c
            var held: [String] = []
            for (id, other) in calls where id != callID && other.phase == .answered && !other.held {
                if let e = other.engineCallID {
                    calls[id]?.held = true
                    held.append(e)
                }
            }
            return (c, held)
        }
        guard let call else { return }
        // The ear now belongs to a conversation: any progress tone stops
        // (plan Phase J). An outgoing call of our own can still be ringing
        // behind this one — call waiting admits the second call, and its
        // ring-back would otherwise play on over the answer.
        stopTone(for: nil)
        for e in others {
            log("\(callID): holding the other call first")
            engine?.setHeld(engineCallID: e, true)
        }
        if let engineID = call.engineCallID {
            log("answered \(callID)")
            answerSIP(callID: callID, engineCallID: engineID)
        } else {
            let user = Self.userPart(of: call.wake.to.uri)
            log("answered \(callID); registering \(user) to \(call.wake.sip.host):\(call.wake.sip.port); answering when its INVITE arrives")
            engine?.register(user: user, sip: call.wake.sip)
            armInviteDeadline(callID: callID, wake: call.wake)
        }
    }

    /// Answers the SIP call and records whether it really went up.
    ///
    /// The 200 OK can fail to send — the dialog is bound to the connection
    /// its INVITE arrived on, and after a suspension that can be dead with
    /// the stack yet to notice. Nothing used to act on that: CallKit was
    /// left showing a connected call, it handed over the audio session, and
    /// the user sat in silence while the caller went on ringing until the
    /// server gave up (2026-09-23, call ef036a07). The dialog cannot be
    /// rescued — the far end's INVITE transaction is on the same dead
    /// connection — so end the call and let the user see that it failed.
    private func answerSIP(callID: String, engineCallID: String) {
        guard engine?.answer(engineCallID: engineCallID) != false else {
            log("\(callID): the answer could not be sent; ending the call")
            end(callID: callID, reason: .failed)
            return
        }
        lock.withLock { calls[callID]?.connected = true }
    }

    /// How long after the wake's own expiry we still allow the INVITE to
    /// turn up, and the floor when the user answers as the wake expires:
    /// enough for our REGISTER and the server's INVITE to cross a healthy
    /// link, which is normally well under a second.
    private static let inviteGrace: TimeInterval = 5

    /// Runs `work` after `seconds`, for call deadlines. Separate from
    /// `schedule` — which exists so a four-second tone does not cost a test
    /// four seconds, and which several tests therefore run inline — because
    /// a deadline run inline fires the instant it is armed, which is never
    /// what a test of some other behaviour meant. Replaced on its own by
    /// the tests that are about deadlines.
    var scheduleDeadline: (_ seconds: Double, _ work: @escaping () -> Void) -> Void = { seconds, work in
        CallController.timerQueue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Answering a wake commits CallKit to a call the SIP stack has not seen
    /// yet — the INVITE follows once our REGISTER has given the server a
    /// route to dial. Nothing else ends this call if that INVITE never
    /// comes: CallKit shows it connected, CallKit has handed the audio
    /// session over, and the user sits in permanent silence until they give
    /// up. That is what a stale server-side route produced on 2026-09-23.
    ///
    /// The deadline is the wake's own `expiresAt`, which the server already
    /// sends and `SessionMachine` has already rebased onto our clock: past
    /// it the server has stopped waiting for our registration, so no INVITE
    /// is coming and the call is over whatever we do.
    private func armInviteDeadline(callID: String, wake: Wake) {
        let remaining = wake.expiresAt.timeIntervalSince(now())
        scheduleDeadline(max(remaining, Self.inviteGrace)) { [weak self] in
            self?.inviteDeadlinePassed(callID)
        }
    }

    /// The wake expired with the call still answered and still no INVITE.
    /// Ends it as failed — the user never got a conversation, so it must
    /// not be recorded as a completed call with a duration.
    private func inviteDeadlinePassed(_ callID: String) {
        let stranded: Bool = lock.withLock {
            guard let c = calls[callID] else { return false }
            return c.phase == .answered && c.engineCallID == nil
        }
        guard stranded else { return }
        log("\(callID): answered on the wake but its INVITE never arrived; ending the call")
        end(callID: callID, reason: .failed)
    }

    /// User declined or hung up in the system UI.
    public func userEnded(callID: String) {
        // Hanging up on a busy or congestion tone (plan Phase J): the call
        // is already out of the table and only its end report is waiting on
        // the tone. Make it now — the user is done listening.
        if stopFailureTone(forCallID: callID) {
            log("ended \(callID) by user, on its failure tone")
            return
        }
        stopTone(for: callID) // cancelling an outgoing call stops its ring-back
        // Declining a ringing incoming call: tell the server through the
        // wake channel too (it may be holding the caller for our
        // registration), using the wake's own id. A call that rang from the
        // INVITE alone has no wake to ack; the 486 the engine sends is the
        // whole answer.
        let call: TrackedCall? = lock.withLock {
            defer { calls[callID] = nil }
            return calls[callID]
        }
        guard let call else {
            log("ended \(callID) by user (not tracked)")
            return
        }
        let wasAnswered = call.phase == .answered
        if call.phase == .ringing, call.direction == .incoming, let declineAckID = call.wakeCallID {
            transport?.send(.wakeAck(WakeAck(callID: declineAckID, action: .decline)))
        }
        if let engineID = call.engineCallID { engine?.hangup(engineCallID: engineID) }
        log("ended \(callID) by user")
        record(call, id: callID, ending: .user)
        if wasAnswered { resumeLoneHeldCall() }
    }

    /// "sip:201@dialler;transport=tls" → "201@dialler"; "201" → "201".
    public static func userPart(of uri: String) -> String {
        var s = uri
        if let lt = s.firstIndex(of: "<") { s = String(s[s.index(after: lt)...]) }
        if let gt = s.firstIndex(of: ">") { s = String(s[..<gt]) }
        for p in ["sips:", "sip:"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if let semi = s.firstIndex(of: ";") { s = String(s[..<semi]) }
        return s
    }

    /// The bare number/extension shown when there is no name: the user token
    /// before the host. "\"Alice\" <sip:1001@pbx>" → "1001"; "201" → "201".
    /// Unlike `userPart` this drops the host, so it is for display only, never
    /// for registering the SIP user (which needs the domain).
    public static func numberPart(of uri: String) -> String {
        let up = userPart(of: uri) // "1001@pbx" or "1001"
        return up.split(separator: "@").first.map(String.init) ?? up
    }

    /// The one string a party is known by outside the app (SPEC §6 item
    /// 16): what CallKit writes to the Phone app's Recents and shows on its
    /// call screen, and what a Recents tap hands back to dial. The same
    /// directory number the app's own screens show (`numberPart`), so
    /// "sip:10910@dialpark" from an incoming INVITE, "10910" from the keypad
    /// and "sip:30933@10.7.160.11" from a trunk caller are "10910", "10910"
    /// and "30933": one row per party, and a call-back dials the number the
    /// way the keypad would, completed with the account's domain and routed
    /// by the server. A user part that is not dialable — a name, which SIP
    /// allows and this system does not produce — keeps its host so a
    /// call-back still routes.
    public static func callKitHandle(of uri: String) -> String {
        let number = numberPart(of: uri)
        let dialable = CharacterSet(charactersIn: "0123456789+*#")
        if !number.isEmpty, number.unicodeScalars.allSatisfy(dialable.contains) { return number }
        return userPart(of: uri)
    }

    private func end(callID: String, reason: CallEndReason) {
        let call: TrackedCall? = lock.withLock {
            defer { calls[callID] = nil }
            return calls[callID]
        }
        guard let call else { return }
        log("call \(callID) ended: \(reason)")
        let ending: CallRecord.Ending
        switch reason {
        case .answeredElsewhere: ending = .cancelled(.answeredElsewhere)
        case .unanswered: ending = .cancelled(.timeout)
        case .remoteEnded: ending = .cancelled(.callerHangup)
        case .failed: ending = .failed
        }
        record(call, id: callID, ending: ending)
        ui.end(callID: callID, reason: reason)
        if let engineID = call.engineCallID { engine?.hangup(engineCallID: engineID) }
        if call.phase == .answered { resumeLoneHeldCall() }
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
