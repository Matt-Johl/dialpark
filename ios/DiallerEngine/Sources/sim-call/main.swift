// sim-call: the app's whole call path, headless, on the iOS simulator.
//
// Same objects the app uses — LANSocketTransport → CallController →
// BaresipCallEngine (real baresip, real audiounit driver on
// VoiceProcessingIO) — with CallKit replaced by a scripted stand-in that
// answers and then activates the audio session in the order the device
// does. The call is asserted on what the phone actually received: RTP
// packets and the energy of the rendered audio (the caller plays a tone).
//
//   sim-call <gateway-host> <port> <device-id> <token> <wait-seconds> [activate-delay-ms]
//
// Prints "sim: PASS" or "sim: FAIL: <why>" and exits non-zero on failure.
// Driven by harness/sim_call.sh (`make sim-call`).
import CBaresip
import DiallerCore
import DiallerEngine
import DiallerProtocol
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments
guard args.count >= 6 else {
    print("usage: sim-call <host> <port> <device-id> <token> <wait-seconds> [activate-delay-ms]")
    exit(2)
}
let host = args[1]
let port = UInt16(args[2]) ?? 7443
let deviceID = args[3]
let token = args[4]
let waitSeconds = Int(args[5]) ?? 40
/// CallKit activates the session shortly after the answer action is
/// fulfilled; on the device that is ~100-200 ms, usually before the SIP
/// call establishes. Larger values test the other ordering.
let activateDelayMs = args.count > 6 ? (Int(args[6]) ?? 150) : 150
/// Optional audio source spec ("aufile,/path/tone.wav"): makes the simulated
/// phone transmit even though simctl-spawned processes have no microphone,
/// which is what drives the server's symmetric-RTP latching on a real phone.
let sourceOverride: String? = args.count > 7 && !args[7].isEmpty ? args[7] : nil
/// How long the "user" lets it ring before tapping Answer. A real person
/// takes seconds; the caller is already streaming into the server by then.
let answerDelayMs = args.count > 8 ? (Int(args[8]) ?? 800) : 800
/// Calls to take in this one process before reporting. The app takes many
/// calls per launch; a failure that appears only on the second call needs
/// the same engine, registration and session to be reused.
let callsWanted = args.count > 9 ? max(1, Int(args[9]) ?? 1) : 1
/// "nogateway": register over SIP only, no gateway session, so no wake ever
/// arrives and every call is rung from the INVITE (the app's "sip-N" path).
let noGateway = args.count > 10 && args[10] == "nogateway"
/// "outbound:<target>": this phone places the call (keypad / directory
/// path) instead of waiting for one; the harness callee auto-answers and
/// plays its tone, which is asserted exactly as for incoming calls.
let outboundTarget: String? = args.count > 10 && args[10].hasPrefix("outbound:") ? String(args[10].dropFirst("outbound:".count)) : nil
/// Hold test: after the 2 s verdict, hold for this long, then resume and
/// check that media stopped while held and flows again after. 0 = no hold.
let holdMs = args.count > 11 ? (Int(args[11]) ?? 0) : 0
/// Transfer test: after the 2 s verdict, REFER the far end to this target
/// and expect our call to end with "Call transfered" (the server connected
/// the other party and released us).
let transferTo: String? = args.count > 12 && !args[12].isEmpty ? args[12] : nil
/// Decline test: reject each call from the (scripted) CallKit banner after
/// `answerDelayMs` of ringing instead of answering it — the red button. The
/// caller must then get 486 Busy Here, which sim_call.sh asserts on phone-b's
/// log; here we assert the call rang, was never established, and ended.
let declineMode = args.count > 13 && (args[13] == "decline" || args[13] == "decline-reset")
/// "decline-reset": decline, then reset the SIP transports at once — the
/// sequence that crashed the app four times on 2026-09-17 16:29: the 486's
/// ACK arrives on a connection the reset has just dismembered. Run under
/// IMPAIR=1 so the server's ACK is late enough to be certain to land after
/// the reset. The verdict is the process surviving to report at all.
let resetAfterDecline = args.count > 13 && args[13] == "decline-reset"
/// Call-waiting test (plan Phase I): while call 1 is up, a second caller
/// rings; the scripted user takes Hold & Accept, talks on call 2, swaps
/// back to call 1, then ends both. Asserted on RTP reaching whichever call
/// is active and on the two calls carrying distinct stack ids.
let callWaitingMode = args.count > 13 && args[13] == "callwaiting"
/// Refusal test (plan Phase J): the outbound target refuses the call, and
/// the caller must hear busy or congestion *before* the call disappears —
/// CallKit takes the audio session away with the call, so the end report is
/// held back for the length of the tone.
let refusedMode = args.count > 13 && args[13] == "refused"
/// "ring-reset": the registration reset the app runs when its gateway
/// session comes back is issued while the call is ringing — the sequence
/// of 2026-09-18 15:12, where the INVITE was read 0.3 ms after the app's
/// "no call is up" check and the reset then freed the user agent under it
/// (486 to the caller, who was told the call failed; the phone rang on the
/// wake's replay anyway). The stack must refuse the reset and the call
/// must go on to be answered as usual.
let ringResetMode = args.count > 13 && args[13] == "ring-reset"

