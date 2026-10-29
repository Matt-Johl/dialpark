// Package pbxline keeps this server registered to a PBX as one third-party
// SIP device per app device (SPEC §6 item 3c).
//
// The server registers, never the app. A phone holding the PBX credential
// would be the registered endpoint, so the PBX would send its INVITE to a
// contact that stops existing the moment iOS suspends the app — the problem
// this product exists to solve (§2). So the lines here are held around the
// clock whatever the phones are doing, the INVITE always lands on a live
// element, and the wake path is untouched.
//
// This package owns the *timing and the state* of those registrations: when
// to refresh, how long to back off, when to give up. The SIP itself is
// behind the Registrar seam, as trunkQualifier's probe is (b2bua/qualify.go),
// so the machine that decides all of that is testable without a SIP stack.
package pbxline

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/rand"
	"slices"
	"strings"
	"sync"
	"time"
)

// Line is one device's line on the PBX: the local extension it is known by
// here, the directory number the PBX knows it as, and the digest credential
// the PBX issued for it.
type Line struct {
	// User is the local extension — the device's registry user, what the
	// app registers to us as and what routing resolves.
	User string
	// DN is the directory number on the PBX. Normally identical to User;
	// they differ only where a deployment's CUCM numbering does not match
	// the extension the app dials as.
	DN string
	// DigestUser is the PBX-side credential username (on CUCM, the End
	// User named as the device's Digest User — not the DN).
	DigestUser string
	// Secret is that credential's password. It never leaves this server:
	// it is not pushed to a device and no admin read returns it.
	Secret string
	// Port is the PBX-leg socket this line registers from and is called
	// on, when the server gives each line one (b2bua.PortRange). 0 is the
	// shared trunk socket. An exchange binds a third-party device to the
	// address it registers from, so a line that moves port is unregistered
	// from the old one first.
	Port int
}

// normalised fills DN from User, which is the usual case.
func (l Line) normalised() Line {
	if l.DN == "" {
		l.DN = l.User
	}
	return l
}

// sameCredential reports whether two lines would produce the same
// registration. A write that changes nothing must not disturb a live line.
func (l Line) sameCredential(o Line) bool {
	return l.DN == o.DN && l.DigestUser == o.DigestUser && l.Secret == o.Secret
}

// State is what a line's registration is doing.
type State string

const (
	// StatePending is a line whose first REGISTER has not been sent yet.
	StatePending State = "pending"
	// StateRegistered is a line the PBX has accepted and which is being
	// refreshed before it expires.
	StateRegistered State = "registered"
	// StateRetrying is a line whose REGISTER failed for a reason that may
	// pass — the PBX is down, the network is out, a 5xx.
	StateRetrying State = "retrying"
	// StateRefused is a line the PBX rejected on its merits: a wrong
	// credential, an unknown line. Retrying cannot fix it, so the loop
	// stops until an administrator changes the credential.
	StateRefused State = "refused"
)

// Status is one line's registration as the admin API reports it. It never
// carries the secret.
type Status struct {
	User       string    `json:"user"`
	DN         string    `json:"dn"`
	DigestUser string    `json:"digest_user"`
	State      State     `json:"state"`
	Since      time.Time `json:"since"`
	// ExpiresAt is when the registration we hold lapses; zero unless
	// registered.
	ExpiresAt time.Time `json:"expires_at,omitempty"`
	// Realm is what the PBX challenged with, kept for diagnostics: a realm
	// that is not what the operator expected is the usual first sign of a
	// credential provisioned against the wrong cluster.
	Realm string `json:"realm,omitempty"`
	// Error is why the line is retrying or refused.
	Error string `json:"error,omitempty"`
	// Attempts is how many consecutive failures the line has seen.
	Attempts int `json:"attempts,omitempty"`
	// Port is the PBX-leg socket the line holds; 0 on the shared socket.
	Port int `json:"port,omitempty"`
}

// Registration is what the PBX granted.
type Registration struct {
	// Expiry is the lifetime the PBX gave us, which may be shorter than
	// the one we asked for; the refresh follows it, not our request.
	Expiry time.Duration
	// Realm is the realm it challenged with, empty if it did not challenge.
	Realm string
}

