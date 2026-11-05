import XCTest
import DiallerProtocol
@testable import DiallerCore

final class FakeCallUI: CallUI {
    var reported: [(String, String)] = []
    var updated: [(String, String)] = []
    var ended: [(String, CallEndReason)] = []
    var refuse: Error?
    var started: [(String, String, String)] = []
    var connecting: [String] = []
    var connected: [String] = []
    /// Every `playTone` in order; nil is a stop.
    var tones: [CallTones.Tone?] = []
    /// Every progress report in order, as (call, progress).
    var progress: [(String, CallProgress)] = []
    /// When set, reports do not complete until `completePendingReports` —
    /// as on the device, where CallKit answers asynchronously and, for a
    /// suspended app, only once the process next runs.
    var deferReports = false
    var pendingCompletions: [(String, (Error?) -> Void)] = []
    func reportIncoming(callID: String, displayName: String, handle: String, completion: @escaping (Error?) -> Void) {
        reported.append((callID, displayName))
        if deferReports { pendingCompletions.append((callID, completion)) } else { completion(refuse) }
    }
    func completePendingReports(with error: Error?) {
        let pending = pendingCompletions
        pendingCompletions = []
        for (_, done) in pending { done(error) }
    }
    func updateIncoming(callID: String, displayName: String) { updated.append((callID, displayName)) }
    func end(callID: String, reason: CallEndReason) { ended.append((callID, reason)) }
    func startOutgoing(callID: String, handle: String, displayName: String) { started.append((callID, handle, displayName)) }
    func outgoingConnecting(callID: String) { connecting.append(callID) }
    func outgoingConnected(callID: String) { connected.append(callID) }
    func playTone(_ tone: CallTones.Tone?) { tones.append(tone) }
    func callProgress(callID: String, _ p: CallProgress) { progress.append((callID, p)) }
    var resumed: [String] = []
    func resume(callID: String) { resumed.append(callID) }
}

/// Records what the controller asks of the engine, by the engine's own call
/// ids. `dial` hands back "e-<callID>" so tests can name the outgoing call.
final class FakeEngine: CallEngine {
    var onIncomingCall: ((String, String, String?, String?) -> Void)?
    var onCallEnded: ((String, String, Int) -> Void)?
    var onOutgoingRinging: ((String, Bool) -> Void)?
    var onCallEstablished: ((String) -> Void)?
    var onTransferFailed: ((String, String) -> Void)?
    var transferred: [(String, String)] = []
    var registered: [String] = []
    var answered: [String] = []
    var rejected: [String] = []
    var hungUp: [String] = []
    var dialled: [(String, String)] = []
    var muted: [Bool] = []
    var held: [(String, Bool)] = []
    var dialFails = false
    /// The 200 OK cannot be written: the connection the INVITE arrived
    /// on died while the phone was suspended (2026-09-23).
    var answerFails = false
    func register(user: String, sip: SIPTarget) { registered.append(user) }
    @discardableResult
    func answer(engineCallID: String) -> Bool {
        if answerFails { return false }
        answered.append(engineCallID)
        return true
    }
    func reject(engineCallID: String) { rejected.append(engineCallID) }
    func dial(callID: String, to target: String) -> String? {
        dialled.append((callID, target))
        return dialFails ? nil : "e-\(callID)"
    }
    func hangup(engineCallID: String) { hungUp.append(engineCallID) }
    func setMuted(_ m: Bool) { muted.append(m) }
    func setHeld(engineCallID: String, _ h: Bool) { held.append((engineCallID, h)) }
    func transfer(engineCallID: String, to target: String) { transferred.append((engineCallID, target)) }
}

final class TransferTests: XCTestCase {
    let sip = SIPTarget(host: "dialler", port: 5061, transport: "tls")

    func testTransferOnlyOnAnsweredCalls() {
        let ui = FakeCallUI(), engine = FakeEngine()
        let c = CallController(ui: ui, engine: engine)
        c.setAccount(user: "201@dialler", sip: sip)
        c.handle(sipIncoming: "sip:202@dialler", engineCallID: "e1")
        c.transfer(callID: "sip-1", to: "100")
        XCTAssertTrue(engine.transferred.isEmpty, "ringing: nothing to transfer yet")
        c.userAnswered(callID: "sip-1")
        XCTAssertEqual(engine.answered, ["e1"])
        c.transfer(callID: "sip-1", to: " 100 ")
        XCTAssertEqual(engine.transferred.map { $0.0 }, ["e1"], "the engine is told which call")
        XCTAssertEqual(engine.transferred.map { $0.1 }, ["100"])
        c.transfer(callID: "sip-1", to: "   ")
        XCTAssertEqual(engine.transferred.count, 1, "empty target ignored")
    }

    /// A refused transfer has to reach the app in words it can show: the
    /// call carries on, so nothing else on screen would ever say it failed.
    func testRefusedTransferCarriesTheReasonAndTheWordsForIt() {
        let ui = FakeCallUI(), engine = FakeEngine()
        let c = CallController(ui: ui, engine: engine)
        var got: [(String, CallProgress?)] = []
        c.onTransferFailed = { reason, progress in got.append((reason, progress)) }
        engine.onTransferFailed?("e1", "486 Busy Here")
        guard let refused = got.first else { return XCTFail("nothing reported") }
        XCTAssertEqual(refused.0, "486 Busy Here", "the far end's own words, for the log")
        XCTAssertEqual(refused.1, .busy, "and words for the screen")

        engine.onTransferFailed?("e1", "Connection timed out")
        guard got.count == 2, let local = got.last else { return XCTFail("second failure not reported") }
        XCTAssertNil(local.1, "a local failure has no status, so nothing is invented")
    }

    func testRefusedTransferIsReportedAndCallContinues() {
        let ui = FakeCallUI(), engine = FakeEngine()
        let c = CallController(ui: ui, engine: engine)
        c.setAccount(user: "201@dialler", sip: sip)
        c.handle(sipIncoming: "sip:202@dialler", engineCallID: "e1")
        c.userAnswered(callID: "sip-1")
        var reported: [String] = []
        c.onTransferFailed = { reason, _ in reported.append(reason) }
        c.transfer(callID: "sip-1", to: "999")
        engine.onTransferFailed?("e1", "404 Not Found")
        XCTAssertEqual(reported, ["404 Not Found"])
        XCTAssertEqual(c.activeCalls.count, 1, "the call is still up after a refused transfer")
        // Success: the far end (server) ends our call once the target answered.
        engine.onCallEnded?("e1", "Call transfered", 0)
        XCTAssertTrue(c.activeCalls.isEmpty)
        XCTAssertEqual(ui.ended.map { $0.0 }, ["sip-1"])
    }
}

