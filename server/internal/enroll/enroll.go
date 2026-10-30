// Package enroll issues and verifies per-device credentials (SPEC §4.6): a
// device id plus a bearer token, persisted as a hash, and the enrolment
// codes that hand a phone its first one (SPEC §4.8).
//
// The store is the call path's credential source (every REGISTER, INVITE
// and hello reads it), so its locking follows ADMIN-API.md §4.7: a write
// mutates memory under the lock and releases it before any disk I/O, and a
// read never waits on an fsync.
package enroll

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"dialpark/server/internal/secrets"
	"dialpark/server/internal/sipauth"
)

// Device is the public view of an enrolled device.
type Device struct {
	DeviceID string `json:"device_id"`
	User     string `json:"user"`
	// Description is the operator's name for the phone ("Matt's iPhone");
	// the device id is a credential username nobody should have to read.
	Description string    `json:"description,omitempty"`
	IssuedAt    time.Time `json:"issued_at"`
	// UpdatedAt moves on every write to the record; the admin API's
	// If-Match compares against it (ADMIN-API.md §4.5).
	UpdatedAt time.Time `json:"updated_at,omitzero"`
	Revoked   bool      `json:"revoked"`
	// Enrolled is whether the device holds a credential at all: false
	// between its creation and the claim of its enrolment code.
	Enrolled bool `json:"enrolled"`
	// Licensed is whether the device holds a licence seat (SPEC §4.9): an
	// enrolled, non-revoked device within the seat count. False for a
	// device that is not enrolled, is revoked, or is a holder beyond the
	// seats, which every door refuses.
	Licensed bool `json:"licensed"`
	// SeatSince is when the device last entered the seat-holding state,
	// which is its place in the queue when there are more holders than
	// seats; zero while it holds none.
	SeatSince time.Time `json:"seat_since,omitzero"`
	// CodePending is whether an unexpired enrolment code is outstanding,
	// and CodeExpiresAt when it stops being claimable.
	CodePending   bool      `json:"code_pending,omitempty"`
	CodeExpiresAt time.Time `json:"code_expires_at,omitzero"`
	// Config is the device's server-managed settings; nil until set.
	Config *DeviceConfig `json:"config,omitempty"`
	// PBXLine is the device's line on the PBX when the server registers on
	// its behalf (SPEC §6 item 3c); nil until set. Never carries the
	// secret.
	PBXLine *PBXLine `json:"pbx_line,omitempty"`
}

// schemaVersion is the shape of devices.json this binary writes and the
// highest it reads (ADMIN-API.md §6.2). A file without a schema field is
// the pre-9b shape: a bare map of device ids, with "label" for the
// description. It is read and rewritten as schema 1 on the first save.
const schemaVersion = 1

// file is the on-disk shape of devices.json.
type file struct {
	Schema  int                `json:"schema"`
	Devices map[string]*record `json:"devices"`
}

type record struct {
	User        string `json:"user"`
	Description string `json:"description,omitempty"`
	// LegacyLabel is the pre-9b name of Description, read once from an old
	// file and folded in; never written (Open clears it).
	LegacyLabel string `json:"label,omitempty"`
	// TokenHash is the hex sha256 of the bearer token; "" until a
	// credential has been issued (a device waiting for its first claim).
	TokenHash string `json:"token_hash"`
	// HA1 is the SIP Digest form of the same token, MD5(device:realm:token)
	// (sipauth.HA1): what the app-leg registrar verifies against. Empty for
	// credentials issued before a realm was configured; re-issue those.
	HA1       string    `json:"ha1,omitempty"`
	IssuedAt  time.Time `json:"issued_at"`
	UpdatedAt time.Time `json:"updated_at,omitzero"`
	Revoked   bool      `json:"revoked"`
	// SeatSince is when the record last became a seat holder (first
	// credential, or a revoked device claiming its way back); a re-issue
	// or re-claim of a live device leaves it alone, so rotating a
	// credential never sends a device to the back of the seat queue.
	// Cleared on revoke. Zero in files written before seats existed, for
	// which IssuedAt stands in.
	SeatSince time.Time `json:"seat_since,omitzero"`
	// The outstanding enrolment code (SPEC §4.8), stored only as its hex
	// sha256, and when it stops being claimable.
	CodeHash    string    `json:"code_hash,omitempty"`
	CodeExpires time.Time `json:"code_expires,omitzero"`
	// Server-managed settings (SPEC §6 item 8b): the Wi-Fi SSIDs the
	// device's Local Push provider runs on. ConfigVersion is 0 until an
	// administrator has set anything, and the app then keeps its own.
	SSIDs         []string `json:"ssids,omitempty"`
	ConfigVersion int64    `json:"config_version,omitempty"`
	// PBXLine is the device's line on the PBX (SPEC §6 item 3c); nil until
	// an administrator sets one.
	PBXLine *lineRecord `json:"pbx_line,omitempty"`
}

