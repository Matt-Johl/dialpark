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
final class IntentHandler: INExtension, INStartCallIntentHandling {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "IntentsExtension", category: "intents")

    func handle(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        guard let handle = intent.contacts?.first?.personHandle?.value, !handle.isEmpty else {
            logger.notice("start call intent without a handle: failure")
            completion(INStartCallIntentResponse(code: .failure, userActivity: nil))
            return
        }
        logger.notice("start call intent for \(handle, privacy: .public): continuing in the app")
        let activity = NSUserActivity(activityType: String(describing: INStartCallIntent.self))
        completion(INStartCallIntentResponse(code: .continueInApp, userActivity: activity))
    }
}
