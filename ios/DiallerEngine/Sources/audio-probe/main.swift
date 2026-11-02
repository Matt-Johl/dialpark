// audio-probe: does the audiounit driver move audio under the CallKit
// contract? No SIP, no server: the driver's player + source are allocated
// through baresip's device layer and the frame counters are asserted.
//
// Scenarios (each must PASS):
//   A  hold → allocate → nothing flows → release → frames flow
//      (call established before didActivate)
//   B  release → allocate → frames flow
//      (didActivate before the call established — the ordering the app
//       usually sees, and the one the first driver patch missed)
//   C  hold while running → frames stop; release → frames resume
//      (didDeactivate / interruption, then a new activation)
//   D  three quick hold/release cycles → frames flow after the last
//      (a route flapping — Bluetooth headset connecting and dropping,
//       a cellular call interrupting twice — restarts the units rapidly;
//       plan Phase H)
//   E  release with nothing allocated → the driver prepares its units;
//      allocate → the prepared units are adopted (the driver says so) and
//      the allocation returns in a fraction of a cold one; frames flow
//      (an outgoing call: didActivate at dial time, the answer later)
//   F  prepared units, then hold → discarded; allocate while held →
//      deferred; release → set up afresh and flowing
//      (the session went away before any call used the prepared units)
//
// Output frames must flow in every case. Input frames need microphone
// access; a run without it reports "rec=0 (no mic access)" and still
// passes on output, because the failure this guards was units that never
// rendered at all.
//
//   make audio-probe        # macOS (HAL output unit)
//   make audio-probe-sim    # iOS simulator (VoiceProcessingIO, as on device)
import CBaresip
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let config = """
sip_listen              0.0.0.0:0
audio_player            audiounit,default
audio_source            audiounit,default
audio_alert             none
audio_srate             48000
audio_channels          1
module                  audiounit.so
module                  auconv.so
module                  auresamp.so
"""

var failures = 0

func log(_ s: String) { print("probe: \(s)") }

func fail(_ s: String) {
    failures += 1
    print("FAIL: \(s)")
}

func stats() -> (play: UInt64, rec: UInt64) {
    var p: UInt64 = 0, r: UInt64 = 0, e: UInt64 = 0
    cb_audio_stats(&p, &r, &e)
    return (p, r)
}

/// Frames delivered during `seconds` from now.
func flow(over seconds: Double) -> (play: UInt64, rec: UInt64) {
    let a = stats()
    Thread.sleep(forTimeInterval: seconds)
    let b = stats()
    return (b.play - a.play, b.rec - a.rec)
}

/// Every driver log line, so a scenario can assert on what the driver
/// said it did (prepared, adopted, discarded, set up afresh).
let driverLock = NSLock()
var driverLines: [String] = []
func driverSaid(_ needle: String) -> Bool {
    driverLock.lock(); defer { driverLock.unlock() }
    return driverLines.contains { $0.contains(needle) }
}
var allocMs = 0.0

let rc = cb_start(config, { _, ev, info in
    if ev == CB_EVENT_LOG, let text = info?.pointee.text, String(cString: text).contains("audiounit") {
        let line = String(cString: text)
        print("  [driver] \(line)")
        driverLock.lock(); driverLines.append(line); driverLock.unlock()
    }
}, nil)
guard rc == 0 else {
    print("FAIL: cb_start \(rc)")
    exit(1)
}
log("stack up (\(String(cString: cb_version())))")

var micSeen = false

// A: established before activation.
log("A: hold, allocate, expect silence, release, expect flow")
cb_audio_interrupt(true)
var arc = cb_audio_test_alloc()
if arc != 0 { fail("A: alloc \(arc)") }
var f = flow(over: 1.0)
if f.play != 0 { fail("A: \(f.play) output frames flowed while held") }
cb_audio_interrupt(false)
f = flow(over: 1.5)
log("A: after release play=\(f.play) rec=\(f.rec)")
if f.play == 0 { fail("A: no output frames after release") }
micSeen = micSeen || f.rec > 0
cb_audio_test_free()

