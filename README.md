# Dialpark

Dialpark is an on-prem call server that is its own exchange and wakes phones
without APNS. Dialler is the iOS SIP softphone that enrols to a Dialpark
server: the app keeps the Dialler name; the system and its servers are
Dialpark. [SPEC.md](SPEC.md) is the source of truth for architecture and
phases; this file is the map of the repo.

| Path | What | Status |
|---|---|---|
| [`protocol/`](protocol/) | Frozen v1 wire protocol ([PROTOCOL.md](protocol/PROTOCOL.md)) and golden fixtures shared by Go and Swift | Phase 0 ✔ |
| [`server/`](server/) | Go light server: signal gateway, enrolment, registry, routing, directory API, and the **sipgo + diago** app-leg SIP element (registrar, wake-then-bridge call controller, media proxied through the server) | Phase 1 server half ✔ |
| [`ios/DiallerProtocol/`](ios/DiallerProtocol/) | Swift package: envelope, bodies, framing, shared golden fixtures with Go | Phase 0 ✔ |
| [`ios/DiallerCore/`](ios/DiallerCore/) | Swift package: TLS signal transport, session machine, call controller, config store, directory client, all behind fakes | Phase 1 ✔ (12 tests) |
| [`ios/Dialler/`](ios/Dialler/) | Xcode project: SwiftUI app + CallKit + PushKit, and the `NEAppPushProvider` extension | rings on device, Local Push saves |
| [`ios/DiallerEngine/`](ios/DiallerEngine/) | baresip-backed `CallEngine` over XCFrameworks built by [`ios/vendor/build-baresip.sh`](ios/vendor/build-baresip.sh) | builds for device + simulator; first real call pending |
| [`website/`](website/) | Product site: `index.html` and `privacy.html` (the app's privacy policy), sharing `style.css` and `site.js`; the app's Hairline palette, light and dark; static, no build step | draft |
| [`harness/`](harness/) | Docker: Asterisk peer, SIPp conformance, headless baresip phones, end-to-end call test | passing |
| [`spike/`](spike/) | Standalone diago B2BUA from the Phase 0 engine spike | superseded by `server/internal/b2bua`; delete once the repo is committed |

## Run the tests

```sh
make test          # Go (vet + test) and Swift
make go-test
make swift-test    # or swift-test-sandboxed inside a restricted build sandbox
```

Every Go test except the UDP relay runs socket-free (in-memory pipes and
`ServeHTTP`), so the suite passes inside sandboxes that forbid binding. The
relay tests skip with an explicit message when UDP bind is forbidden; run
them on a normal machine to exercise real forwarding.

## Run the server locally

```sh
make run           # self-signed TLS on :7443 (signal), :5061 (SIP), 127.0.0.1:8080 (device API) and 127.0.0.1:8081 (admin API)
```

Enrol a device, give it a contact, and fetch its directory (`-k`: the dev
certificate is self-signed). The token doubles as the SIP Digest password on
the app leg, with the device id as the username. Directories are **per
device** (SPEC §6 item 7): the admin writes `/v1/admin/devices/<id>/directory`
(`PUT` with `{"contacts":[…]}` replaces the whole list, as a CSV upload
does), and the device reads and writes its own at `/v1/directory`:

```sh
curl -sk -H 'Authorization: Bearer dev' -H 'Content-Type: application/json' \
     -d '{"device_id":"dev-a","user":"201"}' https://127.0.0.1:8081/v1/admin/devices
curl -sk -H 'Authorization: Bearer dev' -H 'Content-Type: application/json' \
     -d '{"display_name":"Desk","uri":"sip:100@asterisk","mode":"trunk"}' https://127.0.0.1:8081/v1/admin/devices/dev-a/directory
curl -sk -H 'X-Device-ID: dev-a' -H "Authorization: Bearer $TOKEN" 'https://127.0.0.1:8080/v1/directory?since=0'
```

A server that still has the old global `data/directory.json` folds it into
every enrolled device's directory at start-up, once, and renames it
`directory.json.migrated`.

Adding a device also mints its **enrolment code** (SPEC §4.8): eight
characters, fifteen minutes, single use, returned with a `dialler://enrol`
link the admin UI shows as a QR. Leave `token` out (as a real deployment
does) and the device has no credential until it claims the code; a
`token` (the harness's fixed fixtures) issues that credential at once as
well. `POST /v1/admin/devices/<id>/enrol-code` mints a new one for an
existing device — a lost phone, or a revoked device coming back. The phone
claims with the server's one unauthenticated write, which rotates the
credential and drops whatever was connected with the old one:

```sh
curl -sk -H 'Content-Type: application/json' -d '{"code":"A7K2-M9PX"}' https://<host>:8080/v1/enrol
# → {"device_id","user","token","signal_port","sip_domain","cert_sha256"}
```

A miss answers 404 after half a second, and a source address gets five
attempts a minute. `cert_sha256` (also in the link) is what the app pins.

A device's office Wi-Fi list is server-managed too (SPEC §6 item 8b):

```sh
curl -sk -H 'Authorization: Bearer dev' -H 'Content-Type: application/json' -X PUT \
     -d '{"ssids":["Office","Office-5G"]}' https://127.0.0.1:8081/v1/admin/devices/dev-a/config
```

The app receives it in its welcome and as a `config` push on every change,
and applies it to Local Push itself. Until an administrator has set a list
the phone keeps whatever it has.

### The SIP domain

Users are SIP addresses like `sip:201@dialpark`; the part after the `@` is
the **SIP domain**, set with `-local-domain` (`dialpark` in `make dev-server`
and in the docker harness; unset, it defaults to the server's own address).
It plays the role a domain plays in an email address, naming who owns those
identities, and need not be a DNS name. The server uses it for:

- **ownership** — a REGISTER for a user in any other domain is refused, and
  an address in a foreign domain routes to the PBX rather than to an app;
- **what apps are told** — the welcome carries each account as user plus
  domain, and the app builds its address from it;
- **the Digest realm** — app-leg authentication (SPEC §4.4 rule 2) uses the
  domain as the realm, and the server stores each device credential only
  as the MD5 of device id, realm and token.

Because the realm is baked into the stored credential, **renaming the domain
invalidates every enrolled device** until its credential is re-issued. In
development this is invisible (`harness/provision.sh` re-issues the fixed
dev credentials on every start); in production keep the domain fixed, or
re-enrol devices after a rename. There is no reason to change it.

### Reaching a PBX: trunk or registered lines

`-trunk` names the PBX. `-pbx-mode` says how this server presents itself to
it, and the choice is made once, per deployment:

| `-pbx-mode` | what the exchange sees |
|---|---|
| `trunk` (default) | one SIP peer, trusted by address. Nothing is registered; every call rides a trunk the exchange identifies by our IP. |
| `lines` | one **third-party SIP device per device** — a directory number, a digest credential and a registration this server holds around the clock (SPEC §6 item 3c). |

Lines mode exists because a trunk cannot make an app user a thing the
exchange knows about: no per-user class of service, call forwarding,
voicemail, hunt-group membership, CDR by user or corporate-directory entry,
and identity by source address — which is also why most CUCM teams decline
to route an internal number range to an unauthenticated peer.

**The server registers; the app never does, and never holds a PBX
credential.** A phone holding one would be the registered endpoint, and the
exchange would send its INVITE to a contact that stops existing the moment
iOS suspends the app — which is the problem this product exists to solve.
The app leg is identical in both modes.

**Never both at once.** An exchange matches inbound SIP against its trunk
devices by source address and port, so a trunk pointing at this server would
swallow the calls its registered lines place. `-pbx-mode=lines` with no
`-trunk` is refused at start-up.

Provisioning a line is one admin call per device; the secret is write-only
and no read returns it:

```sh
curl -sSk -X POST https://127.0.0.1:8081/v1/admin/devices/dev-a/pbx-line \
  -H 'Authorization: Bearer <admin token>' \
  -d '{"digest_user":"<the exchange End User>","secret":"<its digest credential>"}'
# → {"dn":"","digest_user":"…","configured":true}   ("" dn = the device's own extension)
```

It is stored sealed under `<data-dir>/pbx.key` (see `internal/secrets` for
what that does and does not protect). Other flags: `-pbx-registrar` if
REGISTERs go somewhere other than the trunk peer, `-pbx-domain` for the host
part of each line's address of record, `-pbx-peers` for the other nodes of a
cluster (a call from an unnamed node is challenged like an app's and fails),
`-pbx-default-line` and `-pbx-register-expiry`. Each line is refreshed at
three quarters of the lifetime the exchange granted, against the time of
day: a server that sleeps (a laptop lid, a suspended VM) re-registers every
overdue line within ten seconds of waking, and logs a lease that had already
run out while it slept.

`make harness-pbx-lines` runs the bench: registration, a call each way, and
a wrong credential that must latch refused. `make harness-pbx-outage` cuts
the link to the PBX and back: a line re-registers at once when the exchange
is heard from, and within the 30 s retry cap otherwise. Asterisk stands in for CUCM —
what it can and cannot prove is in SPEC §6 item 3c, and the CUCM-only
checklist is §7.3 item 10.

Two things a CUCM does to a registered line that Asterisk does not, both
handled since 2026-10-17: its INVITE carries no SDP (a *delayed offer* —
the server's 200 OK offers the app's codec first and the rest of
`-trunk-codecs` behind it, the ACK answers, and if the exchange picked
another codec the app is moved onto it by re-INVITE before the bridge;
`make harness-delayed-offer`, with SIPp as the PBX), and it sends the
line an unsolicited message-waiting NOTIFY on every registration, which is
answered 200 and logged (`pbx: message waiting`; the lines bench asserts
it). Nothing shows the mailbox state on the phone yet.

DTMF crosses the server as RFC 4733 telephone-event packets: both legs
offer `telephone-event/8000`, and the relay forwards each event under the
far leg's event payload type rather than as audio. `make harness-dtmf`
proves digits both ways against Asterisk (`LINES=1` for lines mode).

### The licence

The server enforces a product licence (SPEC §4.9): a number of app devices
until a date, signed by the vendor and bound to one installation. With no
licence installed it has no seats, so no device can enrol or connect.

- At its first start the server mints an **install id** and keeps it at
  `<data-dir>/install.id`. The admin UI's Licence page shows it; give it to
  the vendor, who issues a licence for that id and no other.
- Paste the licence on the Licence page (or `PUT /v1/admin/licence`,
  ADMIN-API §5.13). It takes effect at once. Enrolling a device takes a
  seat; revoking it frees one; a code claimed when none is free is refused
  with "no free licence seats" and stays claimable.
- A smaller or expired licence suspends the newest holders beyond the
  count, everywhere at once: gateway, SIP, device routes, PBX line. A call
  in progress runs to its end. The clients list marks them "No seat".
- Expiry is a hard stop. The log and the admin UI warn from 30 days out;
  the app shows a banner in its last week. Renewal is pasting the new
  licence; devices resume at once.
- Back up `install.id` with the rest of the data directory: without it the
  licence stops matching.

Dev and the harness use a licence issued for a fixed install id that
`make dev-server` seeds into `./data` and the harness bakes into its image;
`harness/provision.sh` installs it first.

#### Issuing a licence (vendor only)

`make licence-tool` builds `bin/dialpark-licence`. The private key is made
once, kept offline, and never enters the repo (`.gitignore` covers
`vendor.key`); a second key pair would strand every licence issued under
the first.

```sh
# once: writes vendor.key and vendor.pub into DIR and prints the public-key
# literals to paste into server/internal/licence/vendorkey.go and
# ios/DiallerCore/Sources/DiallerCore/Licence.swift
bin/dialpark-licence keygen -out DIR

# per customer: the install id is read off their admin Licence page;
# -valid-until is the last day of validity (expires at the start of the
# next day, UTC); prints the DP1… token to paste on that page
bin/dialpark-licence issue -key DIR/vendor.key -customer "Acme Ltd" \
    -install-id 0123456789abcdef0123456789abcdef -seats 25 -valid-until 2027-12-31

# check any token against the compiled-in key (or -pub DIR/vendor.pub)
bin/dialpark-licence inspect DP1.…
```

`issue` also takes `-id` to choose the licence id (default `lic_` plus
eight random characters). A renewal is a new `issue` for the same install
id, pasted over the old one.

## The admin UI: dialpark-admin

`dialpark-admin` is the operator's web UI (SPEC §6 item 9c), a second
binary that talks only to the call server's admin API on 8081 and to
nothing else. It holds the admin token and one operator password, serves
HTTPS on its own certificate, and keeps no state the API cannot re-read,
so it can be restarted or redeployed with no effect on a call.

```sh
make dev-admin            # beside `make dev-server`; sign in as admin, password "dialpark" (data/admin/password)
open https://127.0.0.1:8443
```

Pages: **Clients** (every device with its live state, and where a device is
added and shown its enrolment code and QR), **Licence** (what is installed,
the install id for the vendor, the paste box), **Device** (description,
enrolment, Wi-Fi networks, PBX line, the directory with inline edit, CSV
download and upload with a preview, copy to other devices, diagnostics,
purge), **Calls** (what is bridged right now) and **Server** (identity,
certificate expiry, trunk and lines, logging, recent events).

Production flags: `-listen`, `-server https://127.0.0.1:8081`,
`-admin-token-file` (the same file `dialpark-server` was started with),
`-server-ca` (the call server's certificate; `-insecure` only against the
self-signed dev one), `-password-file`, `-tls-cert`/`-tls-key` (self-signed
and kept in `-data-dir` when absent). Every form carries the version it
was loaded with; an edit that lands on something changed since is refused
with a message rather than overwriting it. When the call server is not
answering, every page says so and disables every write.

The QR is drawn by `internal/qr`, an in-tree encoder (byte mode, level M,
versions 1–10) whose output was checked against an independent decoder;
there is nothing to download and the binary stays standard library only.

## Server packages

```
cmd/dialpark-server     wiring + flags
internal/wire          protocol envelope, bodies, framing        (golden tests)
internal/gateway       TLS signal gateway: hello/welcome, wake fan-out, replay, supersede, idle
internal/enroll        device credentials, enrolment codes + the claim route, admin API, device-auth middleware
internal/registry      user ↔ device ↔ SIP contact location table (+ WaitRegistered for the wake path)
internal/routing       local | trunk | unknown decision
internal/b2bua         app-leg SIP element on sipgo + diago: TLS registrar, wake-then-bridge, media proxy
internal/directory     one address book per device (data/directories/<id>.json) with delta sync, favourites, replace-all + REST (device and admin)
internal/pbx           PBXAdapter seam (None only so far)
internal/pbxline       one registration per device on a PBX that expects third-party SIP devices (-pbx-mode=lines)
internal/secrets       seals the few credentials this server must replay rather than merely verify
internal/tlsutil       cert loading / self-signed dev cert
internal/sip           hand-written SIP parser/registrar — fallback and reference, not on the call path
internal/relay         hand-written UDP relay — fallback and reference; diago's bridge proxies media
```

Dependencies are vendored (`server/vendor`), so builds and tests are offline.

## Headless call test

```sh
make harness-call      # 201 dials 202 through dialpark-server; asserts the callee's recorded audio
make harness-wake      # callee asleep: gateway wake → fake app registers it → bridge → audio
make harness-up        # server + Asterisk, provisioned
make harness-test      # SIPp: TLS register, offline → 480, unknown → 404, unregister, plain TCP refused
make harness-pbx-lines # the server registers lines to the PBX instead of trunking to it
make harness-regression # every trunk-mode test: the gate for anything touching the PBX leg
```

`cmd/fake-app` is the headless stand-in for the app's background wake path:
it holds a wire-protocol connection as an enrolled device, acks the wake, and
brings the SIP user agent up (here, a baresip via `ctrl_tcp`).

## iOS

See [ios/README.md](ios/README.md). `make ios-test`, `make ios-typecheck`,
then open `ios/Dialler/Dialler.xcodeproj` and run on an iPhone simulator
against `make harness-up`; `make harness-ring-sim` rings it.

## Next

The roadmap lives in [SPEC.md §6](SPEC.md) ("Remaining near-term"). Items 6–9
(added 2026-09-21) are the next tranche, in build order: a Recents tab,
per-device directories with favourites, search and in-app editing, first-run
enrolment by QR or code with the Status tab hidden behind a gesture, and a
separate `dialpark-admin` web UI (`cmd/dialpark-admin`, `internal/qr`) that
manages devices and directories (CSV up/down) through the admin API. The
mechanism and the isolation rule are in SPEC §4.8: nothing the admin does
interrupts the call server or any device other than the one named.