// clone is a copy safe to keep while the original is mutated: mutators
// replace SSIDs and PBXLine rather than editing them in place.
func (r *record) clone() *record {
	c := *r
	return &c
}

// lineRecord is the stored form of a PBX line. The credential is sealed
// (internal/secrets) rather than hashed: unlike everything else here, the
// server has to replay it to the exchange on every registration.
type lineRecord struct {
	DN         string    `json:"dn,omitempty"`
	DigestUser string    `json:"digest_user"`
	SecretEnc  string    `json:"secret_enc"`
	UpdatedAt  time.Time `json:"updated_at"`
	// Port is the PBX-leg socket the server gave this line when it runs
	// one per line (SPEC §6 item 3c); 0 until then. Kept so a line keeps
	// its port across restarts: the exchange binds the device to it.
	Port int `json:"port,omitempty"`
}

// PBXLine is a device's line as the admin API reports it — never the
// secret, which no read returns and which is not pushed to any device.
type PBXLine struct {
	// DN is the directory number on the PBX; empty means "the device's
	// user", which is the usual case.
	DN         string `json:"dn,omitempty"`
	DigestUser string `json:"digest_user"`
	// Configured is always true on a line that exists; it is here so a
	// caller reading JSON does not have to infer presence from emptiness.
	Configured bool      `json:"configured"`
	UpdatedAt  time.Time `json:"updated_at,omitempty"`
	// Port is the PBX-leg socket the server registers this line from, when
	// it runs one per line; 0 on the shared socket. Set by the server,
	// never by a write.
	Port int `json:"port,omitempty"`
}

// PBXCredential is one line with its secret, for the registrar alone. It is
// never serialised: nothing may put it in an HTTP body, a log or a welcome.
type PBXCredential struct {
	DeviceID   string
	User       string
	DN         string
	DigestUser string
	Secret     string
	Port       int
}

// DeviceConfig is the device's server-managed settings as the admin API
// and the wire protocol carry them.
type DeviceConfig struct {
	Version int64    `json:"version"`
	SSIDs   []string `json:"ssids"`
}

// CodeTTL is how long an enrolment code can be claimed.
const CodeTTL = 15 * time.Minute

// codeAlphabet is Crockford base32 without I, L, O and U: nothing that
// reads as something else when typed from a screen.
const codeAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// ErrBadCode is returned for an unknown, used or expired enrolment code.
var ErrBadCode = errors.New("enroll: unknown or expired enrolment code")

// Claimed is what a device gets for a valid enrolment code.
type Claimed struct {
	DeviceID string
	User     string
	Token    string
}

// Store is safe for concurrent use.
type Store struct {
	// mu guards devices. Readers on the call path take it shared and are
	// never held behind disk I/O: no method does I/O while holding it.
	mu      sync.RWMutex
	devices map[string]*record
	// wmu serialises writers end to end (mutate, then persist), so the
	// file always reflects the latest memory and a failed persist can
	// restore memory without racing another writer.
	wmu  sync.Mutex
	path string // "" → memory only
	now  func() time.Time
	// Realm is the SIP Digest realm (the server's SIP domain) that HA1 is
	// computed for at issue time. Set it before issuing credentials.
	Realm string
	// Secrets seals the PBX line credentials (SPEC §6 item 3c), the only
	// thing here the server must be able to replay rather than verify.
	// Nil refuses to store one rather than writing a password in clear.
	Secrets *secrets.Box

	// Licence seats (SPEC §4.9), kept under mu and recomputed after every
	// write: seats is the count in force (NoSeatLimit until SetSeats);
	// used is how many enrolled, non-revoked devices hold one; unlicensed
	// is the holders beyond the first `seats` by SeatSince, whom every
	// door refuses. Not persisted: the licence manager sets the count at
	// start and on every change.
	seats      int
	used       int
	unlicensed map[string]bool
	onSeats    func(SeatChange)
}

