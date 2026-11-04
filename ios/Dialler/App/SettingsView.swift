import DiallerCore
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    /// Owned by `ContentView`, so a tab-bar tap can pop the hidden page.
    @Binding var path: NavigationPath
    @State private var confirmSignOut = false

    enum Route: Hashable {
        case acknowledgements
        #if DEBUG
        case status
        #endif
    }

    /// "1.0 (12)", and "· Debug" on a Debug build, so a glance at Settings
    /// says whether the phone runs what Xcode's Run built or an archive.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        #if DEBUG
        return "\(v) (\(b)) · Debug"
        #else
        return "\(v) (\(b))"
        #endif
    }

    private var device: String { UIDevice.current.model }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                // Debug builds only: a five-second press on the title opens
                // the hidden Status page. Release builds (every archive, so
                // TestFlight and the App Store) have no page and no gesture:
                // App Review does not allow hidden features (guideline 2.3.1).
                ScreenHeader(title: "Settings")
                    #if DEBUG
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 5) { path.append(Route.status) }
                    #endif
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        summary
                        connection
                        if model.isDemo { demo }
                        calls
                        about
                        signOut
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
            }
            .background(Palette.ground)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .acknowledgements: AcknowledgementsView()
                #if DEBUG
                case .status: StatusView()
                #endif
                }
            }
        }
    }

    // MARK: Sections

    /// The line and whether it is up: the design canvas's Status page,
    /// folded into the top of Settings (2026-09-27).
    private var summary: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().strokeBorder(Palette.ink, lineWidth: 1.25)
                Image(systemName: linkGlyph)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.line.isEmpty ? "This \(device)" : CallText.party(model.line))
                    .font(.title3.weight(.medium))
                    .tracking(-0.4)
                    .foregroundStyle(Palette.ink)
                Text(linkText)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondary)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("Connection")
            if model.isDemo {
                SettingsRow("Server", value: "None")
                SettingsFooter("This is a demo. Calls are simulated on this \(device): they ring, connect and play your voice back, and nothing leaves the phone.")
            } else {
                SettingsRow("Server", value: model.host.isEmpty ? "—" : model.host)
                SettingsRow("Background Calls", value: backgroundValue)
                SettingsRow("Office Wi-Fi", value: officeNetworks)
                SettingsFooter(backgroundFooter)
            }
        }
    }

    /// Demo mode only: an incoming call on request, since no one else can
    /// ring a demo phone.
    private var demo: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("Demo")
            Button("Receive a Demo Call") { model.receiveDemoCall() }
                .buttonStyle(WideButtonStyle(kind: .outline))
                .padding(.top, 8)
            SettingsFooter("\(Demo.caller.name) calls in a few seconds. Calls to Sales Line are always busy.")
        }
    }

    private var calls: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("Calls")
            Toggle(isOn: $model.callWaiting) {
                Text("Call Waiting").font(.callout).foregroundStyle(Palette.ink)
            }
            .frame(minHeight: 52)
            .overlay(alignment: .bottom) { Palette.hairline.frame(height: 1) }
            SettingsFooter("When this is on, a second caller rings while you’re on a call. When it’s off, they hear a busy tone.")
            Toggle(isOn: $model.showsCallsInPhoneRecents) {
                Text("iPhone Recents").font(.callout).foregroundStyle(Palette.ink)
            }
            .frame(minHeight: 52)
            .overlay(alignment: .bottom) { Palette.hairline.frame(height: 1) }
            SettingsFooter("When this is on, your Dialler calls also appear in the Phone app’s Recents, and calling back from there uses Dialler. When it’s off, they appear only in Dialler.")
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("About")
            SettingsRow("Version", value: Self.version)
            NavigationLink(value: Route.acknowledgements) {
                HStack {
                    Text("Acknowledgements").font(.callout).foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.tertiary)
                }
                .frame(minHeight: 52)
                .overlay(alignment: .bottom) { Palette.hairline.frame(height: 1) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var signOut: some View {
        Button("Sign Out") { confirmSignOut = true }
            .buttonStyle(WideButtonStyle(kind: .outline))
            // On the button, not the screen: iOS 26 shows the dialog as a
            // popover pointing at the view it hangs from.
            .confirmationDialog("Sign out of \(AppName.display)?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { model.logout() }
            } message: {
                Text("Calls won’t reach this \(device) until it’s set up again with a new enrolment code from your administrator.")
            }
            .padding(.top, 32)
    }

    // MARK: Words

    private var linkGlyph: String {
        switch model.link {
        case .connected: return "checkmark"
        case .connecting, .waiting: return "ellipsis"
        case .offline, .refused: return "exclamationmark"
        }
    }

    private var linkText: String {
        if model.isDemo { return "Demo" }
        switch model.link {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .waiting: return "Waiting for Network"
        case .offline: return "Not Connected"
        case .refused: return model.refusalText ?? "Not Accepted by the Server"
        }
    }

    private var backgroundValue: String {
        switch model.backgroundCallsMode {
        case .on: return "On"
        case .waitingForNetwork: return "Waiting for Wi-Fi"
        case .off: return "Off"
        }
    }

    /// The networks the administrator set (SPEC §6 item 8b), or, until
    /// they have, whatever is saved on the phone.
    private var officeNetworks: String {
        let list = model.serverSSIDs ?? model.localPushSSIDs
        return list.isEmpty ? "None" : SSIDList.format(list)
    }

    private var backgroundFooter: String {
        let app = AppName.display
        switch model.backgroundCallsMode {
        case .on:
            return "Calls reach this \(device) on office Wi-Fi, even when \(app) is closed."
        case .waitingForNetwork:
            return "Calls reach this \(device) while \(app) is open. When it’s closed, they reach it only on office Wi-Fi."
        case .off:
            return model.serverSSIDs == nil
                ? "Calls reach this \(device) only while \(app) is open. Your administrator hasn’t set up office Wi-Fi for it yet."
                : "Calls reach this \(device) only while \(app) is open."
        }
    }
}

// MARK: - Rows

/// A section's small-capitals label, spaced like the canvas.
struct SettingsSection: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        SectionLabel(text: title)
            .padding(.top, 28)
            .padding(.bottom, 4)
    }
}

/// A label and its value, over a hairline.
struct SettingsRow: View {
    let label: String
    let value: String
    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).font(.callout).foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(4)
        }
        .padding(.vertical, 15)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { Palette.hairline.frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// Explanatory text under a section.
struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
    }
}