final class HoldTests: XCTestCase {
    let sip = SIPTarget(host: "dialler", port: 5061, transport: "tls")

    func testHoldAndResumeOnAnsweredCall() {
        let ui = FakeCallUI(), engine = FakeEngine()
        let c = CallController(ui: ui, engine: engine)
        c.setAccount(user: "201@dialler", sip: sip)
        c.startCall(to: "202")
        c.userStarted(callID: "out-1")
        // Not yet answered: a hold makes no sense and must not reach the engine.
        c.setHeld(callID: "out-1", true)
        XCTAssertTrue(engine.held.isEmpty)
        engine.onCallEstablished?("e-out-1")
        c.setHeld(callID: "out-1", true)
        c.setHeld(callID: "out-1", false)
        XCTAssertEqual(engine.held.map { $0.1 }, [true, false])
        XCTAssertEqual(engine.held.map { $0.0 }, ["e-out-1", "e-out-1"])
        XCTAssertEqual(c.activeCalls.first?.held, false)
        // Unknown call ids are ignored.
        c.setHeld(callID: "nope", true)
        XCTAssertEqual(engine.held.count, 2)
    }

    func testHoldOnAnsweredIncomingCall() {
        let ui = FakeCallUI(), engine = FakeEngine()
        let c = CallController(ui: ui, engine: engine)
        c.setAccount(user: "201@dialler", sip: sip)
        c.handle(sipIncoming: "sip:202@dialler", engineCallID: "e1")
        c.userAnswered(callID: "sip-1")
        c.setHeld(callID: "sip-1", true)
        XCTAssertEqual(engine.held.map { $0.0 }, ["e1"])
        XCTAssertEqual(c.activeCalls.first?.held, true)
    }
}

final class OutboundCallTests: XCTestCase {
    let sip = SIPTarget(host: "dialler", port: 5061, transport: "tls")

    func make() -> (CallController, FakeCallUI, FakeEngine) {
        let ui = FakeCallUI(), engine = FakeEngine()
        let c = CallController(ui: ui, engine: engine)
        c.setAccount(user: "201@dialler", sip: sip)
        return (c, ui, engine)
    }

    /// Keypad digits or a directory URI: system UI approves, then the engine
    /// dials; progress and answer are reported back to the system UI.
    func testStartCallGoesThroughSystemUIThenDials() {
        let (c, ui, engine) = make()
        let id = c.startCall(to: "202", displayName: "Phone B")
        XCTAssertEqual(id, "out-1")
        XCTAssertEqual(ui.started.map { $0.1 }, ["202"])
        XCTAssertEqual(ui.started.map { $0.2 }, ["Phone B"])
        XCTAssertTrue(engine.dialled.isEmpty, "must not dial before the system approves the call")

        c.userStarted(callID: "out-1")
        XCTAssertEqual(engine.dialled.map { $0.1 }, ["202"])
        XCTAssertEqual(c.activeCalls.first?.engineCallID, "e-out-1", "the stack's id is kept for the call")

        engine.onOutgoingRinging?("e-out-1", false)
        XCTAssertEqual(ui.connecting, ["out-1"])
        engine.onCallEstablished?("e-out-1")
        XCTAssertEqual(ui.connected, ["out-1"])
        XCTAssertEqual(c.activeCalls.first?.phase, .answered)
        XCTAssertEqual(c.activeCalls.first?.direction, .outgoing)

        engine.onCallEnded?("e-out-1", "BYE", 0)
        XCTAssertEqual(ui.ended.map { $0.0 }, ["out-1"])
        XCTAssertTrue(c.activeCalls.isEmpty)
    }

    func testUserHangsUpOutgoingCall() {
        let (c, _, engine) = make()
        c.startCall(to: "sip:202@dialler")
        c.userStarted(callID: "out-1")
        c.userEnded(callID: "out-1")
        XCTAssertEqual(engine.hungUp, ["e-out-1"])
        XCTAssertTrue(c.activeCalls.isEmpty)
    }

    func testDialFailureEndsTheCallInTheSystemUI() {
        let (c, ui, engine) = make()
        engine.dialFails = true
        c.startCall(to: "202")
        c.userStarted(callID: "out-1")
        XCTAssertEqual(ui.ended.map { $0.0 }, ["out-1"])
        XCTAssertEqual(ui.ended.first?.1, .failed)
        XCTAssertTrue(c.activeCalls.isEmpty)
    }

    func testNoAccountOrBusyRefusesToDial() {
        let ui = FakeCallUI(), engine = FakeEngine()
        let c = CallController(ui: ui, engine: engine)
        XCTAssertNil(c.startCall(to: "202"), "no SIP account yet")
        c.setAccount(user: "201@dialler", sip: sip)
        XCTAssertNotNil(c.startCall(to: "202"))
        XCTAssertNil(c.startCall(to: "203"), "one outgoing call at a time (a second outgoing call is a later phase)")
        XCTAssertNil(c.startCall(to: "   "))
    }

    func testSystemRefusalDropsTheCall() {
        let (c, _, engine) = make()
        c.startCall(to: "202")
        c.startFailed(callID: "out-1")
        XCTAssertTrue(c.activeCalls.isEmpty)
        XCTAssertTrue(engine.dialled.isEmpty)
    }

    func testMuteReachesEngine() {
        let (c, _, engine) = make()
        c.setMuted(true)
        c.setMuted(false)
        XCTAssertEqual(engine.muted, [true, false])
    }
}

