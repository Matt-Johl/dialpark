package b2bua

import (
	"net"
	"strings"
	"testing"

	"github.com/emiago/diago/media"
)

// SRTP is the app leg's and only the app leg's (SPEC §4.4 rule 4): a secure
// session offers RTP/SAVP with an SDES key; the trunk's session offers plain
// RTP/AVP with no crypto attribute.
func TestAppLegOffersSRTPAndTrunkDoesNot(t *testing.T) {
	// SRTPAlg is what Init fills in for a secure session; Init is not called
	// here because it also opens sockets, which the sandbox forbids.
	app := &media.MediaSession{Codecs: []media.Codec{media.CodecAudioOpus, media.CodecAudioUlaw}, Laddr: net.UDPAddr{IP: net.IPv4(10, 18, 0, 212), Port: 20000}, Mode: "sendrecv", SecureRTP: 1, SRTPAlg: media.SRTPProfileAes128CmHmacSha1_80}
	offer := string(app.LocalSDP())
	if !strings.Contains(offer, "RTP/SAVP") || !strings.Contains(offer, "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:") {
		t.Fatalf("app-leg offer lacks SDES SRTP:\n%s", offer)
	}

	trunk := &media.MediaSession{Codecs: append([]media.Codec(nil), DefaultTrunkCodecs...), Laddr: net.UDPAddr{IP: net.IPv4(10, 18, 0, 212), Port: 20002}, Mode: "sendrecv"}
	plain := string(trunk.LocalSDP())
	if !strings.Contains(plain, "RTP/AVP ") || strings.Contains(plain, "crypto") {
		t.Fatalf("trunk offer must be plain RTP:\n%s", plain)
	}
}

// The caller's SDP is applied to the callee's session for codec filtering
// only. With SRTP on the app leg that SDP is RTP/SAVP with a key: it must
// neither fail a plain trunk callee nor become the callee's remote key.
func TestOriginatorSDPFiltersCodecsWithoutTouchingSRTP(t *testing.T) {
	appOffer := "v=0\r\no=- 1 2 IN IP4 10.18.0.111\r\ns=-\r\nc=IN IP4 10.18.0.111\r\nt=0 0\r\nm=audio 10000 RTP/SAVP 96 0\r\na=rtpmap:96 opus/48000/2\r\na=rtpmap:0 PCMU/8000\r\na=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:WVNfX19zZW1jdGwgKCkgewkyMjA7fQp9CnVubGVz\r\na=sendrecv\r\n"
	trunk := &media.MediaSession{Codecs: append([]media.Codec(nil), DefaultTrunkCodecs...), Laddr: net.UDPAddr{IP: net.IPv4(10, 18, 0, 212), Port: 20004}, Mode: "sendrecv"}
	if err := trunk.OriginatorCodecs([]byte(appOffer)); err != nil {
		t.Fatalf("plain trunk callee refused a secure originator: %v", err)
	}
	if got := trunk.CommonCodecs(); len(got) != 1 || got[0].Name != "PCMU" {
		t.Fatalf("common codecs = %v, want PCMU only", got)
	}
	if trunk.SecureRTPActive() {
		t.Fatal("the originator's key must not make the trunk leg secure")
	}
	if strings.Contains(string(trunk.LocalSDP()), "crypto") {
		t.Fatal("the trunk offer must stay plain after applying the originator")
	}
}

// A secure offer answered without crypto falls back to plain RTP rather
// than sending encrypted audio to a peer expecting plaintext.
func TestSecureOfferAnsweredPlainIsNotSecure(t *testing.T) {
	app := &media.MediaSession{Codecs: []media.Codec{media.CodecAudioUlaw}, Laddr: net.UDPAddr{IP: net.IPv4(10, 18, 0, 212), Port: 20006}, Mode: "sendrecv", SecureRTP: 1, SRTPAlg: media.SRTPProfileAes128CmHmacSha1_80}
	_ = app.LocalSDP()
	plainAnswer := "v=0\r\no=- 3 4 IN IP4 10.18.0.5\r\ns=-\r\nc=IN IP4 10.18.0.5\r\nt=0 0\r\nm=audio 18104 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\na=sendrecv\r\n"
	if err := app.RemoteSDP([]byte(plainAnswer)); err != nil {
		t.Fatal(err)
	}
	if app.SecureRTPActive() {
		t.Fatal("plain answer must leave the session unprotected")
	}
}