/// RTP received on the current call so far (cumulative).
func rtpReceived() -> UInt32 {
    var m = cb_media_stats_t()
    cb_media_stats(engine.activeEngineCallID, &m)
    return m.rx_packets
}

let t0 = Date()
/// Lines carry seconds since start so a stall shows as a gap.
func stamp() -> String { String(format: "%7.3f", Date().timeIntervalSince(t0)) }
func out(_ s: String) { print("\(stamp()) sim: \(s)") }

let engine = BaresipCallEngine(acceptAnyCertificate: true)

/// Process CPU time every 5 s, against wall time: what iOS's CPU-resource
/// limit measures (a killed app on 2026-09-18 08:45 had used 48 s of CPU in
/// 49 s — the libre loop spinning through a whole call). A healthy engine
/// on a call sits well under 30 %; anything near 100 % is a loop that
/// returns without waiting, and the harness has no other way to see it.
let cpuMeterStart = Date()
Thread {
    var last = 0.0
    while true {
        Thread.sleep(forTimeInterval: 5)
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        let cpu = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
                + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
        let wall = Date().timeIntervalSince(cpuMeterStart)
        out(String(format: "cpu: %.1fs used of %.0fs wall (%.0f%% overall, %.0f%% last 5s)", cpu, wall, cpu / wall * 100, (cpu - last) / 5 * 100))
        last = cpu
    }
}.start()
engine.setCredentials(username: deviceID, password: token) // SIP Digest on the app leg
engine.audioSourceOverride = sourceOverride
var lastCloseReason = ""
engine.onCallEnded = nil // set by the controller below; we observe through the log instead
let engineLog: (String) -> Void = { line in
    print("\(stamp())   \(line)")
    // "engine: call <id> closed (<reason>)"
    if line.hasPrefix("engine: call "), let open = line.range(of: " closed (") {
        lastCloseReason = String(line[open.upperBound...].dropLast())
    }
}
engine.log = engineLog

let lock = NSLock()
var registered = false
var inCall = false
var ended = false
var engineFailed: String?

engine.onStateChange = { s in
    print("  [state] \(s)")
    lock.lock(); defer { lock.unlock() }
    switch s {
    case .registered: registered = true; out("registered")
    case .inCall: inCall = true; out("in call")
    case .failed(let why): engineFailed = why
    default: break
    }
}

