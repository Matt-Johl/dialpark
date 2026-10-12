# App Store submission plan

The work needed to take the iOS app from its current state (branch-built,
installed from Xcode) to a public App Store release. Written 2026-09-28
from a review of the project as it stood on `main` at 58bb0c7.

## Decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | Distribution route | **Public App Store** (2026-09-28). |
| 2 | How App Review uses the app | **Demo mode** (2026-09-28), built after the other must-fixes are done and tested. Compared under [Review access](#review-access). |
| 3 | The hidden Status page | **Debug builds only** (2026-09-28). Release builds (every archive: TestFlight and the App Store) contain no page and no gesture. The manual "Send Diagnostics" goes with it; the automatic upload at launch stays. |
| 4 | Store name | **Done.** "Dialler" is reserved; the app record exists in App Store Connect (pre-submission). |

## Progress

`feature/app-store-readiness`, merged 2026-09-28 as **v1.0.0 (build 1)**:

| Item | State |
|------|-------|
| 1. Icon without transparency | **Done.** Every pixel was already opaque, so dropping the channel changed nothing visible. |
| 2. Privacy manifests | **Done**, for the app and the PushProvider extension. |
| 3. SIP certificate pinning | **Done and tested** against the native server from the iOS simulator: the right pin registers and the call carries audio; a wrong SIP-leg pin, with the gateway pinned right, is refused by the new check. |
| 4. Release builds without developer settings | **Done.** The Status page itself is Debug-only (decision 3); a release binary has no trace of it. Debug builds say so on Settings › Version ("· Debug"). |
| 5. Open-source notices | **Done**: Settings › About › Acknowledgements. |
| 6. Version and encryption key | **Done.** 1.0.0 (build 1), then bumped and tagged at every merge to main (see [Versions](#versions)). No encryption key in Info.plist (see [Export compliance](#export-compliance)): YES without a documentation code fails upload validation. |
| 7. Demo mode | **Done, confirmed on Matt's phone** (2026-09-29), merged as v1.0.1 (build 2). The echo is one VoiceProcessingIO unit created at CallKit's activation (AVAudioEngine stopped itself at the voice-processing switch; only a quiet fallback ever played), delayed by the measured 120 ms of the server echo path. |
| 8. Permission prompts | **Done, confirmed on Matt's phone** (fresh install, 2026-09-28): the Local Network prompt comes up during "Setting Up…" and enrolment then succeeds. The first attempt had failed ahead of the prompt: the probe took a TCP connection's privacy wait (a POSIX error with the reason on the path) for an ordinary failure. |
| Found on the way: device token in the log | **Fixed.** The SIP account line carried `auth_pass=<device token>` into the app log (Status page, diagnostics upload); every engine log line is now redacted. |

## Review access

App Review has to be able to sign in and use the app (guideline 2.1). The app
does nothing without an organisation's own server, which a reviewer cannot
reach. There are two ways to give them one.

### Option A: a public demo server

What it takes:

- A host with a public address and DNS name, running the call server with
  its enrolment, gateway (7443), SIP (5061) and RTP ports open to the
  internet.
- Something to call. The server has no echo or test extension of its own;
  the harness's answering phones are separate containers (baresip,
  Asterisk), so one of those runs beside it.
- Enrolment codes a reviewer can still use. Codes are claimable for 15
  minutes (`CodeTTL`, server/internal/enroll/enroll.go) and once only, and
  review takes days, so the server needs a review-code mechanism: a long-lived
  code, or several.
- Working on an IPv6-only network. Apple reviews on NAT64. The SIP and
  media stack (libre/baresip) opens its own sockets and runs its own DNS,
  so this has to be tested and probably fixed before a reviewer can
  register at all.
- Kept up, and not abused, for every review of every update: a public SIP
  server attracts scanners and toll-fraud attempts, so it needs no route
  to a real PBX or trunk.

### Option B: a demo mode in the app

Guideline 2.1 allows it: if a demo account cannot be provided, "you may
include a built-in demo mode in lieu of a demo account with prior approval
by Apple. Ensure the demo mode exhibits your app's full features and
functionality."

What it takes (app only; nothing on the server):

- A way in that is not a hidden feature: a documented enrolment code (for
  example `DEMODEMO`, typed in Enter Code Manually), named in the review
  notes. A "Try the Demo" button on the landing page would also do it, at
  some cost to its minimalism.
- A demo engine behind the existing `CallEngine` protocol (the controller
  already runs on fakes in its tests): outgoing calls ring for a moment,
  connect, and **echo the microphone back** once CallKit activates the
  audio session. That is real CallKit, a real audio path and the real
  in-call screen.
- An incoming demo call, so CallKit's ringing and answering can be shown
  too (for example a "Receive a Demo Call" row in Settings while in demo
  mode, ringing a few seconds later).
- A sample directory and Recents, the keypad, the Settings summary
  ("Demo" in place of the line), and Sign Out to leave the demo.
- Not demonstrable: background calls over office Wi-Fi (Local Push). The
  review notes say what they do and why a reviewer cannot trigger them.

### Comparison

| | A: public server | B: demo mode |
|---|---|---|
| Build work | Hosting, DNS, firewall, an answering endpoint, review codes on the server, the IPv6 fix | A demo engine with echo, the demo data, and a way in; app only |
| Blocking risk | The IPv6-only review network: the reviewer cannot even register until the SIP stack works on NAT64 | Apple's "prior approval" for demo mode, and whether the reviewer accepts that it shows the full app |
| Every later update | The server must be up, patched and holding valid codes for each review | Nothing; the demo ships in the app |
| Side benefit | A live system to show prospects | Anyone can try the app without a server, which is useful for prospects too |
| Rough effort | Several days, plus upkeep | 1–2 days |

**Recommendation: B, demo mode.** It is quicker, it keeps review away from
the IPv6 risk (which still wants fixing for real users, but no longer blocks
the first submission), and it costs nothing at each update. The one real
risk is approval, so ask App Review first, through App Store Connect
(Contact Us → App Review), describing the product and the demo mode. If
Apple insists on a live system, option A is still open, and the demo
engine is not wasted.

## Demo mode

Built 2026-09-28, merged 2026-09-29 (v1.0.1). The whole app with no server:
calls are simulated on the phone and nothing leaves it.

- **Way in:** the enrolment code `DEMODEMO` in Enter Code Manually (the
  server field can stay empty), or a QR carrying that code. Sign Out
  leaves the demo and clears its calls from Recents.
- **What it does:**
  - The line is Ext 200, with a ten-contact directory; adding, editing,
    deleting and favourites all work.
  - An outgoing call to anyone rings, connects and plays the caller's
    voice back 120 ms late, as the server's echo path does (an echo test);
    calls to Sales Line (299) are always busy.
  - Settings › Receive a Demo Call rings from Reception through CallKit a
    few seconds later.
- **How it is built:** stand-ins behind the protocols the app already uses,
  so the real call path is untouched: `DemoCallEngine` (a `CallEngine`,
  behind `CallEngineSwitch`), `DemoGateway` (a `SignalTransport`),
  `DemoDirectory` (a `DirectoryService`, the protocol `DirectoryClient` now
  also conforms to) in DiallerCore, and `DemoEcho` in the app: one
  VoiceProcessingIO unit, created only once CallKit has activated the audio
  session and disposed of when it is deactivated, as the real engine's
  driver does. The demo flag lives in the app's own defaults, never in the
  App Group config the extension reads.
- **Not in the demo:** background calls (Local Push on office Wi-Fi), which
  need the organisation's server and network.

### App Review notes (draft)

> Dialler is a business phone app. It connects to an organisation's own
> call server, installed on the organisation's premises by its
> administrator, so it cannot be used without one. To review it, please use
> the built-in demo mode:
>
> 1. Launch the app and tap **Enter Code Manually**.
> 2. Leave Server empty, enter the code **DEMODEMO**, and tap **Continue**.
>
> The app then runs with a simulated line (Ext 200) and company directory.
> Calls are simulated on the device: call any contact or number from the
> Keypad, Directory or Recents and the call rings, connects and plays your
> voice back (an echo test). Calls to "Sales Line" are always busy. For an
> incoming call, open **Settings** and tap **Receive a Demo Call**:
> Reception rings through CallKit a few seconds later. **Sign Out** in
> Settings leaves the demo.
>
> Background calls, which reach the phone over the office Wi-Fi through
> Local Push Connectivity while the app is closed, need the organisation's
> server and network and cannot be shown in the demo.

## Apple accounts and App Store Connect (Matt)

- **Developer Program** membership in the organisation's name (needs a
  D-U-N-S number).
- **Signing:** a distribution certificate and App Store profiles for the app
  (`com.latentbadger.dialler`) and the extension
  (`com.latentbadger.dialler.PushProvider`). App Groups and Network
  Extensions → App Push Provider must be on the distribution profiles as
  they are on the development ones.
- **Metadata:** description, keywords, support URL, **privacy policy URL**
  (required), category (Business), age rating, copyright, review contact
  and notes.
- **Screenshots:** **Done** (2026-09-29; retaken 2026-10-06 for the
  Dialpark rename and version 1.1.2), six screens in upload order
  (call, directory, recents, keypad, settings, welcome), opaque RGB (App
  Store Connect refuses an alpha channel):
  - `appstore/screenshots/6.5-inch/`: 1284 × 2778, the size App Store
    Connect asked for, from an iPhone 14 Plus simulator;
  - `appstore/screenshots/6.9-inch/`: 1320 × 2868, from the iPhone 17 Pro
    Max simulator, in case the larger size is wanted too;
  - `appstore/screenshots/6.3-inch/`: 1206 × 2622, from an iPhone 17 Pro
    simulator (2026-10-12), for the 6.1"/6.3" slot, which takes 1179 × 2556
    or 1206 × 2622.

  The app's own views on iOS 26 in UK English, release build (no "Debug"),
  status bar 9:41 with full signal and battery, server 10.0.0.10, Wi-Fi
  networks "Staff, Staff-5G", sample data that is fictitious (Ofcom drama
  numbers for outside lines).

  `appstore/screenshots/6.5-inch-dark/` and `6.9-inch-dark/` (2026-10-07)
  are the same six screens in dark mode, for the website to swap with its
  own theme. They are not for App Store Connect, which takes one set per
  size.
- **App Privacy label:** diagnostics and logs go to the customer's own
  server, not to us, so "Data Not Collected" is defensible; the privacy
  policy still says what the app sends and where.
- **Export compliance:** the app ships its own encryption (OpenSSL for TLS
  and SRTP) as well as Apple's, so the encryption questions must be answered.
  Probably standard mass-market encryption; confirm, and check whether
  France needs its own declaration.
- **Territories:** exclude mainland China (Apple does not allow CallKit
  apps there).

## Changes in the project

On a branch `feature/app-store-readiness`, merged on approval.

### Must fix before submitting

1. **App icon without transparency.** `AppIcon.appiconset/icon.png` has an
   alpha channel, which App Store Connect rejects; flatten it onto an opaque
   background (all three appearance slots use the same file).
2. **Privacy manifest** (`PrivacyInfo.xcprivacy`, missing). It must declare:
   UserDefaults (the app and its App Group: reasons CA92.1 and 1C8F.1);
   file timestamps (`stat`/`fstat` in the bundled libre and OpenSSL:
   C617.1); tracking: none; data collected: none (see the privacy label).
3. **SIP certificate checking.** `AppModel` always creates
   `BaresipCallEngine(acceptAnyCertificate: true)`, i.e.
   `sip_verify_server no`, even after enrolment has pinned the server's
   certificate. The SIP leg must be checked against the same pin. This is
   a security fix for a shipped product, not only a review matter.
   *Built:* the shim (`cbaresip.c`, `verify_server_cert`) replaces
   OpenSSL's chain check on baresip's SIP TLS context with a comparison of
   the leaf's SHA-256 against the enrolment pin, as the gateway connection
   does. Issuer, dates and name are not consulted, so self-signed
   certificates work, and nothing needs a publicly trusted CA.
   *Certificates:* one server certificate (self-signed, kept in
   `<data-dir>/tls`) serves the gateway, the phone API, SIP and the
   internal admin API; phones pin it, so it never needs renewing for them,
   and `<data-dir>/tls` belongs in backups (losing it means re-enrolling
   every phone). The admin console (`dialpark-admin`) has its own
   certificate, which can be publicly trusted and renewed freely. Two
   server follow-ups: issue #15 (the console stops reaching the server
   when the server's self-signed certificate passes its one-year expiry)
   and issue #16 (pick up a renewed console certificate without a
   restart).
