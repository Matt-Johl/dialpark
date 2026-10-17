.PHONY: all test go-test swift-test vet fmt server run harness-up harness-down harness-test tone

all: test

test: go-test swift-test

go-test:
	cd server && go vet ./... && go test ./...

swift-test:
	cd ios/DiallerProtocol && swift test

vet:
	cd server && go vet ./...

fmt:
	cd server && gofmt -l -w .

server:
	cd server && go build -ldflags "-X main.version=$$(git describe --tags --match 'v[0-9]*' --always --dirty 2>/dev/null || echo dev)" -o ../bin/dialpark-server ./cmd/dialpark-server

# Dev run: self-signed TLS, data in ./data, admin token printed in the log.
run: server
	@test -f data/install.id || { mkdir -p data && cp harness/dialpark/install.id data/install.id; }
	./bin/dialpark-server -data-dir ./data -admin-token dev

# dialpark-admin, the operator's web UI (SPEC §6 item 9c): a second binary
# that talks only to the call server's admin API on 8081.
admin:
	cd server && go build -ldflags "-X main.version=$$(git describe --tags --match 'v[0-9]*' --always --dirty 2>/dev/null || echo dev)" -o ../bin/dialpark-admin ./cmd/dialpark-admin

# The vendor's licence tool (SPEC §4.9): keygen once, issue per customer,
# inspect a token. Runs offline; the private key never enters the repo.
licence-tool:
	cd server && go build -o ../bin/dialpark-licence ./cmd/dialpark-licence

# Dev run beside `make dev-server` (token "harness") or `make run` (token
# "dev": ADMIN_TOKEN=dev make dev-admin). Sign in as "admin"; the password lives in
# data/admin/password, created as "dialpark" on first run; the UI serves
# https://127.0.0.1:8443 on a self-signed certificate kept in data/admin.
ADMIN_TOKEN ?= harness
dev-admin: admin
	@mkdir -p data/admin
	@test -f data/admin/password || { printf 'dialpark\n' > data/admin/password; echo "created data/admin/password (password: dialpark)"; }
	@grep -q '^pbkdf2' data/admin/password && { echo "data/admin/password is a hash from the old UI; dialpark-admin reads the plain password. Replace it: printf 'dialpark\\n' > data/admin/password"; exit 1; } || true
	./bin/dialpark-admin -listen 127.0.0.1:8443 -server https://127.0.0.1:8081 -admin-token $(ADMIN_TOKEN) -insecure \
	  -password-file data/admin/password -data-dir data/admin

tone:
	python3 harness/baresip/media/gen_tone.py

# The address the server advertises to phones for SIP and media. Defaults to
# this Mac's en0 address so real devices work; inside-docker-only tests are
# fine with it too because the media ports are published on the host.
export DIALPARK_PUBLIC_HOST ?= $(shell ipconfig getifaddr en0 2>/dev/null || ifconfig en0 2>/dev/null | awk '/inet /{print $$2; exit}' || echo dialpark)

harness-up: tone
	@echo "advertising public host $(DIALPARK_PUBLIC_HOST)"
	docker compose -f harness/docker-compose.yml up --build -d dialpark asterisk
	sleep 2 && sh harness/innet.sh dialpark-harness_default harness/provision.sh

harness-test:
	docker compose -f harness/docker-compose.yml --profile test run --rm --build sipp

harness-down:
	docker compose -f harness/docker-compose.yml --profile test down -v

# The product licence (SPEC §4.9): install, refuse, shrink, suspend,
# restore, against the real server and the headless app.
harness-licence:
	sh harness/licence_test.sh

# Headless app↔app call through the real server (registrar + wake path +
# diago bridge), asserted on the callee's recorded audio.
harness-call:
	sh harness/call_test.sh

# Callee registered, then its connection dies: the server must not dial the
# stale route but fall back to the wake path.
harness-flow-gone:
	sh harness/flow_gone_test.sh

