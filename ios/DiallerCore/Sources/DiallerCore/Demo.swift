import DiallerProtocol
import Foundation

/// Demo mode (appstore.md, decision 2): the whole app with no server, for
/// App Review and for anyone trying it without one. Calls are simulated on
/// the phone — they ring, connect and play the caller's voice back — and
/// nothing leaves it.
///
/// The pieces sit behind the protocols the app already uses, so none of the
/// real call path changes: `DemoCallEngine` (a `CallEngine`), `DemoGateway`
/// (a `SignalTransport`) and `DemoDirectory` (a `DirectoryService`).
public enum Demo {
    /// Typed as the enrolment code, with no server needed. Named in the
    /// App Review notes.
    public static let code = "DEMODEMO"

    /// Whether `code` is the demo's, however it was typed (enrolment codes
    /// are normalised: case, dashes, O for 0 and so on).
    public static func isCode(_ code: String) -> Bool {
        EnrolmentLink.normalise(code) == EnrolmentLink.normalise(Self.code)
    }

    /// The demo phone's own line.
    public static let line = "2000"
    static let domain = "demo.dialler"

    /// A contact whose calls are always busy, so the busy tone and a
    /// "Busy" in Recents can be seen too.
    public static let busyNumber = "2990"

    /// Who rings when the demo is asked for an incoming call.
    public static let caller = (name: "Reception", number: "1000")

    public struct Contact: Sendable {
        public let name: String
        public let number: String
        public let favourite: Bool
        /// On this server (an extension), or through the phone system.
        var mode: String { CallText.isExtension(number) ? "local" : "trunk" }
    }

    /// The demo directory as it starts. Fictitious people; the one outside
    /// number is from Ofcom's range reserved for drama (07700 900xxx).
    /// Every extension, the demo's own line and the busy line included, is
    /// four digits: the Phone app applies the carrier's number rules to a
    /// CallKit handle it can read as a number, and three digit extensions
    /// collide with carrier and emergency codes — 100 was the voicemail
    /// access number on the test network ("Voicemail" in its Recents) and
    /// 112 is the emergency number (device, 2026-11-05).
    public static let contacts: [Contact] = [
        Contact(name: "Amara Nwosu", number: "1120", favourite: true),
        Contact(name: "Ben Hartley", number: "2150", favourite: false),
        Contact(name: "Daniel Okafor", number: "2310", favourite: true),
        Contact(name: "Facilities", number: "3200", favourite: false),
        Contact(name: "IT Helpdesk", number: "3000", favourite: false),
        Contact(name: "Marta Lindqvist", number: "1420", favourite: false),
        Contact(name: "Priya Shah", number: "1180", favourite: false),
        Contact(name: caller.name, number: caller.number, favourite: false),
        Contact(name: "Sales Line", number: busyNumber, favourite: false),
        Contact(name: "Sam Carter", number: "+447700900123", favourite: false),
    ]

    /// A number's SIP URI in the demo's domain.
    static func uri(_ number: String) -> String { "\(number)@\(domain)" }

    /// The greeting `DemoGateway` gives: the demo line, and a directory
    /// version of -1, which never matches the app's cursor, so every
    /// connect syncs the demo directory.
    static func welcome(now: Date) -> Welcome {
        Welcome(sessionID: "demo", heartbeatSeconds: 30, serverTime: now, directoryVersion: -1,
                sip: SIPAccount(user: line, domain: domain, host: domain, port: 5061, transport: "tls"))
    }

    /// What the app says hello with in demo mode; the demo gateway ignores it.
    public static let hello = Hello(deviceID: "demo", token: "", client: .app)
}