// Registrar sends one REGISTER for a line and reports what came back. It
// owns the SIP and the digest exchange; this package owns everything else.
//
// A refusal on the credential's merits — a challenge answered and refused
// again, a line the PBX does not have — must be reported as *Refused so the
// loop stops instead of hammering the exchange. Every other error is taken
// as transient.
type Registrar interface {
	Register(ctx context.Context, l Line, expiry time.Duration) (Registration, error)
	// Unregister drops the line's contact (Expires: 0). Best effort, at
	// shutdown and when a line is removed, so the PBX does not ring a
	// contact we have stopped listening on.
	Unregister(ctx context.Context, l Line) error
}

// Refused is a final refusal: the credential or the line is wrong and
// retrying cannot change that.
type Refused struct {
	Status int
	Reason string
}

func (e *Refused) Error() string {
	return fmt.Sprintf("pbx refused the registration: %d %s", e.Status, e.Reason)
}

// Config is the manager's wiring. Every duration has a working default, and
// the two sources of non-determinism — the clock and the jitter — are
// injected so the loop can be tested without waiting on either.
type Config struct {
	Registrar Registrar
	// Expiry is the registration lifetime we ask for (default 1 hour).
	Expiry time.Duration
	// MinRefresh floors the refresh interval, so a PBX granting a very
	// short expiry cannot turn the lines into a REGISTER storm.
	MinRefresh time.Duration
	// BackoffBase and BackoffCap bound the retry interval after a
	// transient failure (defaults 5 s and 30 s). The cap was five minutes
	// until 2026-10-22: right against a wrong password, which latches and
	// never retries anyway, and wrong against a dead link — a line stayed
	// unregistered for up to five minutes after the network returned, on
	// an exchange whose lease is sixty seconds. A REGISTER every thirty
	// seconds per line while the registrar is unreachable costs nothing.
	BackoffBase, BackoffCap time.Duration
	// Ports is the PBX-leg port range when each line has a socket of its
	// own; the manager does not allocate from it (the device store keeps
	// each line's port, cmd/dialpark-server), it carries it for whoever
	// puts lines here. Zero: one shared socket.
	Ports PortRange
	// RegistrarDebounce is the least time between a retrying line's last
	// attempt and one prompted by RegistrarSeen (default 5 s), so a burst
	// of traffic from the exchange prompts one attempt, not one per packet.
	RegistrarDebounce time.Duration
	// StartSpread is the window the first REGISTER of each line is
	// scattered over, so lines coming up together do not stampede one PBX node
	// (default 5 s).
	StartSpread time.Duration
	// UnregisterTimeout bounds the best-effort Expires:0 at shutdown.
	UnregisterTimeout time.Duration
	// Tick is how often the manager compares the time of day with each
	// line's refresh deadline (default 10 s). The refresh itself waits on a
	// timer, and a Go timer counts only time the machine is awake: on macOS
	// it runs on mach_absolute_time, on Linux on CLOCK_MONOTONIC, and both
	// stand still through a system sleep. The PBX's lease does not. After a
	// sleep longer than the quarter of the lease kept in hand, the contact
	// has lapsed before the timer fires, and every call to the line fails
	// at the PBX with no trace here (2026-10-02 15:21–15:24: an 18-minute
	// clamshell sleep, a three-minute hole, two calls refused). The tick is
	// what notices the clock has moved on; it costs one comparison per line
	// and acts only when a deadline has passed, so it is idle on a machine
	// that never sleeps. It bounds how long after a wake the lines are
	// re-registered.
	Tick time.Duration
	Log  *slog.Logger
	// Now and Rand are seams for tests. Rand returns a value in [0,1).
	Now  func() time.Time
	Rand func() float64
	// OnState, if set, is told each line state change (for the event ring).
	OnState func(Status)
}