// NoSeatLimit is the seat count of a store nobody has given one: every
// holder is licensed. It is the library's default so a store used on its
// own behaves as before; the server sets the real count before it binds a
// listener.
const NoSeatLimit = -1

// SeatChange is what OnSeats is told after a write or a seat-count change
// moved a device across the line: the ids that gained a seat, the ids
// that lost one, and the totals after.
type SeatChange struct {
	Gained, Lost []string
	Used, Seats  int
}

// SeatStatus is a device's standing in the seat count.
type SeatStatus string

const (
	// SeatHolder: enrolled, not revoked, within the seats.
	SeatHolder SeatStatus = "holder"
	// SeatUnlicensed: enrolled, not revoked, beyond the seats.
	SeatUnlicensed SeatStatus = "unlicensed"
	// SeatNone: unknown, un-enrolled or revoked — holds no seat.
	SeatNone SeatStatus = "none"
)

// Match is an If-Match precondition (ADMIN-API.md §4.5): a write proceeds
// only if the record is as the caller last saw it. Checked inside the
// commit, so two writers cannot both pass. Nil fields are not checked.
type Match struct {
	// UpdatedAt must equal the record's updated_at.
	UpdatedAt *time.Time
	// ConfigVersion must equal the settings' version (0: none set yet).
	ConfigVersion *int64
}

func (m Match) check(r *record) error {
	if m.UpdatedAt != nil && !m.UpdatedAt.Equal(r.UpdatedAt) {
		return ErrVersionMismatch
	}
	if m.ConfigVersion != nil && *m.ConfigVersion != r.ConfigVersion {
		return ErrVersionMismatch
	}
	return nil
}

// checkAll runs every precondition against r.
func checkAll(pre []Match, r *record) error {
	for _, m := range pre {
		if err := m.check(r); err != nil {
			return err
		}
	}
	return nil
}

// Errors the store returns; the handlers map them to the §4.4 codes.
var (
	// ErrVersionMismatch is returned when a Match precondition fails.
	ErrVersionMismatch = errors.New("enroll: the record changed since it was read")
	// ErrInvalid is returned for empty device ids or users.
	ErrInvalid = errors.New("enroll: device_id and user are required")
	// ErrExists is returned by Create for a device id already in use.
	ErrExists = errors.New("enroll: device already exists")
	// ErrUserTaken is returned when another device already has the user.
	ErrUserTaken = errors.New("enroll: another device already has that user")
	// ErrImmutable is returned for an attempt to change a device's user.
	ErrImmutable = errors.New("enroll: a device's user cannot change; add a new device and purge the old")
	// ErrNoSeats is returned when a device would take a licence seat and
	// none is free (SPEC §4.9). Nothing is changed: a claim leaves the code
	// claimable, an issue leaves no record.
	ErrNoSeats = errors.New("enroll: no free licence seats")
)

// Open loads the store at path, creating it on first save. An empty path
// gives an in-memory store. A file of a newer schema than this binary
// knows is refused rather than misread.
func Open(path string) (*Store, error) {
	s := &Store{path: path, devices: map[string]*record{}, now: time.Now, seats: NoSeatLimit, unlicensed: map[string]bool{}}
	if path == "" {
		return s, nil
	}
	raw, err := os.ReadFile(path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		return s, nil
	case err != nil:
		return nil, fmt.Errorf("enroll: read %s: %w", path, err)
	}
	if len(raw) == 0 {
		return s, nil
	}
	devices, err := parseFile(raw)
	if err != nil {
		return nil, fmt.Errorf("enroll: parse %s: %w", path, err)
	}
	// A holder written before seats existed has no seat_since. Its place in
	// the queue is when it was issued, fixed here at load: read from
	// issued_at on every recompute it would move to the back each time its
	// credential is re-issued or re-claimed, which rewrites issued_at (SPEC
	// §4.9). Persisted with the next write.
	for _, r := range devices {
		if r.holdsSeat() && r.SeatSince.IsZero() {
			r.SeatSince = r.IssuedAt
		}
	}
	s.devices = devices
	s.recomputeSeatsLocked()
	return s, nil
}

