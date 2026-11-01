import DiallerProtocol
import XCTest
@testable import DiallerEngine

/// The audio profile the stack starts with is a measured choice (SPEC §6
/// near-term item 5): these pin every key so a "harmless" edit cannot
/// quietly put the fixed 100–200 ms jitter buffer or FEC-less Opus back,
/// and so the keys stay ones baresip actually reads (`audio_srate` and
/// `audio_channels` were not, and sat in the config for weeks).
final class StackConfigTests: XCTestCase {
    private func value(_ key: String, in config: String) -> String? {
        for line in config.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.first.map(String.init) == key { return parts.dropFirst().joined(separator: " ") }
        }
        return nil
    }

    func testAudioProfile() {
        let c = BaresipCallEngine.stackConfig(acceptAnyCertificate: true, audioSource: nil)
        let expected: [String: String] = [
            // Lab (lab/audio-continuity): baresip's jitter buffer is off and
            // the playout engine (ios/vendor/patches/playout) manages delay
            // between 20 and 400 ms; audio_buffer is what it is sized from.
            "audio_jitter_buffer_type": "off",
            "audio_buffer": "20-400",
            "audio_buffer_mode": "adaptive",
            "opus_application": "voip",
            "opus_inbandfec": "yes",
            "opus_packet_loss": "10", // without it baresip neither encodes nor decodes FEC
            "opus_bitrate": "32000",
            "opus_stereo": "no", // speech is mono; stereo at 32 kbit/s pushes libopus into CELT, which has no FEC
            "opus_sprop_stereo": "no",
            "opus_complexity": "6",
            "opus_cbr": "no",
            "opus_dtx": "no",
            "rtp_stats": "yes",
            "rtp_timeout": "30",
            "rtp_tos": "184", // DSCP EF on media
            "sip_tos": "96", // DSCP CS3 on signalling (baresip's default would be CS5)
            "audio_player": "audiounit,default",
            "audio_source": "audiounit,default",
            "call_max_calls": "2", // call waiting: one active, one held; a third caller gets 486
        ]
        for (k, v) in expected {
            XCTAssertEqual(value(k, in: c), v, "config key \(k)")
        }
    }

    func testNoDeadKeys() {
        let c = BaresipCallEngine.stackConfig(acceptAnyCertificate: true, audioSource: nil)
        // Not baresip keys (config.c reads ausrc_srate/auplay_srate; the
        // audiounit driver follows the negotiated codec's rate anyway).
        XCTAssertNil(value("audio_srate", in: c))
        XCTAssertNil(value("audio_channels", in: c))
        // The deprecated spellings must not creep back in either.
        XCTAssertNil(value("jitter_buffer_type", in: c))
        XCTAssertNil(value("jitter_buffer_delay", in: c))
    }

    func testAccountCodecListMatchesMonoOpus() {
        // With opus_stereo no, baresip registers Opus as opus/48000/1; an
        // account list saying /2 finds no codec and the call silently runs
        // PCMU (the harness caught exactly that).
        let e = BaresipCallEngine(acceptAnyCertificate: true)
        let aor = e.aor(user: "201@dialler", sip: SIPTarget(host: "10.0.0.1", port: 5061, transport: "tls"))
        // Opus first for app↔app; G.722 wideband then G.711 for calls the
        // server answers with the PBX's codec (SPEC §4.4 rule 4).
        XCTAssertTrue(aor.contains("audio_codecs=opus/48000/1,G722/16000/1,PCMU/8000/1"), aor)
        XCTAssertTrue(aor.contains(";mediaenc=srtp-mand;"), "the app leg is always SRTP: \(aor)")
        // baresip names G.722 by its 16 kHz audio rate, not the 8000 RTP clock;
        // G722/8000/1 is "audio codec not found" and the call silently runs PCMU.
        XCTAssertFalse(aor.contains("G722/8000"))
        XCTAssertFalse(aor.contains("opus/48000/2"))
    }

    func testInputsAreHonoured() {
        let c = BaresipCallEngine.stackConfig(acceptAnyCertificate: false, audioSource: "aufile,/tmp/in.wav")
        XCTAssertEqual(value("sip_verify_server", in: c), "yes")
        XCTAssertEqual(value("audio_source", in: c), "aufile,/tmp/in.wav")
        let modules = c.split(separator: "\n").filter { $0.hasPrefix("module ") }.count
        XCTAssertEqual(modules, 9, "audiounit, aufile, opus, g722, g711, ice, srtp, auconv, auresamp")
    }

    /// libre terminates a session with ECONNRESET when the far end sends a
    /// BYE, so baresip's close text reads like a network failure. The log
    /// must not invite that misreading again (2026-09-15).
    func testCloseReasonsAreNamedNotLeftAsErrno() {
        XCTAssertTrue(BaresipCallEngine.closeReason("Connection reset by peer [54]").hasPrefix("far end hung up (BYE)"))
        XCTAssertTrue(BaresipCallEngine.closeReason("Connection reset by peer").hasPrefix("far end hung up (BYE)"))
        XCTAssertTrue(BaresipCallEngine.closeReason("Connection reset by user").hasPrefix("hung up here"))
        // The raw text stays visible for anyone reading an old log beside a new one.
        XCTAssertTrue(BaresipCallEngine.closeReason("Connection reset by peer [54]").contains("Connection reset by peer [54]"))
        // A real failure is passed through untouched.
        XCTAssertEqual(BaresipCallEngine.closeReason("486 Busy Here"), "486 Busy Here")
        XCTAssertEqual(BaresipCallEngine.closeReason("Connection timed out [60]"), "Connection timed out [60]")
    }
}