func (c *Config) applyDefaults() {
	if c.Expiry <= 0 {
		c.Expiry = time.Hour
	}
	if c.MinRefresh <= 0 {
		c.MinRefresh = 5 * time.Second
	}
	if c.BackoffBase <= 0 {
		c.BackoffBase = 5 * time.Second
	}
	if c.BackoffCap <= 0 {
		c.BackoffCap = 30 * time.Second
	}
	if c.RegistrarDebounce < 0 {
		c.RegistrarDebounce = 0
	} else if c.RegistrarDebounce == 0 {
		c.RegistrarDebounce = 5 * time.Second
	}
	if c.StartSpread < 0 {
		c.StartSpread = 0
	}
	if c.UnregisterTimeout <= 0 {
		c.UnregisterTimeout = 2 * time.Second
	}
	if c.Tick <= 0 {
		c.Tick = 10 * time.Second
	}
	if c.Log == nil {
		c.Log = slog.Default()
	}
	if c.Now == nil {
		c.Now = time.Now
	}
	if c.Rand == nil {
		c.Rand = rand.Float64
	}
}

// Manager holds every device's line. It is safe for concurrent use, and its
// read-only accessors are safe on a nil receiver so a caller in trunk mode
// (where no manager exists) needs no special case.
type Manager struct {
	cfg Config

	mu        sync.Mutex
	lines     map[string]*line // by Line.User
	ctx       context.Context  // non-nil once started
	started   bool
	wg        sync.WaitGroup
	stopSweep context.CancelFunc // ends the clock watcher; non-nil once started
}

// line is one registration's goroutine and the state it publishes.
type line struct {
	mu     sync.Mutex
	cur    Line
	status Status

	// wake carries "the credential changed, register again now"; buffered
	// so a write never blocks on a loop that is mid-REGISTER.
	wake chan struct{}
	// until is the time of day the loop's current wait is due to end; zero
	// while it is not waiting. late carries "that moment has passed on the
	// wall clock though your timer has not fired" from the manager's sweep
	// (Config.Tick). It is a channel of its own, not wake: a late token that
	// outlived a wait the timer had already ended would otherwise be read
	// as a credential change and send a REGISTER for nothing.
	until  time.Time
	late   chan struct{}
	cancel context.CancelFunc
	// lastAttempt is when the loop last sent a REGISTER (RegistrarSeen's
	// debounce).
	lastAttempt time.Time
}

// New builds a manager. Nothing registers until Start.
func New(cfg Config) *Manager {
	cfg.applyDefaults()
	return &Manager{cfg: cfg, lines: map[string]*line{}}
}

// Start begins registering every line configured so far, and every line
// added from here on. It returns immediately; Stop waits for the loops.
func (m *Manager) Start(ctx context.Context) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.started {
		return
	}
	m.started, m.ctx = true, ctx
	for _, l := range m.lines {
		m.startLocked(l)
	}
	sctx, stop := context.WithCancel(ctx)
	m.stopSweep = stop
	m.wg.Add(1)
	go m.sweep(sctx)
	m.cfg.Log.Info("pbx lines: registering", "lines", len(m.lines), "expiry", m.cfg.Expiry)
}

// Stop cancels every line's loop and waits for it, dropping each contact on
// the way out so the PBX does not ring a line we have stopped serving.
func (m *Manager) Stop() {
	m.mu.Lock()
	running := m.started
	lines := make([]Line, 0, len(m.lines))
	for _, l := range m.lines {
		if l.cancel != nil {
			l.cancel()
		}
		lines = append(lines, l.snapshot())
	}
	if m.stopSweep != nil {
		m.stopSweep()
	}
	m.started = false
	m.mu.Unlock()
	m.wg.Wait()
	if !running {
		return
	}
	// Drop the bindings. Without this the exchange goes on sending calls to
	// a contact nothing is listening on until the registration expires —
	// up to an hour of callers ringing out for no reason. Concurrently and
	// best effort: each is bounded, and a PBX that has itself gone away
	// must not hold up the shutdown once per line.
	var wg sync.WaitGroup
	for _, l := range lines {
		wg.Add(1)
		go func(l Line) {
			defer wg.Done()
			m.unregister(l)
		}(l)
	}
	wg.Wait()
}

// Set replaces the configured lines wholesale — the device store's view at
// start-up. Lines that are unchanged are left running untouched: re-setting
// an identical set of lines must not drop a single registration.
func (m *Manager) Set(lines []Line) {
	keep := make(map[string]bool, len(lines))
	for _, l := range lines {
		keep[l.User] = true
		m.Put(l)
	}
	m.mu.Lock()
	var gone []string
	for user := range m.lines {
		if !keep[user] {
			gone = append(gone, user)
		}
	}
	m.mu.Unlock()
	for _, user := range gone {
		m.Delete(user)
	}
}

