import AVFoundation
import Combine
import DiallerCore
import DiallerProtocol
import Foundation
import Intents
import MetricKit
// @preconcurrency: NetworkExtension's classes (NEAppPushManager) are not yet
// marked Sendable, and its completion handlers are @Sendable. We only touch
// the manager after hopping back to the main actor inside those handlers,
// so the capture is safe; this silences the false Sendable warnings.
@preconcurrency import NetworkExtension
import os
import UIKit
#if canImport(DiallerEngine)
import DiallerEngine
#endif

/// App-side wiring of DiallerCore: config, the foreground LAN transport,
/// the call controller behind CallKit, and the directory. UI-observable.
@MainActor
final class AppModel: ObservableObject {
    // Settings
    @Published var host = ""
    @Published var port = "7443"
    @Published var deviceID = ""
    @Published var token = ""
    /// The dev path's "accept any certificate" (the Status page, Debug
    /// builds only); never true in a release build.
    @Published var acceptAnyCertificate = DevSettings.allowsAnyCertificate
    /// The server certificate pinned at enrolment (SPEC §4.8); nil on the
    /// dev path, where the toggle above decides.
    @Published var certSHA256: String?

    // Enrolment (SPEC §6 item 8)
    /// Whether the app holds a credential. False shows the onboarding
    /// screen instead of the tabs.
    @Published private(set) var enrolled = false
    @Published private(set) var enrolling = false
    @Published var enrolmentError: String?
    /// Enrolment stopped because Local Network access is refused: the
    /// onboarding screen offers Settings instead of a plain error.
    @Published private(set) var localNetworkDenied = false

    /// Demo mode (appstore.md, decision 2; `Demo` in DiallerCore): no
    /// server, calls simulated on this phone. Entered with the enrolment
    /// code `Demo.code`, left with Sign Out. Kept in the app's own
    /// defaults, never in the App Group config the extension reads.
    @Published private(set) var isDemo = UserDefaults.standard.bool(forKey: "demo")
    private var demoGateway: DemoGateway?
    private var demoDirectory = DemoDirectory()

    // Status
    @Published private(set) var status = "disconnected"
    /// The same, reduced to what Settings tells the user.
    enum Link: Equatable { case offline, connecting, waiting, connected, refused }
    @Published private(set) var link: Link = .offline
    /// Why the server refused us, in the user's words, while `link` is
    /// `.refused` (SPEC §4.9: a seat or licence problem names itself).
    @Published private(set) var refusalText: String?
    /// The licence the welcome carried, as the phone verified it: when it
    /// expires, and a one-line warning in its last week.
    @Published private(set) var licenceValidUntil: Date?
    @Published private(set) var licenceWarning: String?
    /// This phone's line (the SIP user the welcome names, e.g. "204"),
    /// remembered so Settings and the keypad can show it before the first
    /// welcome of a launch. Empty until one has arrived.
    @Published private(set) var line = UserDefaults.standard.string(forKey: "line") ?? ""
    @Published private(set) var sessionID = ""
    @Published private(set) var contacts: [DirectoryContact] = []
    /// The Recents list (SPEC §6 item 6), newest first. Written by the
    /// controller's record of every call and by the extension's sidecars.
    @Published private(set) var recents: [CallRecord] = []
    /// Missed calls the user has not looked at yet: the Recents tab's badge.
    @Published private(set) var unseenMissed = 0
    @Published private(set) var log: [String] = []
    @Published private(set) var localPushStatus = "Not configured"
    /// Whether iOS is actually running the provider extension right now.
    /// This is the one that decides whether a call can reach the phone
    /// while the app is not open: with it false the server's wake has
    /// nowhere to land and the caller gets "callee offline, wake
    /// undeliverable". It had been visible only as a log line, which cost
    /// a morning's debugging to work out (2026-09-16).
    @Published private(set) var backgroundCalls = "unknown"
    /// The same state for Settings: whether a call can reach the phone
    /// while the app is closed, in the user's terms.
    enum BackgroundCalls: Equatable { case off, on, waitingForNetwork }
    @Published private(set) var backgroundCallsMode: BackgroundCalls = .off
    /// The SSIDs of the saved Local Push configuration, as loaded from
    /// the framework's preferences (the source of truth; the app persists
    /// nothing of its own).
    @Published private(set) var localPushSSIDs: [String] = []
    /// The SSIDs the server manages for this device (SPEC §6 item 8b), as
    /// last received; nil until an administrator has set any. Settings
    /// shows them read-only.
    @Published private(set) var serverSSIDs: [String]?

    /// The call in progress, for the in-call screen. Nil while idle or
    /// merely ringing (ringing is CallKit's UI alone).
    struct ActiveCall: Identifiable, Equatable {
        var id: String
        var title: String
        var outgoing: Bool
        var connectedAt: Date?
        var muted = false
        var speaker = false
        var held = false
        /// Outgoing only: what the call is doing, from the SIP the
        /// controller sees. Stays on screen through the failure tone.
        var progress: CallProgress = .calling
        var status: String {
            if connectedAt == nil {
                return outgoing ? progress.label : "Connecting…"
            }
            return held ? "On Hold" : "Connected"
        }
    }
    /// Every call the in-call screen shows (answered, or outgoing and
    /// connecting), oldest first. With call waiting there are up to two:
    /// one active and one held.
    @Published private(set) var calls: [ActiveCall] = []
    /// The call the screen is about: the one not on hold, else (all held)
    /// the first, so the screen stays up for a single held call.
    var activeCall: ActiveCall? { calls.first { !$0.held } ?? calls.first }
    /// The other call, on hold, while two are up — named under the active
    /// party on the in-call screen (switching is the system's control).
    var heldCall: ActiveCall? {
        guard let active = activeCall else { return nil }
        return calls.first { $0.id != active.id && $0.held }
    }

    /// Call waiting (Settings): a second incoming call rings over the
    /// current one (Hold & Accept / End & Accept / Decline); off, a second
    /// caller hears busy at once. Persisted; default on.
    @Published var callWaiting: Bool {
        didSet {
            controller.callWaitingEnabled = callWaiting
            UserDefaults.standard.set(callWaiting, forKey: "callWaiting")
        }
    }

    /// iPhone Recents (Settings; SPEC §6 item 16): on, Dialler's calls are
    /// written to the Phone app's Recents, where they call back through
    /// Dialler (`callBack(activity:)`); off, nothing is written and the
    /// history lives in Dialler's Recents tab alone. Rows already written
    /// stay in the Phone app and still call back. Persisted; default on,
    /// which is what the app did before the setting existed.
    @Published var showsCallsInPhoneRecents: Bool {
        didSet {
            callKit.set(includesCallsInRecents: showsCallsInPhoneRecents)
            UserDefaults.standard.set(showsCallsInPhoneRecents, forKey: Self.phoneRecentsKey)
        }
    }

    private static let phoneRecentsKey = "phoneRecents"
    private static var savedShowsCallsInPhoneRecents: Bool {
        UserDefaults.standard.object(forKey: phoneRecentsKey) as? Bool ?? true
    }