# A bridged call whose party vanishes must end itself: the callee is
# SIGKILLed mid-call while the caller talks on, and the server must notice
# that it has stopped answering (b2bua qualifyLegs). Also asserts the case
# that must NOT end: both parties answering.
harness-peer-gone:
	sh harness/peer_gone_test.sh

# NAT regression (macOS host, not sandboxable): the real engine on this Mac
# registers through Docker's port forwarding — a genuine NAT — and must be
# reached over its own TLS connection with symmetric RTP.
#   make probe-call                                 # PASS
#   DIALPARK_REWRITE_CONTACT=false make probe-call   # must FAIL (the bug this guards)
probe-call:
	sh harness/probe_call.sh

# Wake path: callee starts unregistered, a fake app on the gateway receives
# the wake and registers the phone, then the bridge completes.
harness-wake:
	sh harness/wake_test.sh

# PBX leg: the server as Asterisk's SIP trunk peer, both directions, asserted
# on recorded audio (app → desk phone, desk phone → app), plus a transfer of
# the desk phone to a PBX extension that the server must hand to Asterisk
# and drop out of (DIRECTION=out|in|transfer for one of them).
harness-trunk:
	sh harness/trunk_test.sh

# Hold music (SPEC §4.4 rule 8b): the app-leg caller holds a trunk call and
# the desk phone must hear the server's music, not silence. The caller plays
# silence throughout, so anything the desk phone records is the music.
harness-hold-music:
	sh harness/hold_music_test.sh

# The PBX's own phone holds and resumes (nothing signalled to us): the app
# must keep hearing it. The LAN phone's resume sent the RTP timeline 31 s
# backwards on one SSRC and silenced the app (SPEC §9 item 11); the relay
# now re-bases a timeline that parts from the packets' arrival.
harness-pbx-hold:
	sh harness/pbx_hold_test.sh

# The same on an SRTP trunk: the clips the server writes into a trunk leg
# and the relay that carries on after them, where libsrtp's replay window
# punishes a sequence-number jump that plain RTP forgives.
harness-hold-music-srtp:
	TRUNK_SRTP=sdes sh harness/hold_music_test.sh

# A PBX extension with no registration must be refused by the PBX (480),
# not rung: the dialplan's dial-status context turns Dial()'s outcome into a
# SIP status. Publishes no host ports, so it is safe beside `make dev-server`.
harness-pbx-unavailable:
	sh harness/pbx_unavailable_test.sh

# A caller hanging up while the callee still rings must leave the callee's
# registration (and the TLS connection it lives on) intact: the next call
# rings it directly, never via the wake path. Publishes no host ports.
harness-cancel-before-answer:
	sh harness/cancel_before_answer_test.sh

# A delayed-offer INVITE from the PBX (SPEC §6 item 3c): no SDP in the
# INVITE, our 200 OK makes the offer, the ACK answers it. CUCM sends these
# to every third-party SIP line and Asterisk never does, so SIPp plays the
# PBX at the trunk listener and echoes the media back to the app. Publishes
# no host ports.
harness-delayed-offer:
	sh harness/delayed_offer_test.sh

# A trunk TCP/TLS connection gone silently dead (a network blip on either
# side): the per-call watchdog must drop it and redial within seconds, not
# sit on it until Timer B, and the OPTIONS qualify must drop it before any
# call is placed so the next one rings at once. Black-holes the server's
# packets to the PBX with a tc filter. Publishes no host ports.
harness-trunk-stall:
	sh harness/trunk_stall_test.sh

# Trunk-leg SRTP (SPEC §6 near-term item 3a): the PBX is built with a secure
# trunk profile and the server told to use it; both trunk directions must
# come up encrypted.
harness-trunk-srtp:
	TRUNK_SRTP=sdes sh harness/trunk_test.sh

# Trunk-leg TLS (SPEC §6 near-term item 3b): the whole trunk runs SIP over
# TLS, each side authenticating the other against a private CA — the PBX is
# configured the way a CUCM secure SIP trunk is, so it will not even qualify
# the server without a valid client certificate.
harness-trunk-tls:
	TRUNK_TLS=1 sh harness/trunk_test.sh