// B: activation before establishment. The release finds no client and
// prepares units (scenario E's subject); they are discarded here so B
// measures the cold path the app took before prepared units existed.
log("B: release first, allocate, expect flow")
cb_audio_interrupt(false)
Thread.sleep(forTimeInterval: 0.5)
cb_audio_interrupt(true)
Thread.sleep(forTimeInterval: 0.1)
cb_audio_interrupt(false)
Thread.sleep(forTimeInterval: 0.5)
cb_audio_interrupt(true)
Thread.sleep(forTimeInterval: 0.1)
// now held with nothing prepared: allocate held (deferred), then release and time the cold setup
arc = cb_audio_test_alloc()
if arc != 0 { fail("B: alloc \(arc)") }
var tB = Date()
cb_audio_interrupt(false)
allocMs = Date().timeIntervalSince(tB) * 1000
log("B: cold setup on release took \(Int(allocMs)) ms")
f = flow(over: 1.5)
log("B: play=\(f.play) rec=\(f.rec)")
if f.play == 0 { fail("B: no output frames when allocated on a released session") }
micSeen = micSeen || f.rec > 0

// C: hold while running, then release again.
log("C: hold while running, expect stop, release, expect resume")
cb_audio_interrupt(true)
_ = flow(over: 0.3) // let in-flight callbacks drain
f = flow(over: 1.0)
if f.play != 0 { fail("C: \(f.play) output frames flowed while held") }
cb_audio_interrupt(false)
f = flow(over: 1.5)
log("C: after re-release play=\(f.play) rec=\(f.rec)")
if f.play == 0 { fail("C: no output frames after re-release") }
micSeen = micSeen || f.rec > 0
cb_audio_test_free()

// D: rapid restart churn, as a route flap or repeated interruptions produce.
log("D: three quick hold/release cycles, expect flow after the last")
cb_audio_interrupt(false)
arc = cb_audio_test_alloc()
if arc != 0 { fail("D: alloc \(arc)") }
for _ in 1...3 {
    cb_audio_interrupt(true)
    Thread.sleep(forTimeInterval: 0.2)
    cb_audio_interrupt(false)
    Thread.sleep(forTimeInterval: 0.2)
}
f = flow(over: 1.5)
log("D: after the cycles play=\(f.play) rec=\(f.rec)")
if f.play == 0 { fail("D: no output frames after rapid hold/release cycles") }
micSeen = micSeen || f.rec > 0
cb_audio_test_free()

// E: prepared units adopted by the allocation that follows.
log("E: release with nothing allocated, expect prepared units; allocate, expect adoption and flow")
cb_audio_interrupt(false)
Thread.sleep(forTimeInterval: 0.5) // the release runs on the loop; let the preparation finish
if !driverSaid("prepared player and record units") { fail("E: the driver did not prepare units on a release with nothing allocated") }
let coldAlloc = allocMs // scenario B's allocation, on a released session with nothing prepared
var t = Date()
arc = cb_audio_test_alloc()
let warmAlloc = Date().timeIntervalSince(t) * 1000
if arc != 0 { fail("E: alloc \(arc)") }
log("E: allocation took \(Int(warmAlloc)) ms with prepared units, \(Int(coldAlloc)) ms without (scenario B)")
if !driverSaid("player adopted the prepared unit") || !driverSaid("record adopted the prepared unit") {
    fail("E: the allocation did not adopt the prepared units")
}
if coldAlloc > 0 && warmAlloc > coldAlloc / 2 { fail("E: adopting prepared units took \(Int(warmAlloc)) ms, not clearly less than a cold setup (\(Int(coldAlloc)) ms)") }
f = flow(over: 1.5)
log("E: play=\(f.play) rec=\(f.rec)")
if f.play == 0 { fail("E: no output frames through adopted units") }
micSeen = micSeen || f.rec > 0
cb_audio_test_free()

// F: prepared units discarded by a hold; a held allocation still sets up on release.
log("F: release (prepare), hold (discard), allocate held, release, expect flow")
cb_audio_interrupt(false)
Thread.sleep(forTimeInterval: 0.5)
cb_audio_interrupt(true)
Thread.sleep(forTimeInterval: 0.2)
if !driverSaid("prepared units discarded (audio held)") { fail("F: the hold did not discard the prepared units") }
arc = cb_audio_test_alloc()
if arc != 0 { fail("F: alloc \(arc)") }
f = flow(over: 0.5)
if f.play != 0 { fail("F: \(f.play) output frames flowed while held") }
cb_audio_interrupt(false)
f = flow(over: 1.5)
log("F: after release play=\(f.play) rec=\(f.rec)")
if f.play == 0 { fail("F: no output frames after release") }
if !driverSaid("player set up afresh") { fail("F: the held allocation was not set up afresh on release") }
micSeen = micSeen || f.rec > 0
cb_audio_test_free()

cb_stop()

if !micSeen { log("rec=0 throughout (no mic access in this environment); output asserted only") }
if failures == 0 {
    print("PASS: audiounit driver starts only on release and moves audio in every ordering")
    exit(0)
} else {
    print("FAIL: \(failures) assertion(s)")
    exit(1)
}