/// Scripted CallKit: report → (user taps) answer → (CallKit) didActivate.
final class ScriptedCallKit: CallUI {
    var onAnswer: (String) -> Void = { _ in }
    var onDecline: (String) -> Void = { _ in }
    /// Calls reported so far and the one in progress, so the main loop can
    /// wait for the NEXT call rather than react to the previous one's end.
    var reported = 0
    var current: String?
    /// Call-waiting mode: the second call, ringing while the first is up;
    /// the main loop performs Hold & Accept on it.
    var waiting: String?
    /// Whether the controller still tracks any call (set once it exists).
    var noCallsLeft: () -> Bool = { true }
    func reportIncoming(callID: String, displayName: String, handle: String, completion: @escaping (Error?) -> Void) {
        out("callkit: reporting \(callID) from \(displayName)")
        lock.lock()
        reported += 1
        let second = callWaitingMode && inCall && current != nil
        if second { waiting = callID } else { current = callID; ended = false }
        lock.unlock()
        completion(nil)
        if second {
            out("callkit: \(callID) is waiting (call-waiting banner: Hold & Accept / End & Accept / Decline)")
            return
        }
        if declineMode {
            // The user taps the red button while it rings: CallKit's end
            // action → controller.userEnded → wake_ack{decline} on the wire
            // channel and a 486 on the SIP leg. No answer, no audio session.
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(answerDelayMs)) {
                out("callkit: end action for \(callID) while ringing (declined after \(answerDelayMs)ms)")
                self.onDecline(callID)
                lock.lock(); if self.current == callID { ended = true }; lock.unlock()
            }
            return
        }
        if ringResetMode {
            // Off this thread, as the app's welcome handler is: the reset
            // is queued to the loop thread while the call it must not touch
            // is already in the stack's list.
            DispatchQueue.global().async {
                out("ring-reset: resetting the registration while \(callID) rings")
                engine.resetRegistration()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(answerDelayMs)) {
            out("callkit: answer action for \(callID) (after \(answerDelayMs)ms ringing)")
            self.onAnswer(callID) // → controller.userAnswered → engine answers → fulfill
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(activateDelayMs)) {
                out("callkit: didActivate (+\(activateDelayMs)ms)")
                engine.audioSessionActivated()
                callKit.toneSession(active: true)
            }
        }
    }
    func resume(callID: String) {
        // CallKit would perform the hold action and call back; do the same.
        out("callkit: resume action for \(callID) (the only call left)")
        controller.setHeld(callID: callID, false)
    }
    func end(callID: String, reason: CallEndReason) {
        out("callkit: ended \(callID) (\(reason))")
        lock.lock(); if current == callID { ended = true }; if endedAt == nil { endedAt = Date() }; lock.unlock()
        // CallKit deactivates the session only after the last call ends.
        if noCallsLeft() { engine.audioSessionDeactivated(); callKit.toneSession(active: false) }
    }
    /// Outgoing: CallKit approves the start action at once, then activates
    /// the session shortly after (as on the device).
    var onStart: (String) -> Void = { _ in }
    func startOutgoing(callID: String, handle: String, displayName: String) {
        out("callkit: start action for \(callID) → \(handle)")
        lock.lock(); reported += 1; current = callID; ended = false; lock.unlock()
        onStart(callID)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(activateDelayMs)) {
            out("callkit: didActivate (+\(activateDelayMs)ms)")
            engine.audioSessionActivated()
            callKit.toneSession(active: true)
        }
    }
    func outgoingConnecting(callID: String) { out("callkit: \(callID) connecting (far end ringing)") }
    /// Call-progress tones (plan Phase J). The simulator has no earpiece to
    /// judge, but which tone the controller asks for, when it stops, and —
    /// the part that broke the app on 2026-09-15 — whether it waits for
    /// CallKit's didActivate rather than activating the session itself, all
    /// are. The app's `TonePlayer` runs the same `TonePolicy`.
    var tonePolicy = TonePolicy()
    func playTone(_ tone: CallTones.Tone?) {
        apply(tonePolicy.want(tone), asked: tone)
    }
    /// CallKit handed the session over (or took it back).
    func toneSession(active: Bool) {
        apply(tonePolicy.session(active: active), asked: nil)
    }
    private func apply(_ action: TonePolicy.Action, asked: CallTones.Tone?) {
        switch action {
        case .stop: out("callkit: tone stop")
        case .nothing: break
        case .hold(let t): out("callkit: tone \(name(t)) HELD (no audio session yet)")
        case .play(let t):
            out("callkit: tone \(name(t))")
            if name(t) == "busy" || name(t) == "congestion" { noteFailureTone(name(t)) }
        }
        _ = asked
    }
    private func name(_ tone: CallTones.Tone) -> String {
        switch tone {
        case CallTones.ringback: return "ringback"
        case CallTones.busy: return "busy"
        case CallTones.congestion: return "congestion"
        case CallTones.callWaiting: return "callwaiting"
        default: return "\(Int(tone.hz))Hz"
        }
    }
    /// What the in-call screen would say under the name. The simulator has
    /// no screen, but the words are the app's answer to "what happened",
    /// and a refused call that says "Calling…" is the bug this guards.
    func callProgress(callID: String, _ progress: CallProgress) {
        out("callkit: \(callID) screen says \"\(progress.label)\"")
    }

    /// Refusal test: which failure tone started, and when — judged against
    /// when the call was reported ended.
    var failureTone: (name: String, at: Date)?
    var endedAt: Date?
    private func noteFailureTone(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        if failureTone == nil { failureTone = (name, Date()) }
    }
    func outgoingConnected(callID: String) {
        out("callkit: \(callID) connected")
        lock.lock(); inCall = true; lock.unlock()
        out("in call")
    }
}

