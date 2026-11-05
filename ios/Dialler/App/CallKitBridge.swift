import AVFoundation
import CallKit
import DiallerCore
import Foundation
import OSLog
import UIKit
import os

/// CallKit as a `CallUI` (SPEC §5 component 7): reports incoming calls and
/// forwards the user's answer/end actions to the controller.
///
/// Every CallKit callback is echoed to the app log with a "callkit:" prefix,
/// including the transaction receipt (`provider(_:execute:)`), the system's
/// own view of the call (`CXCallObserver`), resets, action time-outs, and
/// audio-session interruptions — so a tap that "does nothing" shows exactly
/// how far it got.
final class CallKitBridge: NSObject, CallUI, CXProviderDelegate, CXCallObserverDelegate {
    var onAnswer: (String) -> Void = { _ in }
    var onEnd: (String) -> Void = { _ in }
    /// CallKit approved an outgoing call we asked for: dial now.
    var onStart: (String) -> Void = { _ in }
    /// CallKit refused the outgoing call.
    var onStartFailed: (String) -> Void = { _ in }
    /// Our outgoing call was answered (reported to CallKit as connected).
    var onConnected: (String) -> Void = { _ in }
    var onMute: (String, Bool) -> Void = { _, _ in }
    var onHold: (String, Bool) -> Void = { _, _ in }
    var onAudioActivated: () -> Void = {}
    var onAudioDeactivated: () -> Void = {}
    /// Bridge events for the app's visible log (os_log alone was invisible
    /// while diagnosing on a device).
    var onLog: (String) -> Void = { _ in }

    /// The app's registration with the system's call daemon. Replaced, not
    /// kept, when the system reports that registration lost (`providerDidReset`)
    /// or refuses a start for want of one — see `ProviderRecovery`.
    private var provider: CXProvider
    private let controller = CXCallController()
    private let observer = CXCallObserver()
    private var uuids: [String: UUID] = [:]
    private var callIDs: [UUID: String] = [:]
    private var lastUpdate: [UUID: CXCallUpdate] = [:]
    /// Which of `uuids` CallKit has accepted (see `CallRoster`). Main thread only.
    private var roster = CallRoster()
    private var recovery = ProviderRecovery()
    /// What each outgoing start asked for, until the start is performed or
    /// given up, so a refused one can be asked again on a new provider.
    private var pendingStarts: [String: (handle: String, displayName: String)] = [:]
    private var notificationTokens: [NSObjectProtocol] = []
    /// Whether calls are written to the Phone app's Recents (Settings:
    /// "iPhone Recents", SPEC §6 item 16). Part of the provider's
    /// configuration, so a change is sent to the call daemon through the
    /// configuration setter; the next call is written or not accordingly.
    /// Rows already written stay, and `AppModel.callBack(activity:)` keeps
    /// them callable whatever this says.
    private(set) var includesCallsInRecents: Bool

    init(includesCallsInRecents: Bool) {
        self.includesCallsInRecents = includesCallsInRecents
        Breadcrumb.drop("CallKit: creating the provider")
        provider = CXProvider(configuration: Self.makeConfiguration(includesCallsInRecents: includesCallsInRecents))
        super.init()
        provider.setDelegate(self, queue: .main)
        observer.setDelegate(self, queue: .main)
        observeSystemNotifications()
        // Category, mode and hardware preferences are set once, at launch.
        // If the first call is also the first time they are applied, the
        // change only takes effect when CallKit activates the session, the
        // hardware is still reconfiguring while the engine creates its
        // VoiceProcessingIO units, and every render fails for that call
        // (observed: route change reason 3 at activation, then render -1).
        Breadcrumb.drop("CallKit: provider registered; configuring the audio session")
        configureAudioSession()
        Breadcrumb.drop("CallKit: audio session configured")
    }

    /// Change the Phone app Recents setting on the live provider. Main thread.
    func set(includesCallsInRecents on: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard on != includesCallsInRecents else { return }
        includesCallsInRecents = on
        provider.configuration = Self.makeConfiguration(includesCallsInRecents: on)
        onLog("callkit: calls \(on ? "will" : "will not") be written to the Phone app's Recents")
    }

