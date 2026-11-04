import DiallerCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    enum Tab: Hashable { case recents, keypad, directory, settings }
    @State private var tab: Tab = .recents
    /// The Settings tab's navigation: the hidden Status page is pushed
    /// onto it, and any tab-bar tap empties it (SPEC §6 item 8).
    @State private var settingsPath = NavigationPath()

    var body: some View {
        Group {
            if model.enrolled {
                tabs
            } else {
                // First run (SPEC §6 item 8): no credential, no tabs.
                OnboardingView()
            }
        }
        .tint(Palette.ink)
        .toggleStyle(.greenSwitch)
        // A dialler://enrol link from the iOS Camera app.
        .onOpenURL { model.handle(url: $0) }
        // A tap on one of our rows in the Phone app's Recents (SPEC §6 item
        // 16): our Intents extension has answered the system's
        // INStartCallIntent with "continue in app", and the system opens us
        // with the intent in this activity; warm or a cold launch alike.
        .onContinueUserActivity("INStartCallIntent") { model.callBack(activity: $0) }
        // Ringing is CallKit's UI alone (banner, lock screen, Recents). While
        // a call is ACTIVE and the app is in front, iOS shows only the green
        // status indicator, so the in-call controls are ours. The cover
        // stands for "in a call", not for one particular call: keyed on the
        // active call's identity it was dismissed and presented again every
        // time the active call changed (accepting a second call, a swap, the
        // resume after a hang-up) — the keypad flashed through and iOS's own
        // banner blinked with each pass (device, 2026-09-14). The screen
        // inside follows `activeCall` and re-renders in place.
        .fullScreenCover(isPresented: Binding(get: { !model.calls.isEmpty }, set: { _ in })) {
            InCallView()
        }
    }

    private var tabs: some View {
        // Four tabs in the design canvas's order (2026-09-27: Keypad before
        // Directory). Status has no tab (SPEC §6 item 8): it is reached by
        // a five-second press on the Settings title. The selection binding's
        // setter runs on every tab-bar tap, the current tab included, which
        // is what hides Status again.
        TabView(selection: Binding(get: { tab }, set: { tab = $0; settingsPath = NavigationPath() })) {
            RecentsView()
                .tabItem { Label("Recents", systemImage: "clock") }
                .badge(model.unseenMissed)
                .tag(Tab.recents)
            KeypadView().tabItem { Label("Keypad", systemImage: "circle.grid.3x3") }.tag(Tab.keypad)
            DirectoryView().tabItem { Label("Directory", systemImage: "person.2") }.tag(Tab.directory)
            SettingsView(path: $settingsPath).tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(Tab.settings)
        }
        // The licence's last week (SPEC §4.9): one line above every tab, so
        // the person who can do something about it hears before the day
        // calls stop.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let warning = model.licenceWarning {
                Text(warning)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(Color.yellow.opacity(0.25))
            }
        }
    }
}
