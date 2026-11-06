import XCTest
import DiallerProtocol
@testable import DiallerCore

/// The classification table and the on-disk list (SPEC §6 item 6).
final class RecentsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func record(_ id: String, outcome: CallRecord.Outcome = .missed, wakeCallID: String? = nil, endedAt: Date? = nil) -> CallRecord {
        CallRecord(id: id, wakeCallID: wakeCallID, direction: .incoming, counterpart: Party(displayName: "Reception", uri: "sip:100@pbx"),
                   startedAt: t0, endedAt: endedAt ?? t0.addingTimeInterval(10), outcome: outcome)
    }

    func tempStore() -> RecentsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recents-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return RecentsStore(directory: dir)
    }

    // MARK: Classification

    func testAnsweredCallsAreCompleteWhateverEndedThem() {
        for direction in [CallRecord.Direction.incoming, .outgoing] {
            for ending in [CallRecord.Ending.sip(status: 0), .sip(status: 486), .user, .cancelled(.callerHangup), .failed] {
                XCTAssertEqual(CallRecord.outcome(direction: direction, answered: true, ending: ending), .completed, "\(direction) \(ending)")
            }
        }
    }

    func testIncomingUnansweredTable() {
        let o = { (e: CallRecord.Ending) in CallRecord.outcome(direction: .incoming, answered: false, ending: e) }
        XCTAssertEqual(o(.sip(status: 0)), .missed, "the caller cancelled")
        XCTAssertEqual(o(.cancelled(.callerHangup)), .missed)
        XCTAssertEqual(o(.cancelled(.timeout)), .missed)
        XCTAssertEqual(o(.cancelled(.answeredElsewhere)), .answeredElsewhere)
        XCTAssertEqual(o(.user), .declined)
        XCTAssertEqual(o(.refused), .missed, "call waiting off: the caller heard busy, the user saw nothing")
        XCTAssertEqual(o(.failed), .missed, "CallKit would not show it")
    }

    func testOutgoingUnansweredTable() {
        let o = { (e: CallRecord.Ending) in CallRecord.outcome(direction: .outgoing, answered: false, ending: e) }
        XCTAssertEqual(o(.user), .cancelled)
        XCTAssertEqual(o(.sip(status: 487)), .cancelled, "the answer to our own CANCEL")
        XCTAssertEqual(o(.sip(status: 486)), .busy)
        XCTAssertEqual(o(.sip(status: 600)), .busy)
        XCTAssertEqual(o(.sip(status: 603)), .declined)
        XCTAssertEqual(o(.sip(status: 408)), .noAnswer)
        XCTAssertEqual(o(.sip(status: 404)), .unknownNumber)
        XCTAssertEqual(o(.sip(status: 480)), .unavailable)
        XCTAssertEqual(o(.sip(status: 503)), .unavailable)
        XCTAssertEqual(o(.sip(status: 500)), .failed)
        XCTAssertEqual(o(.sip(status: 0)), .failed, "ended with no answer and no status")
        XCTAssertEqual(o(.failed), .failed)
    }

    func testSummaryAndDuration() {
        var r = record("c1", outcome: .completed)
        r.connectedAt = t0.addingTimeInterval(2)
        r.endedAt = t0.addingTimeInterval(47)
        XCTAssertEqual(r.duration, 45)
        XCTAssertEqual(r.summary, "0:45")
        XCTAssertEqual(CallRecord.durationText(3725), "1:02:05")
        XCTAssertEqual(CallRecord.durationText(0.4), "0:00")
        XCTAssertEqual(record("c2", outcome: .missed).summary, "Missed")
        XCTAssertNil(record("c2").duration)
        XCTAssertEqual(record("c2").number, "100")
    }

    // MARK: The list

    func testRecordUpsertsByEitherIdNewestFirstAndCaps() {
        let store = tempStore()
        XCTAssertEqual(store.load(), [])
        store.record(record("a", outcome: .missed))
        store.record(record("b", outcome: .completed, endedAt: t0.addingTimeInterval(20)))
        XCTAssertEqual(store.load().map(\.id), ["b", "a"], "newest first")

        // The same call again (an INVITE-first call whose wake id was "a")
        // replaces the earlier record instead of duplicating it.
        store.record(record("sip-1", outcome: .declined, wakeCallID: "a"))
        XCTAssertEqual(store.load().map(\.id), ["sip-1", "b"])
        XCTAssertEqual(store.load().first?.outcome, .declined)

        // Round trip through the file: a fresh store reads the same list.
        let again = RecentsStore(directory: store.directory)
        XCTAssertEqual(again.load(), store.load())

        for i in 0..<(RecentsStore.capacity + 5) { store.record(record("x\(i)")) }
        XCTAssertEqual(store.load().count, RecentsStore.capacity)
        XCTAssertEqual(store.load().first?.id, "x\(RecentsStore.capacity + 4)")

        store.delete(id: "x3")
        XCTAssertFalse(store.load().contains { $0.id == "x3" })
        store.clear()
        XCTAssertEqual(store.load(), [])
    }

    /// The case that evicted history (2026-11-05): a run's first outgoing
    /// call used to be "out-1" like the previous run's, and the store's
    /// same-call rule replaced the old record. With run tokens both stay.
    func testCallsFromTwoRunsWithTheSameCounterBothSurvive() {
        let store = tempStore()
        store.record(record("out-a1b2c3-1", outcome: .completed))
        store.record(record("out-d4e5f6-1", outcome: .completed, endedAt: t0.addingTimeInterval(60)))
        XCTAssertEqual(store.load().map(\.id), ["out-d4e5f6-1", "out-a1b2c3-1"], "two runs, two calls")

        // The rule itself is unchanged: one call recorded twice is one row.
        store.record(record("out-d4e5f6-1", outcome: .failed, endedAt: t0.addingTimeInterval(61)))
        XCTAssertEqual(store.load().count, 2)
        XCTAssertEqual(store.load().first?.outcome, .failed)
    }

    func testFoldingTheExtensionsSidecars() {
        let store = tempStore()
        let wake = Wake(callID: "w1", from: Party(displayName: "Reception", uri: "sip:100@pbx"), to: Party(uri: "sip:201@dialler"),
                        sip: SIPTarget(host: "dialler", port: 5061, transport: "tls"), expiresAt: t0.addingTimeInterval(30))
        // The extension reported a wake the app never ran for.
        store.notePending(wake: wake, at: t0)
        XCTAssertEqual(store.pending().map(\.id), ["w1"])
        // …and one the app did take (its own record exists under the
        // synthetic id with the wake's id merged in).
        var second = wake
        second.callID = "w2"
        store.notePending(wake: second, at: t0)
        store.record(CallRecord(id: "sip-1", wakeCallID: "w2", direction: .incoming, counterpart: wake.from,
                                startedAt: t0, connectedAt: t0.addingTimeInterval(1), endedAt: t0.addingTimeInterval(9), outcome: .completed))
        // …and one another device answered.
        var third = wake
        third.callID = "w3"
        store.notePending(wake: third, at: t0.addingTimeInterval(5))
        store.notePending(cancel: WakeCancel(callID: "w3", reason: .answeredElsewhere), at: t0.addingTimeInterval(8))
        // A cancel for a wake nobody noted is ignored.
        store.notePending(cancel: WakeCancel(callID: "w9", reason: .timeout), at: t0)

        let list = store.foldPending()
        XCTAssertEqual(list.map(\.id), ["sip-1", "w3", "w1"], "newest first by end; the app's own record wins for w2")
        XCTAssertEqual(list.first { $0.id == "w1" }?.outcome, .missed)
        XCTAssertEqual(list.first { $0.id == "w3" }?.outcome, .answeredElsewhere)
        XCTAssertEqual(list.first { $0.id == "w3" }?.endedAt, t0.addingTimeInterval(8))
        XCTAssertEqual(store.pending(), [], "every sidecar is consumed")
        XCTAssertEqual(store.foldPending(), list, "nothing pending: the list is unchanged")

        // A sidecar that arrives after the app already recorded the call
        // (the extension wrote it a moment later) is still discarded.
        store.notePending(wake: second, at: t0.addingTimeInterval(60))
        XCTAssertEqual(store.foldPending().map(\.id), ["sip-1", "w3", "w1"])
    }
}

