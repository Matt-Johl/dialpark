# Standalone PBX for real phones (Ubuntu)

The Docker harness's Asterisk sits behind Docker Desktop's UDP port proxy,
which does not carry two-way RTP for a phone on the LAN (the same fault
that silenced the iPhone against the containerised server), and Homebrew
no longer ships Asterisk for the Mac. For a physical SIP phone, the PBX is
a stock Ubuntu Asterisk on another machine on the LAN, configured from
the files in this directory:

```sh
# on the Mac
scp -r harness/asterisk-native ubuntu-box:~/
ssh ubuntu-box 'sudo DIALPARK_HOST=<this Mac's LAN address> sh asterisk-native/install-ubuntu.sh'

ASTERISK_HOST=<ubuntu-box address> make dev-server     # the light server, trunked to it
```

That gives a plain UDP trunk. For the encrypted one see **Secure trunk**
below — it needs certificates generated first, so it is not the default.

`install-ubuntu.sh` installs the `asterisk` package if needed, keeps the
package's original `/etc/asterisk` as `/etc/asterisk.dist`, renders
`pjsip.conf` with the light server's address, copies the other configs
in, opens the ports in ufw when it is active, and restarts Asterisk.
Re-run it after editing any `.conf` here.

Then in the app, dial `101` (the phone), `600` (PBX echo) or `echo`
(server echo); from the phone dial `201` (the app) or `600`.

## Phone configuration (Grandstream and similar)

| Setting | Value |
|---|---|
| SIP server / registrar | the Ubuntu box's LAN address, port 5060 |
| Transport | UDP |
| SIP user ID / auth ID | 101 |
| Password | dialpark101 (in `pjsip.conf`) |
| Codecs | PCMU, PCMA (G.711); disable others |
| NAT traversal / STUN | off (same LAN) |

`sudo asterisk -rvvv` on the Ubuntu box opens the console; `pjsip show
endpoints` lists 101 as Avail once the phone has registered, and the
`dialpark` endpoint as Avail once `make dev-server` is up on the Mac (it is
qualified every 10 s).

## Registered lines instead of a trunk (SPEC §6 item 3c)

The same bench, with the light server registering the app's extension to
Asterisk as a third-party SIP device instead of trunking to it. The app is
unchanged: same enrolment, same welcome, and it never sees a PBX credential.

```sh
# on the Ubuntu box — lines mode needs no DIALPARK_HOST (a line is reached at
# whatever its REGISTER advertised, not at a fixed address)
ssh ubuntu-box 'sudo LINES=1 sh asterisk-native/install-ubuntu.sh'

# on the Mac
ASTERISK_HOST=<ubuntu-box address> PBX_MODE=lines make dev-server
```