    private func upsertCall(_ id: String, outgoing: Bool, connectedAt: Date?) {
        let title = controller.activeCalls.first { $0.wake.callID == id }.map { self.title(for: $0) } ?? "Call"
        if let i = calls.firstIndex(where: { $0.id == id }) {
            calls[i].connectedAt = connectedAt ?? calls[i].connectedAt
            calls[i].title = title
        } else {
            var c = ActiveCall(id: id, title: title, outgoing: outgoing, connectedAt: connectedAt)
            c.muted = calls.first?.muted ?? false // one microphone
            c.speaker = calls.first?.speaker ?? false // one route
            calls.append(c)
        }
    }

    /// A short-lived line on the in-call screen for something that happened
    /// to the call without changing its state — a refused transfer, where
    /// the call simply continues and nothing else would say so.
    @Published private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?

    private func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func clearNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
    }

    private let store: AppConfigStore = AppGroupConfigStore(appGroup: DiallerIDs.appGroup)
    private let callKit = CallKitBridge(includesCallsInRecents: AppModel.savedShowsCallsInPhoneRecents)
    /// Call-progress tones into the call's audio session (plan Phase J).
    private lazy var tones = TonePlayer(log: { [weak self] m in Task { @MainActor in self?.append(m) } })
    /// The controller's engine: the SIP engine, or the demo's in demo mode.
    private let engine: CallEngineSwitch
    private let demoEngine: DemoCallEngine
    /// The demo's far end, played while `demoEngine` says so.
    private lazy var demoEcho: DemoEcho = {
        let echo = DemoEcho()
        echo.log = { [weak self] m in Task { @MainActor in self?.append(m) } }
        return echo
    }()
    @Published private(set) var engineState = "None"
    private lazy var controller = CallController(ui: callKit, engine: engine, log: { [weak self] m in
        Task { @MainActor in self?.append(m) }
    })
    /// The gateway session, kept up by `GatewaySession` (reconnects after a
    /// drop while we are in the foreground).
    private var session: GatewaySession?
    /// A session was lost since the last welcome: the SIP registration died
    /// with it and must be rebuilt when the next welcome arrives.
    private var sessionDropped = false
    private var eventTask: Task<Void, Never>?
    /// The saved Local Push configuration, kept loaded so its delegate stays
    /// attached: iOS hands incoming calls to that delegate whenever this
    /// process exists (foreground or suspended) and only goes through
    /// PushKit to launch a dead one. See `LocalPushDelegate`.
    private var pushManager: NEAppPushManager?
    /// Every loaded manager instance, kept alive so their delegates stay set.
    private var pushManagers: [NEAppPushManager] = []
    /// Live observation of the adopted manager's `isActive`.
    private var pushObservation: NSKeyValueObservation?
    private lazy var localPushDelegate = LocalPushDelegate(model: self)
    /// The address book, persisted (SPEC §6 item 7) so the sync cursor
    /// survives a launch and the list is on screen before the first sync.
    private var book = AddressBook()
    private let bookStore = AddressBookStore()
    /// The SIP domain the welcome named, for guessing a new contact's mode.
    private var sipDomain = ""
    /// A failed directory write, for the Directory tab's alert.
    @Published var directoryError: String?
    /// Thread-safe caller-name lookup for incoming calls (the controller
    /// resolves names off the main actor). Kept in step with `contacts`.
    private nonisolated let nameIndex = DirectoryNameIndex()
    private let recentsStore = RecentsStore()
    /// When the user last opened the Recents tab; missed calls after it
    /// count towards the badge. A per-device convenience, so UserDefaults.
    private var recentsSeenAt: Date {
        get { UserDefaults.standard.object(forKey: "recentsSeenAt") as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "recentsSeenAt") }
    }
    private let logger = Logger(subsystem: DiallerIDs.bundlePrefix, category: "app")
    /// Persistent log in the App Group (survives a kill; uploaded to the dev
    /// server on the next launch), beside the in-memory view.
    private let fileLog = Breadcrumb.log
    private let diagnostics = DiagnosticsCollector()
    @Published private(set) var diagnosticsStatus = ""

    init() {
        callWaiting = UserDefaults.standard.object(forKey: "callWaiting") as? Bool ?? true
        showsCallsInPhoneRecents = Self.savedShowsCallsInPhoneRecents
        Breadcrumb.drop("AppModel: creating the SIP engine")
        let demo = DemoCallEngine()
        demoEngine = demo
        #if canImport(DiallerEngine)
        let baresip = BaresipCallEngine(acceptAnyCertificate: DevSettings.allowsAnyCertificate)
        engine = CallEngineSwitch(primary: baresip, alternate: demo)
        engineState = Self.engineText(.idle)
        #else
        let logging = LoggingCallEngine()
        engine = CallEngineSwitch(primary: logging, alternate: demo)
        #endif
        if let cfg = store.load() {
            host = cfg.gateway.host
            port = String(cfg.gateway.port)
            deviceID = cfg.deviceID
            token = cfg.token
            acceptAnyCertificate = cfg.gateway.acceptAnyCertificate
            certSHA256 = cfg.gateway.certSHA256
            enrolled = cfg.isComplete
        }
        if isDemo {
            enrolled = true
            engine.use(alternate: true)
            engineState = "Demo"
        }
        fileLog?.write("---- launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") ----")
        if let saved = bookStore?.load() {
            book = saved
            publishBook()
        }
        // MetricKit hands the app its own crash / hang / CPU-kill reports on
        // the launch after they happened; they are queued and uploaded with
        // the logs, so a termination on the phone is readable on the Mac.
        diagnostics.onPayload = { [weak self] data in
            DiagnosticsClient.enqueue(kind: "metrickit", data: data)
            Task { @MainActor in self?.append("diagnostics: MetricKit report queued (\(data.count) bytes)") }
        }
        MXMetricManager.shared.add(diagnostics)
        Task { await sendDiagnostics(reason: "launch") }
        controller.callWaitingEnabled = callWaiting
        // Recents: every call the controller lets go of, whatever became of
        // it, plus what the extension noted while this process was not
        // running. Folded again on each return to the foreground.
        recents = recentsStore?.foldPending() ?? []
        refreshUnseenMissed()
        controller.onCallEnded = { [weak self] record in
            Task { @MainActor in self?.recordCall(record) }
        }
        // A second call rings without a ringtone (iOS suppresses it) and
        // without a tone of its own; the beep is ours to play, into the ear
        // of the person already on a call.
        callKit.onCallWaiting = { [weak self] waiting in
            Task { @MainActor in
                guard let self else { return }
                self.tones.want(waiting ? CallTones.callWaiting : nil)
            }
        }
        // Every other call-progress tone (ring-back, busy, congestion) is
        // chosen by the controller, which knows the SIP, and played here,
        // which owns the audio session's player.
        // What the screen says under the name: "Ringing…" once the far end
        // is genuinely alerting, and why a call failed for as long as its
        // tone plays — it used to read "Calling…" through both.
        callKit.onProgress = { [weak self] id, progress in
            Task { @MainActor in
                guard let self, let i = self.calls.firstIndex(where: { $0.id == id }) else { return }
                self.calls[i].progress = progress
            }
        }
        callKit.onTone = { [weak self] tone in
            Task { @MainActor in
                guard let self else { return }
                self.tones.want(tone)
            }
        }
        callKit.onAnswer = { [weak self] id in
            guard let self else { return }
            // Answering a second call holds the first (the controller tells
            // the engine; CallKit's Hold & Accept sends the hold action too).
            self.controller.userAnswered(callID: id)
            for i in self.calls.indices where self.calls[i].id != id { self.calls[i].held = true }
            self.upsertCall(id, outgoing: false, connectedAt: Date())
        }
        callKit.onEnd = { [weak self] id in
            guard let self else { return }
            self.controller.userEnded(callID: id)
            self.callEnded(id)
        }
        callKit.onStart = { [weak self] id in
            guard let self else { return }
            self.clearNotice()
            self.controller.userStarted(callID: id)
            self.upsertCall(id, outgoing: true, connectedAt: nil)
        }
        callKit.onEnded = { [weak self] id in self?.callEnded(id) }
        callKit.onStartFailed = { [weak self] id in
            self?.controller.startFailed(callID: id)
            self?.calls.removeAll { $0.id == id }
        }
        callKit.onConnected = { [weak self] id in
            guard let self, let i = self.calls.firstIndex(where: { $0.id == id }) else { return }
            self.calls[i].connectedAt = Date()
        }
        callKit.onMute = { [weak self] id, muted in
            guard let self else { return }
            self.controller.setMuted(muted)
            for i in self.calls.indices { self.calls[i].muted = muted } // one microphone
        }
        controller.onTransferFailed = { [weak self] reason, progress in
            Task { @MainActor in
                guard let self else { return }
                self.append("transfer refused: \(reason)")
                // On screen, not only in the log: the call carries on, so
                // without this the user taps Transfer and nothing visible
                // happens at all.
                self.show(notice: progress.map { "Transfer Failed — \($0.label)" } ?? "Transfer Failed")
            }
        }
        // Show the directory's friendly name for a known incoming caller
        // (e.g. "SIP phone (101)" instead of sip:101@…). The controller runs
        // this off the main actor, so read a snapshot of the contacts.
        controller.resolveDisplayName = { [weak self] uri, provided in
            self?.nameIndex.name(forURI: uri) ?? provided
        }
        callKit.onHold = { [weak self] id, held in
            guard let self else { return }
            self.controller.setHeld(callID: id, held)
            if let i = self.calls.firstIndex(where: { $0.id == id }) { self.calls[i].held = held }
        }
        callKit.onAudioActivated = { [weak self] in
            self?.engine.audioSessionActivated()
            // After the engine, never before: a tone must not be what
            // activates the session, and must not race the call's own
            // audio units into it (see `TonePlayer`).
            Task { @MainActor in self?.tones.session(active: true) }
        }
        callKit.onAudioDeactivated = { [weak self] in
            self?.engine.audioSessionDeactivated()
            Task { @MainActor in self?.tones.session(active: false) }
        }
        callKit.onLog = { [weak self] m in Task { @MainActor in self?.append(m) } }
        // iOS suspends the app (and kills its sockets) in the background;
        // reconnect the moment we are back, and do not retry while away.
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // Leaving the foreground: a Local Push delivery to this
            // (soon suspended) process must find a delegate on the loaded
            // manager. Re-attach now; cheap, and it is exactly when it counts.
            Task { @MainActor in self?.attachLocalPushDelegate() }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appBecameActive() }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appEnteredBackground() }
        }
        #if canImport(DiallerEngine)
        baresip.log = { [weak self] m in Task { @MainActor in self?.append(m) } }
        baresip.onStateChange = { [weak self] s in Task { @MainActor in self?.engineChanged(s) } }
        #else
        logging.log = { [weak self] m in Task { @MainActor in self?.append(m) } }
        #endif
        demoEngine.log = { [weak self] m in Task { @MainActor in self?.append(m) } }
        demoEngine.echoing = { [weak self] on in Task { @MainActor in self?.demoEcho.set(running: on) } }
        demoEngine.echoMuted = { [weak self] muted in Task { @MainActor in self?.demoEcho.set(muted: muted) } }
    }

    // MARK: Calls

    /// Place a call. `target` is whatever the user gave: a directory URI
    /// ("sip:202@dialler"), a user ("202") or digits from the keypad; the
    /// engine completes bare targets with the account's domain and the
    /// server routes local users to apps and everything else to the trunk.
    /// Place a call; the controller's id for it, or nil when it could not
    /// start. The id is also the call's Recents record id when it ends.
    @discardableResult
    func dial(_ target: String) -> String? {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        dropPendingCallBack() // the user's own dial supersedes a held call-back
        let name = contacts.first { $0.uri == t || CallController.userPart(of: $0.uri) == t }?.displayName
        let id = controller.startCall(to: t, displayName: name)
        if id == nil {
            append("call to \(t) not started (see log above)")
        }
        return id
    }

    func hangUp() {
        guard let id = activeCall?.id else { return }
        callKit.requestEnd(callID: id)
    }

    /// Swap the active and the held call: one CallKit transaction, hold the
    /// active and resume the held; the hold actions come back through
    /// `onHold` and the screen follows. On iOS 26 the system's own swap
    /// banner does this; the in-call screen offers it only on older iOS.
    func swapCalls() {
        guard let active = activeCall, let held = heldCall else { return }
        callKit.requestSwap(active: active.id, held: held.id)
    }

    func toggleMute() {
        guard let call = activeCall else { return }
        callKit.requestMute(callID: call.id, muted: !call.muted)
    }

    /// Blind transfer of the active call. The call ends when the server has
    /// connected the other party; a refusal is logged and the call stays up.
    func transfer(to target: String) {
        guard let call = activeCall, call.connectedAt != nil else { return }
        controller.transfer(callID: call.id, to: target)
    }

    func toggleHold() {
        guard let call = activeCall, call.connectedAt != nil else { return }
        callKit.requestHold(callID: call.id, held: !call.held)
    }

    func toggleSpeaker() {
        guard let call = activeCall else { return }
        let speaker = !call.speaker
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none)
            for i in calls.indices { calls[i].speaker = speaker } // one route
        } catch {
            append("speaker toggle failed: \(error.localizedDescription)")
        }
    }

    /// CallKit ended a call that the in-call screen is showing (remote
    /// hangup, failure) — the bridge reports it through the controller's
    /// `end`, which calls this.
    func callEnded(_ id: String) {
        calls.removeAll { $0.id == id }
        if calls.isEmpty { clearNotice() } // it belonged to a call that is gone
        // The last call is over and we are not on screen: back to the
        // background rule (no session; the extension covers wakes).
        if controller.activeCalls.isEmpty, UIApplication.shared.applicationState != .active {
            session?.setActive(false)
        }
    }

    /// A call the extension woke rings while the app is in the background,
    /// where the keeper holds no session of its own — so the caller's
    /// hangup, a wake_cancel the server sends on the app's socket (and
    /// replays to a session that connects later), had nowhere to arrive and
    /// the phone rang until the user gave up (2026-09-13, repeatedly). CallKit
    /// keeps the process running while a call is tracked, so hold a session
    /// for exactly that long; `callEnded` lets it go again.
    private func holdSessionWhileCallTracked() {
        session?.setActive(true)
    }

    // MARK: Recents

    private func recordCall(_ record: CallRecord) {
        guard let store = recentsStore else { return }
        store.record(record)
        recents = store.foldPending() // the extension may have noted this wake too
        refreshUnseenMissed()
    }

    /// The name to show for a record: the directory's current name for the
    /// number, else the name known when the call ended, else the number.
    func recentName(for record: CallRecord) -> String {
        nameIndex.name(forURI: record.counterpart.uri)
            ?? (record.counterpart.displayName?.isEmpty == false ? record.counterpart.displayName! : record.number)
    }

    func deleteRecent(id: String) {
        guard let store = recentsStore else { return }
        recents = store.delete(id: id)
        refreshUnseenMissed()
    }

    func clearRecents() {
        recentsStore?.clear()
        recents = []
        refreshUnseenMissed()
    }

    /// The user is looking at the list: nothing on it is unseen any more.
    func markRecentsSeen() {
        recentsSeenAt = Date()
        refreshUnseenMissed()
    }

    private func refreshUnseenMissed() {
        let since = recentsSeenAt
        unseenMissed = recents.filter { $0.isMissed && $0.endedAt > since }.count
    }

    private func title(for call: TrackedCall) -> String {
        if call.direction == .outgoing {
            return call.wake.to.displayName ?? call.target
        }
        let provided = call.wake.from.displayName?.isEmpty == false ? call.wake.from.displayName : nil
        return nameIndex.name(forURI: call.wake.from.uri) ?? provided ?? CallController.numberPart(of: call.wake.from.uri)
    }

    var currentConfig: AppConfig {
        AppConfig(gateway: GatewayEndpoint(host: host, port: UInt16(port) ?? 7443, acceptAnyCertificate: acceptAnyCertificate, certSHA256: certSHA256),
                  deviceID: deviceID, token: token)
    }

    // MARK: Call-back from the Phone app (SPEC §6 item 16)

    /// A call-back from the Phone app's Recents. A CallKit call written there
    /// (`includesCallsInRecents`) is not a number the Phone app can dial: a
    /// tap on its row makes the system build an `INStartCallIntent` for the
    /// row's handle and ask our Intents extension (`IntentsExtension/
    /// IntentHandler.swift`) to handle it; the extension answers "continue
    /// in app", and the system opens the app with an `NSUserActivity` of
    /// that type, the intent inside it, which
    /// `ContentView.onContinueUserActivity("INStartCallIntent")` receives.
    /// Apple's own CallKit sample is this exact shape. The handle is the
    /// string the app gave CallKit — what it dialled or the server reported,
    /// the same value the Recents tab calls back with — so it goes to `dial`
    /// as it is.
    ///
    /// Warm, the dial is immediate. Cold (the tap launched the app) the
    /// activity arrives before the gateway has welcomed us and the SIP
    /// engine has registered, and `startCall` would refuse it ("no SIP
    /// account yet"); the target is held and dialled the moment the engine
    /// is up (`engineChanged`) or, in the demo, the welcome has arrived.
    func callBack(activity: NSUserActivity) {
        guard let intent = activity.interaction?.intent as? INStartCallIntent else {
            append("phone recents: ignored activity \(activity.activityType)")
            return
        }
        guard let handle = intent.contacts?.first?.personHandle?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !handle.isEmpty else {
            append("phone recents: call-back without a handle ignored")
            return
        }
        Breadcrumb.drop("phone recents: call-back to \(handle)")
        if readyToDial {
            append("phone recents: calling back \(handle)")
            dial(handle)
        } else {
            append("phone recents: holding call-back to \(handle) until the engine is up")
            pendingCallBack = handle
            pendingCallBackExpiry?.cancel()
            pendingCallBackExpiry = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.callBackHoldSeconds) * 1_000_000_000)
                guard !Task.isCancelled, let self, let held = self.pendingCallBack else { return }
                // Not a retry: a call placed minutes after the tap, when
                // the person has moved on, is a surprise call, not a late
                // success. The hold is as long as a launch and registration
                // reasonably take; past that the tap is dropped and said so.
                self.append("phone recents: call-back to \(held) dropped — not registered after \(Self.callBackHoldSeconds) s")
                self.pendingCallBack = nil
                self.pendingCallBackExpiry = nil
            }
        }
    }

    /// A call-back from the Phone app waiting for the engine (cold launch).
    private var pendingCallBack: String?
    private var pendingCallBackExpiry: Task<Void, Never>?
    private static let callBackHoldSeconds = 30
    /// The SIP stack is registered (or the demo's welcome has arrived), so
    /// `startCall` has an account and the engine can dial. Set from the
    /// engine's state, not from the gateway's: the welcome sets the
    /// account and starts registration, and a dial before registration
    /// completes would still fail.
    private var engineUp = false
    private var readyToDial: Bool { isDemo ? link == .connected : engineUp }

    private func flushPendingCallBack() {
        guard let handle = pendingCallBack, readyToDial else { return }
        dropPendingCallBack()
        append("phone recents: calling back \(handle) now the engine is up")
        dial(handle)
    }

    private func dropPendingCallBack() {
        pendingCallBack = nil
        pendingCallBackExpiry?.cancel()
        pendingCallBackExpiry = nil
    }

    #if canImport(DiallerEngine)
    private func engineChanged(_ state: BaresipCallEngine.State) {
        engineState = Self.engineText(state)
        switch state {
        case .idle, .starting, .registering, .failed: engineUp = false
        case .registered, .ringing, .dialing, .inCall: engineUp = true
        }
        flushPendingCallBack()
    }
    #endif

    // MARK: Enrolment (SPEC §6 item 8, §4.8)

    /// A `dialler://enrol` link: from the in-app scanner, or from the iOS
    /// Camera app through `onOpenURL`.
    func handle(url: URL) {
        guard let link = EnrolmentLink(url: url) else {
            append("ignored URL \(url)")
            return
        }
        Task { await enrol(link) }
    }

    func enrol(url: URL) async {
        guard let link = EnrolmentLink(url: url) else {
            localNetworkDenied = false
            enrolmentError = "This QR code isn’t an enrolment code."
            return
        }
        await enrol(link)
    }

    /// Manual entry: host and code; the server's reply names the
    /// certificate to pin (trust on first use).
    func enrol(host: String, port: UInt16, code: String) async {
        await enrol(EnrolmentLink(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port, code: EnrolmentLink.normalise(code)))
    }

    private func enrol(_ link: EnrolmentLink) async {
        guard !enrolling else { return }
        enrolling = true
        enrolmentError = nil
        defer { enrolling = false }
        if Demo.isCode(link.code) {
            startDemo()
            return
        }
        append("enrolling at \(link.host):\(link.port) (\(link.certSHA256 == nil ? "trust on first use" : "pinned from the QR"))")
        // Raise the Local Network prompt, and wait for the answer, before the
        // enrolment request: on a first run that request used to fail while
        // the prompt appeared behind the error (appstore.md, must-fix 8).
        localNetworkDenied = false
        let access = await LocalNetworkAccess.probe(host: link.host, port: link.port,
                                                    log: { [weak self] line in Task { @MainActor in self?.append(line) } }) {
            await MainActor.run { UIApplication.shared.applicationState == .active }
        }
        append("local network: \(access)")
        if access == .denied {
            localNetworkDenied = true
            enrolmentError = "\(AppName.display) needs Local Network access to reach your server."
            return
        }
        do {
            let result = try await EnrolmentClient().claim(link)
            let cfg = result.config(host: link.host, appVersion: currentConfig.appVersion)
            // A different device than before: its directory is not ours.
            if cfg.deviceID != deviceID {
                book.reset()
                publishBook()
            }
            host = cfg.gateway.host
            port = String(cfg.gateway.port)
            deviceID = cfg.deviceID
            token = cfg.token
            acceptAnyCertificate = false
            certSHA256 = cfg.gateway.certSHA256
            append("enrolled as \(cfg.deviceID) (user \(result.user)); certificate pinned")
            enrolled = true
            connect()
        } catch {
            append("enrolment failed: \(error.localizedDescription)")
            enrolmentError = error.localizedDescription
        }
    }

    /// Log out: forget the credential and return to onboarding. The
    /// server-side device is untouched: its next code brings this phone
    /// (or another) back under the same identity. The Local Push
    /// configuration goes too: the provider holds a gateway session built
    /// from the credential being cleared, and removing the configuration
    /// is what makes iOS stop it.
    func logout() {
        disconnect()
        if isDemo { leaveDemo() }
        removeLocalPush()
        store.clear()
        bookStore?.clear()
        book.reset()
        publishBook()
        host = ""
        deviceID = ""
        token = ""
        certSHA256 = nil
        line = ""
        UserDefaults.standard.removeObject(forKey: "line")
        enrolmentError = nil
        localNetworkDenied = false
        enrolled = false
        append("logged out: credential cleared, Local Push removed")
    }

    // MARK: Connection

    func autoConnectIfConfigured() {
        attachLocalPushDelegate()
        if isDemo || currentConfig.isComplete { connect() }
    }

    /// Loads the saved Local Push configuration(s) and attaches our delegate
    /// to every loaded instance. The framework delivers an incoming call to
    /// the delegate of a manager it LOADED from preferences: a manager the
    /// app created itself and saved is not that instance, even though it
    /// carries the same configuration. Seen 2026-09-13: after re-enabling
    /// Local Push (new object, delegate set on it, saved), the next wake to
    /// the suspended app logged "NEAppPushManager app has not set the
    /// delegate to receive the incoming call payload" and callservicesd
    /// killed the app (0xBAADCA11). So: attach at launch, again after every
    /// save, and again whenever the app leaves the foreground — the moment
    /// a delivery to this process starts to matter.
    private func attachLocalPushDelegate() {
        NEAppPushManager.loadAllFromPreferences { [weak self] managers, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.append("Local Push: load failed: \(error.localizedDescription)"); return }
                let loaded = managers ?? []
                guard !loaded.isEmpty else { self.append("Local Push: no saved configuration"); return }
                self.pushManagers = loaded
                for m in loaded { m.delegate = self.localPushDelegate }
                self.adopt(pushManager: loaded[0])
            }
        }
    }

    #if canImport(DiallerEngine)
    /// The SIP engine's state as the Status page shows it.
    static func engineText(_ state: BaresipCallEngine.State) -> String {
        switch state {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .registering: return "Registering"
        case .registered: return "Registered"
        case .ringing: return "Ringing"
        case .dialing: return "Dialling"
        case .inCall: return "In a Call"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
    #endif

    /// What the Local Push section says about whether calls can arrive
    /// while the app is closed. `isActive` is only true when iOS is running
    /// the extension, which it does on a matching SSID — so "waiting for a
    /// listed Wi-Fi network" is the ordinary off-site answer, not a fault.
    static func backgroundCallState(enabled: Bool, active: Bool) -> String {
        switch (enabled, active) {
        case (false, _): return "Off — calls arrive only while the app is open"
        case (true, true): return "Running"
        case (true, false): return "Not running — waiting for a listed Wi-Fi network, or needs turning on again below"
        }
    }

    private func adopt(pushManager manager: NEAppPushManager) {
        manager.delegate = localPushDelegate
        pushManager = manager
        localPushSSIDs = manager.matchSSIDs
        // isActive: whether iOS is currently running the provider extension
        // (on a matching SSID). false here explains "callee offline, wake
        // undeliverable" on the server: nothing holds the wake connection.
        append("Local Push: delegate attached (enabled=\(manager.isEnabled), active=\(manager.isActive), ssids=\(manager.matchSSIDs))")
        refreshBackgroundCalls()
        // The provider starts (and stops) a moment after a save, not
        // during it, so a value read at save time went stale until the
        // next launch. Apple's sample observes `isActive` (SimplePush
        // `PushConfigurationManager`); so do we, for the life of the
        // loaded instance.
        pushObservation = manager.observe(\.isActive, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshBackgroundCalls() }
        }
    }

    /// The Settings line, from the loaded manager as it stands now.
    private func refreshBackgroundCalls() {
        guard let m = pushManager else {
            backgroundCalls = Self.backgroundCallState(enabled: false, active: false)
            backgroundCallsMode = .off
            return
        }
        backgroundCalls = Self.backgroundCallState(enabled: m.isEnabled, active: m.isActive)
        backgroundCallsMode = !m.isEnabled ? .off : m.isActive ? .on : .waitingForNetwork
    }

    func connect() {
        if isDemo { return connectDemo() }
        let cfg = currentConfig
        guard cfg.isComplete else { status = "incomplete settings"; link = .offline; return }
        do { try store.save(cfg) } catch { append("config save failed: \(error)") }
        enrolled = true // the dev path: fields entered directly on the Status page
        // The same enrolment credential authenticates the SIP leg (Digest).
        engine.setCredentials(username: cfg.deviceID, password: cfg.token)
        // Asked here, once the phone is set up, not at first launch before
        // setup (appstore.md, must-fix 8); a no-op once answered.
        callKit.requestMicrophonePermission()
        // The SIP leg trusts the certificate the gateway connection trusts:
        // the one pinned at enrolment (SPEC §4.8), self-signed or not.
        engine.setServerTrust(pin: cfg.gateway.certSHA256, acceptAnyCertificate: cfg.gateway.acceptAnyCertificate)

        disconnect()
        let s = GatewaySession(endpoint: cfg.gateway)
        session = s
        sessionDropped = false
        start(s, hello: cfg.hello(kind: .app), status: "connecting to \(cfg.gateway.host):\(cfg.gateway.port)")
    }

    /// Hand the controller a transport and follow its events: the server's
    /// gateway session, or the demo's.
    private func start(_ transport: SignalTransport, hello: Hello, status label: String) {
        controller.attach(transport: transport)
        status = label
        link = .connecting
        eventTask = Task { [weak self] in
            for await ev in transport.events {
                guard let self else { return }
                await self.handle(ev)
            }
        }
        transport.connect(hello: hello)
    }

    // MARK: Demo mode

    /// Enter demo mode: nothing is saved to the App Group and nothing leaves
    /// the phone; the controller talks to the demo engine and gateway.
    private func startDemo() {
        append("demo: starting (no server; calls are simulated on this phone)")
        UserDefaults.standard.set(true, forKey: "demo")
        isDemo = true
        engine.use(alternate: true)
        engineState = "Demo"
        demoDirectory = DemoDirectory()
        enrolled = true
        connect()
    }

    private func connectDemo() {
        callKit.requestMicrophonePermission()
        disconnect()
        let gateway = DemoGateway()
        demoGateway = gateway
        start(gateway, hello: Demo.hello, status: "demo")
    }

    /// Sign Out from the demo. Its calls leave Recents with it: they were
    /// never this phone's.
    private func leaveDemo() {
        UserDefaults.standard.removeObject(forKey: "demo")
        isDemo = false
        engine.use(alternate: false)
        #if canImport(DiallerEngine)
        engineState = Self.engineText(.idle)
        #else
        engineState = "None"
        #endif
        clearRecents()
        append("demo: ended")
    }

    /// Settings › Receive a Demo Call: the demo's caller rings in a moment.
    func receiveDemoCall() {
        guard isDemo else { return }
        demoEngine.ringIncoming()
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        session?.disconnect()
        session = nil
        demoGateway?.disconnect()
        demoGateway = nil
        status = "disconnected"
        link = .offline
        sessionID = ""
    }

    /// Back in the foreground: a session that dropped while we were away
    /// reconnects now; with no session at all (never connected, or the
    /// user disconnected) nothing happens.
    private func appBecameActive() {
        session?.setActive(true)
        refreshBackgroundCalls() // the provider may have started or stopped while we were away
        // Calls the extension reported while we were away.
        if let store = recentsStore {
            recents = store.foldPending()
            refreshUnseenMissed()
        }
    }

    /// Backgrounded: normally stop retrying the gateway (the extension
    /// covers wakes while iOS suspends us). NOT while a call is tracked.
    /// iOS backgrounds this app every time it puts its own call screen in
    /// front — which it does for every second incoming call — and
    /// `setActive(false)` cancels the reconnect `holdSessionWhileCallTracked`
    /// had just asked for, so the session that carries `wake_cancel` stayed
    /// down for the life of the call. On 2026-09-14 (10:43 and 10:52) the
    /// server marked the device offline mid-call within a fraction of a
    /// second of the app resigning active, and the caller's hangup had to go
    /// the long way round. CallKit keeps the process alive while a call is
    /// tracked, so retrying costs nothing there.
    private func appEnteredBackground() {
        let tracked = controller.activeCalls.count
        guard tracked == 0 else {
            append("gateway: staying connected in the background (\(tracked) call(s) tracked)")
            return
        }
        session?.setActive(false)
    }

    private func handle(_ ev: SignalEvent) async {
        switch ev {
        case .waiting(let reason):
            if reason.hasPrefix("reconnecting") {
                status = reason
                link = .connecting
                append("gateway: \(reason)")
            } else {
                status = "waiting for network (\(reason))"
                link = .waiting
                append("waiting: \(reason) — allow Local Network access if prompted")
            }
        case .connected(let w):
            status = "connected"
            link = .connected
            refusalText = nil
            sessionID = w.sessionID
            noteLicence(w.licence)
            append("welcome: session \(w.sessionID), heartbeat \(w.heartbeatSeconds)s, directory v\(w.directoryVersion)")
            if sessionDropped {
                // The SIP connection died with the old session; start over
                // rather than refreshing a registration on a dead socket.
                sessionDropped = false
                engine.resetRegistration()
            }
            if let sip = w.sip {
                // Foreground path (SPEC §2): stay registered while running so
                // calls reach us directly; wakes are for the background.
                sipDomain = sip.domain
                if line != sip.user {
                    line = sip.user
                    UserDefaults.standard.set(sip.user, forKey: "line")
                }
                controller.setAccount(user: "\(sip.user)@\(sip.domain)",
                                      sip: SIPTarget(host: sip.host, port: sip.port, transport: sip.transport))
            }
            if let cfg = w.config { apply(deviceConfig: cfg) }
            flushPendingCallBack()
            if w.directoryVersion != book.version { await syncDirectory() }
        case .wake, .wakeCancel:
            controller.handle(ev)
        case .directoryChanged(let v):
            append("directory changed → v\(v)")
            await syncDirectory()
        case .config(let cfg):
            append("settings changed → v\(cfg.version)")
            apply(deviceConfig: cfg)
        case .protocolError(let e):
            append("gateway error \(e.code.rawValue): \(e.message ?? "")")
            if e.fatal { status = "rejected: \(e.code.rawValue)"; link = .refused; refusalText = Self.refusalCopy(e) }
        case .disconnected(let reason):
            // Logged, not just shown: a session that goes down mid-call left
            // no trace in the diagnostics at all, so an incident could only
            // be read from the server's side (2026-09-14). The call count
            // says whether the drop happened while calls were up.
            append("gateway: session down (\(reason)); \(controller.activeCalls.count) call(s) tracked, app \(UIApplication.shared.applicationState == .active ? "active" : "background")")
            status = "disconnected (\(reason))"
            if link != .refused { link = .offline } // keep saying why
            sessionID = ""
            sessionDropped = true
        }
    }

    /// The words Settings shows for a fatal refusal. The server (and the
    /// session machine, for the licence it checks itself) name the reason
    /// in the error's message; anything else is the plain refusal.
    static func refusalCopy(_ e: ProtocolError) -> String {
        switch e.message {
        case "no licence seat":
            return "The server has no free licence seat for this phone. Ask your administrator."
        case "licence expired":
            return "This server's licence has expired. Ask your administrator to renew it."
        case "licence missing", "no licence":
            return "This server has no licence, or needs updating. Ask your administrator."
        case "licence invalid":
            return "This server's licence could not be verified. Ask your administrator."
        default:
            return "Not Accepted by the Server"
        }
    }

    /// Record what the welcome's licence says: its expiry, and a warning in
    /// the last seven days (SPEC §4.9). The session has already refused a
    /// welcome whose licence does not pass, so only a valid one gets here.
    private func noteLicence(_ token: String?) {
        guard case .valid(let until) = LicenceVerifier.verify(token, now: Date()) else {
            licenceValidUntil = nil
            licenceWarning = nil
            return
        }
        licenceValidUntil = until
        let days = Int(until.timeIntervalSinceNow / 86_400)
        switch days {
        case ..<0: licenceWarning = nil
        case 0: licenceWarning = "This server's licence expires today. Ask your administrator to renew it."
        case 1: licenceWarning = "This server's licence expires tomorrow. Ask your administrator to renew it."
        case 2...7: licenceWarning = "This server's licence expires in \(days) days. Ask your administrator to renew it."
        default: licenceWarning = nil
        }
        if licenceWarning != nil { append("licence expires in \(days) days") }
    }

    /// Wake delivered by the NEAppPushProvider extension through PushKit.
    func handleExtensionWake(userInfo: [AnyHashable: Any]) {
        guard let json = userInfo["wake"] as? String,
              let wake = try? WireCoding.makeDecoder().decode(Wake.self, from: Data(json.utf8)) else {
            append("push payload without a wake: \(userInfo)")
            return
        }
        append("wake via extension for call \(wake.callID)")
        // Every PushKit delivery must be met with a CallKit report, even when
        // the app's own socket already rang this call (iOS 13+ contract).
        let name = nameIndex.name(forURI: wake.from.uri) ?? (wake.from.displayName?.isEmpty == false ? wake.from.displayName! : CallController.numberPart(of: wake.from.uri))
        let outcome = controller.handle(wake: wake)
        switch outcome {
        case .rang:
            holdSessionWhileCallTracked()
        case .duplicate(let id):
            holdSessionWhileCallTracked()
            append("wake \(wake.callID) already ringing as \(id); reaffirming with CallKit")
            if !callKit.reaffirm(callID: id) {
                // The controller still tracks the call but CallKit has no
                // entry for it (its report was refused, or it was ended on
                // the CallKit side alone). Every push must produce a report,
                // so ring it afresh under the tracked id.
                append("wake \(wake.callID): CallKit lost call \(id); reporting it again")
                callKit.reportIncoming(callID: id, displayName: name, handle: wake.from.uri) { _ in }
            }
        case .expired, .refused:
            // PushKit's contract: every push is met with a report. A wake
            // that is past its expiry, or refused (call waiting off, or two
            // calls already), is reported and ended at once.
            append("\(wake.callID): wake via extension \(outcome == .expired ? "expired" : "refused"); reporting and ending it to satisfy PushKit")
            callKit.reportIncoming(callID: wake.callID, displayName: name, handle: wake.from.uri) { [weak self] err in
                if err == nil { self?.callKit.end(callID: wake.callID, reason: .unanswered) }
            }
        }
    }

    // MARK: Directory

    /// The server's directory, or the demo's.
    private var directory: any DirectoryService {
        if isDemo { return demoDirectory }
        let cfg = currentConfig
        return DirectoryClient(base: cfg.httpBase(), deviceID: cfg.deviceID, token: cfg.token,
                               session: DirectoryClient.session(for: cfg.gateway))
    }

    /// `contacts` and the name index follow the book; the book follows disk.
    private func publishBook() {
        contacts = book.sorted
        nameIndex.update(contacts)
        bookStore?.save(book)
    }

    var favourites: [DirectoryContact] { contacts.filter(\.isFavourite) }

    func syncDirectory() async {
        do {
            let had = book.version
            // A local copy: an actor-isolated property cannot be passed
            // inout across an await.
            var synced = book
            let reset = try await directory.sync(&synced)
            book = synced
            publishBook()
            append(reset
                ? "directory: server is behind our cursor v\(had) (reset or re-provisioned); re-synced in full to v\(book.version), \(contacts.count) contacts"
                : "directory synced: v\(book.version), \(contacts.count) contacts")
        } catch {
            append("directory sync failed: \(error.localizedDescription)")
        }
    }

    /// The mode a new contact most likely has (SPEC §4 "Standalone mode"):
    /// a bare number or one in our own domain is an app on this server;
    /// anything elsewhere goes through the trunk. The user can change it.
    func defaultMode(for number: String) -> String {
        let user = CallController.userPart(of: number)
        guard let at = user.firstIndex(of: "@") else { return "local" }
        let host = user[user.index(after: at)...]
        return host.caseInsensitiveCompare(sipDomain) == .orderedSame ? "local" : "trunk"
    }

    /// Writes go to the server first — it is the source of truth — and the
    /// list follows by the sync the server's own directory_changed triggers
    /// (and one requested here, so the change shows even if that push is
    /// slow). A failure is shown and nothing local changes.
    private func write(_ what: String, _ op: @escaping (any DirectoryService) async throws -> Void) async -> Bool {
        do {
            try await op(directory)
            await syncDirectory()
            return true
        } catch {
            append("directory \(what) failed: \(error.localizedDescription)")
            directoryError = "Couldn’t \(what). \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func addContact(_ draft: ContactDraft) async -> Bool {
        await write("add the contact") { _ = try await $0.create(draft) }
    }

    @discardableResult
    func updateContact(id: String, _ draft: ContactDraft) async -> Bool {
        await write("save the contact") { _ = try await $0.update(id: id, draft) }
    }

    @discardableResult
    func deleteContact(id: String) async -> Bool {
        await write("delete the contact") { try await $0.delete(id: id) }
    }

    /// The star is optimistic: it flips at once and the sync after the
    /// write confirms it, or a failed write's sync puts it back.
    func toggleFavourite(_ c: DirectoryContact) async {
        let on = !c.isFavourite
        book.setFavourite(id: c.id, on)
        publishBook()
        var draft = ContactDraft(c)
        draft.favourite = on
        if !(await updateContact(id: c.id, draft)) {
            book.setFavourite(id: c.id, !on)
            publishBook()
        }
    }

    // MARK: Local Push Connectivity (device only; SPEC §2)

    /// The server's settings for this device arrived (in the welcome, or
    /// pushed on change): bring the Local Push configuration into line.
    /// `LocalPushPolicy` decides — and leaves an identical configuration
    /// alone, since re-saving one can restart the provider (SPEC §6 item 8b).
    private func apply(deviceConfig cfg: DeviceConfig) {
        serverSSIDs = cfg.ssids
        NEAppPushManager.loadAllFromPreferences { [weak self] managers, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.append("settings v\(cfg.version): Local Push load failed: \(error.localizedDescription)")
                    return
                }
                let current = managers?.first
                let action = LocalPushPolicy.plan(received: cfg, current: current?.matchSSIDs, enabled: current?.isEnabled ?? false)
                switch action {
                case .leave:
                    self.append("settings v\(cfg.version): Local Push already matches \(cfg.ssids)")
                case .save(let list):
                    self.append("settings v\(cfg.version): applying SSIDs \(list) to Local Push")
                    self.configureLocalPush(ssids: list)
                case .remove:
                    self.append("settings v\(cfg.version): no SSIDs; removing the Local Push configuration")
                    self.removeLocalPush()
                }
            }
        }
    }

    /// Saves the provider configuration for `ssids` (already parsed, see
    /// `SSIDList`): iOS runs the extension whenever the phone is joined to
    /// any one of them.
    func configureLocalPush(ssids: [String]) {
        guard !ssids.isEmpty else { localPushStatus = "No networks entered"; return }
        NEAppPushManager.loadAllFromPreferences { [weak self] managers, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.localPushStatus = "Couldn’t load: \(error.localizedDescription)"; return }
                let manager = managers?.first ?? NEAppPushManager()
                manager.localizedDescription = "\(AppName.display) Background Calls"
                manager.providerBundleIdentifier = DiallerIDs.pushProviderBundleID
                manager.matchSSIDs = ssids
                manager.providerConfiguration = ["gateway": "\(self.host):\(self.port)"]
                manager.isEnabled = true
                manager.saveToPreferences { err in
                    Task { @MainActor in
                        if let err {
                            let ns = err as NSError
                            let detail = ns.userInfo.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                            self.localPushStatus = "Couldn’t save: \(ns.domain) \(ns.code) \(detail)"
                            self.append("NEAppPushManager save failed: \(ns.domain) \(ns.code) \(detail); provider=\(DiallerIDs.pushProviderBundleID)")
                        } else {
                            self.localPushStatus = "On for \(SSIDList.format(ssids))"
                            self.append("NEAppPushManager saved for SSIDs \(SSIDList.format(ssids))")
                            // Not adopt(manager): deliveries go to the delegate
                            // of the instance the framework loads, so reload.
                            self.attachLocalPushDelegate()
                        }
                    }
                }
            }
        }
    }

    /// Removes any saved Local Push configuration. Stale configurations
    /// survive reinstalls and are the usual cause of NEAppPushErrorDomain 3.
    func removeLocalPush() {
        NEAppPushManager.loadAllFromPreferences { [weak self] managers, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.localPushStatus = "Couldn’t load: \(error.localizedDescription)"; return }
                let existing = managers ?? []
                self.append("Local Push: \(existing.count) saved configuration(s)")
                guard !existing.isEmpty else { self.localPushStatus = "Nothing to remove"; return }
                for m in existing {
                    m.removeFromPreferences { err in
                        Task { @MainActor in
                            self.localPushStatus = err.map { "Couldn’t remove: \($0.localizedDescription)" } ?? "Removed. Turn on again to save a new configuration."
                            if err == nil {
                                // Nothing is saved any more: say so now, not at
                                // the next launch (it read "running" until then).
                                self.localPushSSIDs = []
                                self.pushObservation = nil
                                self.pushManager = nil
                                self.pushManagers = []
                                self.refreshBackgroundCalls()
                            }
                        }
                    }
                }
            }
        }
    }

    private func append(_ line: String) {
        // notice, not info: iOS keeps info-level entries in memory only, so
        // after a kill (0xBAADCA11 for an unreported push) the lines that
        // explain it were gone. notice is persisted and shows in Console.app,
        // sysdiagnose and `log show` after the fact.
        logger.notice("\(line, privacy: .public)")
        fileLog?.write(line)
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    /// Queues this process's and the extension's persistent logs and sends
    /// everything queued (logs, MetricKit reports) to the dev server, which
    /// files them under data/diag/<device>/. Called at launch and from the
    /// "Send diagnostics" button; failures leave the queue for next time.
    func sendDiagnostics(reason: String) async {
        guard let cfg = store.load(), cfg.isComplete else {
            diagnosticsStatus = "Not configured"
            return
        }
        if let data = fileLog?.drain() { DiagnosticsClient.enqueue(kind: "app-log", name: reason, data: data) }
        if let ext = FileLog(name: "extension"), let data = ext.drain() {
            DiagnosticsClient.enqueue(kind: "extension-log", name: reason, data: data)
        }
        if let intents = FileLog(name: "intents"), let data = intents.drain() {
            DiagnosticsClient.enqueue(kind: "intents-log", name: reason, data: data)
        }
        let client = DiagnosticsClient(base: cfg.httpBase(), deviceID: cfg.deviceID, token: cfg.token,
                                       acceptAnyCertificate: cfg.gateway.acceptAnyCertificate, certSHA256: cfg.gateway.certSHA256)
        let result = await client.flush()
        diagnosticsStatus = result.failed == 0 ? "Sent \(result.sent) \(result.sent == 1 ? "item" : "items")" : "Sent \(result.sent); \(result.failed) queued (server unreachable)"
        append("diagnostics (\(reason)): \(diagnosticsStatus)")
    }
}

