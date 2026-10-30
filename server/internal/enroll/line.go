package enroll

import (
	"errors"
	"fmt"
	"sort"
	"strings"
)

// The device's line on the PBX, for the deployments where this server
// registers on each device's behalf instead of trunking (SPEC §6 item 3c).
//
// Two rules hold everywhere below. The secret is **sealed, never hashed** —
// the server has to present it to the exchange, so it must be recoverable —
// and it leaves this package in exactly one direction: PBXCredentials, for
// the registrar. No admin read returns it, no device is ever sent it.

// ErrNoSecretKey is returned when a line credential is written to a store
// with no encryption key, which would mean storing the password in clear.
var ErrNoSecretKey = errors.New("enroll: no secret key configured; cannot store a PBX credential")

// SetPBXLine sets (or replaces) deviceID's line. dn may be empty, meaning
// the device's own user, which is the usual case. Both digestUser and secret
// are required: a line with no credential could never register, and storing
// half of one only produces a puzzle later.
func (s *Store) SetPBXLine(deviceID, dn, digestUser, secret string, pre ...Match) (PBXLine, error) {
	dn, digestUser = strings.TrimSpace(dn), strings.TrimSpace(digestUser)
	if digestUser == "" || secret == "" {
		return PBXLine{}, fmt.Errorf("%w: digest_user and secret are required", ErrInvalid)
	}
	if s.Secrets == nil {
		return PBXLine{}, ErrNoSecretKey
	}
	sealed, err := s.Secrets.Seal(deviceID, secret)
	if err != nil {
		return PBXLine{}, err
	}

	var view PBXLine
	err = s.commit(func() error {
		r, ok := s.devices[deviceID]
		if !ok {
			return ErrInvalid
		}
		if err := checkAll(pre, r); err != nil {
			return err
		}
		now := s.now()
		port := 0
		if r.PBXLine != nil {
			// A credential change keeps the socket: the exchange knows
			// the device by it.
			port = r.PBXLine.Port
		}
		r.PBXLine = &lineRecord{DN: dn, DigestUser: digestUser, SecretEnc: sealed, UpdatedAt: now, Port: port}
		r.UpdatedAt = now
		view = r.PBXLine.view()
		return nil
	})
	if err != nil {
		return PBXLine{}, err
	}
	return view, nil
}

// SetPBXLinePort records the PBX-leg socket the server registers deviceID's
// line from (0 clears it). The server's to set, from the port range it runs
// with; no admin write reaches it. Not an error for a device with no line
// or one already on that port.
func (s *Store) SetPBXLinePort(deviceID string, port int) error {
	err := s.commit(func() error {
		r, ok := s.devices[deviceID]
		if !ok || r.PBXLine == nil || r.PBXLine.Port == port {
			return errNoChange
		}
		rec := *r.PBXLine
		rec.Port = port
		r.PBXLine = &rec
		return nil
	})
	if errors.Is(err, errNoChange) {
		return nil
	}
	return err
}

// PBXLine returns deviceID's line, without its secret. ok is false for an
// unknown device or one with no line set.
func (s *Store) PBXLine(deviceID string) (PBXLine, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	r, ok := s.devices[deviceID]
	if !ok || r.PBXLine == nil {
		return PBXLine{}, false
	}
	return r.PBXLine.view(), true
}

// DeletePBXLine removes deviceID's line. ok is false for an unknown device;
// removing a line that is not there is not an error.
func (s *Store) DeletePBXLine(deviceID string, pre ...Match) (bool, error) {
	found := false
	err := s.commit(func() error {
		r, ok := s.devices[deviceID]
		if !ok {
			return nil
		}
		found = true
		if err := checkAll(pre, r); err != nil {
			return err
		}
		if r.PBXLine == nil {
			return errNoChange
		}
		r.PBXLine = nil
		r.UpdatedAt = s.now()
		return nil
	})
	if errors.Is(err, errNoChange) {
		err = nil
	}
	return found, err
}

// PBXCredential returns one device's line with its secret. The single way a
// credential leaves this package, alongside PBXCredentials.
func (s *Store) PBXCredential(deviceID string) (PBXCredential, bool, error) {
	s.mu.RLock()
	r, ok := s.devices[deviceID]
	var (
		rec  lineRecord
		user string
	)
	if ok && r.PBXLine != nil {
		rec, user = *r.PBXLine, r.User
	} else {
		ok = false
	}
	s.mu.RUnlock()
	if !ok {
		return PBXCredential{}, false, nil
	}
	c, err := s.credential(deviceID, user, rec)
	if err != nil {
		return PBXCredential{}, false, err
	}
	return c, true, nil
}

// PBXCredentials returns every line the server should register, for the
// registrar to hold.
//
// A **revoked** device is left out: its phone cannot connect, so keeping its
// line registered would have the exchange ring a number nobody can answer
// for the full ring timeout. A device that simply has not enrolled yet is
// included — that is a line an administrator has deliberately provisioned,
// and it will be answered as soon as the phone is in someone's hand.
//
// One line failing to decrypt does not hide the rest: the error names the
// device and the others are still returned, because the other lines should not go
// dark over one bad record.
func (s *Store) PBXCredentials() ([]PBXCredential, error) {
	type pending struct {
		deviceID, user string
		rec            lineRecord
	}
	s.mu.RLock()
	list := make([]pending, 0, len(s.devices))
	for id, r := range s.devices {
		// A holder beyond the seats is left out like a revoked device:
		// its line must not be registered for the exchange to ring a
		// phone that is refused everywhere else (SPEC §4.9).
		if r.PBXLine == nil || r.Revoked || s.unlicensed[id] {
			continue
		}
		list = append(list, pending{id, r.User, *r.PBXLine})
	}
	s.mu.RUnlock()

	out := make([]PBXCredential, 0, len(list))
	var errs []error
	for _, p := range list {
		c, err := s.credential(p.deviceID, p.user, p.rec)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		out = append(out, c)
	}
	sortCredentials(out)
	return out, errors.Join(errs...)
}

// credential unseals one stored line.
func (s *Store) credential(deviceID, user string, rec lineRecord) (PBXCredential, error) {
	if s.Secrets == nil {
		return PBXCredential{}, ErrNoSecretKey
	}
	secret, err := s.Secrets.Open(deviceID, rec.SecretEnc)
	if err != nil {
		return PBXCredential{}, fmt.Errorf("enroll: PBX credential for %s: %w", deviceID, err)
	}
	dn := rec.DN
	if dn == "" {
		dn = user
	}
	return PBXCredential{
		DeviceID: deviceID, User: user, DN: dn,
		DigestUser: rec.DigestUser, Secret: secret, Port: rec.Port,
	}, nil
}

// PBXLinePorts is the PBX-leg socket each stored line holds, by device,
// for allocating a free one. Lines on the shared socket (0) and devices
// with no line are left out; a revoked device's line is in, since the
// record keeps its port for the phone that re-enrols.
func (s *Store) PBXLinePorts() map[string]int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := map[string]int{}
	for id, r := range s.devices {
		if r.PBXLine != nil && r.PBXLine.Port != 0 {
			out[id] = r.PBXLine.Port
		}
	}
	return out
}

func (r *lineRecord) view() PBXLine {
	return PBXLine{DN: r.DN, DigestUser: r.DigestUser, Configured: true, UpdatedAt: r.UpdatedAt, Port: r.Port}
}

func sortCredentials(c []PBXCredential) {
	sort.Slice(c, func(i, j int) bool { return c[i].DeviceID < c[j].DeviceID })
}