final class CallControllerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func wake(_ id: String, expiresIn: TimeInterval = 30, name: String? = "Reception", from: String = "sip:100@pbx") -> Wake {
        Wake(callID: id, from: Party(displayName: name, uri: from), to: Party(uri: "sip:201@dialler"),
             sip: SIPTarget(host: "dialler", port: 5061, transport: "tls"), expiresAt: t0.addingTimeInterval(expiresIn))
    }

    func make() -> (CallController, FakeCallUI, FakeEngine, FakeTransport) {
        let ui = FakeCallUI(), engine = FakeEngine(), tr = FakeTransport()
        let c = CallController(ui: ui, engine: engine, now: { self.t0 })
        c.attach(transport: tr)
        return (c, ui, engine, tr)
    }

    func testResolveDisplayNameNamesIncomingCaller() {
        let (c, ui, _, _) = make()
        // The app layer resolves a known caller to its directory name.
        c.resolveDisplayName = { uri, provided in
            uri.contains("100") ? "SIP phone (101)" : provided
        }
        c.handle(.wake(wake("c1"))) // from sip:100@pbx, wake display name "Reception"
        XCTAssertEqual(ui.reported.first?.1, "SIP phone (101)", "directory name overrides the wake's own")
    }

    func testFallsBackToProvidedDisplayNameWhenNotInDirectory() {
        let (c, ui, _, _) = make()
        // Resolver models a directory that does not contain this caller.
        c.resolveDisplayName = { _, provided in provided }
        c.handle(.wake(wake("c1"))) // From display name "Reception", no directory match
        XCTAssertEqual(ui.reported.first?.1, "Reception", "middle tier: the caller's own display name")
    }

    func testWakeRingsThenAcksThenAnswerRegistersSIP() {
        let (c, ui, engine, tr) = make()
        c.handle(.wake(wake("c1")))
        XCTAssertEqual(ui.reported.map { $0.0 }, ["c1"])
        XCTAssertEqual(ui.reported.first?.1, "Reception")
        XCTAssertEqual(tr.sent, [.wakeAck(WakeAck(callID: "c1", action: .willAnswer))])
        XCTAssertEqual(c.activeCalls.map(\.phase), [.ringing])

        // Answered before the INVITE (wake path): the engine registers; the
        // INVITE is answered the moment it arrives.
        c.userAnswered(callID: "c1")
        XCTAssertEqual(engine.registered, ["201@dialler"], "user part of the wake's to URI")
        XCTAssertTrue(engine.answered.isEmpty, "nothing to answer yet")
        XCTAssertEqual(CallController.userPart(of: "\"Matt\" <sip:201@dialler;transport=tls>;tag=x"), "201@dialler")
        XCTAssertEqual(CallController.userPart(of: "201"), "201")
        XCTAssertEqual(c.activeCalls.map(\.phase), [.answered])

        engine.onIncomingCall?("e1", "sip:100@pbx", nil, "c1")
        XCTAssertEqual(engine.answered, ["e1"], "the INVITE that arrives is answered at once")
        XCTAssertEqual(ui.reported.count, 1, "it joined the ringing call; nothing rang twice")

        c.userEnded(callID: "c1")
        XCTAssertEqual(engine.hungUp, ["e1"])
        XCTAssertTrue(c.activeCalls.isEmpty)
        XCTAssertEqual(tr.sent.count, 1, "no decline ack after an answered call")
    }

    func testDuplicateWakeFromSecondTransportIsIgnored() {
        let (c, ui, _, tr) = make()
        c.handle(wake: wake("c1")) // e.g. via PushKit from the extension
        c.handle(.wake(wake("c1"))) // and again via the foreground socket
        XCTAssertEqual(ui.reported.count, 1)
        XCTAssertEqual(tr.sent.count, 1)
    }

    func testCancelEndsRingingCall() {
        let (c, ui, engine, _) = make()
        c.handle(.wake(wake("c1")))
        c.handle(.wakeCancel(WakeCancel(callID: "c1", reason: .callerHangup)))
        XCTAssertEqual(ui.ended.map { $0.0 }, ["c1"])
        XCTAssertEqual(ui.ended.first?.1, .remoteEnded)
        XCTAssertTrue(engine.hungUp.isEmpty, "no INVITE had arrived: nothing in the stack to hang up")
        XCTAssertTrue(c.activeCalls.isEmpty)
        c.handle(.wakeCancel(WakeCancel(callID: "ghost", reason: .timeout)))
        XCTAssertEqual(ui.ended.count, 1, "unknown call cancel is ignored")
    }

    // INVITE first (registered app), wake second: the call is tracked under
    // the INVITE's synthetic id. The server's cancel names the wake's id and
    // must still end it.
    func testCancelByWakeIDEndsACallThatRangFromItsINVITE() {
        let (c, ui, engine, _) = make()
        c.setAccount(user: "201@dialler", sip: SIPTarget(host: "10.0.0.1", port: 5061, transport: "tls"))
        c.handle(sipIncoming: "sip:100@pbx", displayName: "Reception", engineCallID: "e1", diallerCallID: "c1")
        c.handle(.wake(wake("c1")))
        XCTAssertEqual(c.activeCalls.count, 1)
        c.handle(.wakeCancel(WakeCancel(callID: "c1", reason: .callerHangup)))
        XCTAssertEqual(ui.ended.count, 1, "the cancel must resolve through the merged wake id")
        XCTAssertEqual(ui.ended.first?.1, .remoteEnded)
        XCTAssertEqual(engine.hungUp, ["e1"])
        XCTAssertTrue(c.activeCalls.isEmpty)
    }

    func testDeclineWhileRingingSendsDeclineAck() {
        let (c, _, _, tr) = make()
        c.handle(.wake(wake("c1")))
        c.userEnded(callID: "c1")
        XCTAssertEqual(tr.sent.last, .wakeAck(WakeAck(callID: "c1", action: .decline)))
    }

    func testExpiredWakeAndUIRefusal() {
        let (c, ui, _, tr) = make()
        c.handle(.wake(wake("old", expiresIn: -1)))
        XCTAssertTrue(ui.reported.isEmpty)
        XCTAssertTrue(c.activeCalls.isEmpty)

        ui.refuse = NSError(domain: "callkit", code: 1)
        c.handle(.wake(wake("c2")))
        XCTAssertEqual(tr.sent.last, .wakeAck(WakeAck(callID: "c2", action: .busy)))
        XCTAssertTrue(c.activeCalls.isEmpty)
    }

    // Device, 2026-09-17 13:22: the wake rang, the server dialled as soon as
    // the registration landed, and only then did CallKit refuse the report
    // (a Focus filter; the answer reached the app 20 s later, when the next
    // call resumed it). Dropping the record alone left the INVITE ringing
    // inside the SIP stack with nothing to answer or cancel it, which kept
    // the engine "in a call" and every later call off the phone.
    func testUIRefusalAfterTheInviteArrivedHangsUpTheSIPCall() {
        let (c, ui, engine, tr) = make()
        c.setAccount(user: "201@dialler", sip: SIPTarget(host: "10.0.0.1", port: 5061, transport: "tls"))
        ui.deferReports = true
        c.handle(.wake(wake("c1")))
        engine.onIncomingCall?("e1", "sip:100@pbx", nil, "c1") // joins the ringing call
        XCTAssertEqual(c.activeCalls.first?.engineCallID, "e1")
        XCTAssertTrue(engine.hungUp.isEmpty)

        ui.completePendingReports(with: NSError(domain: "com.apple.CallKit.error.incomingcall", code: 3))
        XCTAssertEqual(engine.hungUp, ["e1"], "the SIP call must not outlive the refused report")
        XCTAssertTrue(c.activeCalls.isEmpty)
        XCTAssertEqual(tr.sent.last, .wakeAck(WakeAck(callID: "c1", action: .busy)))
    }

    /// The same refusal before any INVITE: nothing in the stack to hang up.
    func testUIRefusalBeforeTheInviteHangsUpNothing() {
        let (c, ui, engine, _) = make()
        ui.deferReports = true
        c.handle(.wake(wake("c1")))
        ui.completePendingReports(with: NSError(domain: "callkit", code: 3))
        XCTAssertTrue(engine.hungUp.isEmpty)
        XCTAssertTrue(c.activeCalls.isEmpty)
    }

    func testRegisteredAppRingsFromInviteAlone() {
        // Foreground path: welcome carried the SIP account, the app registered,
        // and the server delivers the INVITE directly (no wake, or wake late).
        let (c, ui, engine, tr) = make()
        c.setAccount(user: "201@dialler", sip: SIPTarget(host: "10.0.0.1", port: 5061, transport: "tls"))
        XCTAssertEqual(engine.registered, ["201@dialler"])

        engine.onIncomingCall?("e1", "sip:202@dialler", nil, nil)
        XCTAssertEqual(ui.reported.count, 1)
        XCTAssertEqual(ui.reported.first?.1, "202", "no name, no directory → bare number, never the raw URI")
        XCTAssertTrue(tr.sent.isEmpty, "no wake → nothing to ack")
        let id = ui.reported.first!.0

        // A late wake for the same call (no header on this INVITE: the one
        // unclaimed INVITE-first call is the match) must not ring again.
        c.handle(.wake(wake("late")))
        XCTAssertEqual(ui.reported.count, 1)

        c.userAnswered(callID: id)
        XCTAssertEqual(engine.answered, ["e1"])

        engine.onCallEnded?("e1", "BYE", 0)
        XCTAssertEqual(ui.ended.map { $0.0 }, [id])
        XCTAssertTrue(c.activeCalls.isEmpty)
    }

    func testWakeThenInviteIsOneCall() {
        let (c, ui, engine, _) = make()
        c.setAccount(user: "201@dialler", sip: SIPTarget(host: "10.0.0.1", port: 5061, transport: "tls"))
        c.handle(.wake(wake("c1")))
        engine.onIncomingCall?("e1", "sip:100@pbx", nil, "c1")
        XCTAssertEqual(ui.reported.count, 1, "wake + INVITE for one call ring once")
        XCTAssertEqual(c.activeCalls.first?.sipArrived, true)
        XCTAssertEqual(c.activeCalls.first?.engineCallID, "e1")
        engine.onCallEnded?("e1", "caller hung up", 0)
        XCTAssertEqual(ui.ended.map { $0.0 }, ["c1"])
    }

    // Background wake (SPEC §2): the extension delivers the wake through
    // PushKit while the app is suspended. When the app resumes, its own
    // gateway session reports the drop it suffered during the suspension
    // (ECONNABORTED). That drop must not touch the ringing call: the INVITE
    // comes from the SIP registration the engine makes on answer, not from
    // the gateway session, and the extension's session is the one that acks.

    func testSessionDropDoesNotEndAnExtensionDeliveredWake() {
        let (c, ui, engine, _) = make()
        c.setAccount(user: "201@dialler", sip: SIPTarget(host: "10.0.0.1", port: 5061, transport: "tls"))
        XCTAssertEqual(c.handle(wake: wake("c1")), .rang) // via PushKit, not the socket
        c.handle(.disconnected(reason: "read failed: ECONNABORTED"))
        XCTAssertTrue(ui.ended.isEmpty, "the stale app session's drop must not end the ringing wake")
        c.userAnswered(callID: "c1")
        XCTAssertEqual(engine.registered.count, 2, "answer registers (again) so the server dials us")
        engine.onIncomingCall?("e1", "sip:100@pbx", nil, "c1")
        XCTAssertEqual(ui.reported.count, 1, "the INVITE joins the ringing call; nothing rings twice")
        XCTAssertEqual(c.activeCalls.first?.sipArrived, true)
        XCTAssertEqual(engine.answered, ["e1"], "and is answered, since the user already said yes")
        XCTAssertTrue(engine.hungUp.isEmpty)
    }

    // The same holds for a wake that came over the app's own socket and for a
    // call whose INVITE has arrived: a drop is not a call event. (A stale
    // wake replayed for a finished call is the server's to prevent — it
    // forgets a wake once its call is over — not the client's to guess at.)

    func testSessionDropLeavesSocketDeliveredAndEstablishedCallsAlone() {
        let (c, ui, engine, _) = make()
        c.setAccount(user: "201@dialler", sip: SIPTarget(host: "10.0.0.1", port: 5061, transport: "tls"))
        c.handle(.wake(wake("c1")))
        c.userAnswered(callID: "c1")
        c.handle(.disconnected(reason: "server closed"))
        XCTAssertTrue(ui.ended.isEmpty, "answered, INVITE pending: the registration will bring it")
        engine.onIncomingCall?("e1", "sip:100@pbx", nil, "c1")
        c.handle(.disconnected(reason: "server closed"))
        XCTAssertTrue(ui.ended.isEmpty, "the call lives on its SIP dialog, not the session")
        XCTAssertTrue(engine.hungUp.isEmpty)
        XCTAssertEqual(ui.reported.count, 1)
    }

    // The INVITE-first path (registered app, INVITE beats the wake) must name
    // the call exactly like the wake path: directory → caller's display name
    // → bare number. It used to report the raw peer URI.

    func testInviteFirstResolvesNameLikeTheWakePath() {
        let (c, ui, engine, _) = make()
        c.setAccount(user: "201@dialler", sip: SIPTarget(host: "10.0.0.1", port: 5061, transport: "tls"))
        c.resolveDisplayName = { uri, provided in uri.contains("101") ? "SIP phone (101)" : provided }
        engine.onIncomingCall?("e1", "sip:101@10.18.0.5", nil, nil)
        XCTAssertEqual(ui.reported.first?.1, "SIP phone (101)", "INVITE-first banner uses the directory, not the raw URI")
    }

    func testInviteFirstUsesCallerDisplayNameWhenNotInDirectory() {
        let (c, ui, engine, _) = make()
        c.setAccount(user: "201@dialler", sip: SIPTarget(host: "10.0.0.1", port: 5061, transport: "tls"))
        engine.onIncomingCall?("e1", "sip:101@10.18.0.5", "SIP phone", nil)
        XCTAssertEqual(ui.reported.first?.1, "SIP phone", "middle tier: the From display name baresip supplied")
        XCTAssertEqual(c.activeCalls.first?.wake.from.displayName, "SIP phone", "kept for the in-call title")
    }

    // Declining: the server only knows call ids it issued in a wake. An
    // INVITE-only call gets no ack (its 486 is the answer); a call the wake
    // caught up with is acked under the wake's id, not the synthetic one.

    func testDecliningAnInviteOnlyCallSendsNoWakeAck() {
        let (c, ui, engine, tr) = make()
        c.setAccount(user: "201@dialler", sip: SIPTarget(host: "10.0.0.1", port: 5061, transport: "tls"))
        engine.onIncomingCall?("e1", "sip:100@pbx", nil, nil)
        let id = ui.reported.first!.0
        c.userEnded(callID: id)
        XCTAssertTrue(tr.sent.isEmpty, "no wake was issued for \(id); an ack would be refused as unknown_call")
        XCTAssertEqual(engine.hungUp, ["e1"], "the engine rejects the INVITE (486)")
    }

    func testDecliningAfterALateWakeAcksTheWakeId() {
        let (c, ui, engine, tr) = make()
        c.setAccount(user: "201@dialler", sip: SIPTarget(host: "10.0.0.1", port: 5061, transport: "tls"))
        engine.onIncomingCall?("e1", "sip:100@pbx", nil, "late") // rings as sip-1, header names the server's id
        c.handle(.wake(wake("late")))                            // the same call's wake
        let id = ui.reported.first!.0
        c.userEnded(callID: id)
        XCTAssertEqual(tr.sent.last, .wakeAck(WakeAck(callID: "late", action: .decline)), "acked under the server's id")
    }

    func testLateWakeCorrectsTheBannerName() {
        let (c, ui, engine, _) = make()
        c.setAccount(user: "201@dialler", sip: SIPTarget(host: "10.0.0.1", port: 5061, transport: "tls"))
        engine.onIncomingCall?("e1", "sip:100@pbx", nil, "late") // INVITE wins the race: only the URI is known
        XCTAssertEqual(ui.reported.first?.1, "100")
        let id = ui.reported.first!.0
        c.handle(.wake(wake("late"))) // the wake knows the caller is "Reception"
        XCTAssertEqual(ui.reported.count, 1, "still one call")
        XCTAssertEqual(ui.updated.map { $0.0 }, [id])
        XCTAssertEqual(ui.updated.first?.1, "Reception", "banner corrected mid-ring")
        XCTAssertEqual(c.activeCalls.first?.wake.from.displayName, "Reception")
    }

    func testDisplayNameFallsBackToNumber() {
        let (c, ui, _, _) = make()
        c.handle(.wake(wake("c3", name: nil)))
        XCTAssertEqual(ui.reported.first?.1, "100", "no name, no directory match → the bare number, not user@host or the raw URI")
    }

    func testNumberPartStripsSchemeParamsAndHost() {
        XCTAssertEqual(CallController.numberPart(of: "\"Alice\" <sip:1001@pbx>"), "1001")
        XCTAssertEqual(CallController.numberPart(of: "sip:101@10.18.0.5;transport=udp"), "101")
        XCTAssertEqual(CallController.numberPart(of: "201"), "201")
    }

    /// SPEC §6 item 16: the handle CallKit writes to the Phone app is the
    /// directory number whatever spelling the party arrived under, so one
    /// party is one row; a non-numeric user keeps its host for routing.
    func testCallKitHandleIsTheDirectoryNumber() {
        let cases: [(String, String)] = [
            ("10910", "10910"),                                   // keypad
            ("sip:10910@dialpark", "10910"),                      // the Recents tab's stored URI, an incoming INVITE
            ("sip:10910@dialpark;transport=tls", "10910"),        // with transport parameter
            ("\"Alice\" <sip:1001@pbx>;tag=x", "1001"),          // a From header
            ("sip:30933@10.7.160.11;transport=udp", "30933"),     // a trunk caller via the PBX
        ]
        for (uri, want) in cases {
            XCTAssertEqual(CallController.callKitHandle(of: uri), want, uri)
        }
        XCTAssertEqual(CallController.callKitHandle(of: "sip:+441632960000@10.7.160.11"), "+441632960000", "an external number keeps its plus")
        XCTAssertEqual(CallController.callKitHandle(of: "*72"), "*72", "feature codes are dialable")
        XCTAssertEqual(CallController.callKitHandle(of: "sip:alice@example.com"), "alice@example.com", "a named user keeps its host so a call-back routes")
    }
}

