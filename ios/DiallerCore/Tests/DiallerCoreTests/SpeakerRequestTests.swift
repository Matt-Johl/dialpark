import DiallerCore
import XCTest

/// SPEC §6 item 17: Siri's "on speaker" is applied when the requested
/// call's audio comes up, once, and never to another call.
final class SpeakerRequestTests: XCTestCase {
    func testAppliedOnceWhenTheRequestedCallsAudioIsLive() {
        var r = SpeakerRequest()
        XCTAssertFalse(r.takeIfDue(activeCallID: "out-1"), "nothing requested")
        r.request(callID: "out-1")
        XCTAssertTrue(r.isPending)
        XCTAssertTrue(r.takeIfDue(activeCallID: "out-1"))
        XCTAssertFalse(r.takeIfDue(activeCallID: "out-1"), "once")
        XCTAssertFalse(r.isPending)
    }

    func testAnotherCallsActivationLeavesTheRequestStanding() {
        var r = SpeakerRequest()
        r.request(callID: "out-2")
        XCTAssertFalse(r.takeIfDue(activeCallID: "sip-9"), "an incoming call's session is not the requested call's")
        XCTAssertTrue(r.isPending)
        XCTAssertTrue(r.takeIfDue(activeCallID: "out-2"))
    }

    func testForgottenWithTheCall() {
        var r = SpeakerRequest()
        r.request(callID: "out-3")
        r.forget(callID: "out-9")
        XCTAssertTrue(r.isPending, "another call ending changes nothing")
        r.forget(callID: "out-3")
        XCTAssertFalse(r.isPending)
        XCTAssertFalse(r.takeIfDue(activeCallID: "out-3"))
    }
}
