import DiallerCore
import Intents
import os

/// The system's way of calling back a Dialler row from the Phone app's
/// Recents (SPEC §6 item 16). A row written by CallKit is not a number the
/// Phone app can dial itself: a tap on it makes the system build an
/// `INStartCallIntent` for the row's handle and hand it to the owning app's
/// Intents extension — this one, declared in Info.plist `IntentsSupported`.
/// The extension does not place the call (Apple: "Don't try to initiate
/// calls directly from your Intents extension"); it answers "continue in
/// app" with a user activity of the intent's type, and the system then
/// opens the app with that activity, the intent inside it, which
/// `ContentView.onContinueUserActivity("INStartCallIntent")` receives and
/// `AppModel.callBack(activity:)` dials.
///
/// The same shape as Apple's CallKit sample ("VoIP calling with CallKit",
/// `IntentsExtension/IntentHandler.swift`): fail when there is no handle to
/// call, otherwise continue in the app. Siri's "call … with Dialler" would
/// arrive here too, but resolving a spoken name against the directory is
/// not built; Recents rows arrive with their handle already resolved.
///
/// Each decision is written to `logs/intents.log` in the App Group, which
/// the app uploads with its own log (`AppModel.sendDiagnostics`), so a tap
/// that opened the app and dialled nothing shows whether the extension
/// ever ran — the console-only line it had before was not in any upload
/// when that question came up on 2026-11-05.
final class IntentHandler: INExtension, INStartCallIntentHandling {
    private let logger = Logger(subsystem: DiallerIDs.bundlePrefix, category: "intents")
    private let fileLog = FileLog(name: "intents")

    private func note(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        fileLog?.write(line)
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
}
