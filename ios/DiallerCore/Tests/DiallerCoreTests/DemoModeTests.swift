import DiallerProtocol
import XCTest
@testable import DiallerCore

/// Demo mode through the real call controller, as the app drives it: the
/// demo engine stands where the SIP engine does, and nothing else changes.
final class DemoCallTests: XCTestCase {
    private var pending: [(TimeInterval, () -> Void)] = []
    private var echo: [Bool] = []
    private var records: [CallRecord] = []
    private var ui: FakeCallUI!
    private var engine: DemoCallEngine!
    private var controller: CallController!

    override func setUp() {
        pending = []
        echo = []
        records = []
        ui = FakeCallUI()
        engine = DemoCallEngine()
        engine.schedule = { [unowned self] seconds, work in pending.append((seconds, work)) }
        engine.echoing = { [unowned self] in echo.append($0) }
        controller = CallController(ui: ui, engine: engine)
        controller.onCallEnded = { [unowned self] in records.append($0) }
        controller.setAccount(user: Demo.line, sip: SIPTarget(host: "demo.dialler", port: 5061, transport: "tls"))
    }

    /// Runs the scripted far end in time order, including anything it
    /// schedules on the way.
    private func runScript() {
        while !pending.isEmpty {
            let batch = pending.sorted { $0.0 < $1.0 }
            pending = []
            for (_, work) in batch { work() }
        }
    }

    func testAnOutgoingCallRingsConnectsAndEchoesOnlyOnceCallKitHasTheAudio() throws {
        let amara = try XCTUnwrap(Demo.contacts.first?.number) // a demo contact, whatever its number
        let id = try XCTUnwrap(controller.startCall(to: amara))
        controller.userStarted(callID: id)
        runScript()
        XCTAssertEqual(ui.connecting, [id], "ringing")
        XCTAssertEqual(ui.connected, [id], "answered")
        XCTAssertEqual(echo, [], "no audio before CallKit activates the session")
        engine.audioSessionActivated()
        XCTAssertEqual(echo, [true])
        controller.userEnded(callID: id)
        XCTAssertEqual(echo, [true, false])
        XCTAssertEqual(records.map(\.outcome), [.completed])
    }

    func testTheSalesLineIsAlwaysBusy() throws {
        let id = try XCTUnwrap(controller.startCall(to: Demo.busyNumber))
        controller.userStarted(callID: id)
        engine.audioSessionActivated()
        runScript()
        XCTAssertEqual(ui.connected, [], "never answered")
        XCTAssertEqual(ui.progress.last?.1, .busy)
        XCTAssertEqual(records.map(\.outcome), [.busy])
        XCTAssertEqual(echo, [], "nothing to echo")
    }

    func testAnIncomingCallRingsFromReceptionAndEchoesOnceAnswered() throws {
        engine.ringIncoming()
        runScript()
        let call = try XCTUnwrap(ui.reported.first)
        XCTAssertEqual(call.1, Demo.caller.name)
        engine.audioSessionActivated() // CallKit may activate before the answer lands
        XCTAssertEqual(echo, [])
        controller.userAnswered(callID: call.0)
        XCTAssertEqual(echo, [true])
    }

    func testHoldStopsTheEchoAndResumeStartsIt() throws {
        let id = try XCTUnwrap(controller.startCall(to: "231"))
        controller.userStarted(callID: id)
        runScript()
        engine.audioSessionActivated()
        controller.setHeld(callID: id, true)
        controller.setHeld(callID: id, false)
        XCTAssertEqual(echo, [true, false, true])
    }

    func testDeactivationStopsTheEcho() throws {
        let id = try XCTUnwrap(controller.startCall(to: "231"))
        controller.userStarted(callID: id)
        runScript()
        engine.audioSessionActivated()
        engine.audioSessionDeactivated()
        XCTAssertEqual(echo, [true, false])
    }

