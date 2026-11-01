import CBaresip
import DiallerCore
import DiallerProtocol
import Foundation
import os

/// The real `CallEngine` (SPEC §5 component 6): wraps libbaresip via the
/// CBaresip shim.
///
/// Lifecycle: `register` is called as soon as the gateway welcome names our
/// SIP account, so the phone stays registered while the app runs and INVITEs
/// reach it directly (SPEC §2 foreground path). An INVITE is reported through
/// `onIncomingCall` with the stack's call id; the controller rings CallKit
/// (unless a wake already did) and, on the user's answer, calls `answer` for
/// that id — or, on the wake path where the INVITE has not arrived yet,
/// `register` and then `answer` when the INVITE comes.
///
/// Audio is baresip's `audiounit` module; CallKit activates the audio
/// session on answer, before the INVITE round trip completes.
///
/// Calls are addressed by baresip's SIP Call-ID. Up to `call_max_calls`
/// exist at once (call waiting: one active, one held); `State` is the
/// coarse summary the status screen shows.
public final class BaresipCallEngine: CallEngine {
    public enum State: Equatable, Sendable {
        case idle, starting, registering, registered, ringing, dialing, inCall, failed(String)
    }

    public var onIncomingCall: ((String, String, String?, String?) -> Void)?
    public var onCallEnded: ((String, String, Int) -> Void)?
    public var onOutgoingRinging: ((String, Bool) -> Void)?
    public var onCallEstablished: ((String) -> Void)?
    public var onTransferFailed: ((String, String) -> Void)?
    /// Observed by the app for status display.
    public var onStateChange: ((State) -> Void)?
    /// The engine's log, into the app's (shown on the Status page and
    /// uploaded with diagnostics). Every line goes through `redacted`: the
    /// SIP account line carries the device token as `auth_pass`, and it
    /// reached the log in full (found 2026-09-28).
    public var log: (String) -> Void {
        get { let sink = logSink; return { sink(Self.redacted($0)) } }
        set { logSink = newValue }
    }
    private var logSink: (String) -> Void = { _ in }