4. **Release builds without the developer settings:** Accept Any
   Certificate, manual device ID and token, and Local Push by hand
   (decision 3 settles the rest of the Status page).
5. **Open-source notices.** OpenSSL (Apache 2.0), libre and baresip (BSD),
   and Opus (BSD) require their notices to ship with the app: an
   Acknowledgements page under Settings › About.
6. **Version and encryption keys.** `ITSAppUsesNonExemptEncryption` in
   Info.plist once export compliance is settled; `MARKETING_VERSION` 1.0
   (it is 0.1.0) and a build number that rises with every upload
   (`CURRENT_PROJECT_VERSION` is 1).
7. **Demo mode** (if decision 2 is B), as described above.
8. **Permission prompts at the right moment, and no failure on first run.**
   - *Local network (found by Matt on device, 2026-09-28):* after a fresh
     install the first enrolment fails, then iOS asks for Local Network
     access; once allowed, the second attempt works. iOS has no call that
     asks for the permission; the prompt appears on the first local-network
     connection, and that connection (the enrolment request) fails at once
     rather than waiting for the answer. Fix: once the server's address is
     known (after the QR scan, or on Continue in Enter Code), open a plain
     test connection to it first (`NWConnection`, the approach in Apple's
     Local Network Privacy FAQ) and wait. It becomes ready when access is
     allowed, and enrolment then goes ahead, so the user never sees a
     failure. It waits with a policy-denied error when access is refused,
     and the app says so plainly, with a button to open Settings, instead
     of an enrolment error. For a public server there is no prompt and the
     test connection costs milliseconds. Device-only to verify: the
     simulator does not enforce Local Network privacy.
   - *Microphone:* the prompt appears at first launch, before setup
     (`CallKitBridge.requestMicrophonePermission` at provider
     registration); ask once enrolment succeeds instead.