// Put adds a line or replaces one. A write that changes nothing is a no-op;
// a write that changes the credential re-registers that line at once and
// clears a refusal, which is how an administrator fixes a wrong password.
func (m *Manager) Put(in Line) {
	l := in.normalised()
	if l.User == "" {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if ex, ok := m.lines[l.User]; ok {
		ex.mu.Lock()
		unchanged := ex.cur.sameCredential(l) && ex.cur.Port == l.Port
		was := ex.cur
		ex.cur = l
		ex.status.DN, ex.status.DigestUser, ex.status.Port = l.DN, l.DigestUser, l.Port
		ex.mu.Unlock()
		if was.Port != l.Port && m.started && was.Port != 0 {
			// The exchange holds this line's binding against the old
			// socket's address: drop it there, or it stays bound to a
			// socket this line no longer answers on until it lapses.
			go m.unregister(was)
		}
		if !unchanged {
			ex.signal()
		}
		return
	}
	n := &line{cur: l, wake: make(chan struct{}, 1), late: make(chan struct{}, 1)}
	n.status = Status{User: l.User, DN: l.DN, DigestUser: l.DigestUser, State: StatePending, Since: m.cfg.Now(), Port: l.Port}
	m.lines[l.User] = n
	if m.started {
		m.startLocked(n)
	}
}

// Delete stops a line and drops its contact on the PBX.
func (m *Manager) Delete(user string) {
	m.mu.Lock()
	l, ok := m.lines[user]
	if ok {
		delete(m.lines, user)
	}
	started := m.started
	m.mu.Unlock()
	if !ok {
		return
	}
	if l.cancel != nil {
		l.cancel()
	}
	if !started {
		return
	}
	go m.unregister(l.snapshot())
}

// startLocked launches one line's loop. m.mu is held.
func (m *Manager) startLocked(l *line) {
	if l.cancel != nil {
		return
	}
	ctx, cancel := context.WithCancel(m.ctx)
	l.cancel = cancel
	m.wg.Add(1)
	go m.run(ctx, l)
}

// Ports is the configured PBX-leg port range, zero on one shared socket.
// Nil-safe.
func (m *Manager) Ports() PortRange {
	if m == nil {
		return PortRange{}
	}
	return m.cfg.Ports
}

// Credentials returns the digest credential to answer a PBX challenge for a
// call placed on this user's behalf. Nil-safe: trunk mode has no manager.
func (m *Manager) Credentials(user string) (digestUser, secret string, ok bool) {
	if m == nil {
		return "", "", false
	}
	m.mu.Lock()
	l, found := m.lines[user]
	m.mu.Unlock()
	if !found {
		return "", "", false
	}
	c := l.snapshot()
	if c.DigestUser == "" {
		return "", "", false
	}
	return c.DigestUser, c.Secret, true
}

// Number returns the directory number a call from this user must present as
// its calling party. Nil-safe.
func (m *Manager) Number(user string) (string, bool) {
	if m == nil {
		return "", false
	}
	m.mu.Lock()
	l, ok := m.lines[user]
	m.mu.Unlock()
	if !ok {
		return "", false
	}
	return l.snapshot().DN, true
}

// Port returns the PBX-leg socket this user's line holds (0 on the shared
// socket). ok is false for a user with no line. Nil-safe.
func (m *Manager) Port(user string) (int, bool) {
	if m == nil {
		return 0, false
	}
	m.mu.Lock()
	l, ok := m.lines[user]
	m.mu.Unlock()
	if !ok {
		return 0, false
	}
	return l.snapshot().Port, true
}

// UserAtPort returns the user whose line holds the PBX-leg socket on port:
// how a request the exchange sent to that socket is attributed to its line.
// ok is false for a port no line holds, and always for 0. Nil-safe.
func (m *Manager) UserAtPort(port int) (string, bool) {
	if m == nil || port == 0 {
		return "", false
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	for user, l := range m.lines {
		if l.snapshot().Port == port {
			return user, true
		}
	}
	return "", false
}

// Statuses reports every line, ordered by user. Nil-safe.
func (m *Manager) Statuses() []Status {
	if m == nil {
		return nil
	}
	m.mu.Lock()
	out := make([]Status, 0, len(m.lines))
	for _, l := range m.lines {
		out = append(out, l.state())
	}
	m.mu.Unlock()
	sortStatuses(out)
	return out
}

// Status reports one line. Nil-safe.
func (m *Manager) Status(user string) (Status, bool) {
	if m == nil {
		return Status{}, false
	}
	m.mu.Lock()
	l, ok := m.lines[user]
	m.mu.Unlock()
	if !ok {
		return Status{}, false
	}
	return l.state(), true
}

// ---- the loop ---------------------------------------------------------------

// run keeps one line registered until ctx ends.
//
// Logging follows the qualifier's discipline: transitions, not every
// failure. A PBX that is down says so once and once more when it returns.
func (m *Manager) run(ctx context.Context, l *line) {
	defer m.wg.Done()

	log := m.cfg.Log.With("line", l.snapshot().User)
	// Scatter the first REGISTERs: fifty lines coming up together
	// would otherwise arrive at one PBX node in the same millisecond.
	if d := time.Duration(m.cfg.Rand() * float64(m.cfg.StartSpread)); d > 0 {
		if ok, _ := m.wait(ctx, l, d); !ok {
			return
		}
	}

	attempt := 0
	late := false // the last wait ended because the sweep found it overdue
	for {
		cur := l.snapshot()
		if late {
			// The time of day jumped past the refresh: the machine slept.
			// If it slept past the lease too, the PBX has had no contact
			// for this line since then and every call to it has failed;
			// say so, since nothing else here can see it (the state stayed
			// "registered" throughout — the last REGISTER had succeeded).
			if st := l.state(); st.State == StateRegistered && !st.ExpiresAt.IsZero() {
				if now := m.cfg.Now(); now.After(st.ExpiresAt) {
					log.Warn("pbx line: lease ran out before the refresh was sent; the clock jumped past it (system sleep?); re-registering now",
						"dn", cur.DN, "lapsed", now.Sub(st.ExpiresAt).Round(time.Second))
				}
			}
			// Lines waking from one sleep are due all at once; spread the
			// catch-up as a start is spread. Zero by default: a lapsed line
			// has already waited long enough.
			if d := time.Duration(m.cfg.Rand() * float64(m.cfg.StartSpread)); d > 0 {
				if ok, _ := m.wait(ctx, l, d); !ok {
					return
				}
			}
		}
		l.mu.Lock()
		l.lastAttempt = m.cfg.Now()
		l.mu.Unlock()
		reg, err := m.cfg.Registrar.Register(ctx, cur, m.cfg.Expiry)
		if ctx.Err() != nil {
			return
		}

		// errors.As rather than a type switch: a Registrar is free to wrap
		// its refusal in context, and a refusal that went unrecognised
		// would be retried for ever against an exchange that has already
		// said no.
		// One reading of the clock for the outcome and for the wait that
		// follows it: the refresh is due a fixed time after the moment the
		// lease began, so its deadline is taken from that moment, not from
		// a later look at a clock that may already have moved on.
		now := m.cfg.Now()
		var refused *Refused
		var wait time.Duration
		switch {
		case err == nil:
			granted := reg.Expiry
			if granted <= 0 {
				granted = m.cfg.Expiry
			}
			was := l.state().State
			l.registered(now, granted, reg.Realm)
			m.stateChanged(l)
			if was != StateRegistered {
				attrs := []any{"dn", cur.DN, "expiry", granted, "realm", reg.Realm}
				if cur.Port != 0 {
					attrs = append(attrs, "port", cur.Port)
				}
				log.Info("pbx line: registered", attrs...)
			}
			attempt = 0
			wait = refreshAfter(granted, m.cfg.MinRefresh)

		case errors.As(err, &refused):
			l.refused(now, refused)
			m.stateChanged(l)
			log.Warn("pbx line: refused; not retrying until the credential changes",
				"dn", cur.DN, "digest_user", cur.DigestUser, "status", refused.Status, "reason", refused.Reason)
			// Nothing but an administrator can help now. Park until the
			// credential changes (Put signals) or the server stops.
			if !m.waitForChange(ctx, l) {
				return
			}
			attempt = 0
			continue

		default:
			attempt++
			if l.state().State != StateRetrying {
				log.Warn("pbx line: registration failed; retrying", "dn", cur.DN, "err", err)
			}
			l.retrying(now, err, attempt)
			m.stateChanged(l)
			wait = m.jittered(backoff(attempt, m.cfg.BackoffBase, m.cfg.BackoffCap))
		}

		var ok bool
		if ok, late = m.waitUntil(ctx, l, now.Add(wait)); !ok {
			return
		}
	}
}

// wait sleeps for d from now; see waitUntil.
func (m *Manager) wait(ctx context.Context, l *line, d time.Duration) (ok, late bool) {
	if d <= 0 {
		return ctx.Err() == nil, false
	}
	return m.waitUntil(ctx, l, m.cfg.Now().Add(d))
}

// waitUntil sleeps until the time of day `until`, returning ok=false if the
// server stopped. A credential change cuts the wait short: a corrected
// password should take effect now, not at the next refresh. So does the
// sweep finding `until` already behind the time of day (late=true): the
// timer slept on counts only time the machine is awake, so after a system
// sleep it would fire as much later as the machine slept, while the PBX's
// lease ran on. A deadline already past on entry is late at once.
func (m *Manager) waitUntil(ctx context.Context, l *line, until time.Time) (ok, late bool) {
	d := until.Sub(m.cfg.Now())
	if d <= 0 {
		return ctx.Err() == nil, true
	}
	l.armDeadline(until)
	defer l.disarmDeadline()
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false, false
	case <-l.wake:
		return true, false
	case <-l.late:
		return true, true
	case <-t.C:
		return true, false
	}
}

// sweep is the manager's one clock watcher: every Tick it compares the time
// of day with each waiting line's deadline and wakes the lines whose moment
// has passed (see Config.Tick). One ticker for all lines, one comparison per
// line per tick, and nothing to do unless the clock has jumped.
func (m *Manager) sweep(ctx context.Context) {
	defer m.wg.Done()
	t := time.NewTicker(m.cfg.Tick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		now := m.cfg.Now()
		overdue := 0
		m.mu.Lock()
		for _, l := range m.lines {
			if l.flagIfOverdue(now) {
				overdue++
			}
		}
		m.mu.Unlock()
		if overdue > 0 {
			m.cfg.Log.Info("pbx lines: refresh overdue on the wall clock; the clock jumped past it (system sleep?); re-registering now", "lines", overdue, "tick", m.cfg.Tick)
		}
	}
}

// waitForChange blocks a refused line until its credential changes.
func (m *Manager) waitForChange(ctx context.Context, l *line) bool {
	select {
	case <-ctx.Done():
		return false
	case <-l.wake:
		return true
	}
}

// RegistrarSeen says the exchange has just been heard from — a request it
// sent us, a response to something we sent it — so a line that is retrying
// because it could not be reached should try again now rather than at the
// end of its backoff. Lines that are registered or refused are left alone:
// a refused line waits for a new credential, and nothing else.
//
// Why this exists: on 2026-10-22 the link to CUCM went down for twenty
// minutes; the line's REGISTERs timed out one after another and the retry
// interval climbed to its cap, so when the link came back the next attempt
// was minutes away — while an INVITE from the app had already reached the
// exchange and been answered. The answer was the proof; nothing read it.
//
// Safe on a nil receiver, like the other accessors.
func (m *Manager) RegistrarSeen() {
	if m == nil {
		return
	}
	now := m.cfg.Now()
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, l := range m.lines {
		l.mu.Lock()
		retrying := l.status.State == StateRetrying && now.Sub(l.lastAttempt) >= m.cfg.RegistrarDebounce
		dn := l.cur.DN
		l.mu.Unlock()
		if retrying {
			m.cfg.Log.Info("pbx line: the exchange is reachable again; re-registering now", "line", l.cur.User, "dn", dn)
			l.signal()
		}
	}
}

// Unregistered says the exchange has answered a request on this user's
// line with "I do not know this device" — CUCM's 503 with Warning 399
// "Unable to find a device handler" — so whatever this side believes, the
// line is not registered there and is re-registered now. A refused line is
// left alone, as in RegistrarSeen. Safe on a nil receiver.
func (m *Manager) Unregistered(user string) {
	if m == nil {
		return
	}
	m.mu.Lock()
	l, ok := m.lines[user]
	m.mu.Unlock()
	if !ok {
		return
	}
	l.mu.Lock()
	st := l.status.State
	dn := l.cur.DN
	l.mu.Unlock()
	if st == StateRefused {
		return
	}
	m.cfg.Log.Warn("pbx line: the exchange says this line is not registered; re-registering now", "line", user, "dn", dn, "was", st)
	l.signal()
}

// unregister drops one line's contact, bounded and best effort.
func (m *Manager) unregister(l Line) {
	ctx, cancel := context.WithTimeout(context.Background(), m.cfg.UnregisterTimeout)
	defer cancel()
	if err := m.cfg.Registrar.Unregister(ctx, l); err != nil {
		m.cfg.Log.Debug("pbx line: unregister failed", "line", l.User, "err", err)
	}
}

// jittered spreads a retry by ±20 % so lines that failed together do not
// retry together.
func (m *Manager) jittered(d time.Duration) time.Duration {
	return time.Duration(float64(d) * (0.8 + 0.4*m.cfg.Rand()))
}

// refreshAfter is when to re-register given the lifetime the PBX granted:
// three quarters of it, leaving a full quarter to retry in before the
// contact lapses, and never below the floor.
func refreshAfter(granted, floor time.Duration) time.Duration {
	d := granted * 3 / 4
	if d < floor {
		return floor
	}
	return d
}

// backoff is the interval before retry number n (1-based): the base,
// doubling, capped.
func backoff(attempt int, base, limit time.Duration) time.Duration {
	if attempt < 1 {
		attempt = 1
	}
	d := base
	for i := 1; i < attempt; i++ {
		d *= 2
		if d >= limit {
			return limit
		}
	}
	if d > limit {
		return limit
	}
	return d
}

// ---- line state -------------------------------------------------------------

func (l *line) snapshot() Line {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.cur
}

func (l *line) state() Status {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.status
}

// signal asks the loop to register again now.
func (l *line) signal() {
	select {
	case l.wake <- struct{}{}:
	default:
	}
}

// armDeadline records the time of day the current wait is due to end.
func (l *line) armDeadline(t time.Time) {
	l.mu.Lock()
	l.until = t
	l.mu.Unlock()
}

// disarmDeadline clears it and discards any late token, under the same lock
// the sweep checks and sends under, so a token can never outlive its wait.
func (l *line) disarmDeadline() {
	l.mu.Lock()
	l.until = time.Time{}
	select {
	case <-l.late:
	default:
	}
	l.mu.Unlock()
}

// flagIfOverdue wakes the loop if its wait is due by the time of day, once
// per wait: the deadline is cleared as the token is sent.
func (l *line) flagIfOverdue(now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.until.IsZero() || now.Before(l.until) {
		return false
	}
	l.until = time.Time{}
	select {
	case l.late <- struct{}{}:
	default:
	}
	return true
}

func (l *line) registered(now time.Time, granted time.Duration, realm string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.status.State != StateRegistered {
		l.status.Since = now
	}
	l.status.State = StateRegistered
	l.status.ExpiresAt = now.Add(granted)
	l.status.Error, l.status.Attempts = "", 0
	if realm != "" {
		l.status.Realm = realm
	}
}

func (l *line) retrying(now time.Time, err error, attempt int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.status.State != StateRetrying {
		l.status.Since = now
	}
	l.status.State = StateRetrying
	l.status.ExpiresAt = time.Time{}
	l.status.Error, l.status.Attempts = err.Error(), attempt
}

func (l *line) refused(now time.Time, err *Refused) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.status.State != StateRefused {
		l.status.Since = now
	}
	l.status.State = StateRefused
	l.status.ExpiresAt = time.Time{}
	l.status.Error = err.Error()
}

// stateChanged tells Config.OnState, if set, a line's new state.
func (m *Manager) stateChanged(l *line) {
	if m.cfg.OnState != nil {
		m.cfg.OnState(l.state())
	}
}

// sortStatuses orders by user, so the admin API and the logs are stable.
func sortStatuses(s []Status) {
	slices.SortFunc(s, func(a, b Status) int { return strings.Compare(a.User, b.User) })
}