// Call waiting (plan Phase I): a second incoming call while one is up rings
// as its own call; answering it holds the first; each call ends, is held or
// is declined on its own; a third caller, or any second caller with call
// waiting off, is refused with 486.
final class CallWaitingTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let sip = SIPTarget(host: "10.0.0.1", port: 5061, transport: "tls")

    func wake(_ id: String, from: String) -> Wake {
        Wake(callID: id, from: Party(displayName: nil, uri: from), to: Party(uri: "sip:201@dialler"),
             sip: sip, expiresAt: t0.addingTimeInterval(30))
    }

    /// A controller with call 1 (from 101) answered and active.
    func makeInCall() -> (CallController, FakeCallUI, FakeEngine, FakeTransport) {
        let ui = FakeCallUI(), engine = FakeEngine(), tr = FakeTransport()
        let c = CallController(ui: ui, engine: engine, now: { self.t0 })
        c.attach(transport: tr)
        c.setAccount(user: "201@dialler", sip: sip)
        engine.onIncomingCall?("e1", "sip:101@pbx", nil, "c1")
        c.userAnswered(callID: "sip-1")
        XCTAssertEqual(engine.answered, ["e1"])
        return (c, ui, engine, tr)
    }

    func testSecondInviteRingsItsOwnCallAndAnsweringHoldsTheFirst() {
        let (c, ui, engine, _) = makeInCall()
        engine.onIncomingCall?("e2", "sip:100@pbx", "Reception", "c2")
        XCTAssertEqual(ui.reported.map { $0.0 }, ["sip-1", "sip-2"], "the second caller rings as a second call")
        XCTAssertEqual(ui.reported.last?.1, "Reception")
        XCTAssertEqual(c.activeCalls.count, 2)

        // Hold & Accept: the first call goes on hold, then the second is answered.
        c.userAnswered(callID: "sip-2")
        XCTAssertEqual(engine.held.map { $0.0 }, ["e1"])
        XCTAssertEqual(engine.held.map { $0.1 }, [true])
        XCTAssertEqual(engine.answered, ["e1", "e2"])
        let first = c.activeCalls.first { $0.wake.callID == "sip-1" }
        XCTAssertEqual(first?.held, true)
        XCTAssertEqual(c.activeCalls.first { $0.wake.callID == "sip-2" }?.held, false)
    }

    /// Call 1 answered, call 2 taken with Hold & Accept: call 1 held, call 2 active.
    func makeTwoCalls() -> (CallController, FakeCallUI, FakeEngine) {
        let (c, ui, engine, _) = makeInCall()
        engine.onIncomingCall?("e2", "sip:100@pbx", "Reception", "c2")
        c.userAnswered(callID: "sip-2")
        XCTAssertEqual(engine.held.map { $0.0 }, ["e1"])
        return (c, ui, engine)
    }

    func testEndingTheActiveCallResumesTheHeldOne() {
        let (c, ui, engine) = makeTwoCalls()
        c.userEnded(callID: "sip-2")
        XCTAssertEqual(engine.hungUp, ["e2"])
        XCTAssertEqual(ui.resumed, ["sip-1"], "the only call left was on hold: the controller asks the system to resume it")
        // The system performs the resume and calls back, as CallKit does.
        c.setHeld(callID: "sip-1", false)
        XCTAssertEqual(engine.held.last?.0, "e1")
        XCTAssertEqual(engine.held.last?.1, false)
        XCTAssertEqual(c.activeCalls.first?.held, false)
    }

    func testFarEndEndingTheActiveCallResumesTheHeldOne() {
        let (c, ui, engine) = makeTwoCalls()
        engine.onCallEnded?("e2", "Connection reset by peer", 0)
        XCTAssertEqual(ui.ended.map { $0.0 }, ["sip-2"])
        XCTAssertEqual(ui.resumed, ["sip-1"])
    }

    func testEndingTheHeldCallLeavesTheActiveOneAlone() {
        let (c, ui, engine) = makeTwoCalls()
        c.userEnded(callID: "sip-1")
        XCTAssertEqual(engine.hungUp, ["e1"])
        XCTAssertEqual(ui.resumed, [], "the remaining call is active, nothing to resume")
    }

    func testDecliningARingingSecondCallDoesNotResumeACallHeldOnPurpose() {
        let (c, ui, engine, _) = makeInCall()
        c.setHeld(callID: "sip-1", true) // the user held call 1 themselves
        engine.onIncomingCall?("e2", "sip:100@pbx", nil, "c2")
        c.userEnded(callID: "sip-2") // Decline
        XCTAssertEqual(engine.hungUp, ["e2"])
        XCTAssertEqual(ui.resumed, [], "no conversation ended; the held call stays as the user left it")
    }

    func testSecondWakeMatchesItsOwnInviteByHeaderNotTheActiveCall() {
        let (c, ui, engine, tr) = makeInCall()
        XCTAssertEqual(c.handle(wake: wake("c2", from: "sip:100@pbx")), .rang)
        XCTAssertEqual(ui.reported.map { $0.0 }, ["sip-1", "c2"])
        XCTAssertEqual(tr.sent.last, .wakeAck(WakeAck(callID: "c2", action: .willAnswer)))
        engine.onIncomingCall?("e2", "sip:100@pbx", nil, "c2")
        XCTAssertEqual(ui.reported.count, 2, "the INVITE joined the second call, it did not ring a third")
        XCTAssertEqual(c.activeCalls.first { $0.wake.callID == "c2" }?.engineCallID, "e2")
        XCTAssertEqual(c.activeCalls.first { $0.wake.callID == "sip-1" }?.wakeCallID, nil, "the active call is untouched")
    }

    func testByeOnOneCallLeavesTheOther() {
        let (c, ui, engine, _) = makeInCall()
        engine.onIncomingCall?("e2", "sip:100@pbx", nil, "c2")
        c.userAnswered(callID: "sip-2")
        engine.onCallEnded?("e2", "BYE", 0)
        XCTAssertEqual(ui.ended.map { $0.0 }, ["sip-2"])
        XCTAssertEqual(c.activeCalls.map { $0.wake.callID }, ["sip-1"], "the first call stays (on hold, for the user to resume)")
        XCTAssertEqual(c.activeCalls.first?.held, true)
    }

    func testCancelOfTheWaitingCallLeavesTheActiveOne() {
        let (c, ui, engine, _) = makeInCall()
        c.handle(.wake(wake("c2", from: "sip:100@pbx")))
        engine.onIncomingCall?("e2", "sip:100@pbx", nil, "c2")
        c.handle(.wakeCancel(WakeCancel(callID: "c2", reason: .callerHangup)))
        XCTAssertEqual(ui.ended.map { $0.0 }, ["c2"])
        XCTAssertEqual(engine.hungUp, ["e2"])
        XCTAssertEqual(c.activeCalls.map { $0.wake.callID }, ["sip-1"])
        XCTAssertTrue(engine.held.isEmpty, "the active call was never touched")
    }

    func testDecliningTheWaitingCallRejectsOnlyIt() {
        let (c, ui, engine, tr) = makeInCall()
        c.handle(.wake(wake("c2", from: "sip:100@pbx")))
        engine.onIncomingCall?("e2", "sip:100@pbx", nil, "c2")
        c.userEnded(callID: "c2")
        XCTAssertEqual(tr.sent.last, .wakeAck(WakeAck(callID: "c2", action: .decline)))
        XCTAssertEqual(engine.hungUp, ["e2"], "486 for the second call only")
        XCTAssertEqual(c.activeCalls.map { $0.wake.callID }, ["sip-1"])
        XCTAssertTrue(ui.ended.isEmpty)
    }

    func testSwapIsAHoldAndAResumeOnTheRightCalls() {
        let (c, _, engine, _) = makeInCall()
        engine.onIncomingCall?("e2", "sip:100@pbx", nil, "c2")
        c.userAnswered(callID: "sip-2") // holds e1
        engine.held.removeAll()
        // CallKit's swap: hold the active, resume the held.
        c.setHeld(callID: "sip-2", true)
        c.setHeld(callID: "sip-1", false)
        XCTAssertEqual(engine.held.map { $0.0 }, ["e2", "e1"])
        XCTAssertEqual(engine.held.map { $0.1 }, [true, false])
        XCTAssertEqual(c.activeCalls.first { $0.wake.callID == "sip-1" }?.held, false)
        XCTAssertEqual(c.activeCalls.first { $0.wake.callID == "sip-2" }?.held, true)
    }

    func testCallWaitingOffRefusesASecondCaller() {
        let (c, ui, engine, tr) = makeInCall()
        c.callWaitingEnabled = false
        engine.onIncomingCall?("e2", "sip:100@pbx", nil, nil)
        XCTAssertEqual(engine.rejected, ["e2"], "486 Busy Here for the second INVITE")
        XCTAssertEqual(ui.reported.count, 1, "nothing rang")
        XCTAssertEqual(c.activeCalls.count, 1)
        // A wake for another call is refused the same way, through the server.
        XCTAssertEqual(c.handle(wake: wake("c3", from: "sip:100@pbx")), .refused)
        XCTAssertEqual(tr.sent.last, .wakeAck(WakeAck(callID: "c3", action: .busy)))
        XCTAssertEqual(ui.reported.count, 1)
    }

    func testAThirdCallerIsRefused() {
        let (c, ui, engine, _) = makeInCall()
        engine.onIncomingCall?("e2", "sip:100@pbx", nil, "c2")
        c.userAnswered(callID: "sip-2")
        engine.onIncomingCall?("e3", "sip:102@pbx", nil, "c3")
        XCTAssertEqual(engine.rejected, ["e3"])
        XCTAssertEqual(ui.reported.count, 2)
        XCTAssertEqual(c.activeCalls.count, 2)
        XCTAssertEqual(c.handle(wake: wake("c4", from: "sip:102@pbx")), .refused)
    }

    func testTheEngineEndOfARefusedCallIsIgnored() {
        let (c, ui, engine, _) = makeInCall()
        c.callWaitingEnabled = false
        engine.onIncomingCall?("e2", "sip:100@pbx", nil, nil)
        engine.onCallEnded?("e2", "rejected 486 Busy Here", 0) // the stack reports the end of what we refused
        XCTAssertTrue(ui.ended.isEmpty)
        XCTAssertEqual(c.activeCalls.count, 1)
    }
}