    /// The one place a party's identity leaves the app for iOS: the Phone
    /// app's Recents row, CallKit's call screen and the handle a Recents tap
    /// hands back. Always the directory number, however the party was
    /// spelt on the way in (SPEC §6 item 16, `CallController.callKitHandle`),
    /// so no caller of this bridge can put a SIP URI in front of the user —
    /// 10910 had two rows in the Phone app, "10910" and "sip:10910@dialpark",
    /// before this (device, 2026-11-05).
    private static func callKitHandle(_ value: String) -> CXHandle {
        CXHandle(type: .generic, value: CallController.callKitHandle(of: value))
    }

    private static func makeConfiguration(includesCallsInRecents: Bool) -> CXProviderConfiguration {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        // Call waiting (plan Phase I): TWO call groups of ONE call each —
        // two independent calls, one active and one held. A *group* is a
        // conference: `maximumCallsPerCallGroup = 1` says we do not merge
        // calls. `maximumCallGroups` is what decides the second call's
        // answer UI: iOS's own rule (TelephonyUtilities,
        // `-[TUCallCenter isHoldAndAnswerAllowed]`, read from the iOS 26.5
        // runtime on 2026-09-14) is that for two calls of the SAME provider
        // hold-and-answer is allowed exactly when the provider's
        // `maximumCallGroups` is greater than one — the call's
        // `supportsHolding` is only consulted between different providers.
        // With one group of two calls iOS could only offer "End & Accept"
        // (device, 2026-09-14). With two groups, iOS 26 shows its plain
        // Accept for the second call and, on Accept, performs
        // `holdActiveAndAnswerCall`: a hold for the current call and the
        // answer for the new one. That is the "Hold & Accept" of older
        // releases, relabelled — the app sees the same two actions.
        config.maximumCallGroups = 2
        config.maximumCallsPerCallGroup = 1
        // A generic handle: a directory number, not a phone number the Phone
        // app could dial itself (`callKitHandle`). A Recents row made from
        // it comes back through our Intents extension as an INStartCallIntent
        // with the same string (`AppModel.callBack(activity:)`).
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = includesCallsInRecents
        return config
    }

    // MARK: Provider registration

    /// Register with the system afresh: a new `CXProvider` opens a new
    /// connection to the call daemon and sends it the configuration, which
    /// is what a relaunch does and what fixed 2026-09-27 by hand. The old
    /// one is released; `invalidate` is a no-op on iOS 26 (the framework
    /// says so in its own log) but is the documented courtesy. Main thread.
    ///
    /// Not a restart of anything else: calls, engine and session are
    /// untouched, and after a reset there are no CallKit calls to move.
    private func rebuildProvider(reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let retired = provider
        retired.setDelegate(nil, queue: nil)
        retired.invalidate()
        provider = CXProvider(configuration: Self.makeConfiguration(includesCallsInRecents: includesCallsInRecents))
        provider.setDelegate(self, queue: .main)
        onLog("callkit: provider rebuilt and registered afresh (\(reason))")
    }

    private func perform(_ actions: [ProviderRecovery.Action]) {
        for action in actions {
            switch action {
            case .rebuild(let reason):
                rebuildProvider(reason: reason)
            case .retryStart(let callID):
                guard let want = pendingStarts[callID] else { break }
                onLog("callkit: asking again for \(callID) on the new provider")
                requestStart(callID: callID, handle: want.handle, displayName: want.displayName)
            case .giveUp(let callID):
                pendingStarts[callID] = nil
                if let uuid = uuids.removeValue(forKey: callID) { callIDs[uuid] = nil }
                roster.remove(callID)
                onStartFailed(callID)
            }
        }
    }