/// One call's outcome.
struct CallResult {
    var index: Int
    var best: BaresipCallEngine.AudioVerdict?
    var established: Bool
    /// Decline mode: the call rang and then ended without being answered.
    var declined: Bool = false
}

func judge(_ r: CallResult) -> (String, Bool) {
    if refusedMode {
        if r.established { return ("FAIL: the call was answered, not refused", false) }
        lock.lock(); let tone = callKit.failureTone; let endedAt = callKit.endedAt; lock.unlock()
        guard let tone else { return ("FAIL: the call was refused but no failure tone was played", false) }
        guard let endedAt else { return ("FAIL: the failed call was never reported ended", false) }
        // Busy runs 4 s and congestion 3 s; anything under two means the
        // end was reported over the top of the tone.
        let held = endedAt.timeIntervalSince(tone.at)
        if held < 2 {
            return (String(format: "FAIL: the %@ tone was cut off — the end was reported %.1fs after it started", tone.name, held), false)
        }
        return (String(format: "PASS: refused; %@ tone played and the call disappeared %.1fs later", tone.name, held), true)
    }
    if declineMode {
        if r.established { return ("FAIL: call was answered, not declined", false) }
        if !r.declined { return ("FAIL: decline never took effect (still ringing at the deadline)", false) }
        return ("PASS: rang, declined from the banner, never established (phone-b must show 486 Busy Here)", true)
    }
    return judge(r.best, established: r.established)
}