// parseFile reads either shape of devices.json.
func parseFile(raw []byte) (map[string]*record, error) {
	var f struct {
		Schema  *int               `json:"schema"`
		Devices map[string]*record `json:"devices"`
	}
	if err := json.Unmarshal(raw, &f); err == nil && f.Schema != nil {
		if *f.Schema > schemaVersion {
			return nil, fmt.Errorf("schema %d is newer than this binary's %d; upgrade the server rather than let it misread the file", *f.Schema, schemaVersion)
		}
		if f.Devices == nil {
			f.Devices = map[string]*record{}
		}
		return fold(f.Devices), nil
	}
	// The pre-9b shape: the map itself.
	var legacy map[string]*record
	if err := json.Unmarshal(raw, &legacy); err != nil {
		return nil, err
	}
	if legacy == nil {
		legacy = map[string]*record{}
	}
	return fold(legacy), nil
}

// fold moves a legacy "label" into Description.
func fold(m map[string]*record) map[string]*record {
	for _, r := range m {
		if r == nil {
			continue
		}
		if r.Description == "" && r.LegacyLabel != "" {
			r.Description = r.LegacyLabel
		}
		r.LegacyLabel = ""
	}
	return m
}

func hashToken(tok string) string {
	sum := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(sum[:])
}

// commit runs mutate under the write lock, then persists the result with
// no lock held. If persisting fails, memory is restored to what it was so
// the entry is unchanged (ADMIN-API.md §4.4, 500 store). mutate returns
// an error to abort with nothing changed.
func (s *Store) commit(mutate func() error) error {
	change, err := s.commitLocked(mutate)
	if err != nil {
		return err
	}
	s.fireSeats(change)
	return nil
}