    /// CallKit's own lines from this process (subsystem com.apple.callkit)
    /// for the last `seconds`, into the app log. The framework logs why a
    /// provider connection was interrupted and what the daemon answered;
    /// without this the next reset is as opaque as 2026-09-27's, whose
    /// device log could not be pulled. Read off the main thread; the log
    /// sink hops back.
    private func dumpSystemCallKitLog(lastSeconds seconds: TimeInterval, why: String) {
        let onLog = self.onLog
        DispatchQueue.global(qos: .utility).async {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let from = store.position(date: Date().addingTimeInterval(-seconds))
                let entries = try store.getEntries(at: from, matching: NSPredicate(format: "subsystem == %@", "com.apple.callkit"))
                let stamp = ISO8601DateFormatter()
                stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                var lines: [String] = []
                for case let entry as OSLogEntryLog in entries {
                    lines.append("    \(stamp.string(from: entry.date)) [\(entry.category)] \(entry.composedMessage)")
                    if lines.count == 60 { lines.append("    …"); break }
                }
                onLog("callkit: system log for \(why), last \(Int(seconds)) s, \(lines.count) line(s):\n" + lines.joined(separator: "\n"))
            } catch {
                onLog("callkit: system log for \(why) unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// The recorder unit needs record permission; without it the voice
    /// processing unit fails to render. Ask at launch, not mid-call.
    /// Asked by `AppModel.connect()`, once the phone is set up: not at
    /// provider registration, which is first launch, before setup.
    func requestMicrophonePermission() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            onLog("audio: microphone permission granted")
        case .denied:
            onLog("audio: microphone permission DENIED — calls will be silent; enable it in Settings")
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async { self?.onLog("audio: microphone permission \(granted ? "granted" : "DENIED")") }
            }
        @unknown default:
            break
        }
    }

    deinit {
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: In-app controls → CallKit
    // Requests go through CXCallController and land in the same provider
    // delegate as the system UI's own actions.

    func requestAnswer(callID: String) {
        guard let uuid = uuids[callID] else { return }
        controller.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { [weak self] err in
            if let err { self?.onLog("callkit: answer request failed: \(err.localizedDescription)") }
        }
    }

    func requestEnd(callID: String) {
        guard let uuid = uuids[callID] else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [weak self] err in
            if let err { self?.onLog("callkit: end request failed: \(err.localizedDescription)") }
        }
    }

    func requestHold(callID: String, held: Bool) {
        guard let uuid = uuids[callID] else { return }
        controller.request(CXTransaction(action: CXSetHeldCallAction(call: uuid, onHold: held))) { [weak self] err in
            if let err { self?.onLog("callkit: hold request failed: \(err.localizedDescription)") }
        }
    }