# The pair as they belong together: encrypted signalling carrying the SDES
# keys that encrypt the media. SRTP without TLS is the configuration the
# server warns about at startup; this is the one it asks for.
harness-trunk-secure:
	TRUNK_TLS=1 TRUNK_SRTP=sdes sh harness/trunk_test.sh

# PBX lines (SPEC §6 item 3c): the server registers one third-party SIP
# line per device to the PBX instead of trunking to it — registration, a
# call in to a registered line, a call out that is challenged and must
# arrive as that line, and a wrong credential that must latch refused
# without disturbing anything else. Asterisk stands in for CUCM; what it
# cannot prove is §7.3 item 10.
harness-pbx-lines:
	sh harness/pbx_lines_test.sh

# The merge gate for anything that touches the PBX leg: every trunk-mode
# test, in the order they get cheaper to debug. Lines mode is an addition
# to this server, not a change to it, and this is what says so.
# The admin API cannot disturb a call (ADMIN-API.md §4.7): admin actions
# and a sustained flood against the admin listener while a call is
# bridged, with the audio gate as the judge. LOAD_SECONDS=10 for a quick
# look; the gate is 60.
harness-admin:
	sh harness/admin_test.sh

# dialpark-admin end to end: the real UI against the real server, driven
# with curl inside the compose network (SPEC §6 item 9c).
harness-admin-ui:
	sh harness/admin_ui_test.sh

harness-regression:
	@set -e; \
	echo "=== harness-test (SIPp conformance; needs the stack up, unlike the rest)"; \
	$(MAKE) harness-up >/dev/null 2>&1; \
	$(MAKE) harness-test || { $(MAKE) harness-down >/dev/null 2>&1; echo "REGRESSION FAILED: harness-test"; exit 1; }; \
	$(MAKE) harness-down >/dev/null 2>&1; \
	for t in harness-call harness-wake harness-qos \
	         harness-trunk harness-trunk-srtp harness-trunk-tls harness-trunk-secure \
	         harness-trunk-stall harness-pbx-hold harness-pbx-unavailable \
	         harness-hold-music harness-cancel-before-answer harness-delayed-offer \
	         harness-admin harness-admin-ui harness-licence; do \
	  echo "=== $$t"; $(MAKE) $$t || { echo "REGRESSION FAILED: $$t"; exit 1; }; \
	done; \
	echo "=== NARROWBAND=1 harness-trunk"; NARROWBAND=1 sh harness/trunk_test.sh || exit 1; \
	echo "=== DIRECTION=xfer-app harness-trunk"; DIRECTION=xfer-app sh harness/trunk_test.sh || exit 1; \
	echo "ALL TRUNK-MODE TESTS PASS"

# Regenerate the harness CA and the two trunk certificates. Run by the TLS
# trunk tests themselves; here for when they need replacing (FORCE=1) or a
# PBX outside compose needs the CA.
harness-tls-certs:
	FORCE=$(FORCE) sh harness/tls/gen_certs.sh

# Echo self-test and audio-quality gate (SPEC §7.2): the app hears its own
# audio back from the server ("echo", app leg only) or from the PBX ("600",
# through the trunk); the recording is correlated with the played tone for
# mouth-to-ear delay (≤150 ms / ≤200 ms) and gaps (none). IMPAIR=1 adds
# 2% loss + 30±10 ms jitter to what the server sends and judges concealment.
#   IMPAIR=1 make harness-echo      MAX_GAP_MS=… MAX_GAPS=… to relax a bound
# QoS gate (SPEC §4.4): a tcpdump sidecar asserts the server marks media
# DSCP EF and signalling CS3.
harness-qos:
	sh harness/qos_test.sh

harness-echo:
	sh harness/echo_test.sh
	TRUNK=1 sh harness/echo_test.sh

# Ring the iOS app (simulator or device, connected as dev-a) through the server.
harness-ring-sim:
	sh harness/ring_sim.sh