// A re-INVITE runs on a forked session: it must still be secure, re-offer
// the same local key, and keep the peer's context when the peer's key is
// unchanged (the transfer scenario failed on this: "remote requested secure
// RTP, but no context is created" on the codec-change re-INVITE).
func TestReInviteKeepsSRTPAcrossAFork(t *testing.T) {
	app := &media.MediaSession{Codecs: []media.Codec{media.CodecAudioOpus, media.CodecAudioUlaw}, Laddr: net.UDPAddr{IP: net.IPv4(10, 18, 0, 212), Port: 20008}, Mode: "sendrecv", SecureRTP: 1, SRTPAlg: media.SRTPProfileAes128CmHmacSha1_80}
	offer1 := string(app.LocalSDP())
	answer := "v=0\r\no=- 5 6 IN IP4 10.18.0.111\r\ns=-\r\nc=IN IP4 10.18.0.111\r\nt=0 0\r\nm=audio 10000 RTP/SAVP 96\r\na=rtpmap:96 opus/48000/2\r\na=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:WVNfX19zZW1jdGwgKCkgewkyMjA7fQp9CnVubGVz\r\na=sendrecv\r\n"
	if err := app.RemoteSDP([]byte(answer)); err != nil {
		t.Fatal(err)
	}
	if !app.SecureRTPActive() {
		t.Fatal("negotiated session must be secure")
	}

	// The codec-change re-INVITE: new offer on the same session, answer on a fork.
	app.SetCodecs([]media.Codec{media.CodecAudioG722})
	offer2 := string(app.LocalSDP())
	key := func(sdp string) string {
		i := strings.Index(sdp, "inline:")
		return sdp[i : i+30]
	}
	if key(offer1) != key(offer2) {
		t.Fatalf("re-INVITE must re-offer the same local key:\n%s\n%s", offer1, offer2)
	}
	forked := app.Fork()
	answer2 := strings.Replace(answer, "m=audio 10000 RTP/SAVP 96\r\na=rtpmap:96 opus/48000/2", "m=audio 10000 RTP/SAVP 9\r\na=rtpmap:9 G722/8000", 1)
	if err := forked.RemoteSDP([]byte(answer2)); err != nil {
		t.Fatalf("forked session refused the SRTP answer: %v", err)
	}
	if !forked.SecureRTPActive() {
		t.Fatal("the forked session must still be secure")
	}
	if got := media.CodecAudioFromSession(forked); got.Name != "G722" {
		t.Fatalf("forked session negotiated %s, want G722", got.Name)
	}
}

// A PBX answer in any of the shapes Asterisk produces negotiates against the
// default trunk offer: PCMU only, PCMU+PCMA, or G.722.
func TestTrunkOfferAcceptsPBXAnswers(t *testing.T) {
	for _, ans := range []string{
		"v=0\r\no=- 1 2 IN IP4 10.18.0.5\r\ns=Asterisk\r\nc=IN IP4 10.18.0.5\r\nt=0 0\r\nm=audio 18104 RTP/AVP 0 101\r\na=rtpmap:0 PCMU/8000\r\na=rtpmap:101 telephone-event/8000\r\na=fmtp:101 0-16\r\na=ptime:20\r\na=maxptime:150\r\na=sendrecv\r\n",
		"v=0\r\no=- 1 2 IN IP4 10.18.0.5\r\ns=Asterisk\r\nc=IN IP4 10.18.0.5\r\nt=0 0\r\nm=audio 18104 RTP/AVP 0 8 101\r\na=rtpmap:0 PCMU/8000\r\na=rtpmap:8 PCMA/8000\r\na=rtpmap:101 telephone-event/8000\r\na=fmtp:101 0-16\r\na=sendrecv\r\n",
		"v=0\r\no=- 1 2 IN IP4 10.18.0.5\r\ns=Asterisk\r\nc=IN IP4 10.18.0.5\r\nt=0 0\r\nm=audio 18104 RTP/AVP 9 101\r\na=rtpmap:9 G722/8000\r\na=rtpmap:101 telephone-event/8000\r\na=sendrecv\r\n",
	} {
		ms := &media.MediaSession{Codecs: append([]media.Codec(nil), DefaultTrunkCodecs...), Laddr: net.UDPAddr{IP: net.IPv4(10, 18, 0, 212), Port: 20000}, Mode: "sendrecv"}
		_ = ms.LocalSDP()
		if err := ms.RemoteSDP([]byte(ans)); err != nil {
			t.Errorf("answer %q → %v", ans, err)
		} else {
			t.Logf("negotiated %v", media.CodecAudioFromSession(ms))
		}
	}
}