    /// A log line with any SIP password replaced.
    static func redacted(_ line: String) -> String {
        guard line.contains("auth_pass") else { return line }
        return line.replacingOccurrences(of: #"auth_pass=[^;>\s"]*"#, with: "auth_pass=•••", options: .regularExpression)
    }

    /// Headless tools only (engine-probe): answer every INVITE at once, with
    /// no controller in the loop.
    public var autoAnswer = false

    private let logger = Logger(subsystem: DiallerIDs.bundlePrefix, category: "engine")
    private let lock = NSLock()
    private var state: State = .idle { didSet { onStateChange?(state) } }

    /// What the stack holds, by SIP Call-ID.
    private struct CallInfo {
        enum Phase { case incoming, outgoing, established }
        var phase: Phase
        var held = false
    }
    private var calls: [String: CallInfo] = [:]

    /// The call whose audio is live: established and not held (the one the
    /// self-check samples). Nil when every call is ringing or held.
    public var activeEngineCallID: String? {
        lock.withLock { calls.first { $0.value.phase == .established && !$0.value.held }?.key }
    }

    /// `state` from the call table: the coarse summary the app shows.
    private func refreshState() {
        let phases: [CallInfo.Phase] = lock.withLock { calls.values.map(\.phase) }
        if phases.contains(.established) { state = .inCall }
        else if phases.contains(.outgoing) { state = .dialing }
        else if phases.contains(.incoming) { state = .ringing }
        else { state = cb_registered() ? .registered : .idle }
    }
    /// CallKit has activated the audio session (didActivate) and not yet
    /// deactivated it.
    private var sessionActive = false
    private var account: String? // the AOR line currently registered (or registering)
    private var domain = ""      // SIP domain of the account, completes bare dial targets
    /// What `register` was last asked for, so a failed registration can be
    /// retried on our own initiative (a dead connection after the app was
    /// suspended) rather than waiting for the next gateway welcome.
    private var lastRegistration: (user: String, sip: SIPTarget)?
    private var registerRetries = 0
    private var retryGeneration = 0 // bumped to cancel a pending retry
    private let acceptAnyCertificate: Bool
    /// Whether libre/baresip are up. Independent of `state`: a failed
    /// registration leaves the stack running (restarting it returns EALREADY).
    private var stackRunning = false

    /// Headless tests only: replace the microphone with another baresip
    /// audio source, e.g. "aufile,/path/tone.wav", so the phone transmits
    /// where no capture device exists (simctl spawn). Set before start.
    public var audioSourceOverride: String?

    public init(acceptAnyCertificate: Bool = true) {
        self.acceptAnyCertificate = acceptAnyCertificate
        cb_set_tls_trust(nil, acceptAnyCertificate) // until a pin is set
    }

    /// SIP Digest credential for the app leg: the device id and enrolment
    /// token. Goes into the account as auth_user / auth_pass so baresip
    /// answers the server's 401 on REGISTER and INVITE by itself.
    private var credentials: (user: String, pass: String)?

    public func setCredentials(username: String, password: String) {
        lock.withLock { credentials = (username, password) }
    }

    /// The SIP leg's certificate check, done in the shim (cbaresip.c
    /// `verify_server_cert`): the pinned certificate, whatever its issuer
    /// and dates; with no pin, any certificate only on the dev path. A pin
    /// that is not a SHA-256 pins nothing and accepts nothing.
    public func setServerTrust(pin: String?, acceptAnyCertificate: Bool) {
        guard let pin else {
            cb_set_tls_trust(nil, acceptAnyCertificate)
            log("engine: SIP TLS trusts \(acceptAnyCertificate ? "any certificate (dev)" : "no certificate: none pinned")")
            return
        }
        guard let digest = CertificatePin.digest(of: pin) else {
            cb_set_tls_trust(nil, false)
            log("engine: SIP TLS pin \(pin) is not a SHA-256; trusting no certificate")
            return
        }
        digest.withUnsafeBytes { cb_set_tls_trust($0.bindMemory(to: UInt8.self).baseAddress, false) }
        log("engine: SIP TLS pinned to \(pin)")
    }

    deinit { cb_stop() }

    /// Whether a libre/baresip log line goes into the app's own log (it
    /// always goes to os_log). `warning` is the stack's severity for the
    /// line, from the shim (cbaresip.c emit_line via `scode`).
    ///
    /// A warning always gets through. Filtering by wording is only for the
    /// stack's ordinary chatter, and it must never be the thing that decides
    /// whether a warning is seen: on 2026-09-25 every "transp:" line of the
    /// SIP connection lifecycle logging (libre patch level 5) was dropped
    /// because that module was not a word on the list, and the same filter
    /// hid a 38 000-line "tcp:" recv spin from the app log of the capture
    /// that was meant to explain a lost call.
    static func stackLineReachesAppLog(_ text: String, warning: Bool) -> Bool {
        if warning { return true }
        return text.contains("cbaresip") || text.contains("register") || text.contains("tls") || text.contains("dns") || text.contains("fail") || text.contains("error") || text.contains("audiounit") || text.contains("rtp") || text.contains("stream:") || text.contains("rtcp")
    }

    // MARK: CallEngine

    public func register(user: String, sip: SIPTarget) {
        guard ensureStack() else { return } // start()/stop() logged the reason
        lock.withLock {
            lastRegistration = (user, sip)
            retryGeneration += 1 // an explicit register supersedes a pending retry
        }
        let aor = self.aor(user: user, sip: sip)
        lock.withLock { domain = user.split(separator: "@", maxSplits: 1).count > 1 ? String(user.split(separator: "@", maxSplits: 1)[1]) : sip.host }
        let already: Bool = lock.withLock { account == aor }
        if already, state == .ringing || state == .inCall || state == .dialing {
            return // a call is up on this account; leave its flow alone
        }
        if already, state == .registered || state == .registering {
            // Same account, but the caller has a reason to doubt the binding:
            // a new gateway session (server restarted → registry empty) or a
            // wake with no INVITE pending (server has no usable route).
            // Our TLS flow may be dead without baresip having noticed yet,
            // so drop the cached connections (a send on a dead one fails at
            // once with EPROTO) and send a fresh REGISTER on a new one.
            _ = cb_reset_transports()
            let rc = cb_ua_register()
            if rc == 0 {
                state = .registering
                log("engine: re-registering \(user) (fresh REGISTER)")
            } else {
                log("engine: re-register failed (\(rc)); re-creating the user agent")
                lock.withLock { account = nil }
                register(user: user, sip: sip)
            }
            return
        }
        lock.withLock { account = aor }
        log("engine: registering \(user) via \(sip.host):\(sip.port)/tls")
        state = .registering
        let rc = cb_ua_alloc(aor)
        if rc == -EBUSY {
            // The user agent to be replaced holds a call (its INVITE was
            // read after the state check above): leave it, and its
            // registration, to the call. Try again once it is over.
            lock.withLock { account = nil }
            refreshState()
            log("engine: registration left to the call in progress; retrying after it")
            scheduleRegisterRetry()
            return
        }
        if rc != 0 {
            lock.withLock { account = nil }
            // rc is -errno straight from the SIP stack: a synchronous
            // connect() failure on the TLS socket to the server comes back
            // this way (libre returns the errno of connect() up through
            // sipreg → ua_register), so name it.
            let why = String(cString: strerror(-rc))
            state = .failed("ua_alloc \(rc): \(why)")
            log("engine: ua_alloc failed (\(rc): \(why)); the REGISTER's connection to \(sip.host):\(sip.port) could not be opened")
            scheduleRegisterRetry() // e.g. the loop was busy/recovering: try again
        }
    }

    @discardableResult
    public func answer(engineCallID: String) -> Bool {
        let rc = cb_answer(engineCallID)
        if rc == 0 {
            log("engine: answered \(engineCallID)")
            return true
        }
        // rc is -errno from the SIP stack. -EPROTO here means the 200 OK
        // could not be written to the connection the INVITE came in on: it
        // died while the phone was suspended and nothing had noticed yet.
        // The dialog cannot be rescued — the far end's INVITE transaction is
        // on that same dead connection — so the call is over.
        let why = String(cString: strerror(-rc))
        log("engine: answer of \(engineCallID) failed (\(rc): \(why)); the 200 OK could not be sent")
        return false
    }

    /// Refuse an incoming call with 486 Busy Here: the PBX applies its busy
    /// rule (busy tone, forward-on-busy). Used for a caller the app will not
    /// take — call waiting off, or a third call.
    public func reject(engineCallID: String) {
        let rc = cb_reject(engineCallID, 486, "Busy Here")
        lock.withLock { calls[engineCallID] = nil }
        refreshState()
        log(rc == 0 ? "engine: rejected \(engineCallID) with 486" : "engine: reject of \(engineCallID) failed (\(rc))")
    }

    @discardableResult
    public func dial(callID: String, to target: String) -> String? {
        guard stackRunning else { log("engine: cannot dial \(target): stack not running"); return nil }
        let uri = Self.dialURI(target, domain: lock.withLock { domain })
        log("engine: dialling \(uri) for \(callID)")
        var buf = [CChar](repeating: 0, count: 128)
        let rc = cb_dial(uri, &buf, buf.count)
        let id = String(cString: buf)
        if rc != 0 || id.isEmpty {
            log("engine: dial failed (\(rc))")
            refreshState()
            return nil
        }
        lock.withLock { calls[id] = CallInfo(phase: .outgoing) }
        state = .dialing
        return id
    }

    /// Every call, at once (headless tools' teardown).
    public func hangupAll() {
        cb_hangup(nil)
        lock.withLock { calls.removeAll() }
        refreshState()
        log("engine: hung up every call")
    }

    /// baresip's close reason, in words a reader will not misdiagnose.
    ///
    /// libre answers a received BYE with 200 OK and then terminates the
    /// session with `ECONNRESET` (`sipsess/listen.c` `bye_handler`,
    /// `accept.c` for a CANCEL), which baresip renders through `strerror`
    /// as "Connection reset by peer". It reads like a dropped TCP
    /// connection and is nothing of the kind: it is the ordinary far-end
    /// hangup. Two days were spent chasing it as a network fault
    /// (2026-09-14/15) before the libre source settled it, so the log now
    /// says which it is. The local user's hangup arrives as "Connection
    /// reset by user" (`call_hangup`), equally misleading, so it is named
    /// too. Anything else is passed through untouched.
    /// The errno suffix baresip sometimes appends ("… [54]") is kept, so a
    /// reader can still see the raw text this was translated from.
    static func closeReason(_ text: String) -> String {
        if text.hasPrefix("Connection reset by peer") {
            return "far end hung up (BYE) [libre: \(text)]"
        }
        if text.hasPrefix("Connection reset by user") {
            return "hung up here [libre: \(text)]"
        }
        return text
    }

    /// "202" → "sip:202@dialler"; "202@dialler" → "sip:202@dialler";
    /// "sip:…" unchanged. Digits typed on a keypad take the same route.
    static func dialURI(_ target: String, domain: String) -> String {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("sip:") || t.hasPrefix("sips:") { return t }
        if t.contains("@") { return "sip:\(t)" }
        return "sip:\(t)@\(domain)"
    }

    public func setMuted(_ muted: Bool) {
        guard stackRunning else { return }
        cb_mute(muted)
        log("engine: microphone \(muted ? "muted" : "unmuted")")
    }

    /// Hold: baresip re-INVITEs with the audio stream sendonly and stops its
    /// audio; resume re-INVITEs sendrecv. The audio units stay bound to the
    /// CallKit session throughout (CallKit keeps it active for a held call).
    public func setHeld(engineCallID: String, _ held: Bool) {
        guard stackRunning else { return }
        let rc = cb_hold(engineCallID, held)
        if rc == 0 { lock.withLock { calls[engineCallID]?.held = held } }
        log(rc == 0 ? "engine: \(held ? "held" : "resumed") \(engineCallID)" : "engine: \(held ? "hold" : "resume") of \(engineCallID) failed (\(rc))")
    }

    /// Blind transfer: baresip sends REFER with the target URI; the server
    /// answers 202, connects the other party, and NOTIFYs the outcome —
    /// 200 ends this call ("Call transfered"), a failure keeps it up.
    public func transfer(engineCallID: String, to target: String) {
        guard stackRunning else { return }
        let uri = Self.dialURI(target, domain: lock.withLock { domain })
        let rc = cb_transfer(engineCallID, uri)
        log(rc == 0 ? "engine: REFER \(engineCallID) → \(uri)" : "engine: transfer failed to send (\(rc))")
        if rc != 0 { onTransferFailed?(engineCallID, "could not send REFER (\(rc))") }
    }

    public func hangup(engineCallID: String) {
        cb_hangup(engineCallID)
        lock.withLock { calls[engineCallID] = nil }
        refreshState()
        log("engine: hangup \(engineCallID)")
    }

    /// CallKit activated the audio session. baresip creates its AudioUnit
    /// player/source when the call is established, which is not tied to
    /// this moment in any way; units created before the session is live
    /// (or in the same instant as its activation) never render. So the
    /// devices are bound once BOTH the call and the session are up, on
    /// whichever of the two events comes last — the same shape as
    /// pjsip's set_snd_dev / linphone's activateAudioSession in didActivate.
    /// Manual audio (the contract WebRTC calls `useManualAudio`): the
    /// audiounit driver is held from stack start, so units it allocates
    /// when a call is established are initialised but not started. CallKit's
    /// didActivate releases the hold (units start), didDeactivate re-holds
    /// (units stop). The driver never starts audio on its own.
    public func audioSessionActivated() {
        guard stackRunning else { return }
        lock.withLock { sessionActive = true }
        cb_audio_mark(1) // lab: didActivate on the audio timeline
        cb_audio_interrupt(false)
        log("engine: audio session active → audio released (units start)")
        verifyAudioFlow()
    }

    /// Self-check: frames must flow shortly after audio is released during a
    /// call. Makes a device log conclusive on its own — "AUDIO STALLED"
    /// means CoreAudio delivered nothing, whatever else the log says.
    /// Every verdict of the current call, for headless tests (sim-call).
    public private(set) var audioVerdicts: [AudioVerdict] = []
    public var lastAudioVerdict: AudioVerdict? { audioVerdicts.last }
    public func clearAudioVerdicts() { lock.withLock { audioVerdicts.removeAll() } }

    public struct AudioVerdict: Equatable, Sendable {
        public var seconds: Int
        public var playFrames: UInt64
        public var recFrames: UInt64
        public var playEnergy: UInt64
        public var rtpTx: UInt32
        public var rtpRx: UInt32
        public var rxLost: Int32
        public var jitterMs: UInt32
        public var jbLate: UInt32
        public var jbUnderflow: UInt32
        public var verdict: String
        /// Tone (or speech) is actually being rendered: average |sample|
        /// over the window is well above silence/noise floor.
        public var audible: Bool { playFrames > 0 && playEnergy / max(playFrames, 1) > 200 }
    }

    /// Set once the checks for the current call are scheduled (both the
    /// activation and the establishment paths call in; whichever is last
    /// wins, the other is a no-op).
    private var flowCheckScheduled = false
    /// Bumped when the last call ends: the windows an earlier call scheduled
    /// (up to 300 s of them) kept firing through the next call, so one device
    /// log carried three verdicts per window on three clocks (2026-09-27).
    private var flowCheckGeneration = 0

    private func verifyAudioFlow() {
        let (already, gen): (Bool, Int) = lock.withLock {
            let a = flowCheckScheduled
            flowCheckScheduled = true
            if !a { audioVerdicts.removeAll() } // verdicts are per call
            return (a, flowCheckGeneration)
        }
        if already { return }
        var p0: UInt64 = 0, r0: UInt64 = 0, e0: UInt64 = 0
        cb_audio_stats(&p0, &r0, &e0)
        var lastRx: UInt32 = 0 // RTP received as of the previous window
        var eventsSeen = 0 // lab: audio continuity events reported so far
        // Windows at 2 s and 5 s, then every 5 s for the life of the call
        // (capped), so a call that degrades at 30 s is visible; each window
        // reports the audio it rendered since the previous one.
        let checkpoints: [Double] = [2.0, 5.0] + stride(from: 10.0, through: 300.0, by: 5.0).map { $0 }
        for delay in checkpoints {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.state == .inCall,
                      self.lock.withLock({ self.flowCheckGeneration == gen }) else { return }
                var p1: UInt64 = 0, r1: UInt64 = 0, e1: UInt64 = 0
                cb_audio_stats(&p1, &r1, &e1)
                var m = cb_media_stats_t()
                cb_media_stats(self.activeEngineCallID, &m)
                let play = p1 - p0, rec = r1 - r0, energy = e1 - e0
                (p0, r0, e0) = (p1, r1, e1)
                let rxSinceLast = m.rx_packets &- lastRx
                lastRx = m.rx_packets
                // Units: play = output rendered, rec = mic captured.
                // RTP: tx = packets sent to the server, rx = received from it
                // (cumulative; a count that stops rising is a stalled relay).
                let verdict: String
                if play == 0 && rec == 0 { verdict = "UNITS DEAD (no CoreAudio callbacks)" }
                else if play == 0 { verdict = "OUTPUT UNIT DEAD" }
                else if rec == 0 { verdict = "MIC DEAD (no capture)" }
                else if m.rx_packets == 0 { verdict = "NO RTP FROM SERVER (media path, not audio)" }
                else if rxSinceLast == 0 { verdict = "RTP FROM SERVER STOPPED (relay sent \(m.rx_packets) packets then nothing)" }
                else if m.tx_packets == 0 { verdict = "NO RTP SENT (encoder/tx path)" }
                else if energy / max(play, 1) <= 200 { verdict = "RENDERING SILENCE (RTP arrives, decoded audio is empty)" }
                else if m.rx_lost > 0 || m.jb_late > 0 || m.jb_underflow > 0 { verdict = "audio flowing but LOSSY (gaps you can hear)" }
                else { verdict = "audio flowing" }
                let v = AudioVerdict(seconds: Int(delay), playFrames: play, recFrames: rec, playEnergy: energy,
                                     rtpTx: m.tx_packets, rtpRx: m.rx_packets, rxLost: m.rx_lost, jitterMs: m.rx_jitter_us / 1000,
                                     jbLate: m.jb_late, jbUnderflow: m.jb_underflow, verdict: verdict)
                self.lock.withLock {
                    self.audioVerdicts.append(v)
                    if self.audioVerdicts.count > 60 { self.audioVerdicts.removeFirst() }
                }
                // Lab: what removed or padded audio in this window, by kind.
                let events = Self.audioEvents()
                let fresh = events.count > eventsSeen ? Array(events[eventsSeen...]) : []
                eventsSeen = events.count
                let windowEvents = AudioContinuity.summary(of: fresh).kinds
                self.log("engine: \(verdict) — \(Int(delay))s: play=\(play) rec=\(rec) frames, energy/frame=\(energy / max(play, 1)); rtp tx=\(m.tx_packets) rx=\(m.rx_packets) err=\(m.rx_errors) lost=\(m.rx_lost) jitter=\(m.rx_jitter_us / 1000)ms; jbuf late=\(m.jb_late) lost=\(m.jb_lost) underflow=\(m.jb_underflow) overflow=\(m.jb_overflow); events +\(fresh.count)\(windowEvents.isEmpty ? "" : " " + windowEvents)")
            }
        }
    }