/// Fallback engine with no SIP stack; only logs. Kept for the simulator when
/// the baresip XCFrameworks have not been built.
final class LoggingCallEngine: CallEngine {
    var onIncomingCall: ((String, String, String?, String?) -> Void)?
    var onCallEnded: ((String, String, Int) -> Void)?
    var onOutgoingRinging: ((String, Bool) -> Void)?
    var onCallEstablished: ((String) -> Void)?
    var onTransferFailed: ((String, String) -> Void)?
    var log: (String) -> Void = { _ in }
    func register(user: String, sip: SIPTarget) {
        log("engine: would REGISTER \(user) to \(sip.host):\(sip.port)/\(sip.transport)")
    }
    @discardableResult
    func answer(engineCallID: String) -> Bool {
        log("engine: would answer \(engineCallID)")
        return true // no stack to fail on
    }
    func dial(callID: String, to target: String) -> String? {
        log("engine: would dial \(target) for \(callID)")
        return "log-\(callID)"
    }
    func hangup(engineCallID: String) {
        log("engine: hangup \(engineCallID)")
    }
}

/// Receives incoming calls from the Local Push provider while this process
/// exists. Local Push Connectivity has two delivery paths: when the app is
/// not running, iOS launches it with a VoIP push (PushKit,
/// `AppDelegate.pushRegistry(_:didReceiveIncomingPushWith:...)`); when the
/// process exists — foreground or suspended — iOS calls this delegate on the
/// main queue instead. Without it the call reached nobody and callservicesd
/// killed the app (0xBAADCA11) on every wake to a suspended process, while
/// cold launches worked (device console, 2026-09-11). Both paths end in the
/// same handler, which reports to CallKit synchronously.
final class LocalPushDelegate: NSObject, NEAppPushDelegate {
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func appPushManager(_ manager: NEAppPushManager, didReceiveIncomingCallWithUserInfo userInfo: [AnyHashable: Any]) {
        // Documented as delivered on the main queue; the model is main-actor.
        MainActor.assumeIsolated {
            model?.handleExtensionWake(userInfo: userInfo)
        }
    }
}

/// Receives MetricKit diagnostics (crash, hang, CPU exception, disk write)
/// and hands each payload's JSON to `onPayload`. Delivered by the system on
/// the launch following the event.
final class DiagnosticsCollector: NSObject, MXMetricManagerSubscriber {
    var onPayload: ((Data) -> Void)?

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads { onPayload?(p.jsonRepresentation()) }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {}
}