// A peer that numbers a dynamic codec its own way. CUCM answered an Opus
// offered at 96 with Opus at 114 (lines bench 2026-10-17 13:24); diago
// compared whole structs, recorded no common codec, fell back to our own
// first one and the relay sent the phone Opus marked 96, which it dropped.
// Negotiation must match by kind and keep the peer's number as the one to
// send with — on both sides of an offer.
func TestAnAnswerThatRenumbersADynamicCodecStillNegotiates(t *testing.T) {
	cucmAnswer := "v=0\r\no=CiscoSystemsCCM-SIP 1 1 IN IP4 10.7.160.11\r\ns=SIP Call\r\nc=IN IP4 10.7.166.63\r\nt=0 0\r\n" +
		"m=audio 20106 RTP/AVP 114 101\r\na=rtpmap:114 opus/48000/2\r\n" +
		"a=fmtp:114 maxplaybackrate=16000;sprop-maxcapturerate=16000;maxaveragebitrate=64000;stereo=0;sprop-stereo=0;usedtx=0\r\n" +
		"a=rtpmap:101 telephone-event/8000\r\na=fmtp:101 0-15\r\n"
	// We offered 96 9 0 101 (opus-first PBX set narrowed by the app).
	offered := []media.Codec{media.CodecAudioOpus, media.CodecAudioG722, media.CodecAudioUlaw, media.CodecTelephoneEvent8000}
	us := &media.MediaSession{Codecs: append([]media.Codec(nil), offered...), Laddr: net.UDPAddr{IP: net.IPv4(10, 7, 141, 25), Port: 20000}, Mode: "sendrecv"}
	_ = us.LocalSDP() // the offer went out
	if err := us.RemoteSDP([]byte(cucmAnswer)); err != nil {
		t.Fatalf("apply answer: %v", err)
	}
	common := us.CommonCodecs()
	if len(common) == 0 || common[0].Name != "opus" {
		t.Fatalf("common codecs = %v, want opus first", common)
	}
	if got := media.CodecAudioFromSession(us); got.PayloadType != 114 {
		t.Fatalf("the codec to send with has payload type %d, want the peer's 114", got.PayloadType)
	}
	ev, ok := telephoneEventPT(us)
	if !ok || ev != 101 {
		t.Fatalf("telephone-event = %d %v, want 101", ev, ok)
	}

	// The other side of the same habit: an offer at 114 is answered at 114.
	cucmOffer := strings.Replace(cucmAnswer, "m=audio 20106 RTP/AVP 114 101", "m=audio 20106 RTP/AVP 114 0 101", 1) +
		"a=rtpmap:0 PCMU/8000\r\n"
	them := &media.MediaSession{Codecs: []media.Codec{media.CodecAudioOpus, media.CodecAudioG722, media.CodecAudioUlaw, media.CodecTelephoneEvent8000},
		Laddr: net.UDPAddr{IP: net.IPv4(10, 7, 141, 25), Port: 20002}, Mode: "sendrecv"}
	if err := them.RemoteSDP([]byte(cucmOffer)); err != nil {
		t.Fatalf("apply offer: %v", err)
	}
	answer := string(them.LocalSDP())
	if !strings.Contains(answer, "a=rtpmap:114 opus/48000/2") || strings.Contains(answer, "a=rtpmap:96 ") {
		t.Fatalf("our answer must echo the offerer's 114, got:\n%s", answer)
	}
	if got := media.CodecAudioFromSession(them); got.PayloadType != 114 {
		t.Fatalf("answerer sends with %d, want 114", got.PayloadType)
	}
}