func judge(_ v: BaresipCallEngine.AudioVerdict?, established: Bool) -> (String, Bool) {
    if !established { return ("FAIL: call never established (no INVITE or answer failed)", false) }
    guard let v else { return ("FAIL: no audio verdict (call ended before 2s?)", false) }
    if v.playFrames == 0 { return ("FAIL: output unit rendered nothing", false) }
    if v.rtpRx == 0 { return ("FAIL: no RTP received from the server", false) }
    if !v.audible { return ("FAIL: RTP arrived but rendered audio is silent (energy/frame \(v.playEnergy / max(v.playFrames, 1)))", false) }
    // A process spawned by simctl has no microphone access, so no capture
    // and nothing to send is the norm here; reported, not failed.
    let mic = v.recFrames > 0 ? "mic captured \(v.recFrames) frames, rtp tx=\(v.rtpTx)" : "rtp tx=\(v.rtpTx) (file source; no mic under simctl spawn)"
    if v.rxLost > 0 || v.jbUnderflow > 0 || v.jbLate > 0 {
        // On a clean network any loss or late packet is a defect somewhere
        // in the path (audio-quality gate, SPEC §7.2). Under deliberate
        // impairment (IMPAIR=1 → IMPAIRED=1 in our environment) it is the
        // expected input and the decoder's concealment is what is judged —
        // by the recording-based gates, not here.
        let detail = "lost=\(v.rxLost) late=\(v.jbLate) underflow=\(v.jbUnderflow); \(mic)"
        if impaired { return ("PASS under impairment: tone rendered; \(detail)", true) }
        return ("FAIL: tone rendered but the path lost or delayed packets on a clean network; \(detail)", false)
    }
    return ("PASS: tone received and rendered, no loss; \(mic)", true)
}
/// IMPAIR=1 runs export IMPAIRED=1 into the simulator process.
let impaired = ProcessInfo.processInfo.environment["IMPAIRED"] == "1"
let labCallSeconds = Int(ProcessInfo.processInfo.environment["CALL_SECONDS"] ?? "") ?? 0

let callKit = ScriptedCallKit()
let controller = CallController(ui: callKit, engine: engine, log: { print("\(stamp())   \($0)") })
callKit.onAnswer = { controller.userAnswered(callID: $0) }
/// decline-reset: how long after the 486 the reset runs (ms; env
/// DECLINE_RESET_DELAY_MS, forwarded by simctl as SIMCTL_CHILD_…). On the
/// phone the ACK arrives 2–5 ms after the 486, so the reset that crashed
/// it ran while the ACK was in flight; sweeping this places the reset
/// before, around and after the ACK's arrival.
let resetDelayMs = Int(ProcessInfo.processInfo.environment["DECLINE_RESET_DELAY_MS"] ?? "") ?? 0
callKit.onDecline = {
    let id = $0
    controller.userEnded(callID: id) // 486 on the SIP leg, decline ack on the wire
    if resetAfterDecline {
        // What the app does when its gateway session comes back: drop the
        // registration and flush libre's cached connections — here while
        // the 486's transaction is still waiting for its ACK.
        let fire = {
            out("decline-reset: resetting transports \(resetDelayMs)ms behind the 486")
            engine.resetRegistration()
            // And what follows the reset in the app: the welcome's
            // register, which allocates a fresh user agent while the old
            // connection's last packets may still be arriving.
            controller.setAccount(user: "203@dialpark", sip: SIPTarget(host: host, port: 5061, transport: "tls"))
        }
        if resetDelayMs > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(resetDelayMs), execute: fire)
        } else {
            fire()
        }
    }
}
callKit.onStart = { controller.userStarted(callID: $0) }
callKit.noCallsLeft = { controller.activeCalls.isEmpty }

// SIP_PIN (via SIMCTL_CHILD_SIP_PIN): the server certificate's pin, as
// enrolment stores it. Both legs then accept that certificate only, as the
// app does after enrolment; unset, both accept any (the harness default).
// SIP_LEG_PIN overrides the SIP leg's pin alone: a wrong one there, with
// the gateway pinned right, shows the SIP check refusing by itself.
let sipPin = ProcessInfo.processInfo.environment["SIP_PIN"].flatMap { $0.isEmpty ? nil : $0 }
let sipLegPin = ProcessInfo.processInfo.environment["SIP_LEG_PIN"].flatMap { $0.isEmpty ? nil : $0 } ?? sipPin
engine.setServerTrust(pin: sipLegPin, acceptAnyCertificate: sipLegPin == nil)
if let sipPin { out("pinned to \(sipPin) (SIP leg \(sipLegPin ?? "unpinned"))") }
let cfg = AppConfig(gateway: GatewayEndpoint(host: host, port: port, acceptAnyCertificate: sipPin == nil, certSHA256: sipPin),
                    deviceID: deviceID, token: token)