# Device testing without Docker's UDP proxy in the media path: the server
# runs natively on this Mac (media ports on en0), provisioned with the same
# fixed dev tokens; the docker caller registers to it over outbound NAT.
# The PBX for real SIP phones is a standalone Asterisk on an Ubuntu box on
# the LAN (harness/asterisk-native/README.md); pass its address as
# ASTERISK_HOST to trunk to it, or leave it unset for app-only testing.
#   make dev-server                          # terminal 1 (Ctrl-C to stop)
#   ASTERISK_HOST=10.18.0.50 make dev-server # trunked to the Ubuntu PBX
#   ASTERISK_HOST=10.18.0.50 PBX_MODE=lines make dev-server  # registered to it instead
#   make harness-ring-native                 # terminal 2: 212 (docker) dials the phone
ASTERISK_HOST ?=
# TRUNK_TLS=1 dials the PBX over SIP/TLS instead of UDP, using the LAN
# certificate set (harness/tls/lan, generated by harness/tls/gen_certs.sh
# with the real addresses — the default set is for the docker harness and
# its SANs are compose addresses). The PBX must have been installed with
# TRUNK_TLS=1 too; see harness/asterisk-native/README.md.
# TRUNK_SRTP=sdes adds SDES on the media, which is what TLS is protecting.
TRUNK_TLS ?= 0
TRUNK_SRTP ?=
LAN_TLS = harness/tls/lan
TRUNK_TLS_FLAGS = $(if $(filter 1,$(TRUNK_TLS)),-trunk "sip:$(ASTERISK_HOST):5061;transport=tls" -trunk-tls-cert $(LAN_TLS)/dialpark.pem -trunk-tls-key $(LAN_TLS)/dialpark.key -trunk-tls-ca $(LAN_TLS)/ca.pem,-trunk "sip:$(ASTERISK_HOST):5060;transport=udp")
# PBX_MODE=lines makes the server register a line per device to the PBX
# instead of trunking to it (SPEC §6 item 3c). The PBX must have been
# installed the same way (LINES=1 sh install-ubuntu.sh), and each device
# needs its credential, which provision.sh seeds for dev-a under PBX_LINES=1.
PBX_MODE ?= trunk
PBX_MODE_FLAGS = $(if $(filter lines,$(PBX_MODE)),-pbx-mode=lines -pbx-domain=$(ASTERISK_HOST),)
TRUNK_FLAGS = $(if $(ASTERISK_HOST),$(TRUNK_TLS_FLAGS) -trunk-addr :5062 -trunk-external-host $(DIALPARK_PUBLIC_HOST) $(if $(TRUNK_SRTP),-trunk-srtp $(TRUNK_SRTP),) $(PBX_MODE_FLAGS),)
dev-server: server tone
	@echo "native server on $(DIALPARK_PUBLIC_HOST); enrol the app with the dev-a code printed below (15 min), or the dev path: host $(DIALPARK_PUBLIC_HOST), port 7443, dev-a / tok_dev_a_harness_fixed (fresh data dir only — an enrolled dev-a keeps its own token)"
	@$(if $(filter lines,$(PBX_MODE)),$(if $(ASTERISK_HOST),true,{ echo "PBX_MODE=lines needs a PBX to register to: set ASTERISK_HOST=<ubuntu-ip>"; exit 1; }),true)
	@echo "pbx: $(if $(ASTERISK_HOST),$(if $(filter lines,$(PBX_MODE)),LINES — registering 201 to Asterisk at $(ASTERISK_HOST):5060; the PBX must have LINES=1 too,trunk to Asterisk at $(ASTERISK_HOST):$(if $(filter 1,$(TRUNK_TLS)),5061 over TLS,5060 over UDP))$(if $(TRUNK_SRTP), ; media SRTP $(TRUNK_SRTP),); listener :5062,none (set ASTERISK_HOST=<ubuntu-ip> for the PBX))"
	@$(if $(filter 1,$(TRUNK_TLS)),test -f $(LAN_TLS)/dialpark.pem || { echo "no $(LAN_TLS)/dialpark.pem — run: OUT=lan DIALPARK_IP=$(DIALPARK_PUBLIC_HOST) ASTERISK_IP=$(ASTERISK_HOST) sh harness/tls/gen_certs.sh"; exit 1; },true)
	( sleep 2 && DIALPARK_API=https://127.0.0.1:8081 PBX_LINES=$(if $(filter lines,$(PBX_MODE)),1,0) sh harness/provision.sh ) &
	@mkdir -p data/logs
	@test -f data/install.id || cp harness/dialpark/install.id data/install.id
	./bin/dialpark-server -data-dir ./data -admin-token harness -public-host $(DIALPARK_PUBLIC_HOST) -local-domain dialpark \
	  -http-addr 0.0.0.0:8080 -ring-timeout 30s -rtp-min 20000 -rtp-max 20100 $(TRUNK_FLAGS) $(DEV_SERVER_FLAGS) \
	  2>&1 | tee -a data/logs/dev-server.log
# The server log is also kept in data/logs/dev-server.log, and devices upload
# their own logs and crash reports to data/diag/<device>/ (ios/README.md).
# e.g. DEV_SERVER_FLAGS="-log-level debug" make dev-server   (shows sipgo's connection reference counting)

harness-ring-native:
	sh harness/ring_native.sh

# Same call through the standalone engine-spike B2BUA in ./spike.
spike-call:
	sh harness/spike/call_test.sh

# ---- iOS ---------------------------------------------------------------------
IOS_SDK = $(shell xcrun --sdk iphonesimulator --show-sdk-path)
IOS_TRIPLE = arm64-apple-ios17.0-simulator
IOS_SCRATCH = $${TMPDIR:-/tmp}/spm-build-ios
# SwiftPM and clang write module caches under ~/Library by default, which
# the build sandbox refuses — including for the *manifest* compile, so a
# package cannot even be read without this. Harmless outside the sandbox.
# (Surfaced 2026-09-16 when an Xcode update invalidated the existing caches.)
SWIFT_CACHE_ENV = SWIFTPM_MODULECACHE_OVERRIDE="$${TMPDIR:-/tmp}/spm-modcache" \
  CLANG_MODULE_CACHE_PATH="$${TMPDIR:-/tmp}/clang-modcache"
# Where SwiftPM leaves the built .swiftmodules. The layout moved with the
# Xcode that ships Swift 6.4 (flat `debug/`, plus an Xcode-style `out/`);
# earlier toolchains used `<triple>/debug/Modules`. swiftc ignores an -I
# that does not exist, so naming all three keeps `make ios-typecheck`
# working across a toolchain update instead of failing with "no such
# module" (2026-09-16).
IOS_MODULE_PATHS = -I "$(IOS_SCRATCH)/debug" \
  -I "$(IOS_SCRATCH)/out/Products/Debug-iphonesimulator" \
  -I "$(IOS_SCRATCH)/arm64-apple-ios-simulator/debug/Modules" \
  -I "$(IOS_SCRATCH)/arm64-apple-ios-simulator/debug/CBaresip.build" \
  $(IOS_CMODULE_MAPS)
# The C module (CBaresip) is reached through a module map, and the newer
# toolchain generates it as `<Module>.modulemap` rather than the
# `module.modulemap` that -I looks for — so point swiftc straight at each
# one. Empty on the older layout, where -I above is enough.
IOS_CMODULE_MAPS = $(foreach m,\
  $(wildcard $(TMPDIR)/spm-build-ios/out/Intermediates.noindex/GeneratedModuleMaps-iphonesimulator/CBaresip.modulemap),\
  -Xcc -fmodule-map-file=$(m))

# Package tests on macOS (no device).
# --disable-sandbox: SwiftPM wraps the build in its own sandbox-exec, which
# a restricted shell refuses outright ("sandbox_apply: Operation not
# permitted"); harmless in an unrestricted one.
ios-test:
	cd ios/DiallerProtocol && $(SWIFT_CACHE_ENV) swift test --disable-sandbox
	cd ios/DiallerCore && $(SWIFT_CACHE_ENV) swift test --disable-sandbox

# Compile the packages for the simulator and type-check the app + extension
# sources against the iOS SDK without Xcode's package resolution. Useful in
# restricted sandboxes; the real build is `xcodebuild -scheme Dialler`.
# `-disable-sandbox`: swiftc runs macro plugins (SwiftUI's @State etc.) in
# swift-plugin-server under its own sandbox-exec, and a nested sandbox is
# refused inside a restricted shell, which reads as "produced malformed
# response" on every macro use.
ios-typecheck:
	cd ios/DiallerEngine && $(SWIFT_CACHE_ENV) swift build --disable-sandbox --scratch-path "$(IOS_SCRATCH)" --triple $(IOS_TRIPLE) --sdk "$(IOS_SDK)" --target DiallerEngine 2>&1 | grep -vE 'Wincomplete-umbrella|Wvisibility' || true
	cd ios/Dialler && $(SWIFT_CACHE_ENV) swiftc -typecheck -Xfrontend -disable-sandbox -parse-as-library -swift-version 5 -target $(IOS_TRIPLE) -sdk "$(IOS_SDK)" -module-cache-path "$${TMPDIR:-/tmp}/swift-modcache" \
	  $(IOS_MODULE_PATHS) App/*.swift
	cd ios/Dialler && $(SWIFT_CACHE_ENV) swiftc -typecheck -Xfrontend -disable-sandbox -parse-as-library -swift-version 5 -target $(IOS_TRIPLE) -sdk "$(IOS_SDK)" -module-cache-path "$${TMPDIR:-/tmp}/swift-modcache" \
	  $(IOS_MODULE_PATHS) PushProvider/*.swift

# Cross-compile libre/baresip/Opus/OpenSSL for iOS device, simulator and macOS
# into ios/vendor/xcframeworks (required once before the app links
# DiallerEngine and before engine-probe; ~15 min).
ios-vendor:
	sh ios/vendor/build-baresip.sh all all

# Host-side unit test of the packet-loss concealment compiled into the
# app's (and the harness phone's) G.711 and G.722 modules.
# Symbolicate an iOS crash / CPU report (.ips) or a MetricKit diagnostic
# (JSON, as uploaded to data/diag/) against the build symbols the Xcode
# "Keep build symbols" phase saves in ios/dsyms/<UUID>/.
symbolicate:
	python3 tools/symbolicate.py "$(FILE)"

plc-test:
	cc -std=c99 -Wall -Wextra -O2 -o "$${TMPDIR:-/tmp}/plc_test" ios/vendor/patches/plc/plc.c ios/vendor/patches/plc/plc_test.c -lm && "$${TMPDIR:-/tmp}/plc_test"

# Does libre drop a dead UDP descriptor from its poll set instead of spinning
# on it (patch level 7; ios/vendor/patches/README.md)? Links the macOS slice
# of libre, so rebuild it first after a patch: `sh ios/vendor/build-baresip.sh re macos`.
re-udp-dead-probe:
	cc -std=c11 -Wall -O2 -o "$${TMPDIR:-/tmp}/re_udp_dead_probe" ios/vendor/patches/re/udp_dead_probe.c \
	  -Iios/vendor/prefix/macos/include/re -Lios/vendor/prefix/macos/lib -lre -lssl -lcrypto -lz -lresolv \
	  -framework SystemConfiguration -framework CoreFoundation && "$${TMPDIR:-/tmp}/re_udp_dead_probe"

# Headless run of the real baresip engine on this Mac against the docker
# server: registers 203 (dev-s, the simulator/probe identity), answers a call if one arrives. Needs the macOS slice
# (ios-vendor) and a server started with DIALPARK_PUBLIC_HOST=<mac-ip>.
#   make engine-probe HOST=$$(ipconfig getifaddr en0)
HOST ?= 127.0.0.1
engine-probe:
	cd ios/DiallerEngine && swift run --disable-sandbox engine-probe $(HOST) 203@dialpark 5061 40 dev-s tok_dev_s_harness_fixed

# Does the audiounit driver move audio under the CallKit contract (units
# start only on release, in every event ordering)? No SIP, no server.
# macOS uses the HAL output unit; the simulator run uses VoiceProcessingIO,
# the same unit as the device. Both must PASS after any driver or engine
# audio change.
audio-probe:
	cd ios/DiallerEngine && swift run --disable-sandbox audio-probe

# The app's call path end to end with no phone: real engine + driver on the
# iOS simulator, real server, phone-b plays a tone; asserted on RTP received
# and rendered audio energy. Needs `make harness-up` first.
#   make sim-call                    # activation ~150ms after answer (device order)
#   ACTIVATE_MS=1500 make sim-call   # activation after the call established
#   CALLS=3 ANSWER_MS=8000 make sim-call   # several calls in one process, long rings
#   OUTBOUND=212 make sim-call       # the simulated phone dials (keypad / directory path)
#   OUTBOUND=echo make sim-call      # full mic→server→speaker loop (server echo)
#   HOLD_MS=3000 make sim-call       # hold/resume mid-call, asserts media stops and restarts
#   TRANSFER=echo make sim-call      # blind transfer of the caller to echo (REFER handled server-side)
#   DECLINE=1 make sim-call          # reject from the banner; asserts phone-b is told 486 Busy Here, not 480
#   RESTART_SERVER=1 make sim-call   # server restarts under the app: it must reconnect, re-register, take the call
#   GATEWAY=no make sim-call         # no wake ever arrives; rings from the INVITE
#   SERVER=native make sim-call      # against `make dev-server` on this Mac
sim-call:
	sh harness/sim_call.sh

# Call waiting (plan Phase I): a second caller while on a call, Hold &
# Accept, swap back, end both.
sim-call-cw:
	CALLWAITING=1 sh harness/sim_call.sh

# An outgoing call the server refuses (plan Phase J): the caller must hear
# the congestion tone and the call must not disappear until it has run.
sim-call-refused:
	OUTBOUND=999 REFUSED=1 sh harness/sim_call.sh

# Decline and reset the SIP transports in the same breath, with the
# server's packets delayed so the 486's ACK lands on the torn-down
# connection: the libre flush hazard (ios/vendor/patches/README.md). Passes
# only if the process survives to report.
sim-call-decline-reset:
	IMPAIR=1 DECLINE_RESET=1 sh harness/sim_call.sh

# The registration reset issued while a call rings (the app's "session came
# back" path racing the INVITE, 2026-09-18 15:12): the stack must refuse it
# and the call must be answered as usual.
sim-call-ring-reset:
	RING_RESET=1 sh harness/sim_call.sh

# The incoming, outbound, decline, ring-reset, refused, reconnect and
# call-waiting runs every call-path change must pass.
sim-call-all:
	OUTBOUND=212 sh harness/sim_call.sh
	CALLS=2 sh harness/sim_call.sh
	DECLINE=1 sh harness/sim_call.sh
	RING_RESET=1 sh harness/sim_call.sh
	OUTBOUND=999 REFUSED=1 sh harness/sim_call.sh
	RESTART_SERVER=1 sh harness/sim_call.sh
	CALLWAITING=1 sh harness/sim_call.sh

SIM ?= iPhone 16
audio-probe-sim:
	cd ios/DiallerEngine && $(SWIFT_CACHE_ENV) swift build --disable-sandbox --scratch-path "$(IOS_SCRATCH)" --triple $(IOS_TRIPLE) --sdk "$(IOS_SDK)" --product audio-probe 2>&1 | grep -vE 'Wincomplete-umbrella|Wvisibility' || true
	xcrun simctl boot "$(SIM)" 2>/dev/null || true
	xcrun simctl spawn "$(SIM)" "$(IOS_SCRATCH)/arm64-apple-ios-simulator/debug/audio-probe"

# Build for the simulator with Xcode (needs an unrestricted shell).
ios-build:
	cd ios/Dialler && xcodebuild -project Dialler.xcodeproj -scheme Dialler -configuration Debug \
	  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