/// Answering a wake commits CallKit to a call the SIP stack has not seen
/// yet. If the INVITE never follows — the server's route to us was stale and
/// nothing brought it back — the call must not sit there connected and
/// silent for ever (2026-09-23: the caller rang on while the app showed a
/// live call with no dialog behind it).
final class WakeAnsweredWithoutInviteTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var clock = Date(timeIntervalSince1970: 1_800_000_000)

    func wake(_ id: String, expiresIn: TimeInterval = 30) -> Wake {
        Wake(callID: id, from: Party(displayName: "Reception", uri: "sip:100@pbx"), to: Party(uri: "sip:201@dialler"),
             sip: SIPTarget(host: "dialler", port: 5061, transport: "tls"), expiresAt: t0.addingTimeInterval(expiresIn))
    }

    /// Returns the controller and a way to fire the armed deadline, so the
    /// test decides when it passes rather than waiting out real seconds.
    func make() -> (CallController, FakeCallUI, FakeEngine, () -> Double?) {
        let ui = FakeCallUI(), engine = FakeEngine()
        let c = CallController(ui: ui, engine: engine, now: { self.clock })
        c.attach(transport: FakeTransport())
        var armed: (Double, () -> Void)?
        c.scheduleDeadline = { secs, work in armed = (secs, work) }
        return (c, ui, engine, {
            guard let (secs, work) = armed else { return nil }
            armed = nil
            work()
            return secs
        })
    }

    func testStrandedCallEndsAtTheWakeExpiry() {
        let (c, ui, engine, fireDeadline) = make()
        var records: [CallRecord] = []
        c.onCallEnded = { records.append($0) }

        c.handle(.wake(wake("c1", expiresIn: 30)))
        clock = t0.addingTimeInterval(4)
        c.userAnswered(callID: "c1")
        XCTAssertEqual(engine.registered, ["201@dialler"], "it registers so the server can dial us")
        XCTAssertEqual(c.activeCalls.map(\.phase), [.answered])

        // 26 s of the wake's 30 s are left when the user answers.
        let armedFor = fireDeadline()
        XCTAssertEqual(armedFor ?? 0, 26, accuracy: 0.001, "armed for what is left of the wake")

        XCTAssertTrue(c.activeCalls.isEmpty, "a call whose INVITE never came must not stay up")
        XCTAssertEqual(ui.ended.map(\.0), ["c1"])
        XCTAssertEqual(ui.ended.map(\.1), [.failed], "it failed; the user never got a conversation")
        XCTAssertEqual(records.count, 1)
        XCTAssertNotEqual(records[0].outcome, .completed, "not a completed call with a duration")
        XCTAssertTrue(engine.hungUp.isEmpty, "there was no SIP call to hang up")
    }

    /// The INVITE arriving is the whole point of the wait: once it has, the
    /// deadline must not touch the call.
    func testDeadlineDoesNotTouchACallWhoseInviteArrived() {
        let (c, ui, engine, fireDeadline) = make()
        c.handle(.wake(wake("c1")))
        c.userAnswered(callID: "c1")
        engine.onIncomingCall?("e1", "sip:100@pbx", nil, "c1")
        XCTAssertEqual(engine.answered, ["e1"])

        _ = fireDeadline()

        XCTAssertEqual(c.activeCalls.map(\.phase), [.answered], "the call carries on")
        XCTAssertTrue(ui.ended.isEmpty)
    }

    /// Answering as the wake expires still allows a grace for our REGISTER
    /// and the server's INVITE to cross, rather than ending at once.
    func testAnsweringAtTheExpiryStillGetsAGrace() {
        let (c, _, _, fireDeadline) = make()
        c.handle(.wake(wake("c1", expiresIn: 30)))
        clock = t0.addingTimeInterval(30) // nothing left of the wake
        c.userAnswered(callID: "c1")

        let armedFor = fireDeadline()
        XCTAssertEqual(armedFor ?? 0, 5, accuracy: 0.001, "the floor, not zero")
    }

    /// A call the user hung up before the deadline is gone; the deadline
    /// must not then report a second ending for it.
    func testDeadlineAfterTheUserHungUpDoesNothing() {
        let (c, ui, _, fireDeadline) = make()
        c.handle(.wake(wake("c1")))
        c.userAnswered(callID: "c1")
        c.userEnded(callID: "c1")
        let endedByUser = ui.ended.count

        _ = fireDeadline()

        XCTAssertEqual(ui.ended.count, endedByUser, "no second ending")
    }

    /// A call that rang from the INVITE alone has a dialog from the start,
    /// so there is nothing to wait for and no deadline to arm.
    func testNoDeadlineWhenTheInviteCameFirst() {
        let (c, ui, engine, fireDeadline) = make()
        // Foreground path: the app is registered and the INVITE comes
        // straight to the SIP stack, so the call has a dialog from the start.
        c.setAccount(user: "201@dialler", sip: SIPTarget(host: "10.0.0.1", port: 5061, transport: "tls"))
        engine.onIncomingCall?("e1", "sip:202@dialler", nil, nil)
        let id = ui.reported.first!.0
        c.userAnswered(callID: id)
        XCTAssertEqual(engine.answered, ["e1"])

        XCTAssertNil(fireDeadline(), "nothing was armed")
        XCTAssertEqual(c.activeCalls.map(\.phase), [.answered])
    }
}