    public func audioSessionDeactivated() {
        guard stackRunning else { return }
        lock.withLock { sessionActive = false }
        cb_audio_interrupt(true)
        log("engine: audio session inactive → audio held (units stopped)")
    }

    /// Tear the stack down (e.g. app going to background with no call).
    public func stop() {
        _ = cb_ua_free() // EBUSY with a call up; cb_stop hangs it up anyway
        cb_stop()
        lock.withLock {
            account = nil; calls.removeAll()
            lastRegistration = nil; retryGeneration += 1
        }
        stackRunning = false
        state = .idle
    }

    /// The gateway session came back after a drop. iOS killed both sockets
    /// in the same suspension and baresip only learns its one is dead on
    /// the next send, so drop the registration (and its connection) now and
    /// let the welcome's `register` start a fresh one. Left alone during a
    /// call.
    public func resetRegistration() {
        if stackRunning && !cb_alive() {
            // The loop thread died with the connection; a fresh stack is
            // the only way back, and the welcome's register starts it.
            log("engine: SIP loop is dead; tearing the stack down for a fresh start")
            stop()
            return
        }
        // Not while a call is in progress — including one that is only
        // ringing. Hanging those up here after a suspension, on the theory
        // that a ringing call at this point must be an orphan, was wrong:
        // the drop being reported is the PREVIOUS suspension's, delivered
        // late as the app resumes, while the ringing call is the new one
        // whose INVITE beat the welcome (2026-09-17 16:29, "Call failed:
        // busy" for the caller). The orphan case is handled where it
        // arises: the controller hangs up the SIP call when CallKit refuses
        // it. And the decision is the stack's, not a check of `state` here:
        // `state` is written by the loop thread as it reads the INVITE, and
        // this op is queued to that same thread — on 2026-09-18 15:12 the
        // INVITE was read 0.3 ms after the check here had passed and before
        // the free ran, and the free hung the new call up (486). The stack
        // refuses with EBUSY when it holds a call, and the call keeps its
        // registration and connection: they are evidently alive.
        let rc = cb_ua_free()
        if rc == -EBUSY {
            log("engine: registration reset refused by the stack: a call is in progress; left alone")
            return
        }
        lock.withLock {
            account = nil
            registerRetries = 0
            retryGeneration += 1
        }
        // iOS tore the SIP socket down with the gateway's; libre still has
        // it cached and would send the next REGISTER on it (EPROTO, seen
        // as "ua_alloc -100" after every unlock). Rebuild the transports.
        _ = cb_reset_transports()
        if stackRunning { state = .idle }
        log("engine: registration dropped (session came back); transports reset; registering afresh")
    }