### Should do

9. **`audio` background mode.** `UIBackgroundModes` has `audio` as well as
   `voip`; reviewers sometimes question it. Test whether CallKit calls work
   without it and drop it if they do.

## Building for the App Store

- **Which build is which.** The shared `Dialler` scheme runs **Debug** (Run,
  ⌘R) and archives **Release** (Product › Archive). Only Debug builds
  define `DEBUG`, which is what keeps the Status page, Accept Any
  Certificate and the manual connection. Settings › Version on the phone
  ends in "· Debug" on a Debug build and has no suffix on an archive.
  Check once in Product › Scheme › Edit Scheme › Archive that Build
  Configuration is Release (it is in the shared scheme file).
- **Version and build** are managed in the repository, not by hand and
  not by Xcode: see [Versions](#versions). When distributing, **untick**
  "Manage Version and Build Number", or Xcode renumbers the upload and it no
  longer matches its tag.
- **Archiving.** Choose "Any iOS Device (arm64)" as the destination
  (Archive is greyed out for a simulator), Product › Archive, then in the
  Organizer: Distribute App › App Store Connect › Upload. Xcode signs with
  the distribution certificate and validates the build before uploading.
- **Trying a release build on your own phone before uploading:** install
  it through TestFlight, or temporarily set Edit Scheme › Run › Build
  Configuration to Release. A release build trusts only a pinned server,
  so it has to be enrolled by QR or code, not through the Debug-only
  manual connection.

## Versions

Every merge to main is a release candidate with its own numbers and a tag
(Matt, 2026-09-28):

- **Version** (`MARKETING_VERSION`, what the App Store shows): X.Y.Z. A
  merge raises Z unless the approval asks for a minor or major bump.
- **Build** (`CURRENT_PROJECT_VERSION`): one more on every merge. App Store
  Connect needs it to rise with every upload.
- **Where:** in the merge commit itself (`git merge --no-ff --no-commit`,
  `tools/bump-version.sh patch|minor|major`, commit), so the commit holds
  exactly the numbers it is tagged with. The app and the extension get the
  same values; the script refuses to run if they disagree.
- **Tag:** `vX.Y.Z` on that merge commit, annotated "Dialpark X.Y.Z
  (build N)", pushed with it. The server binaries take their version from
  the same tags (`git describe --tags --match 'v[0-9]*'` in the Makefile).
- **Upload only tagged commits of main.** A build from a feature branch
  carries main's numbers and would collide with the next real one.
- The first tagged release is the merge of `feature/app-store-readiness`:
  v1.0.0, build 1.

## Export compliance

What the app encrypts, and with what:

- **Apple's encryption:** the gateway connection (Network.framework TLS) and
  every HTTPS call (URLSession).
- **Its own, bundled OpenSSL:** the SIP connection (TLS) and call audio
  (SRTP, AES). Standard, published algorithms, used for confidentiality.

So in App Store Connect's questions: the app **uses encryption**, and the type
is **"standard encryption algorithms instead of, or in addition to, using or
accessing the encryption within Apple's operating system"**. It is not
proprietary encryption, and it is not exempt (it is not only authentication,
and not only Apple's).

What that asks of us:

- **France.** App Store Connect asks whether the app will be available in
  France; for this category that needs a French encryption declaration
  (ANSSI) uploaded to App Store Connect. The alternative is to leave France
  out of the territories until one exists.
- **United States.** Standard encryption in a consumer-available app is
  treated as mass-market (category 5D992.c). Whether a BIS year-end
  self-classification report is needed has changed with the regulations
  (the 2021 rule removed it for many mass-market products); confirm against
  Apple's "Complying with encryption export regulations" page, or with an
  export adviser, before the first submission. This is not legal advice.
- **Info.plist: no key, for now.** `ITSAppUsesNonExemptEncryption` = YES is
  valid only together with `ITSEncryptionExportComplianceCode`, the key App
  Store Connect issues once it approves export documentation; with YES and
  no code, upload validation fails ("Invalid Export Compliance Code", the
  v1.0.1 upload, 2026-09-29). The app has no documentation, so the key stays
  out and App Store Connect asks the encryption questions for each build
  (TestFlight: "Missing Compliance" › Manage): uses encryption, yes; standard
  algorithms in addition to Apple's; France as decided for the territories
  (no: no documentation needed). If documentation is ever filed and
  approved (the French declaration), add YES and the issued code together.
  Matt ran App Store Connect's encryption questionnaire for the app on
  2026-09-29 (standard encryption, not France): no documentation to upload,
  so no key; the per-build answers stay.

## Tests before submitting

- **IPv6-only network (NAT64).** macOS Internet Sharing's NAT64 test network
  with a phone on it: enrolment, registration and a call. Required before
  submission for option A. For option B it does not block review, but real
  customers deserve it before long.
- **An Archive build from the current release Xcode** (not a beta), uploaded
  and installed through **TestFlight**: on a fresh install, the Local
  Network prompt before the first enrolment and no failed attempt;
  enrolment by QR and by code,
  incoming and outgoing calls, background calls on office Wi-Fi, sign out,
  and the demo mode end to end if there is one.

## Order

1. Settle decisions 2 and 3; for demo mode, ask App Review.
2. Must-fixes 1–6 and 8 (and 7) on `feature/app-store-readiness`,
   typechecked and screenshotted; 8 confirmed on a freshly installed phone.
3. The IPv6 test (and fix, for option A).
4. Option A only: the demo server and review codes.
5. TestFlight.
6. Metadata, screenshots, privacy label, export compliance, review notes.
7. Submit.