// The same session keeper as the app: reconnects after a drop, so a server
// restart mid-run (sim_call.sh RESTART_SERVER=1) must be survived.
let transport = GatewaySession(endpoint: cfg.gateway)
controller.attach(transport: transport)
var welcomes = 0
let eventTask = Task {
    for await ev in transport.events {
        switch ev {
        case .waiting(let r): out("gateway waiting: \(r)")
        case .connected(let w):
            out("gateway connected: session \(w.sessionID)")
            welcomes += 1
            if welcomes > 1 {
                // As the app does: the SIP connection died with the old
                // session, so register afresh rather than refresh on it.
                engine.resetRegistration()
            }
            if let sip = w.sip {
                controller.setAccount(user: "\(sip.user)@\(sip.domain)", sip: SIPTarget(host: sip.host, port: sip.port, transport: sip.transport))
            } else {
                out("FAIL: welcome carries no SIP account for \(deviceID)")
            }
        case .wake, .wakeCancel: controller.handle(ev)
        case .protocolError(let e): out("gateway error \(e.code.rawValue) \(e.message ?? "")")
        case .disconnected(let r): out("gateway disconnected: \(r)")
        case .directoryChanged, .config: break
        }
    }
}
out("connecting to \(host):\(port) as \(deviceID); activation delay \(activateDelayMs)ms; \(declineMode ? "DECLINE" : "answer") after \(answerDelayMs)ms; source \(sourceOverride ?? "microphone"); calls \(callsWanted)\(noGateway ? "; NO gateway (INVITE-only path)" : "")")
if noGateway {
    // The gateway's welcome normally names the SIP account; without it,
    // register the harness account directly. The controller then rings
    // every INVITE as a synthetic "sip-N" call, exactly as the app does
    // when a wake fails to arrive.
    controller.setAccount(user: "203@dialpark", sip: SIPTarget(host: host, port: 5061, transport: "tls"))
} else {
    transport.connect(hello: cfg.hello(kind: .app))
}