    /// The stack must be running with a live loop thread. libre ends its
    /// loop on a poll error (seen on Darwin after the SIP connection was
    /// reset by the peer); a dead stack is torn down and started again.
    @discardableResult
    private func ensureStack() -> Bool {
        if stackRunning && !cb_alive() {
            log("engine: SIP loop died; restarting the stack")
            stop()
        }
        if !stackRunning { start() }
        return stackRunning
    }

    /// A failed registration is retried by us with backoff (2, 4, 8, then
    /// 15 s) on the last requested account, re-creating the user agent so a
    /// dead connection is replaced. Cancelled by success, an explicit
    /// register, a reset, or stop.
    private func scheduleRegisterRetry() {
        let (gen, attempt, last): (Int, Int, (user: String, sip: SIPTarget)?) = lock.withLock {
            retryGeneration += 1
            registerRetries += 1
            return (retryGeneration, registerRetries, lastRegistration)
        }
        guard let last else { return }
        let delay = min(15.0, pow(2.0, Double(attempt)))
        log("engine: retrying registration in \(Int(delay))s (attempt \(attempt))")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.lock.withLock({ self.retryGeneration == gen }) else { return }
            // The failed attempt may have gone to a dead cached connection;
            // start the retry on fresh transports.
            if self.stackRunning { _ = cb_reset_transports() }
            self.register(user: last.user, sip: last.sip)
        }
    }

    // MARK: internals

    func aor(user: String, sip: SIPTarget) -> String {
        let parts = user.split(separator: "@", maxSplits: 1)
        let userPart = String(parts[0])
        let domain = parts.count > 1 ? String(parts[1]) : sip.host
        let auth: String = lock.withLock {
            guard let c = credentials else { return "" }
            return ";auth_user=\(c.user);auth_pass=\(c.pass)"
        }
        // audio_codecs names codecs by their AUDIO channel count, not the SDP
        // one: with `opus_stereo no` baresip registers Opus as opus/48000/1
        // (the SDP still says opus/48000/2). Listing /2 here silently fails
        // to find the codec and the call falls back to PCMU — caught by the
        // harness when the "Opus" gate turned out to be running G.711.
        // G.722 likewise: baresip names it G722/16000/1 (its audio rate);
        // the SDP says G722/8000 (RFC 3551's RTP clock). G722/8000/1 here
        // is "audio codec not found" and the call falls back to PCMU.
        // mediaenc=srtp-mand: SDES SRTP, required — the app leg is always
        // encrypted (SPEC §4.4 rule 4); the server offers and answers
        // RTP/SAVP with AES_CM_128_HMAC_SHA1_80.
        return "<sip:\(userPart)@\(domain);transport=tls>\(auth);outbound=\"sip:\(sip.host):\(sip.port);transport=tls\";regint=300;answermode=manual;mediaenc=srtp-mand;audio_codecs=opus/48000/1,G722/16000/1,PCMU/8000/1"
    }

    /// The baresip configuration the stack starts with. A function of its
    /// two inputs so the audio profile is unit-testable (SPEC §6 near-term
    /// item 5): every key here was chosen against a measurement, see the
    /// comments, and the harness phone (`harness/baresip/config`) mirrors
    /// the same profile so headless gates measure what the app runs.
    static func stackConfig(acceptAnyCertificate: Bool, audioSource: String?) -> String {
        """
        # generated by BaresipCallEngine
        sip_listen              0.0.0.0:0
        sip_verify_server       \(acceptAnyCertificate ? "no" : "yes")
        call_local_timeout      60
        call_max_calls          2
        audio_player            audiounit,default
        audio_source            \(audioSource ?? "audiounit,default")
        audio_alert             none

        # Playout: an adaptive jitter buffer of 2–8 frames (40–160 ms at
        # 20 ms) instead of the fixed default 5–10 (100–200 ms), which was
        # most of the mouth-to-ear budget; the play buffer adapts likewise,
        # with a 40 ms floor: after a lost packet the jitter buffer withholds
        # the next one until it has refilled, and one extra frame of play
        # buffer rides that out (measured: no delay cost, fewer gaps).
        audio_jitter_buffer_type  off
        audio_buffer              20-400
        audio_buffer_mode         adaptive

        # Opus for speech on Wi-Fi: voip mode, in-band FEC so a single lost
        # packet is recovered from the next, 32 kbit/s mono, complexity 6
        # (10, the default, is CPU for nothing audible). No DTX: it fights
        # the voice-processing unit's comfort noise and hides silent legs.
        # opus_packet_loss is what makes FEC real: baresip's module only
        # tells the encoder to add redundancy, and only decodes it, when an
        # expected loss is set (modules/opus/decode.c: fec = packet_loss > 0).
        # Measured: with it 0 gaps at 2 % loss, without it 4 (SPEC §7.2).
        opus_application        voip
        opus_inbandfec          yes
        opus_packet_loss        10
        opus_bitrate            32000
        opus_stereo             no
        opus_sprop_stereo       no
        opus_complexity         6
        opus_cbr                no
        opus_dtx                no

        # RTP: statistics on (the loss/jitter numbers the self-check reads
        # are zero without them), dead media hangs the call up after 30 s,
        # EF marking on media (the transport patch maps it to WMM voice).
        rtp_stats               yes
        rtp_timeout             30
        rtp_tos                 184
        # SIP signalling CS3 (baresip's default is 160, CS5). With the libre
        # patch, both also set the Apple net service type (voice / signalling)
        # that selects the Wi-Fi access category.
        sip_tos                 96

        module                  audiounit.so
        module                  aufile.so
        module                  opus.so
        module                  g722.so
        module                  g711.so
        module                  ice.so
        module                  srtp.so
        module                  auconv.so
        module                  auresamp.so
        """
    }

    private func start() {
        state = .starting
        let config = Self.stackConfig(acceptAnyCertificate: acceptAnyCertificate, audioSource: audioSourceOverride)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        log("engine: starting the SIP stack")
        let rc = cb_start(config, { ctx, event, info in
            guard let ctx, let info else { return }
            let engine = Unmanaged<BaresipCallEngine>.fromOpaque(ctx).takeUnretainedValue()
            let s = { (p: UnsafePointer<CChar>?) in p.map { String(cString: $0) } ?? "" }
            engine.handle(event: event, callID: s(info.pointee.call_id), peer: s(info.pointee.peer),
                          text: s(info.pointee.text), diallerCallID: s(info.pointee.dialler_call_id),
                          status: Int(info.pointee.scode))
        }, ctx)
        if rc != 0 {
            state = .failed("start \(rc)")
            log("engine: start failed (\(rc))")
        } else {
            stackRunning = true
            // Manual audio: hold the driver until CallKit activates a session.
            cb_audio_interrupt(true)
            log("engine: started \(String(cString: cb_version())); audio held until CallKit activates")
        }
    }

    /// Runs on the libre loop thread.
    private func handle(event: cb_event_t, callID: String, peer: String, text: String, diallerCallID: String, status: Int = 0) {
        switch event {
        case CB_EVENT_REGISTER_OK:
            lock.withLock {
                registerRetries = 0
                retryGeneration += 1 // cancel any pending retry
            }
            state = .registered
            log("engine: registered")
        case CB_EVENT_REGISTER_FAIL:
            lock.withLock { account = nil } // allow a fresh attempt
            state = .failed("register: \(text)")
            log("engine: registration failed: \(text)")
            scheduleRegisterRetry()
        case CB_EVENT_CALL_INCOMING:
            // For this event the shim passes the caller's From display name
            // as `text` ("" when the caller sent none).
            let displayName = text.isEmpty ? nil : text
            lock.withLock { calls[callID] = CallInfo(phase: .incoming) }
            refreshState()
            log("engine: INVITE \(callID) from \(peer)\(displayName.map { " (\"\($0)\")" } ?? "")\(diallerCallID.isEmpty ? "" : " for call \(diallerCallID)")")
            if autoAnswer {
                answer(engineCallID: callID)
            } else {
                onIncomingCall?(callID, peer, displayName, diallerCallID.isEmpty ? nil : diallerCallID)
            }
        case CB_EVENT_CALL_OUTGOING:
            lock.withLock { if calls[callID] == nil { calls[callID] = CallInfo(phase: .outgoing) } }
            refreshState()
            log("engine: INVITE \(callID) sent to \(peer)")
        case CB_EVENT_CALL_TRANSFER_FAILED:
            log("engine: transfer of \(callID) failed: \(text)")
            onTransferFailed?(callID, text)
        case CB_EVENT_CALL_RINGING, CB_EVENT_CALL_PROGRESS:
            // 180 with no SDP (RINGING) versus 183 with early media
            // (PROGRESS): the app lays its own ring-back over the first and
            // never over the second, which already carries audio.
            let earlyMedia = event == CB_EVENT_CALL_PROGRESS
            log("engine: far end \(earlyMedia ? "in progress (early media)" : "ringing") \(peer)")
            onOutgoingRinging?(callID, earlyMedia)
        case CB_EVENT_CALL_ESTABLISHED:
            let (active, wasOutgoing): (Bool, Bool) = lock.withLock {
                let out = calls[callID]?.phase == .outgoing
                calls[callID] = CallInfo(phase: .established, held: calls[callID]?.held ?? false)
                return (sessionActive, out)
            }
            refreshState()
            cb_audio_mark(2) // lab: established on the audio timeline
            log("engine: call \(callID) established with \(peer); audio \(active ? "starting (session already active)" : "held until didActivate")")
            if active { verifyAudioFlow() }
            if wasOutgoing { onCallEstablished?(callID) }
        case CB_EVENT_CALL_CLOSED:
            log("engine: call \(callID) closed (\(Self.closeReason(text)))\(status == 0 ? "" : " [\(status)]")")
            logAudioContinuity(callID)
            let last: Bool = lock.withLock {
                calls[callID] = nil
                if calls.isEmpty { flowCheckScheduled = false; flowCheckGeneration += 1 }
                return calls.isEmpty
            }
            // sessionActive is cleared by didDeactivate, which CallKit sends
            // after the last call is reported ended.
            if last { state = cb_registered() ? .registered : .idle } else { refreshState() }
            onCallEnded?(callID, text, status)
        case CB_EVENT_LOG:
            logger.info("baresip: \(Self.redacted(text), privacy: .public)")
            if Self.stackLineReachesAppLog(text, warning: status != 0) {
                log("baresip: \(text)")
            }
        default:
            if !text.isEmpty { log("engine event: \(text)") }
        }
    }
}