    func requestMute(callID: String, muted: Bool) {
        guard let uuid = uuids[callID] else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted))) { [weak self] err in
            if let err { self?.onLog("callkit: mute request failed: \(err.localizedDescription)") }
        }
    }

    /// Swap: hold the active call and resume the held one, as one CallKit
    /// transaction (the same two actions the system's own swap control
    /// sends), so the two hold changes are performed together.
    func requestSwap(active: String, held: String) {
        guard let a = uuids[active], let h = uuids[held] else { return }
        let tx = CXTransaction(actions: [CXSetHeldCallAction(call: a, onHold: true), CXSetHeldCallAction(call: h, onHold: false)])
        controller.request(tx) { [weak self] err in
            if let err { self?.onLog("callkit: swap request failed: \(err.localizedDescription)") }
        }
    }

    // MARK: CallUI — outgoing

    /// Outgoing calls go through CallKit too: request a start action, and
    /// dial only when CallKit performs it (so the system call bar, Recents
    /// and audio-session activation all work as for incoming calls).
    func startOutgoing(callID: String, handle: String, displayName: String) {
        DispatchQueue.main.async { [self] in
            pendingStarts[callID] = (handle, displayName)
            requestStart(callID: callID, handle: handle, displayName: displayName)
        }
    }

    /// One start request. A fresh UUID each time: the system keeps a record
    /// of a refused one. Until the delegate performs the action this is a
    /// request, not a call (`CallRoster.State.awaitingStart`).
    private func requestStart(callID: String, handle: String, displayName: String) {
        let uuid = UUID()
        uuids[callID] = uuid
        callIDs[uuid] = callID
        roster.add(callID, .awaitingStart)
        let action = CXStartCallAction(call: uuid, handle: Self.callKitHandle(handle))
        action.contactIdentifier = displayName
        onLog("callkit: requesting outgoing call \(callID) to \(handle) as \(short(uuid))")
        controller.request(CXTransaction(action: action)) { [weak self] err in
            guard let self, let err else { return }
            // `unknownCallProvider` (code 2): the daemon has no registration
            // for this app and waited 10 s for one; every start after the
            // 2026-09-27 reset ended here. Rebuild and ask once more; any
            // other refusal, or a second one, is final.
            let code = (err as? CXErrorCodeRequestTransactionError)?.code.rawValue ?? -1
            self.onLog("callkit: start request for \(callID) failed: \(err.localizedDescription) (code \(code))")
            if code == ProviderRecovery.unknownCallProviderCode {
                self.dumpSystemCallKitLog(lastSeconds: 30, why: "start refused, unknown call provider")
            }
            self.callIDs[uuid] = nil
            self.perform(self.recovery.startFailed(callID: callID, code: code))
        }
    }

    func outgoingConnecting(callID: String) {
        DispatchQueue.main.async { [self] in
            guard let uuid = uuids[callID] else { return }
            provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
            onLog("callkit: \(callID) connecting")
        }
    }

    func outgoingConnected(callID: String) {
        DispatchQueue.main.async { [self] in
            guard let uuid = uuids[callID] else { return }
            provider.reportOutgoingCall(with: uuid, connectedAt: Date())
            onLog("callkit: \(callID) connected")
            onConnected(callID)
        }
    }

    // MARK: CallUI

    // The controller calls these from whichever thread delivered the event
    // (gateway socket, PushKit, libre loop); CallKit wants the main thread.

    /// Calls whose report is queued for the main thread but not yet made.
    /// A wake that arrives on the main thread in that window (PushKit) must
    /// not report the same call again: two CallKit calls for one SIP call,
    /// only one of which is ended when the caller hangs up, left a phantom
    /// ring the user had to end by hand (2026-09-13 01:32, "sip-1").
    private let pendingLock = NSLock()
    /// Reports queued for the main thread and not yet run, by call id — so
    /// `reaffirm` can run one on the spot instead of leaving it in the queue
    /// (see there). Guarded by pendingLock. Each report runs once, from
    /// whichever path reaches it first, and unregisters only itself: a
    /// second report for the same id (INVITE path and push path can both
    /// ask) replaces the entry and still runs, to reach its own completion.
    private var pendingReports: [String: (token: UUID, run: () -> Void)] = [:]

    func reportIncoming(callID: String, displayName: String, handle: String, completion: @escaping (Error?) -> Void) {
        // PushKit's contract (iOS 13+): reportNewIncomingCall must be called
        // BEFORE the push delegate returns. The registry delivers on the main
        // queue, so when we are already there the report is made inline. It
        // used to be dispatched asynchronously, which let the delegate return
        // first; iOS then killed the app (0xBAADCA11) every time it had been
        // resumed from suspension for the push, while a cold launch survived
        // only by timing (console log 2026-09-11 16:11–16:13). Other threads
        // (gateway socket, SIP loop) still hop asynchronously: a synchronous
        // hop from the SIP loop could deadlock against a main thread waiting
        // on that loop in run_op.
        let token = UUID()
        let ran = RanOnce()
        let report = { [self] in
            // Runs once, from whichever path gets to it first: the main-queue
            // hop below, or `reaffirm` running it inline for a push.
            guard ran.take() else { return }
            pendingLock.withLock {
                if pendingReports[callID]?.token == token { pendingReports[callID] = nil }
            }
            if let existing = uuids[callID] {
                onLog("callkit: \(callID) already reported as \(short(existing)); not reporting it twice")
                completion(nil)
                return
            }
            // Not while another call is up: the session is live for it and
            // re-configuring the category mid-call is the hardware
            // reconfiguration hazard noted at the top of this file.
            //
            // "Up" means CallKit has accepted it (`CallRoster`). A call whose
            // report is still out can yet be refused — and was, by a Focus
            // filter, on 2026-09-17; an outgoing call whose start has not
            // been performed can too — and was, for 10 s at a time, on
            // 2026-09-27. Either counted as live made this call ring as call
            // waiting: beep at nobody, no audio-session setup for the call
            // it was the only one for.
            let callWaiting = roster.anyUp
            if !callWaiting { configureAudioSession() }
            let uuid = UUID()
            uuids[callID] = uuid
            callIDs[uuid] = callID
            roster.add(callID, .awaitingReport)
            let update = callUpdate(handle: Self.callKitHandle(handle), name: displayName)
            lastUpdate[uuid] = update
            onLog("callkit: reporting \(callID) as \(short(uuid)) (app \(appState))")
            provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.onLog("callkit: report of \(callID) refused: \(error.localizedDescription)")
                    self.uuids[callID] = nil
                    self.callIDs[uuid] = nil
                    self.lastUpdate[uuid] = nil
                    self.roster.remove(callID)
                } else {
                    self.onLog("callkit: report of \(callID) accepted")
                    self.roster.confirm(callID)
                    self.recovery.providerAnswered()
                    if callWaiting {
                        self.onLog("callkit: \(callID) is waiting behind another call; playing the call-waiting tone")
                        self.waitingCallID = callID
                        self.onCallWaiting(true)
                    }
                }
                completion(error)
            }
        }
        pendingLock.withLock { pendingReports[callID] = (token, report) }
        if Thread.isMainThread { report() } else { DispatchQueue.main.async(execute: report) }
    }

    /// A flag a closure can take exactly once, from any thread.
    private final class RanOnce {
        private let lock = NSLock()
        private var done = false
        func take() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    /// A better caller name learned while the call is still ringing (the
    /// wake arrived after the INVITE had rung it with only the peer URI).
    func updateIncoming(callID: String, displayName: String) {
        DispatchQueue.main.async { [self] in
            guard let uuid = uuids[callID] else {
                onLog("callkit: name update for \(callID): no CallKit call")
                return
            }
            let update = lastUpdate[uuid] ?? CXCallUpdate()
            update.localizedCallerName = displayName
            lastUpdate[uuid] = update
            provider.reportCall(with: uuid, updated: update)
            onLog("callkit: \(callID) caller name updated to \(displayName)")
        }
    }

    /// A PushKit delivery for a call that is already ringing. iOS requires
    /// every VoIP push to be answered with `reportNewIncomingCall`; doing so
    /// again with the same UUID is refused (already exists) but satisfies
    /// that requirement, and leaves the ringing call untouched.
    ///
    /// Returns false when CallKit has no such call, in which case NOTHING has
    /// been reported and the caller must report the call itself: returning
    /// silently here got the app killed by iOS (0xBAADCA11, "no call
    /// reported for a VoIP push") on a wake to a suspended app. Main thread
    /// only: the PushKit registry delivers on the main queue and `uuids` is
    /// only touched there.
    @discardableResult
    func reaffirm(callID: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let uuid = uuids[callID] else {
            if let queued = pendingLock.withLock({ pendingReports[callID]?.run }) {
                // The INVITE's report is queued behind us on the main thread.
                // It used to be left there, on the theory that it would
                // satisfy the push "in a moment" — but the moment is after
                // the push delegate has returned, and iOS judges the
                // obligation at that return: it killed the app 250 ms later
                // (0xBAADCA11, MetricKit 2026-09-17 14:05) while the queued
                // report was still 30 ms from running. Run it now, here on
                // the main thread, inside the delegate; the queued copy
                // finds it done and steps aside.
                onLog("callkit: reaffirm of \(callID): running its queued report now, inside the push")
                queued()
                return true
            }
            onLog("callkit: reaffirm of \(callID): no CallKit call to reaffirm")
            return false
        }
        let update = lastUpdate[uuid] ?? CXCallUpdate()
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            self?.onLog("callkit: reaffirmed \(callID) (\(error.map { $0.localizedDescription } ?? "accepted"))")
        }
        return true
    }

    func end(callID: String, reason: CallEndReason) {
        DispatchQueue.main.async { [self] in
            guard let uuid = uuids.removeValue(forKey: callID) else { return }
            callIDs[uuid] = nil
            lastUpdate[uuid] = nil
            roster.remove(callID)
            pendingStarts[callID] = nil
            recovery.forget(callID)
            let cxReason: CXCallEndedReason
            switch reason {
            case .remoteEnded: cxReason = .remoteEnded
            case .answeredElsewhere: cxReason = .answeredElsewhere
            case .unanswered: cxReason = .unanswered
            case .failed: cxReason = .failed
            }
            onLog("callkit: ending \(callID) (\(reason))")
            clearWaiting(callID)
            provider.reportCall(with: uuid, endedAt: Date(), reason: cxReason)
            onEnded(callID)
        }
    }

    /// A call was ended by the far end or failed (not by the user).
    var onEnded: (String) -> Void = { _ in }

    /// The controller wants the last remaining call off hold (the call in
    /// progress ended). Requested as a hold action of its own so CallKit's
    /// state and iOS's banner follow, and after the end action that led
    /// here has been fulfilled.
    func resume(callID: String) {
        DispatchQueue.main.async { [self] in
            onLog("callkit: resuming \(callID), the only call left")
            requestHold(callID: callID, held: false)
        }
    }

    /// A second call is ringing while another is up (call waiting), or that
    /// call has stopped ringing. iOS suppresses the ringtone for it and
    /// shows its own answer UI, but plays no tone for a VoIP app (device,
    /// 2026-09-14), so the app puts the call-waiting beep into the ear of
    /// the person already talking, as a desk phone does.
    var onCallWaiting: (Bool) -> Void = { _ in }
    private var waitingCallID: String?

    /// `CallUI.playTone`: the controller's call-progress tones (ring-back,
    /// busy, congestion — plan Phase J), handed to the app's `TonePlayer`.
    /// The call-waiting beep has its own hook above because it is decided
    /// here, by CallKit's view of the calls, not by the controller.
    /// Unlike the rest of this file it does not hop to the main thread: it
    /// touches no CallKit state, and the app's sink hops to the main actor
    /// itself. A second hop here would let a tone stop overtake the
    /// call-waiting beep's start, which takes only one.
    var onTone: (CallTones.Tone?) -> Void = { _ in }

    func playTone(_ tone: CallTones.Tone?) { onTone(tone) }

    /// `CallUI.callProgress`: what the in-call screen says under the name.
    /// CallKit is told nothing — it has no notion of "busy" for a VoIP call
    /// and shows its own "calling" until the call ends.
    var onProgress: (String, CallProgress) -> Void = { _, _ in }

    func callProgress(callID: String, _ progress: CallProgress) { onProgress(callID, progress) }

    /// A call's capabilities as this app supports them. `supportsHolding`
    /// is, in CallKit's words, "whether the call can be held on its own or
    /// swapped with another call"; grouping is off because the app does
    /// not conference calls (SPEC §4.4 rule 8).
    private func callUpdate(handle: CXHandle?, name: String?) -> CXCallUpdate {
        let update = CXCallUpdate()
        if let handle { update.remoteHandle = handle }
        if let name { update.localizedCallerName = name }
        update.hasVideo = false
        update.supportsHolding = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        return update
    }

    /// Called on the main thread whenever a reported call stops ringing.
    private func clearWaiting(_ callID: String) {
        guard waitingCallID == callID else { return }
        waitingCallID = nil
        onCallWaiting(false)
    }

    /// Set the category and mode for the call; never activate the session —
    /// CallKit activates it and calls didActivate.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Bluetooth headsets over HFP, the hands-free profile that carries
            // a microphone. `.allowBluetooth` was renamed to say which profile
            // it means; the new name is available on every iOS we target
            // (the SDK back-deploys the rename, same underlying option).
            // `.voiceChat` implies it, but the intent is worth stating.
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            // What baresip's audiounit module (VoiceProcessingIO) is configured
            // for: 48 kHz, 20 ms frames. Preferences only; iOS may adjust.
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(0.02)
        } catch {
            logger.error("audio session configure: \(error.localizedDescription, privacy: .public)")
            onLog("callkit: audio session configure failed: \(error.localizedDescription)")
        }
    }

    private let logger = Logger(subsystem: DiallerIDs.bundlePrefix, category: "callkit")

    private func short(_ uuid: UUID) -> String { String(uuid.uuidString.prefix(8)) }

    private var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "?"
        }
    }

    /// Audio-session interruptions and app state changes, logged around the
    /// answer so a silent tap can be placed against what the system did.
    private func observeSystemNotifications() {
        let nc = NotificationCenter.default
        notificationTokens.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 99
            let reason = n.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            self?.onLog("callkit: audio interruption type=\(raw == 1 ? "began" : raw == 0 ? "ended" : "\(raw)") reason=\(reason.map(String.init) ?? "-")")
        })
        notificationTokens.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 99
            let route = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "?"
            self?.onLog("callkit: audio route change reason=\(reason) now \(route)")
        })
        notificationTokens.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onLog("app: will resign active")
        })
        notificationTokens.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.onLog("app: did become active")
            // A reset taken in the background (2026-09-27) is the one whose
            // registration did not come back; the foreground is where it
            // is needed and, on the evidence, where it is honoured.
            self.perform(self.recovery.didBecomeActive())
        })
    }

    // MARK: CXCallObserverDelegate — the system's view of each call

    func callObserver(_: CXCallObserver, callChanged call: CXCall) {
        let id = callIDs[call.uuid] ?? "unknown"
        onLog("callkit: observer \(short(call.uuid)) (\(id)) outgoing=\(call.isOutgoing) connected=\(call.hasConnected) ended=\(call.hasEnded) held=\(call.isOnHold)")
    }

    // MARK: CXProviderDelegate

    /// Called before the individual actions of every transaction CallKit
    /// hands us. Returning false lets the per-action methods run.
    func provider(_: CXProvider, execute transaction: CXTransaction) -> Bool {
        let names = transaction.actions.map { action -> String in
            let name = String(describing: type(of: action)).replacingOccurrences(of: "CX", with: "")
            let call = (action as? CXCallAction).map { short($0.callUUID) } ?? "-"
            let held = (action as? CXSetHeldCallAction).map { $0.isOnHold ? " hold" : " resume" } ?? ""
            return "\(name)(\(call)\(held))"
        }
        onLog("callkit: transaction \(names.joined(separator: ",")) (app \(appState))")
        recovery.providerAnswered()
        return false
    }

    func providerDidBegin(_: CXProvider) {
        onLog("callkit: provider began")
    }

    func provider(_: CXProvider, timedOutPerforming action: CXAction) {
        onLog("callkit: TIMED OUT performing \(String(describing: type(of: action)))")
    }

    func provider(_: CXProvider, didActivate session: AVAudioSession) {
        let route = session.currentRoute.outputs.first?.portName ?? "?"
        let input = session.currentRoute.inputs.first?.portName ?? "none"
        logger.info("audio session activated (\(route, privacy: .public))")
        onLog("callkit: audio session activated (out \(route), in \(input), \(Int(session.sampleRate))Hz, io \(Int(session.ioBufferDuration * 1000))ms, inputAvailable=\(session.isInputAvailable), inCh=\(session.inputNumberOfChannels), outCh=\(session.outputNumberOfChannels), otherAudio=\(session.isOtherAudioPlaying))")
        // The call was answered in the action; the engine binds its audio
        // devices now (or on establishment, whichever comes last).
        onAudioActivated()
    }

    func provider(_: CXProvider, didDeactivate _: AVAudioSession) {
        logger.info("audio session deactivated")
        onLog("callkit: audio session deactivated")
        onAudioDeactivated()
    }

    /// The provider's connection to the call daemon was interrupted (the
    /// framework calls this from its interruption handler); on this phone
    /// that has only ever happened while suspended, delivered on resume. The
    /// system's record of our calls is gone with it, and so, on 2026-09-27,
    /// was our registration: register afresh here, at the event, instead of
    /// hoping the framework does (`ProviderRecovery` has the history).
    func providerDidReset(_ reset: CXProvider) {
        guard reset === provider else {
            onLog("callkit: reset from a retired provider ignored")
            return
        }
        let active = UIApplication.shared.applicationState == .active
        onLog("callkit: PROVIDER RESET (\(uuids.count) call(s) dropped, app \(appState))")
        dumpSystemCallKitLog(lastSeconds: 20, why: "provider reset")
        for id in uuids.keys { onEnd(id) }
        uuids.removeAll()
        callIDs.removeAll()
        lastUpdate.removeAll()
        roster.removeAll()
        pendingStarts.removeAll()
        perform(recovery.didReset(appActive: active))
    }

    func provider(_: CXProvider, perform action: CXAnswerCallAction) {
        guard let id = callIDs[action.callUUID] else {
            onLog("callkit: answer for unknown call \(short(action.callUUID)); known: \(callIDs.keys.map(short))")
            action.fail()
            return
        }
        let session = AVAudioSession.sharedInstance()
        onLog("audio: at answer category=\(session.category.rawValue) mode=\(session.mode.rawValue) mic=\(AVAudioApplication.shared.recordPermission.rawValue) rate=\(Int(session.sampleRate))")
        // Answer in the action and fulfill (Speakerbox order). CallKit then
        // activates the session and calls didActivate; the engine binds its
        // audio devices once both the call and the session are up.
        onLog("callkit: answer accepted for \(id)")
        clearWaiting(id)
        onAnswer(id)
        action.fulfill()
    }

    func provider(_: CXProvider, perform action: CXEndCallAction) {
        if let id = callIDs.removeValue(forKey: action.callUUID) {
            uuids[id] = nil
            lastUpdate[action.callUUID] = nil
            roster.remove(id)
            pendingStarts[id] = nil
            recovery.forget(id)
            onLog("callkit: end for \(id)")
            clearWaiting(id)
            onEnd(id)
        } else {
            onLog("callkit: end for unknown call \(short(action.callUUID))")
        }
        action.fulfill()
    }

    func provider(_: CXProvider, perform action: CXStartCallAction) {
        guard let id = callIDs[action.callUUID] else {
            onLog("callkit: start for unknown call \(short(action.callUUID))")
            action.fail()
            return
        }
        onLog("callkit: start accepted for \(id) → \(action.handle.value)")
        // Only now is it a call (CallRoster); the request is spent.
        roster.confirm(id)
        pendingStarts[id] = nil
        recovery.forget(id)
        // Same shape as answering: hand it to the engine, fulfill; CallKit
        // then activates the session and the engine releases its audio.
        onStart(id)
        action.fulfill()
        // Only now does CallKit have this call, so only now can it keep an
        // update for it. The update gives the outgoing call the same
        // capabilities as an incoming one (holdable, no conference, no
        // DTMF) instead of CallKit's defaults, which allow all four. It
        // does not decide the answer UI for a second call — see the
        // provider configuration above.
        let update = callUpdate(handle: action.handle, name: action.contactIdentifier)
        lastUpdate[action.callUUID] = update
        provider.reportCall(with: action.callUUID, updated: update)
        onLog("callkit: \(id) capabilities reported")
    }

    func provider(_: CXProvider, perform action: CXSetMutedCallAction) {
        if let id = callIDs[action.callUUID] {
            onLog("callkit: mute=\(action.isMuted) for \(id)")
            onMute(id, action.isMuted)
        }
        action.fulfill()
    }

    func provider(_: CXProvider, perform action: CXSetHeldCallAction) {
        if let id = callIDs[action.callUUID] {
            onLog("callkit: hold=\(action.isOnHold) for \(id)")
            onHold(id, action.isOnHold)
        }
        action.fulfill()
    }
}