// Each call: wait for its 5 s verdict, its end, or the deadline. Between
// calls the process stays registered and connected, like the app.
let deadline = Date().addingTimeInterval(TimeInterval(waitSeconds))
var results: [CallResult] = []
var fatal: String?
for index in 1...callsWanted {
    lock.lock(); inCall = false; ended = false; let base = callKit.reported; lock.unlock()
    engine.clearAudioVerdicts()
    if let target = outboundTarget {
        // Place the call once registered (the account arrives with the
        // welcome; registration follows within a second).
        while Date() < deadline {
            lock.lock(); let ready = registered; lock.unlock()
            if ready { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        Thread.sleep(forTimeInterval: 0.5)
        out("dialling \(target)")
        if controller.startCall(to: target) == nil { out("FAIL: could not start the call") }
    }
    // Wait for this call to be reported before judging anything.
    while Date() < deadline {
        lock.lock(); let seen = callKit.reported > base; let failed = engineFailed; lock.unlock()
        if seen || failed != nil { break }
        Thread.sleep(forTimeInterval: 0.25)
    }
    var sawVerdict = false
    var holdResult: String?
    var transferAsked = false
    var transferResult: String?
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.25)
        if declineMode || refusedMode {
            // Nothing to measure: the call is over once the decline fires,
            // or (refused) once the tone has run and the end is reported.
            lock.lock(); let done = ended; let failed = engineFailed; lock.unlock()
            if failed != nil { fatal = failed; break }
            if done { sawVerdict = true; break }
            continue
        }
        if let target = transferTo, !transferAsked, let v = engine.audioVerdicts.first(where: { $0.seconds == 2 }), v.rtpRx > 0 {
            transferAsked = true
            lock.lock(); let id = callKit.current ?? ""; lock.unlock()
            out("transfer: REFER \(id) → \(target)")
            controller.transfer(callID: id, to: target)
        }
        if transferAsked, transferResult == nil {
            lock.lock(); let done = ended; lock.unlock()
            if done {
                transferResult = lastCloseReason.contains("transfer") ? "PASS: call released after the transfer (\(lastCloseReason))" : "FAIL: call ended with \(lastCloseReason), not a completed transfer"
                out("transfer: \(transferResult!)")
                if transferResult!.hasPrefix("FAIL") { fatal = transferResult }
                sawVerdict = true
                break
            }
        }
        if callWaitingMode, holdResult == nil, let v = engine.audioVerdicts.first(where: { $0.seconds == 2 }), v.rtpRx > 0 {
            // Call 1 is up and audible. The script now has the second
            // phone dial us; wait for its ring, then behave as the user
            // tapping Hold & Accept, talk, swap back, and end both.
            lock.lock(); let first = callKit.current ?? ""; lock.unlock()
            var second: String?
            let ringDeadline = Date().addingTimeInterval(20)
            while Date() < ringDeadline {
                lock.lock(); second = callKit.waiting; lock.unlock()
                if second != nil { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            guard let second else {
                holdResult = "FAIL: no second call rang within 20 s"
                out("callwaiting: \(holdResult!)")
                break
            }
            out("callwaiting: Hold & Accept — hold \(first), answer \(second)")
            controller.setHeld(callID: first, true) // CallKit's own hold action
            callKit.onAnswer(second)                // → userAnswered → engine answers call 2
            Thread.sleep(forTimeInterval: 1.0)      // let the answer and the re-INVITE settle
            let ids = controller.activeCalls.map { $0.engineCallID ?? "" }
            let a = rtpReceived()
            Thread.sleep(forTimeInterval: 3.0)
            let rx2 = rtpReceived() - a             // media on call 2 (the active one)
            out("callwaiting: swap — hold \(second), resume \(first)")
            controller.setHeld(callID: second, true)
            controller.setHeld(callID: first, false)
            Thread.sleep(forTimeInterval: 1.0)
            let b = rtpReceived()
            Thread.sleep(forTimeInterval: 2.0)
            let rx1 = rtpReceived() - b             // media back on call 1
            out("callwaiting: stack ids \(ids); rx on call 2 while active: \(rx2) packets in 3 s; rx on call 1 after the swap: \(rx1) packets in 2 s")
            if ids.count != 2 || ids.contains("") || ids[0] == ids[1] { holdResult = "FAIL: the two calls do not carry two distinct stack ids: \(ids)" }
            else if rx2 < 40 { holdResult = "FAIL: only \(rx2) packets on the second call while it was active" }
            else if rx1 < 40 { holdResult = "FAIL: only \(rx1) packets on the first call after swapping back" }
            else { holdResult = "PASS: second call rang, Hold & Accept took it, swap restored the first" }
            out("callwaiting: \(holdResult!)")
            out("callwaiting: ending both calls")
            controller.userEnded(callID: second)
            controller.userEnded(callID: first)
            sawVerdict = true
            break
        }
        if holdMs > 0, holdResult == nil, let v = engine.audioVerdicts.first(where: { $0.seconds == 2 }), v.rtpRx > 0 {
            // Hold: our re-INVITE goes sendonly; the server must stop
            // sending to us. Resume: it must start again.
            lock.lock(); let id = callKit.current ?? ""; lock.unlock()
            out("callkit: hold action for \(id)")
            controller.setHeld(callID: id, true)
            Thread.sleep(forTimeInterval: 0.6) // let in-flight packets land
            let atHold = rtpReceived()
            Thread.sleep(forTimeInterval: TimeInterval(holdMs) / 1000)
            let duringHold = rtpReceived() - atHold
            out("callkit: resume action for \(id)")
            controller.setHeld(callID: id, false)
            Thread.sleep(forTimeInterval: 0.6)
            let atResume = rtpReceived()
            Thread.sleep(forTimeInterval: 1.5)
            let afterResume = rtpReceived() - atResume
            out("hold: received \(duringHold) packets while held (\(holdMs)ms), \(afterResume) in 1.5s after resume")
            if duringHold > 5 { holdResult = "FAIL: server kept sending \(duringHold) packets while we were on hold" }
            else if afterResume < 40 { holdResult = "FAIL: only \(afterResume) packets after resume" }
            else { holdResult = "PASS: hold stopped media, resume restored it" }
            out("hold: \(holdResult!)")
        }
        // Lab: CALL_SECONDS keeps the call up past the 5 s verdict so the
        // jitter buffer's slow shrink (1–6 s timers) has time to act.
        let longEnough = labCallSeconds == 0 || engine.audioVerdicts.contains(where: { $0.seconds >= labCallSeconds })
        if engine.audioVerdicts.contains(where: { $0.seconds == 5 }) && (holdMs == 0 || holdResult != nil) && longEnough { sawVerdict = true; break }
        lock.lock(); let done = ended; let failed = engineFailed; lock.unlock()
        if failed != nil { fatal = failed; break }
        if done { break }
    }
    if let r = holdResult, r.hasPrefix("FAIL") { fatal = r }
    lock.lock(); let established = inCall; lock.unlock()
    if let c = BaresipCallEngine.lastAudioContinuity {
        out("call \(index) continuity: \(c.line)\(c.kinds.isEmpty ? "" : " [" + c.kinds + "]")")
    }
    let verdicts = engine.audioVerdicts
    for v in verdicts {
        out("call \(index) verdict @\(v.seconds)s: \(v.verdict) play=\(v.playFrames) rec=\(v.recFrames) energy/frame=\(v.playEnergy / max(v.playFrames, 1)) rtp tx=\(v.rtpTx) rx=\(v.rtpRx) lost=\(v.rxLost) jitter=\(v.jitterMs)ms jbuf late=\(v.jbLate) underflow=\(v.jbUnderflow)")
    }
    // Judge the LAST window: a call that degrades late must show it. The
    // hold test is the exception — its last window is the held stretch,
    // where silence is the expected result — so it keeps the best window.
    let best = holdMs > 0 || callWaitingMode
        ? verdicts.max { ($0.rtpRx, $0.playEnergy) < ($1.rtpRx, $1.playEnergy) }
        : verdicts.last
    lock.lock(); let wasDeclined = ended; lock.unlock()
    let res = CallResult(index: index, best: best, established: established, declined: wasDeclined)
    results.append(res)
    let (line, _) = judge(res)
    out("call \(index): \(line)")
    if fatal != nil || Date() >= deadline { break }
    if index < callsWanted {
        // Let this call end (the script hangs up) before expecting the next.
        while Date() < deadline {
            lock.lock(); let done = ended; lock.unlock()
            if done { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if !sawVerdict { out("note: call \(index) ended before its 5s verdict") }
        out("ready for call \(index + 1)")
    }
}

lock.lock(); let wasRegistered = registered; lock.unlock()
func result() -> (String, Int32) {
    if let fatal { return ("FAIL: engine failed: \(fatal)", 1) }
    if !wasRegistered { return ("FAIL: never registered", 1) }
    if results.count < callsWanted { return ("FAIL: only \(results.count) of \(callsWanted) calls happened before the deadline", 1) }
    var allOK = true
    for r in results where !judge(r).1 { allOK = false }
    if !allOK { return ("FAIL: see per-call lines above", 1) }
    if declineMode { return ("PASS: \(callsWanted) call(s) declined from the banner", 0) }
    if refusedMode { return ("PASS: \(callsWanted) refused call(s) heard their tone before disappearing", 0) }
    if callWaitingMode { return ("PASS: call waiting — second call taken with Hold & Accept and swapped back", 0) }
    return ("PASS: \(callsWanted) call(s) received and rendered", 0)
}
let (line, code) = result()
out(line)

engine.hangupAll()
transport.disconnect()
eventTask.cancel()
// Independent exit watchdog: baresip teardown must not hang the process.
Thread.detachNewThread { Thread.sleep(forTimeInterval: 5); exit(code) }
engine.stop()
exit(code)