// MARK: - Lab: audio continuity (lab/audio-continuity)
//
// Every event that removed or padded audio on the play path, from the
// vendored aubuf/jbuf/audiounit hooks (see cbaresip.h cb_audio_events),
// summarised per call and dumped in full at call end so a device log can be
// read against the server's relay line for the same call.

public struct AudioEvent: Sendable {
    public let tMs: Double
    public let kind: UInt32
    public let name: String
    public let a: Int32
    public let b: Int32
}

public struct AudioContinuity: Sendable {
    public var removedMs: Int = 0
    public var firstReadMs: Int = 0
    public var jbufDropMs: Int = 0
    public var ajbSkipMs: Int = 0
    public var overrunMs: Int = 0
    public var insertedMs: Int = 0
    public var underruns: Int = 0
    public var jbLate: Int = 0
    public var wishMin: Int32 = 0
    public var wishMax: Int32 = 0
    // Lab playout engine (replaces aubuf): time-scaling and concealment
    public var poAccelMs: Int = 0      // removed by pitch-synchronous compression (not discarded)
    public var poStretchMs: Int = 0    // added by stretching
    public var poConcealMs: Int = 0    // concealed from history (underrun or loss)
    public var poZeroMs: Int = 0       // silence with nothing to conceal from
    public var poLate: Int = 0         // packets behind the playout position
    public var poTargetMin: Int32 = 0
    public var poTargetMax: Int32 = 0
    public var firstRemovedAtMs: Double = -1
    public var events: [AudioEvent] = []

