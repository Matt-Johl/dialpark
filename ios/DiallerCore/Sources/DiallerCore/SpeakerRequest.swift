import Foundation

/// A request that one call be put on the speaker the moment its audio is
/// live (SPEC §6 item 17): "Hey Siri, call Priya with Dialler on speaker".
/// Siri carries "on speaker" as the intent's audio route, not as words,
/// and the app receives it before the call exists. The output route can
/// only be set on the call's audio session, which CallKit activates a few
/// hundred milliseconds after the dial, so the request is held against the
/// call's id and taken exactly once, when that call's session comes up.
/// A request for a call that never reaches its session (refused, failed,
/// ended while ringing) is forgotten with the call.
public struct SpeakerRequest: Equatable, Sendable {
    private var callID: String?

    public init() {}

    /// Siri asked for the speaker; `callID` is the call being placed for it.
    public mutating func request(callID: String) { self.callID = callID }

    /// The audio session is live for `activeCallID`. True once, for the
    /// requested call only; a different call's activation leaves the
    /// request standing for its own call.
    public mutating func takeIfDue(activeCallID: String) -> Bool {
        guard callID == activeCallID else { return false }
        callID = nil
        return true
    }

    /// The call is over (or never started): nothing to apply.
    public mutating func forget(callID: String) {
        if self.callID == callID { self.callID = nil }
    }

    public var isPending: Bool { callID != nil }
}
