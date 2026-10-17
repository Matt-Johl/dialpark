**1. Start Dialpark on the Mac**

Terminal 1:

```sh
ASTERISK_HOST=<CUCM IP> PBX_MODE=lines \
DEV_SERVER_FLAGS='-pbx-default-line <new extension>' \
make dev-server
```

Terminal 2:

```sh
make dev-admin
```

Admin UI: https://127.0.0.1:8443, user admin, password dialpark.

**2. CUCM configuration**

1. User Management > End User > Add New. Set User ID and Digest Credentials. Save.
2. System > Security > Phone Security Profile > Add New. Type: Third-party SIP Device (Basic). Tick Enable Digest Authentication. Transport TCP+UDP, port 5060. Save.
3. Device > Phone > Add New > Third-party SIP Device (Basic). Device Pool, Phone Button Template and CSS as for any phone. Device Security Profile = step 2. SIP Profile = Standard SIP Profile. Digest User = step 1 user. Owner User ID = same. MTP Required unticked. Save.
4. Line [1]: Directory Number = the new extension. Save.

**3. Add the device in the admin UI**

1. Clients > add device, extension = the new extension.
2. Enrol the phone from the QR shown.
3. Open the device page. PBX line form: digest user = the End User ID, secret = its Digest Credentials, DN blank. Save line.

**4. Ports between the Mac and CUCM**

| From | To | Port |
|---|---|---|
| Mac | CUCM node | UDP 5060 |
| CUCM node | Mac | UDP 5062 |
| Cisco phones | Mac | UDP 20000 to 20100 |
| Mac | Cisco phones | UDP 16384 to 32767 |

**5. Confirm**

- CUCM Device > Phone: the device shows Registered.
- Admin UI device page, PBX line row: `registered`.
- Server page: dev-a, dev-ha and dev-hb show failing. Expected, ignore.

Then run the checklist in SPEC §7.3 item 10 in order: CUCM phone calls the app, app calls the CUCM phone, DTMF both ways, hold and transfer.