    /// Counts by kind, "JB_DROP=3 AB_UNDERRUN=1", in the order first seen.
    public var kinds: String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for e in events where e.name != "MARK" {
            if counts[e.name] == nil { order.append(e.name) }
            counts[e.name, default: 0] += 1
        }
        return order.map { "\($0)=\(counts[$0]!)" }.joined(separator: " ")
    }

    public var line: String {
        "removed_ms=\(removedMs) first_read_ms=\(firstReadMs) jbuf_drop_ms=\(jbufDropMs) ajb_skip_ms=\(ajbSkipMs) overrun_ms=\(overrunMs) inserted_ms=\(insertedMs) underruns=\(underruns) jb_late=\(jbLate) wish=\(wishMin)-\(wishMax) events=\(events.count) first_removed_at_ms=\(firstRemovedAtMs < 0 ? "none" : String(Int(firstRemovedAtMs))) po_accel_ms=\(poAccelMs) po_stretch_ms=\(poStretchMs) po_conceal_ms=\(poConcealMs) po_zero_ms=\(poZeroMs) po_late=\(poLate) po_target=\(poTargetMin)-\(poTargetMax)"
    }

    public static func summary(of events: [AudioEvent]) -> AudioContinuity {
        var c = AudioContinuity(events: events)
        func removed(_ ms: Int32, at t: Double) {
            c.removedMs += Int(ms)
            if c.firstRemovedAtMs < 0 { c.firstRemovedAtMs = t }
        }
        for e in events {
            switch e.name {
            case "AB_FIRST_DROP": c.firstReadMs += Int(e.a); removed(e.a, at: e.tMs)
            case "JB_DROP": c.jbufDropMs += Int(e.a); removed(e.a, at: e.tMs)
            case "AB_AJB_HIGH": c.ajbSkipMs += Int(e.a); removed(e.a, at: e.tMs)
            case "AB_OVERRUN": c.overrunMs += Int(e.a); removed(e.a, at: e.tMs)
            case "AB_UNDERRUN": c.underruns += 1; c.insertedMs += Int(e.a)
            case "JB_LATE": c.jbLate += 1
            case "JB_WISH":
                for w in [e.a, e.b] {
                    if c.wishMin == 0 || w < c.wishMin { c.wishMin = w }
                    if w > c.wishMax { c.wishMax = w }
                }
            case "PO_ACCEL": c.poAccelMs += Int(e.a)
            case "PO_PREEMPT": c.poStretchMs += Int(e.a)
            case "PO_EXPAND": c.poConcealMs += Int(e.a)
            case "PO_ZEROS": c.poZeroMs += Int(e.a)
            case "PO_LATE": c.poLate += 1
            case "PO_TARGET":
                for w in [e.a, e.b] {
                    if c.poTargetMin == 0 || w < c.poTargetMin { c.poTargetMin = w }
                    if w > c.poTargetMax { c.poTargetMax = w }
                }
            default: break
            }
        }
        return c
    }
}

