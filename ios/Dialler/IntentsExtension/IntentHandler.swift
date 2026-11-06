import DiallerCore
import Intents
import os

/// The system's way of starting a Dialler call from outside the app (SPEC
/// §6 items 16 and 17): a tap on a Dialler row in the Phone app's Recents,
/// or "Call Amara with Dialler" said to Siri. Both make the system build an
/// `INStartCallIntent` and hand it to this extension, declared in
/// Info.plist `IntentsSupported`.
///
/// Siri drives the intent through three steps. *Resolve*: each parameter is
/// checked, and a party given by name is looked up in the directory —
/// `SiriContactMatcher`, against the address book the app keeps in the App
/// Group (`AddressBookStore`), which the app writes after every change from
/// the server or the user. One match is the party; several make Siri ask
/// which; none is "no contact found". *Confirm*: ready. *Handle*: the
/// extension does not place the call (Apple: "Don't try to initiate calls
/// directly from your Intents extension"); it answers "continue in app" and
/// the system opens the app with the intent in a user activity, which
/// `ContentView.onContinueUserActivity("INStartCallIntent")` receives and
/// `AppModel.callBack(activity:)` dials. A Recents row arrives with its
/// handle already set and resolves to itself.
///
/// The same shape as Apple's CallKit sample ("VoIP calling with CallKit",
/// `IntentsExtension/IntentHandler.swift`), plus the resolution it leaves
/// out. Each decision is written to `logs/intents.log` in the App Group,
/// uploaded by the app with its own log.
final class IntentHandler: INExtension, INStartCallIntentHandling {
    private let logger = Logger(subsystem: DiallerIDs.bundlePrefix, category: "intents")
    private let fileLog = FileLog(name: "intents")

    private func note(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        fileLog?.write(line)
    }

    // MARK: Resolve

    func resolveContacts(for intent: INStartCallIntent, with completion: @escaping ([INStartCallContactResolutionResult]) -> Void) {
        guard let people = intent.contacts, !people.isEmpty else {
            note("resolve: no party named; asking")
            completion([.needsValue()])
            return
        }
        guard people.count == 1, let person = people.first else {
            note("resolve: \(people.count) parties; a call has one")
            completion([.unsupported(forReason: .multipleContactsUnsupported)])
            return
        }
        if let handle = person.personHandle?.value, !handle.isEmpty {
            // A Recents row, or a party Siri already resolved with us.
            note("resolve: \(handle) already has a handle")
            completion([.success(with: person)])
            return
        }
        let spoken = person.displayName.isEmpty
            ? (person.nameComponents.map { PersonNameComponentsFormatter().string(from: $0) } ?? "")
            : person.displayName
        let contacts = AddressBookStore()?.load().sorted ?? []
        switch SiriContactMatcher.match(spoken, in: contacts) {
        case .number(let digits):
            note("resolve: \"\(spoken)\" is a number")
            completion([.success(with: Self.person(handle: digits, name: digits, id: nil))])
        case .one(let c):
            note("resolve: \"\(spoken)\" is \(c.displayName)")
            completion([.success(with: Self.person(for: c))])
        case .several(let cs):
            note("resolve: \"\(spoken)\" could be \(cs.count) contacts; asking")
            completion([.disambiguation(with: cs.map(Self.person(for:)))])
        case .none:
            note("resolve: \"\(spoken)\" is nobody in the directory (\(contacts.count) contacts)")
            completion([.unsupported(forReason: .noContactFound)])
        }
    }

    func resolveCallCapability(for intent: INStartCallIntent, with completion: @escaping (INStartCallCallCapabilityResolutionResult) -> Void) {
        // Audio only: a video call asked for by name is not something the
        // app does, and saying so beats a silent audio call.
        if intent.callCapability == .videoCall {
            note("resolve: video call asked for; not supported")
            completion(.unsupported(forReason: .videoCallUnsupported))
        } else {
            completion(.success(with: .audioCall))
        }
    }

    func resolveDestinationType(for intent: INStartCallIntent, with completion: @escaping (INCallDestinationTypeResolutionResult) -> Void) {
        switch intent.destinationType {
        case .normal, .unknown, .callBack, .redial:
            completion(.success(with: .normal))
        default:
            // Emergency and voicemail are the carrier's, never the directory's.
            note("resolve: destination \(intent.destinationType.rawValue) is not ours")
            completion(.unsupported())
        }
    }

    // MARK: Confirm and handle

    func confirm(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        completion(INStartCallIntentResponse(code: .ready, userActivity: nil))
    }

    func handle(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        guard let handle = intent.contacts?.first?.personHandle?.value, !handle.isEmpty else {
            note("start call intent without a handle: failure")
            completion(INStartCallIntentResponse(code: .failure, userActivity: nil))
            return
        }
        note("start call intent for \(handle): continuing in the app")
        let activity = NSUserActivity(activityType: String(describing: INStartCallIntent.self))
        completion(INStartCallIntentResponse(code: .continueInApp, userActivity: activity))
    }

    // MARK: Parties

    /// A directory contact as Siri sees it: the handle is the directory
    /// number the app's call-back dials and the Phone app shows
    /// (`CallController.callKitHandle`), the name is the directory's, the
    /// custom identifier the contact's id.
    private static func person(for c: DirectoryContact) -> INPerson {
        person(handle: CallController.callKitHandle(of: c.uri), name: c.displayName, id: c.id)
    }

    private static func person(handle: String, name: String, id: String?) -> INPerson {
        INPerson(personHandle: INPersonHandle(value: handle, type: .unknown), nameComponents: nil, displayName: name,
                 image: nil, contactIdentifier: nil, customIdentifier: id)
    }
}