// commitLocked is commit under the writer lock. It returns the seat
// change the write caused, if any, for the caller to announce once the
// lock is released: the hooks disconnect sessions and drop lines, which
// must never run while the store is held.
func (s *Store) commitLocked(mutate func() error) (*SeatChange, error) {
	s.wmu.Lock()
	defer s.wmu.Unlock()
	s.mu.Lock()
	backup := make(map[string]*record, len(s.devices))
	for id, r := range s.devices {
		backup[id] = r.clone()
	}
	prevLicensed := s.licensedSetLocked()
	prevUnlicensed, prevUsed := s.unlicensed, s.used
	err := mutate()
	if err != nil {
		s.devices = backup
		s.mu.Unlock()
		return nil, err
	}
	s.recomputeSeatsLocked()
	s.mu.Unlock()
	if err := s.save(); err != nil {
		s.mu.Lock()
		s.devices, s.unlicensed, s.used = backup, prevUnlicensed, prevUsed
		s.mu.Unlock()
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.seatDiffLocked(prevLicensed), nil
}

// fireSeats tells OnSeats about a change, with no lock held.
func (s *Store) fireSeats(change *SeatChange) {
	if change == nil {
		return
	}
	s.mu.RLock()
	fn := s.onSeats
	s.mu.RUnlock()
	if fn != nil {
		fn(*change)
	}
}

// save serialises under the shared lock (readers are not blocked by it)
// and writes the file with no lock held: temp file, then rename.
func (s *Store) save() error {
	if s.path == "" {
		return nil
	}
	s.mu.RLock()
	raw, err := json.MarshalIndent(file{Schema: schemaVersion, Devices: s.devices}, "", "  ")
	s.mu.RUnlock()
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

// userTakenLocked reports whether a device other than deviceID has user.
func (s *Store) userTakenLocked(user, deviceID string) bool {
	for id, r := range s.devices {
		if id != deviceID && r.User == user {
			return true
		}
	}
	return false
}

// Issue issues a fresh random credential for deviceID. A new device is
// created bound to user; an existing one keeps everything but its
// credential, and its user must match (ErrImmutable). The plaintext
// token is returned once and never stored.
func (s *Store) Issue(deviceID, user string) (string, error) {
	return s.IssueToken(deviceID, user, "")
}

// IssueToken is Issue with a caller-chosen token (min 16 chars). Meant for
// development fixtures so a re-provisioned harness keeps the same tokens;
// "" generates a random one. Only the hash is stored either way.
//
// Re-issuing replaces the credential and nothing else (ADMIN-API.md
// §5.1): description, settings, line, pending code and revocation state
// are all kept, so re-provisioning the harness disturbs nothing.
func (s *Store) IssueToken(deviceID, user, token string) (string, error) {
	if deviceID == "" || user == "" {
		return "", ErrInvalid
	}
	tok := token
	if tok == "" {
		var b [32]byte
		if _, err := rand.Read(b[:]); err != nil {
			return "", err
		}
		tok = "tok_" + base64.RawURLEncoding.EncodeToString(b[:])
	} else if len(tok) < 16 {
		return "", ErrInvalid
	}
	err := s.commit(func() error {
		now := s.now()
		rec, ok := s.devices[deviceID]
		wasHolder := ok && rec.holdsSeat()
		if ok {
			if rec.User != user {
				return ErrImmutable
			}
		} else {
			if s.userTakenLocked(user, deviceID) {
				return ErrUserTaken
			}
			rec = &record{User: user, IssuedAt: now}
			s.devices[deviceID] = rec
		}
		// A credential makes a non-revoked device a seat holder; a device
		// that already holds one keeps it, and a revoked one stays
		// revoked and takes none (SPEC §4.9).
		if !wasHolder && !rec.Revoked {
			if !s.freeSeatLocked() {
				return ErrNoSeats
			}
			rec.SeatSince = now
		}
		rec.TokenHash = hashToken(tok)
		rec.HA1 = ""
		if s.Realm != "" {
			rec.HA1 = sipauth.HA1(deviceID, s.Realm, tok)
		}
		rec.IssuedAt, rec.UpdatedAt = now, now
		return nil
	})
	if err != nil {
		return "", err
	}
	return tok, nil
}

// Create registers a new device without a credential: it exists, bound to
// user, until an enrolment code is claimed for it (SPEC §4.8). An empty
// deviceID is generated ("dev_" + six code characters). An existing id is
// ErrExists; a user another device holds is ErrUserTaken.
func (s *Store) Create(deviceID, user, description string) (string, error) {
	if user == "" {
		return "", ErrInvalid
	}
	err := s.commit(func() error {
		if deviceID == "" {
			for {
				deviceID = "dev_" + randomCode(6)
				if _, taken := s.devices[deviceID]; !taken {
					break
				}
			}
		} else if _, exists := s.devices[deviceID]; exists {
			return ErrExists
		}
		if s.userTakenLocked(user, deviceID) {
			return ErrUserTaken
		}
		now := s.now()
		s.devices[deviceID] = &record{User: user, Description: description, IssuedAt: now, UpdatedAt: now}
		return nil
	})
	if err != nil {
		return "", err
	}
	return deviceID, nil
}

// SetDescription renames a device. ok is false for an unknown device.
func (s *Store) SetDescription(deviceID, description string, pre ...Match) (bool, error) {
	found := false
	err := s.commit(func() error {
		rec, ok := s.devices[deviceID]
		if !ok {
			return nil
		}
		found = true
		if err := checkAll(pre, rec); err != nil {
			return err
		}
		if rec.Description == description {
			return errNoChange
		}
		rec.Description = description
		rec.UpdatedAt = s.now()
		return nil
	})
	if errors.Is(err, errNoChange) {
		err = nil
	}
	return found, err
}

// errNoChange aborts a commit that would write what is already there.
var errNoChange = errors.New("enroll: no change")

// MintCode issues a fresh enrolment code for deviceID, replacing any
// outstanding one: eight characters, claimable for CodeTTL, stored only
// as a hash. The device may be revoked — claiming the code brings it back
// with a new credential.
func (s *Store) MintCode(deviceID string) (code string, expires time.Time, err error) {
	err = s.commit(func() error {
		rec, ok := s.devices[deviceID]
		if !ok {
			return ErrInvalid
		}
		code = randomCode(8)
		now := s.now()
		rec.CodeHash = hashToken(code)
		rec.CodeExpires = now.Add(CodeTTL)
		rec.UpdatedAt = now
		expires = rec.CodeExpires
		return nil
	})
	if err != nil {
		return "", time.Time{}, err
	}
	return code, expires, nil
}

// CancelCode drops deviceID's pending enrolment code. ok is false for an
// unknown device; cancelling when none is pending is not an error.
func (s *Store) CancelCode(deviceID string) (bool, error) {
	found := false
	err := s.commit(func() error {
		rec, ok := s.devices[deviceID]
		if !ok {
			return nil
		}
		found = true
		if rec.CodeHash == "" {
			return errNoChange
		}
		rec.CodeHash, rec.CodeExpires = "", time.Time{}
		rec.UpdatedAt = s.now()
		return nil
	})
	if errors.Is(err, errNoChange) {
		err = nil
	}
	return found, err
}

// Claim trades an enrolment code for a fresh credential: the code is
// spent, the device's previous token (if any) stops working, and a
// revoked device is live again. Every record is compared in constant time
// whether or not one has matched, so the answer's timing says nothing.
func (s *Store) Claim(code string) (Claimed, error) {
	want := []byte(hashToken(NormalizeCode(code)))
	var out Claimed
	err := s.commit(func() error {
		var id string
		var rec *record
		now := s.now()
		for d, r := range s.devices {
			if r.CodeHash == "" {
				continue
			}
			if subtle.ConstantTimeCompare([]byte(r.CodeHash), want) == 1 && now.Before(r.CodeExpires) {
				id, rec = d, r
			}
		}
		if rec == nil {
			return ErrBadCode
		}
		// A device that does not hold a seat takes one now, or is refused
		// with its code intact: the operator frees a seat and the phone
		// claims the same code (SPEC §4.9). A holder rotating its
		// credential keeps its place in the queue.
		if !rec.holdsSeat() {
			if !s.freeSeatLocked() {
				return ErrNoSeats
			}
			rec.SeatSince = now
		}
		var b [32]byte
		if _, err := rand.Read(b[:]); err != nil {
			return err
		}
		tok := "tok_" + base64.RawURLEncoding.EncodeToString(b[:])
		rec.TokenHash = hashToken(tok)
		rec.HA1 = ""
		if s.Realm != "" {
			rec.HA1 = sipauth.HA1(id, s.Realm, tok)
		}
		rec.IssuedAt, rec.UpdatedAt = now, now
		rec.Revoked = false
		rec.CodeHash, rec.CodeExpires = "", time.Time{}
		out = Claimed{DeviceID: id, User: rec.User, Token: tok}
		return nil
	})
	if err != nil {
		return Claimed{}, err
	}
	return out, nil
}

// Config returns deviceID's server-managed settings, or nil when none
// have been set (the app then keeps its own).
func (s *Store) Config(deviceID string) *DeviceConfig {
	s.mu.RLock()
	defer s.mu.RUnlock()
	r, ok := s.devices[deviceID]
	if !ok || r.ConfigVersion == 0 {
		return nil
	}
	return &DeviceConfig{Version: r.ConfigVersion, SSIDs: append([]string{}, r.SSIDs...)}
}

// SetConfig replaces deviceID's SSID list (trimmed, empties and repeats
// dropped, order kept) and bumps its config version. An identical list
// is a no-op — same version, changed false, nothing written — so a
// re-applied form disturbs nobody (ADMIN-API.md §5.3). ErrInvalid for an
// unknown device.
func (s *Store) SetConfig(deviceID string, ssids []string, pre ...Match) (cfg DeviceConfig, changed bool, err error) {
	clean := make([]string, 0, len(ssids))
	seen := map[string]bool{}
	for _, ss := range ssids {
		ss = strings.TrimSpace(ss)
		if ss == "" || seen[ss] {
			continue
		}
		seen[ss] = true
		clean = append(clean, ss)
	}
	err = s.commit(func() error {
		r, ok := s.devices[deviceID]
		if !ok {
			return ErrInvalid
		}
		if err := checkAll(pre, r); err != nil {
			return err
		}
		if r.ConfigVersion > 0 && equalStrings(r.SSIDs, clean) {
			cfg = DeviceConfig{Version: r.ConfigVersion, SSIDs: append([]string{}, clean...)}
			return errNoChange
		}
		r.SSIDs = clean
		r.ConfigVersion++
		r.UpdatedAt = s.now()
		cfg = DeviceConfig{Version: r.ConfigVersion, SSIDs: append([]string{}, clean...)}
		changed = true
		return nil
	})
	if errors.Is(err, errNoChange) {
		err = nil
	}
	if err != nil {
		return DeviceConfig{}, false, err
	}
	return cfg, changed, nil
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// NormalizeCode makes a typed code comparable: upper case, separators
// dropped, and the letters the alphabet leaves out mapped to the digits
// they are mistaken for (I and L → 1, O → 0).
func NormalizeCode(code string) string {
	out := make([]byte, 0, len(code))
	for _, c := range strings.ToUpper(code) {
		switch {
		case c == ' ' || c == '-':
		case c == 'I' || c == 'L':
			out = append(out, '1')
		case c == 'O':
			out = append(out, '0')
		case c < 128:
			out = append(out, byte(c))
		}
	}
	return string(out)
}

func randomCode(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	for i := range b {
		b[i] = codeAlphabet[int(b[i])%len(codeAlphabet)]
	}
	return string(b)
}

// Authenticate satisfies gateway.Authenticator.
func (s *Store) Authenticate(_ context.Context, deviceID, token string) (bool, error) {
	s.mu.RLock()
	r, ok := s.devices[deviceID]
	var hash string
	if ok {
		hash = r.TokenHash
		ok = !r.Revoked && hash != ""
	}
	s.mu.RUnlock()
	if !ok {
		return false, nil
	}
	return subtle.ConstantTimeCompare([]byte(hash), []byte(hashToken(token))) == 1, nil
}

// Revoke disables the device's credential. Returns false if unknown;
// revoking a revoked device is true and writes nothing.
func (s *Store) Revoke(deviceID string) (bool, error) {
	found := false
	err := s.commit(func() error {
		r, ok := s.devices[deviceID]
		if !ok {
			return nil
		}
		found = true
		if r.Revoked {
			return errNoChange
		}
		r.Revoked = true
		r.SeatSince = time.Time{}
		r.UpdatedAt = s.now()
		return nil
	})
	if errors.Is(err, errNoChange) {
		err = nil
	}
	return found, err
}

// Purge deletes the device's record outright. Returns false if unknown.
// The caller removes what else the device owns (directory, diagnostics)
// and unregisters its line.
func (s *Store) Purge(deviceID string) (bool, error) {
	found := false
	err := s.commit(func() error {
		if _, ok := s.devices[deviceID]; !ok {
			return nil
		}
		found = true
		delete(s.devices, deviceID)
		return nil
	})
	return found, err
}

// Exists reports whether a record exists for deviceID, revoked or not.
// The admin API's notion of "known" (ADMIN-API.md §5.1): revoked is an
// authentication state, not a deletion.
func (s *Store) Exists(deviceID string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	_, ok := s.devices[deviceID]
	return ok
}

// UpdatedAt is when the record last changed, for If-Match; zero for an
// unknown device or one never written by this version.
func (s *Store) UpdatedAt(deviceID string) time.Time {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if r, ok := s.devices[deviceID]; ok {
		return r.UpdatedAt
	}
	return time.Time{}
}

// UserFor returns the SIP user bound to an enrolled, non-revoked device:
// the call path's view, where a revoked device does not exist.
func (s *Store) UserFor(deviceID string) (string, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	r, ok := s.devices[deviceID]
	if !ok || r.Revoked {
		return "", false
	}
	return r.User, true
}

// DigestSecret satisfies sipauth.Secrets: the SIP Digest H(A1) and enrolled
// user of a live device. ok is false for unknown or revoked devices and for
// credentials issued before a realm was configured.
func (s *Store) DigestSecret(deviceID string) (ha1, user string, ok bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	r, found := s.devices[deviceID]
	if !found || r.Revoked || r.HA1 == "" || s.unlicensed[deviceID] {
		return "", "", false
	}
	return r.HA1, r.User, true
}

// Device returns one record's public view.
func (s *Store) Device(deviceID string) (Device, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	r, ok := s.devices[deviceID]
	if !ok {
		return Device{}, false
	}
	return s.viewLocked(deviceID, r), true
}

// Devices lists every record, sorted by device id.
func (s *Store) Devices() []Device {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Device, 0, len(s.devices))
	for id, r := range s.devices {
		out = append(out, s.viewLocked(id, r))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].DeviceID < out[j].DeviceID })
	return out
}