/// The controller emits exactly one record per call, on every way out of
/// its table.
final class CallRecordEmissionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var clock = Date(timeIntervalSince1970: 1_800_000_000)

    func wake(_ id: String, expiresIn: TimeInterval = 30) -> Wake {
        Wake(callID: id, from: Party(displayName: "Reception", uri: "sip:100@pbx"), to: Party(uri: "sip:201@dialler"),
             sip: SIPTarget(host: "dialler", port: 5061, transport: "tls"), expiresAt: t0.addingTimeInterval(expiresIn))
    }

    func make() -> (CallController, FakeCallUI, FakeEngine) {
        let ui = FakeCallUI(), engine = FakeEngine()
        let c = CallController(ui: ui, engine: engine, now: { self.clock })
        c.attach(transport: FakeTransport())
        c.schedule = { _, work in work() }
        return (c, ui, engine)
    }

    func collect(_ c: CallController) -> () -> [CallRecord] {
        var records: [CallRecord] = []
        let lock = NSLock()
        c.onCallEnded = { r in lock.withLock { records.append(r) } }
        return { lock.withLock { records } }
    }

    func testAnsweredIncomingCallIsCompleteWithItsDuration() {
        let (c, _, engine) = make()
        let records = collect(c)
        c.handle(.wake(wake("c1")))
        clock = t0.addingTimeInterval(3)
        c.userAnswered(callID: "c1")
        engine.onIncomingCall?("e1", "sip:100@pbx", nil, "c1")
        clock = t0.addingTimeInterval(63)
        engine.onCallEnded?("e1", "BYE", 0)
        XCTAssertEqual(records().count, 1)
        let r = records()[0]
        XCTAssertEqual(r.id, "c1")
        XCTAssertNil(r.wakeCallID, "tracked under the wake's own id")
        XCTAssertEqual(r.direction, .incoming)
        XCTAssertEqual(r.outcome, .completed)
        XCTAssertEqual(r.startedAt, t0)
        XCTAssertEqual(r.connectedAt, t0.addingTimeInterval(3))
        XCTAssertEqual(r.duration, 60)
        XCTAssertEqual(r.counterpart, Party(displayName: "Reception", uri: "sip:100@pbx"))
    }

    func testMissedDeclinedAndAnsweredElsewhere() {
        let (c, _, _) = make()
        let records = collect(c)
        c.handle(.wake(wake("c1")))
        c.handle(.wakeCancel(WakeCancel(callID: "c1", reason: .callerHangup)))
        c.handle(.wake(wake("c2")))
        c.handle(.wakeCancel(WakeCancel(callID: "c2", reason: .timeout)))
        c.handle(.wake(wake("c3")))
        c.userEnded(callID: "c3")
        c.handle(.wake(wake("c4")))
        c.handle(.wakeCancel(WakeCancel(callID: "c4", reason: .answeredElsewhere)))
        XCTAssertEqual(records().map(\.outcome), [.missed, .missed, .declined, .answeredElsewhere])
        XCTAssertEqual(records().map(\.id), ["c1", "c2", "c3", "c4"])
        XCTAssertTrue(records().allSatisfy { $0.connectedAt == nil })
    }

    func testCallerCancelsOnSIPBeforeTheAnswerIsMissed() {
        let (c, _, engine) = make()
        let records = collect(c)
        c.setAccount(user: "201@dialler", sip: SIPTarget(host: "dialler", port: 5061, transport: "tls"))
        // INVITE first, then the wake for the same call, then the caller
        // gives up: the record carries both ids so a sidecar matches it.
        engine.onIncomingCall?("e1", "sip:100@pbx", "Reception", "srv-9")
        c.handle(.wake(wake("srv-9")))
        engine.onCallEnded?("e1", "CANCEL", 0)
        XCTAssertEqual(records().count, 1)
        XCTAssertEqual(records()[0].outcome, .missed)
        XCTAssertEqual(records()[0].id, "sip-1")
        XCTAssertEqual(records()[0].wakeCallID, "srv-9")
    }

    func testRefusedAndExpiredWakesAreMissedCalls() {
        let (c, _, _) = make()
        let records = collect(c)
        c.callWaitingEnabled = false
        c.handle(.wake(wake("c1")))
        c.userAnswered(callID: "c1")
        XCTAssertEqual(c.handle(wake: wake("c2")), .refused, "call waiting off: the second caller hears busy")
        XCTAssertEqual(c.handle(wake: wake("c1")), .duplicate(of: "c1"))
        XCTAssertEqual(records().count, 1, "a duplicate delivery records nothing")
        c.userEnded(callID: "c1")
        clock = t0.addingTimeInterval(120)
        XCTAssertEqual(c.handle(wake: wake("c3", expiresIn: 30)), .expired)
        XCTAssertEqual(records().map(\.id), ["c2", "c1", "c3"])
        // c1 was answered on the wake and its INVITE never arrived, so the
        // user heard nothing before hanging up: a failure, not a completed
        // call with a duration measuring how long they waited in silence
        // (changed 2026-09-23 with the wake-answered deadline).
        XCTAssertEqual(records().map(\.outcome), [.missed, .failed, .missed])
        XCTAssertNil(records()[1].duration, "it never connected")
    }

    func testOutgoingOutcomes() {
        let (c, _, engine) = make()
        let records = collect(c)
        c.setAccount(user: "201@dialler", sip: SIPTarget(host: "dialler", port: 5061, transport: "tls"))
        // Busy: the far end refused with 486; the tone plays, then the end.
        let busy = c.startCall(to: "212", displayName: "Phone B")!
        c.userStarted(callID: busy)
        engine.onCallEnded?("e-\(busy)", "486 Busy Here", 486)
        // Cancelled by the user before the answer.
        let cancelled = c.startCall(to: "213")!
        c.userStarted(callID: cancelled)
        c.userEnded(callID: cancelled)
        // Answered, then the far end hung up.
        let answered = c.startCall(to: "214")!
        c.userStarted(callID: answered)
        clock = t0.addingTimeInterval(5)
        engine.onCallEstablished?("e-\(answered)")
        clock = t0.addingTimeInterval(35)
        engine.onCallEnded?("e-\(answered)", "BYE", 0)
        // Could not be dialled at all.
        engine.dialFails = true
        let failed = c.startCall(to: "215")!
        c.userStarted(callID: failed)

        XCTAssertEqual(records().map(\.outcome), [.busy, .cancelled, .completed, .failed])
        XCTAssertTrue(records().allSatisfy { $0.direction == .outgoing })
        XCTAssertEqual(records()[0].counterpart, Party(displayName: "Phone B", uri: "212"))
        XCTAssertEqual(records()[2].duration, 30)
        XCTAssertEqual(records()[3].counterpart.uri, "215")
        // Hanging up on the busy tone records nothing more: the call was
        // recorded when SIP ended it.
        c.userEnded(callID: busy)
        XCTAssertEqual(records().count, 4)
    }
}