extension BaresipCallEngine {
    /// All events of the current call's audio timeline (since dial/incoming).
    static func audioEvents() -> [AudioEvent] {
        let n = cb_audio_event_count()
        guard n > 0 else { return [] }
        var raw = [cb_audio_event_t](repeating: cb_audio_event_t(), count: n)
        let got = raw.withUnsafeMutableBufferPointer { cb_audio_events($0.baseAddress, n) }
        return raw.prefix(got).map { e in
            AudioEvent(tMs: Double(e.t_us) / 1000, kind: e.kind, name: String(cString: cb_audio_event_name(e.kind)), a: e.a, b: e.b)
        }
    }

    /// The last call's continuity summary, for headless tests (sim-call).
    public static var lastAudioContinuity: AudioContinuity? {
        continuityLock.withLock { continuityLast }
    }
    private static let continuityLock = NSLock()
    nonisolated(unsafe) private static var continuityLast: AudioContinuity?

    func logAudioContinuity(_ callID: String) {
        let c = AudioContinuity.summary(of: Self.audioEvents())
        Self.continuityLock.withLock { Self.continuityLast = c }
        log("engine: audio continuity call=\(callID): \(c.line)")
        for e in c.events {
            log("engine: audio event +\(String(format: "%.3f", e.tMs / 1000))s \(e.name) a=\(e.a) b=\(e.b)")
        }
    }
}