func (s *Store) viewLocked(id string, r *record) Device {
	now := s.now()
	d := Device{
		DeviceID: id, User: r.User, Description: r.Description,
		IssuedAt: r.IssuedAt, UpdatedAt: r.UpdatedAt, Revoked: r.Revoked,
		Enrolled:  r.TokenHash != "",
		Licensed:  r.holdsSeat() && !s.unlicensed[id],
		SeatSince: r.SeatSince,
	}
	if r.CodeHash != "" && now.Before(r.CodeExpires) {
		d.CodePending, d.CodeExpiresAt = true, r.CodeExpires
	}
	if r.ConfigVersion > 0 {
		d.Config = &DeviceConfig{Version: r.ConfigVersion, SSIDs: append([]string{}, r.SSIDs...)}
	}
	if r.PBXLine != nil {
		line := r.PBXLine.view()
		d.PBXLine = &line
	}
	return d
}

// ---- licence seats (SPEC §4.9) ------------------------------------------------

// holdsSeat is whether a record is an enrolled, non-revoked device: the
// definition of a seat holder.
func (r *record) holdsSeat() bool { return r.TokenHash != "" && !r.Revoked }

// seatSince is the record's place in the queue: when it last took a seat,
// or when its credential was issued for records written before seats
// existed.
func (r *record) seatSince() time.Time {
	if r.SeatSince.IsZero() {
		return r.IssuedAt
	}
	return r.SeatSince
}