`provision.sh` seeds dev-a (the app's device, user 201) with the credential
`pjsip-lines.conf` expects, so there is nothing to type. Confirm both ends:

```sh
# the Mac's log
#   "pbx mode: lines" … lines=1
#   "pbx line: registered" line=201 dn=201 realm=asterisk
ssh ubuntu-box "sudo asterisk -rx 'pjsip show contacts'"
#   201/sip:201@<mac>:5062;transport=udp   Avail
```

`Avail` means Asterisk's OPTIONS keep-alive on the line is being answered —
the registration is not just accepted but usable.

Then, on the phone and in the app:

| Try | Expect |
|---|---|
| phone 101 dials **201** | the app rings — through the wake if it is backgrounded or killed |
| app dials **101** | the phone rings, showing **201** as the caller (not "dialpark") |
| app dials **600** | the PBX echo, as on the trunk |
| kill the app, phone dials 201 | still rings: the line is registered by the server, not the phone |
| `sudo asterisk -rvvv`, watch a call out | `PJSIP/201-…` in the dial plan, and a challenge the server answers |

That fourth row is the point of the whole design: the exchange's INVITE
arrives at a registration this server holds around the clock, so a suspended
app is reachable.

To prove the credential path rather than assume it, break it and watch both
ends refuse:

```sh
curl -sSk -X POST https://127.0.0.1:8081/v1/admin/devices/dev-a/pbx-line \
  -H 'Authorization: Bearer harness' \
  -d '{"digest_user":"line201","secret":"wrong"}'
# server log: "pbx line: refused" once, and no retry storm
# an outbound call now fails; the Asterisk log says "Failed to authenticate"
# put the right secret back and the line registers again within a second
```

Going back to the trunk is the two commands at the top of this file
(`DIALPARK_HOST=… sh install-ubuntu.sh`, then `make dev-server` without
`PBX_MODE`). Run one mode or the other, never both: Asterisk matches an
inbound request by source address before it looks at the From user, so a
trunk identify would swallow the calls a registered line places.

Lines mode here is plain UDP, and that is the ordinary shape: Cisco's
documented configuration for a third-party SIP device is the Standard SIP
Non-Secure Profile with digest authentication. The leg carrying a user's
voice to their phone is encrypted either way (TLS 1.3 + SRTP on the app
leg). Encrypting the leg to the exchange is unscheduled — see SPEC §6
"Much later", *Encryption on the line leg*, for what it would take and why
one shared connection is the right shape for it. `TRUNK_TLS` and
`TRUNK_SRTP` configure the trunk and are refused alongside `LINES=1`.

### Test lines 301–310

`pjsip-lines.conf` also carries ten spare lines, 301 to 310, for trying the
admin UI's add and delete: create a client with one of those extensions,
give it the line (digest user `line301`, secret `dialpark-line-301`, and so
on), watch it register on the Clients page, purge the client, watch the
line drop. Nothing on the dialpark side needs to exist for them in advance.

To put them on the box after this change, re-run the installer, which
copies the file and reloads:

```sh
scp -r harness/asterisk-native ubuntu-box:~/
ssh ubuntu-box 'sudo LINES=1 sh asterisk-native/install-ubuntu.sh'
# or, for a running box: sudo cp ~/asterisk-native/pjsip-lines.conf /etc/asterisk/pjsip.conf
#                        sudo cp ~/asterisk-native/extensions-lines.conf /etc/asterisk/extensions.conf
#                        sudo asterisk -rx 'core reload'
ssh ubuntu-box "sudo asterisk -rx 'pjsip show endpoints' | grep -c '^ Endpoint:  3'"   # 10
```

## Transfers

When the app transfers a PBX phone to another PBX extension (say 101 is
talking to the app and the app transfers it to 600), the light server hands
the transfer to Asterisk with a REFER on the trunk leg and drops out: the
audio then runs phone ↔ Asterisk ↔ 600 without the server. That needs
`allow_transfer=yes` on the `dialpark` endpoint (pjsip's default, stated in
`pjsip.conf`) and the target reachable in the `from-dialpark` context. If a
PBX refuses the REFER, the server completes the transfer itself as before,
which keeps it in the media path; on a CUCM trunk, enable REFER on the
trunk profile to get the offload.

## Secure trunk (TLS, and SDES on top)

By default the trunk is plain UDP, which is what most PBXs run. To test the
secure path (SPEC §6 items 3a/3b) — SIP over TLS with each side
authenticating the other against a private CA, and SDES media keys carried
inside it — generate a certificate set for the **real** addresses, copy it
over with the configs, and install with `TRUNK_TLS=1`:

```sh
# on the Mac. OUT=lan keeps these apart from the docker harness's set,
# whose SANs are compose addresses and which the containers still need.
OUT=lan DIALPARK_IP=<mac-ip> ASTERISK_IP=<ubuntu-ip> sh harness/tls/gen_certs.sh
scp -r harness/asterisk-native harness/tls/lan ubuntu-box:~/
ssh ubuntu-box 'sudo TRUNK_TLS=1 TRUNK_SRTP=1 DIALPARK_HOST=<mac-ip> sh asterisk-native/install-ubuntu.sh'

TRUNK_TLS=1 TRUNK_SRTP=sdes ASTERISK_HOST=<ubuntu-ip> make dev-server
```

The two `TRUNK_SRTP`s have to travel together. The installer's puts
`media_encryption=sdes` on the `dialpark` endpoint; the server's makes it
offer RTP/SAVP. Either one without the other is refused with **488 Not
Acceptable Here** on every trunk call — the PBX rejecting an encrypted
offer it cannot answer, or a plain offer it is configured to refuse — and
that 488 looks identical to a broken SDP. The installer renders
`pjsip.conf` from the repo copy on every run, so a `media_encryption` line
added by hand on the box does not survive the next re-run; pass the flag
instead.

The SANs are the addresses each side is **dialled by**, so a set generated
for the wrong addresses verifies by hand and then fails every call; the
installer prints the SAN of what it is about to install for that reason.
Regenerate with `FORCE=1` after either machine changes address.

Asterisk then listens on **5061/tcp** with `require_client_cert=yes`, so it
will not even qualify the server without a valid certificate — `pjsip show
endpoints` showing `dialpark` Avail is itself proof the mutual handshake
worked. Check the transport loaded with `asterisk -rx 'pjsip show transport
transport-tls'`; a missing certificate file leaves Asterisk running with no
TLS listener at all rather than failing loudly.

Without `TRUNK_SRTP=sdes` the media stays in the clear and the server says
so at startup (`trunk SRTP over unencrypted signalling` is the opposite
warning — SDES *without* TLS). The same pairing is asserted headlessly by
`make harness-trunk-secure`.

## Ports

Ubuntu box: 5060/udp (SIP), **5061/tcp only with `TRUNK_TLS=1`** (SIP over
TLS), 10000–10200/udp (RTP, `rtp.conf`).
Mac: 5061/tcp+tls and 7443/tls (light server, app side), **5062** (the
server's trunk listener — udp for a plain trunk, tcp/tls for a TLS one),
20000–20100/udp (server media relay). In lines mode (`PBX_MODE=lines`) the
PBX leg is **5062–5099/udp** (`PBX_LINE_PORTS`): one socket per line, the
first being the trunk listener, because an exchange binds a registered
device to the address and port it registers from.

5062 rather than the conventional 5061 for a TLS trunk: 5061 is the app
leg's port and two SIP listeners on one address cannot share it. The server
refuses a configuration where they collide rather than failing with a bare
"address in use". It costs one field on the PBX — `contact=sip:<mac>:5062`
in the `dialpark` AOR here, *Destination Port* on a CUCM trunk — and nothing
at all outbound, where we dial the PBX's own 5060/5061. `-trunk-addr`
changes it if a deployment needs the trunk on 5061; the app leg would then
have to move (`-sip-addr` plus `-public-sip-port`), or the two legs be
given separate addresses.

## Refusing extensions that are not there

`extensions.conf` has a `dial-status` context that every dialling context
includes. It turns `Dial()`'s outcome into a SIP status — CHANUNAVAIL →
`Hangup(20)` → **480 Temporarily Unavailable**, BUSY → 17 → 486, CONGESTION
→ 34 → 503. Without it a failed `Dial` falls through to a bare `Hangup()`,
the PBX sends nothing that says why, and the caller is left on ring-back.

`pjsip.conf` pairs that with `qualify_frequency` + `remove_unavailable=yes`
on the phone AORs. A phone that is switched off never unregisters, so its
contact stays on file and `Dial()` rings it for the full 30 s; qualify is
what notices and removes it, and only then does `Dial` fail fast. Detection
costs up to `qualify_frequency + qualify_timeout` (30 s + 3 s here), so a
call placed in that window still rings — that is inherent, not a bug.

Both are exercised by `make harness-pbx-unavailable` against the docker
PBX, which carries the same config. Re-deploy after changing either:

    scp -r harness/asterisk-native ubuntu-box:~/
    ssh ubuntu-box 'cd asterisk-native && sudo DIALPARK_HOST=<mac-ip> sh install-ubuntu.sh'