    /// A hang-up before the far end answers: its script must not revive it.
    func testACancelledCallStaysCancelled() throws {
        let id = try XCTUnwrap(controller.startCall(to: "118"))
        controller.userStarted(callID: id)
        controller.userEnded(callID: id)
        runScript()
        XCTAssertEqual(ui.connected, [])
        XCTAssertEqual(records.map(\.outcome), [.cancelled])
    }
}

final class DemoDirectoryTests: XCTestCase {
    func testStartsWithTheDemoContacts() async throws {
        var book = AddressBook()
        try await DemoDirectory().sync(&book)
        XCTAssertEqual(book.sorted.count, Demo.contacts.count)
        XCTAssertEqual(book.sorted.filter(\.isFavourite).count, Demo.contacts.filter(\.favourite).count)
    }

    /// Writes then a sync, as the app does after every edit.
    func testAddEditAndDeleteReachTheBook() async throws {
        let dir = DemoDirectory()
        var book = AddressBook()
        try await dir.sync(&book)
        let added = try await dir.create(ContactDraft(displayName: "New Starter", uri: "400@demo.dialler", mode: "local"))
        let first = try XCTUnwrap(book.sorted.first)
        _ = try await dir.update(id: first.id, ContactDraft(displayName: "Renamed", uri: first.uri, mode: first.mode, favourite: true))
        let gone = try XCTUnwrap(book.sorted.last)
        try await dir.delete(id: gone.id)
        try await dir.sync(&book)
        let names = book.sorted.map(\.displayName)
        XCTAssertTrue(names.contains(added.displayName))
        XCTAssertTrue(names.contains("Renamed"))
        XCTAssertFalse(names.contains(gone.displayName))
        XCTAssertEqual(book.sorted.count, Demo.contacts.count)
    }

    func testEditingADeletedContactFails() async throws {
        let dir = DemoDirectory()
        var book = AddressBook()
        try await dir.sync(&book)
        let c = try XCTUnwrap(book.sorted.first)
        try await dir.delete(id: c.id)
        do {
            _ = try await dir.update(id: c.id, ContactDraft(c))
            XCTFail("updated a deleted contact")
        } catch {}
    }
}

final class DemoEntryTests: XCTestCase {
    func testTheCodeIsReadAsEnrolmentCodesAre() {
        XCTAssertTrue(Demo.isCode("DEMODEMO"))
        XCTAssertTrue(Demo.isCode("demo-demo"))
        XCTAssertTrue(Demo.isCode("DEM0 DEM0"))
        XCTAssertFalse(Demo.isCode("DEMODEM"))
        XCTAssertFalse(Demo.isCode("ABCD2345"))
    }

    func testTheGatewayWelcomesWithTheDemoLineAndAlwaysSyncs() async throws {
        let gateway = DemoGateway()
        gateway.connect(hello: Demo.hello)
        gateway.disconnect()
        var events: [SignalEvent] = []
        for await e in gateway.events { events.append(e) }
        guard case .connected(let w)? = events.first else { return XCTFail("no welcome: \(events)") }
        XCTAssertEqual(w.sip?.user, Demo.line)
        XCTAssertEqual(w.directoryVersion, -1, "never the app's cursor, so every connect syncs")
    }
}

final class CallEngineSwitchTests: XCTestCase {
    func testCallsGoToTheEngineInUseAndCallbacksComeFromBoth() {
        let sip = FakeEngine(), demo = FakeEngine()
        let engines = CallEngineSwitch(primary: sip, alternate: demo)
        var ended: [String] = []
        engines.onCallEnded = { id, _, _ in ended.append(id) }

        _ = engines.answer(engineCallID: "a")
        engines.use(alternate: true)
        _ = engines.answer(engineCallID: "b")
        engines.use(alternate: false)
        engines.hangup(engineCallID: "c")

        XCTAssertEqual(sip.answered, ["a"])
        XCTAssertEqual(demo.answered, ["b"])
        XCTAssertEqual(sip.hungUp, ["c"])
        sip.onCallEnded?("x", "", 0)
        demo.onCallEnded?("y", "", 0)
        XCTAssertEqual(ended, ["x", "y"])
    }
}