// SetSeats sets the seat count in force and announces the devices it
// moves across the line. The licence manager calls it at start and on
// every change; NoSeatLimit lifts the limit.
func (s *Store) SetSeats(n int) {
	if n < 0 {
		n = NoSeatLimit
	}
	s.mu.Lock()
	if n == s.seats {
		s.mu.Unlock()
		return
	}
	prev := s.licensedSetLocked()
	s.seats = n
	s.recomputeSeatsLocked()
	change := s.seatDiffLocked(prev)
	s.mu.Unlock()
	s.fireSeats(change)
}

// OnSeats registers the one callback told, after the write that caused
// it has been saved and with no lock held, which devices gained or lost
// a seat. The server disconnects, unregisters and drops lines from it.
func (s *Store) OnSeats(fn func(SeatChange)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.onSeats = fn
}

// Licensed is whether deviceID holds a seat within the count: the call
// path's question, which every door asks after the credential check.
func (s *Store) Licensed(deviceID string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	r, ok := s.devices[deviceID]
	return ok && r.holdsSeat() && !s.unlicensed[deviceID]
}

// SeatState is deviceID's standing: holder, unlicensed, or none.
func (s *Store) SeatState(deviceID string) SeatStatus {
	s.mu.RLock()
	defer s.mu.RUnlock()
	r, ok := s.devices[deviceID]
	switch {
	case !ok || !r.holdsSeat():
		return SeatNone
	case s.unlicensed[deviceID]:
		return SeatUnlicensed
	}
	return SeatHolder
}