/// The 2026-09-23 failure, call ef036a07. The INVITE arrived, the user
/// answered, and the 200 OK could not be written — the connection it came in
/// on had died while the phone was suspended:
///
///     05:11:11.874Z engine: INVITE 863bf92c… for call ef036a07
///     05:11:15.218Z callkit: answer accepted … answered ef036a07
///     05:11:15.219Z baresip: tls: SSL_write: 5
///     05:11:15.219Z engine: answer of 863bf92c… failed (-100)
///     05:11:15.288Z callkit: observer … connected=true
///     05:11:15.710Z callkit: audio session activated
///
/// Nothing acted on that failure: CallKit went connected, took the audio
/// session, and the user sat in silence while 101 rang on until the server
/// gave up.
final class AnswerThatCannotBeSentTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func wake(_ id: String) -> Wake {
        Wake(callID: id, from: Party(displayName: "SIP phone", uri: "sip:101@10.18.0.5"), to: Party(uri: "sip:201@dialler"),
             sip: SIPTarget(host: "dialler", port: 5061, transport: "tls"), expiresAt: t0.addingTimeInterval(30))
    }

    func make() -> (CallController, FakeCallUI, FakeEngine) {
        let ui = FakeCallUI(), engine = FakeEngine()
        let c = CallController(ui: ui, engine: engine, now: { self.t0 })
        c.attach(transport: FakeTransport())
        return (c, ui, engine)
    }

    /// The wake path, exactly as it happened: wake, INVITE, answer, and the
    /// answer cannot be sent.
    func testCallEndsWhenTheAnswerCannotBeSent() {
        let (c, ui, engine) = make()
        var records: [CallRecord] = []
        c.onCallEnded = { records.append($0) }

        c.handle(.wake(wake("ef036a07")))
        engine.onIncomingCall?("863bf92c", "sip:101@10.18.0.5", "SIP phone", "ef036a07")
        XCTAssertEqual(c.activeCalls.map(\.phase), [.ringing])

        engine.answerFails = true
        c.userAnswered(callID: "ef036a07")

        XCTAssertTrue(c.activeCalls.isEmpty, "a call whose answer never went out must not stay up")
        XCTAssertEqual(ui.ended.map(\.0), ["ef036a07"])
        XCTAssertEqual(ui.ended.map(\.1), [.failed])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].outcome, .failed, "no conversation happened")
        XCTAssertNil(records[0].duration, "and so no duration")
    }

    /// The same failure on the other answer path: the user answered on the
    /// wake and the INVITE arrived afterwards, so the controller answers it
    /// itself.
    func testCallEndsWhenTheAutoAnswerCannotBeSent() {
        let (c, ui, engine) = make()
        c.handle(.wake(wake("ef036a07")))
        c.userAnswered(callID: "ef036a07") // no INVITE yet: registers and waits
        XCTAssertEqual(engine.registered, ["201@dialler"])

        engine.answerFails = true
        engine.onIncomingCall?("863bf92c", "sip:101@10.18.0.5", "SIP phone", "ef036a07")

        XCTAssertTrue(c.activeCalls.isEmpty, "the late INVITE could not be answered either")
        XCTAssertEqual(ui.ended.map(\.1), [.failed])
    }

    /// The normal path must be untouched: an answer that goes out leaves a
    /// connected call that records as completed, with its duration.
    func testAnswerThatGoesOutLeavesTheCallUp() {
        let (c, ui, engine) = make()
        c.handle(.wake(wake("ef036a07")))
        engine.onIncomingCall?("863bf92c", "sip:101@10.18.0.5", "SIP phone", "ef036a07")
        c.userAnswered(callID: "ef036a07")

        XCTAssertEqual(engine.answered, ["863bf92c"])
        XCTAssertEqual(c.activeCalls.map(\.phase), [.answered])
        XCTAssertTrue(ui.ended.isEmpty, "nothing failed")
        XCTAssertEqual(c.activeCalls.first?.connected, true)
    }
}