// Seats reports how many devices hold a seat and how many the licence
// grants (NoSeatLimit when none is set).
func (s *Store) Seats() (used, total int) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.used, s.seats
}

// freeSeatLocked is whether one more device may take a seat.
func (s *Store) freeSeatLocked() bool {
	return s.seats == NoSeatLimit || s.used < s.seats
}

// recomputeSeatsLocked rebuilds used and unlicensed from the records:
// holders ordered by seatSince then id, the first `seats` licensed, the
// rest not. O(n log n) over at most a few hundred devices, once per write.
func (s *Store) recomputeSeatsLocked() {
	type holder struct {
		id    string
		since time.Time
	}
	holders := make([]holder, 0, len(s.devices))
	for id, r := range s.devices {
		if r.holdsSeat() {
			holders = append(holders, holder{id, r.seatSince()})
		}
	}
	sort.Slice(holders, func(i, j int) bool {
		if !holders[i].since.Equal(holders[j].since) {
			return holders[i].since.Before(holders[j].since)
		}
		return holders[i].id < holders[j].id
	})
	s.used = len(holders)
	s.unlicensed = map[string]bool{}
	if s.seats == NoSeatLimit {
		return
	}
	for i := s.seats; i < len(holders); i++ {
		s.unlicensed[holders[i].id] = true
	}
}

// licensedSetLocked is the ids holding a seat within the count.
func (s *Store) licensedSetLocked() map[string]bool {
	out := map[string]bool{}
	for id, r := range s.devices {
		if r.holdsSeat() && !s.unlicensed[id] {
			out[id] = true
		}
	}
	return out
}

// seatDiffLocked is the change from prev to now, or nil if no device
// crossed the line.
func (s *Store) seatDiffLocked(prev map[string]bool) *SeatChange {
	now := s.licensedSetLocked()
	c := SeatChange{Used: s.used, Seats: s.seats}
	for id := range now {
		if !prev[id] {
			c.Gained = append(c.Gained, id)
		}
	}
	for id := range prev {
		if !now[id] {
			c.Lost = append(c.Lost, id)
		}
	}
	if len(c.Gained) == 0 && len(c.Lost) == 0 {
		return nil
	}
	sort.Strings(c.Gained)
	sort.Strings(c.Lost)
	return &c
}
