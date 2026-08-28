package daemon

// The daemon owns the entire licensing surface: it talks to the Cloudflare
// entitlement worker (the app never holds a Stripe key), writes the signed
// grant into the NON-synchronizable dev.llmpilot.entitlement Keychain item as
// its SOLE writer (advisor verdict 2026-07-12), and pushes state so the menu
// bar and cockpit react live. Everything here is nil-safe: builds and tests
// that do not sell Pro leave d.License nil and every handler answers 501.

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/alicicek/llmpilot/internal/pilot"
)

// EntitlementClient is the daemon's link to the entitlement worker. Every call
// is one JSON POST. Injected so daemon tests drive a stub, never the network.
type EntitlementClient interface {
	// Quote returns the worker's pre-checkout consent terms verbatim — the
	// daemon proxies, never interprets, what the paywall renders.
	Quote(ctx context.Context) (json.RawMessage, error)
	// Checkout forwards the client's quote echo untouched; the worker is the
	// boundary that validates consent, so the daemon adds no meaning to it.
	// remindDaysBefore is the buyer's reminder-timing choice (1 or 2 days
	// before the charge); 0 means unset and the worker applies its default.
	Checkout(ctx context.Context, rung, ui string, quote json.RawMessage, remindDaysBefore int) (CheckoutResult, error)
	Activate(ctx context.Context, sessionID string) (LicenseView, error)
	Cancel(ctx context.Context, licenseID string) (LicenseView, error)
	Recover(ctx context.Context, email string) error
	ClaimRecovery(ctx context.Context, token string) (LicenseView, error)
}

// CheckoutResult is the worker's /v1/checkout answer the app acts on: a URL to
// open (a Stripe-hosted session URL, or our /checkout host page) plus the
// session id the activation poller confirms against.
type CheckoutResult struct {
	SessionID string
	License   string
	URL       string
}

// LicenseView projects the worker's license row. Pending marks a checkout that
// is not paid yet (keep polling). Entitlement is the signed capability token,
// served only for trialing/lifetime — it is written to the Keychain, never
// logged.
type LicenseView struct {
	License     string
	Status      string
	TrialEnd    *time.Time
	Entitlement string
	Pending     bool
	// Declined marks a pending answer whose buyer backed out of the hosted
	// checkout (the worker recorded the cancel_url hit). It rides pending —
	// a later payment supersedes it and arrives as a plain non-pending view.
	Declined bool
	// SessionExpired marks a pending answer whose Stripe session can never
	// pay again — the poll has nothing left to watch or reconcile.
	SessionExpired bool
}

// validRungs are the decline-ladder rungs the worker accepts.
var validRungs = map[string]struct{}{
	"full": {}, "discount_trial": {}, "nocard_trial": {},
}

// LicenseGate bundles the licensing dependencies. The daemon holds one at
// d.License; its handlers orchestrate. It carries no Stripe knowledge — only
// the worker client, the offline LicenseManager (whose Keychain store it also
// writes), and the verify keyring.
type LicenseGate struct {
	// Manager provides the offline grant view and owns the shared Keychain
	// store the gate reads and writes.
	Manager *pilot.LicenseManager
	Client  EntitlementClient
	// Keyring verifies worker-minted tokens before they are persisted
	// (nil → derived from Manager.Keys, else the embedded keyring).
	Keyring func() (map[string]ed25519.PublicKey, error)
	Now     func() time.Time
	// Available is true only when the autopilot engine is compiled in (official
	// builds). Source builds leave it false: checkout/cancel/recover answer 501
	// and GET /v1/license reports status "unavailable".
	Available bool
	// PollEvery/PollFor tune the background activation poller (defaults 3s/10m).
	PollEvery time.Duration
	PollFor   time.Duration
	// ReconcileEvery/ReconcileFor tune the slow phase AFTER the abandoned
	// verdict (defaults 60s/24h): the Stripe session stays payable for its
	// full 24h life (owner: come-back-later buyers keep their tab), so a
	// late payment must still find its way to a local grant instead of
	// stranding a paid buyer (money review 2026-08-27 F3).
	ReconcileEvery time.Duration
	ReconcileFor   time.Duration

	mu         sync.Mutex
	marker     bool               // native no-card-trial marker reported at launch
	pollCancel context.CancelFunc // supersede a prior activation poll
}

func (g *LicenseGate) now() time.Time {
	if g.Now != nil {
		return g.Now()
	}
	return time.Now()
}

func (g *LicenseGate) pollEvery() time.Duration {
	if g.PollEvery > 0 {
		return g.PollEvery
	}
	return 3 * time.Second
}

func (g *LicenseGate) pollFor() time.Duration {
	if g.PollFor > 0 {
		return g.PollFor
	}
	return 10 * time.Minute
}

func (g *LicenseGate) reconcileEvery() time.Duration {
	if g.ReconcileEvery > 0 {
		return g.ReconcileEvery
	}
	return 60 * time.Second
}

func (g *LicenseGate) reconcileFor() time.Duration {
	if g.ReconcileFor > 0 {
		return g.ReconcileFor
	}
	return 24 * time.Hour
}

func (g *LicenseGate) markerPresent() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.marker
}

// keyring mirrors the LicenseManager's verifier set so GET's offline verify and
// Manager.Allowed never disagree about which keys are trusted.
func (g *LicenseGate) keyring() (map[string]ed25519.PublicKey, error) {
	if g.Keyring != nil {
		return g.Keyring()
	}
	if g.Manager != nil && g.Manager.Keys != nil {
		out := make(map[string]ed25519.PublicKey, len(g.Manager.Keys))
		for id, raw := range g.Manager.Keys {
			if len(raw) != ed25519.PublicKeySize {
				return nil, pilot.ErrInvalidEntitlement
			}
			out[id] = ed25519.PublicKey(raw)
		}
		return out, nil
	}
	return pilot.EmbeddedKeyring()
}

// trialInfo is the honest trial detail the paywall and Settings render:
// consumer-law checklist (a) — exact length and charge date.
type trialInfo struct {
	EndsAt     time.Time  `json:"ends_at"`
	ChargeDate *time.Time `json:"charge_date,omitempty"`
	DaysLeft   int        `json:"days_left"`
}

// licenseInfo is GET /v1/license. It NEVER carries the entitlement token; the
// full license id appears only under ?reveal=1 (the Settings copy affordance).
type licenseInfo struct {
	Available bool `json:"available"`
	// Active is whether Pro features are ON right now, evaluated offline.
	Active          bool       `json:"active"`
	Status          string     `json:"status"` // none|trialing|lifetime|lapsed|revoked|unavailable
	Kind            string     `json:"kind,omitempty"`
	// CheckoutOutcome is the live checkout's back-out verdict ("declined" |
	// "abandoned") — the ONLY signal the app's win-back decider arms on.
	CheckoutOutcome string     `json:"checkout_outcome,omitempty"`
	Features        []string   `json:"features,omitempty"`
	Seats           int        `json:"seats,omitempty"`
	ExpiresAt       *time.Time `json:"expires_at,omitempty"`
	Trial           *trialInfo `json:"trial,omitempty"`
	LastValidated   *time.Time `json:"last_validated,omitempty"`
	LicenseID       string     `json:"license_id,omitempty"` // full id, only with ?reveal=1
	LicenseIDMasked string     `json:"license_id_masked,omitempty"`
	NocardTrialUsed bool       `json:"nocard_trial_used"`
	// ErrorCode is the last terminal licensing refusal (machine code only);
	// the cockpit maps it to honest copy.
	ErrorCode string `json:"error_code,omitempty"`
}

func maskLicense(id string) string {
	if id == "" {
		return ""
	}
	if len(id) <= 8 {
		return "lic_••••"
	}
	return "lic_••••" + id[len(id)-4:]
}

// handleLicenseGet computes the current entitlement view from the Keychain store
// plus an offline verify. An expired trial is not an error — it is the honest
// paused state (status stays "trialing", Active is false).
func (d *Daemon) handleLicenseGet(w http.ResponseWriter, r *http.Request) {
	g := d.License
	if g == nil {
		httpError(w, http.StatusNotImplemented, errors.New("licensing not wired"))
		return
	}
	info := licenseInfo{Available: g.Available, Status: "none", NocardTrialUsed: g.markerPresent()}
	d.mu.Lock()
	info.ErrorCode = d.licenseError
	info.CheckoutOutcome = d.checkoutOutcome
	d.mu.Unlock()
	if !g.Available {
		info.Status = "unavailable"
		writeJSON(w, http.StatusOK, info)
		return
	}
	ctx := r.Context()
	now := g.now()
	stored, err := g.Manager.Store.Load(ctx)
	if errors.Is(err, pilot.ErrNoLicense) {
		writeJSON(w, http.StatusOK, info)
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, errors.New("read entitlement"))
		return
	}
	info.Status = stored.Status
	info.LicenseIDMasked = maskLicense(stored.LicenseID)
	// The full id is a bearer capability (the worker's /v1/validate serves
	// the current token for it) — revealing it requires the install token.
	if r.URL.Query().Get("reveal") == "1" {
		if !d.requireAuth(w, r) {
			return
		}
		info.LicenseID = stored.LicenseID
	}
	if !stored.LastValidated.IsZero() {
		lv := stored.LastValidated
		info.LastValidated = &lv
	}
	if keys, kerr := g.keyring(); kerr == nil {
		if payload, verr := pilot.VerifyEntitlement(stored.Entitlement, keys, now); verr == nil {
			info.Kind = strings.ToLower(string(payload.Kind))
			info.Features = payload.Features
			info.Seats = payload.Seats
			info.ExpiresAt = payload.ExpiresAt
		}
	}
	info.Active = g.Manager.Allowed(ctx, "autopilot", now)
	if stored.Status == "trialing" && stored.TrialEnd != nil {
		days := int(math.Ceil(stored.TrialEnd.Sub(now).Hours() / 24))
		if days < 0 {
			days = 0
		}
		end := *stored.TrialEnd
		info.Trial = &trialInfo{EndsAt: end, ChargeDate: &end, DaysLeft: days}
	}
	writeJSON(w, http.StatusOK, info)
}

// handleLicenseCheckout creates a worker checkout session, returns the URL to
// open, and starts a background poller that activates SILENTLY on success.
func (d *Daemon) handleLicenseCheckout(w http.ResponseWriter, r *http.Request) {
	g := d.License
	if g == nil || !g.Available {
		httpError(w, http.StatusNotImplemented, errors.New("this build has no Pro engine — the official app at https://llmpilot.dev sells it"))
		return
	}
	if !d.requireAuth(w, r) {
		return
	}
	if !requireJSON(w, r) {
		return
	}
	var req struct {
		Rung string `json:"rung"`
		UI   string `json:"ui"`
		// Quote is the consent echo, forwarded to the worker verbatim.
		Quote json.RawMessage `json:"quote"`
		// RemindDaysBefore is the buyer's reminder-timing choice; absent
		// leaves the worker's default (the day before the charge).
		RemindDaysBefore *int `json:"remind_days_before"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, errors.New(`body must be {"rung": "full|discount_trial|nocard_trial", "ui?": "hosted|embedded", "quote": {...}, "remind_days_before?": 1|2}`))
		return
	}
	remindDays := 0
	if req.RemindDaysBefore != nil {
		if *req.RemindDaysBefore != 1 && *req.RemindDaysBefore != 2 {
			httpError(w, http.StatusBadRequest, fmt.Errorf("remind_days_before must be 1 or 2, got %d", *req.RemindDaysBefore))
			return
		}
		remindDays = *req.RemindDaysBefore
	}
	rung := req.Rung
	if rung == "" {
		rung = "full"
	}
	if _, ok := validRungs[rung]; !ok {
		httpError(w, http.StatusBadRequest, fmt.Errorf("unknown rung %q", rung))
		return
	}
	// The no-card rung is the bottom of the ladder; a reported synchronizable
	// marker means this Apple ID already used it (advisor verdict item 3).
	if rung == "nocard_trial" && g.markerPresent() {
		httpError(w, http.StatusConflict, errors.New("the no-card trial has already been used on this Apple ID"))
		return
	}
	ui := "embedded"
	if req.UI == "hosted" {
		ui = "hosted"
	}
	res, err := g.Client.Checkout(r.Context(), rung, ui, req.Quote, remindDays)
	if err != nil {
		httpWorkerError(w, err, "checkout could not start — try again")
		d.Log.Warn("license checkout", "rung", rung, "err", err)
		return
	}
	d.startActivationPoll(res.SessionID)
	writeJSON(w, http.StatusOK, map[string]string{"url": res.URL, "session_id": res.SessionID})
}

// startActivationPoll runs one activation poll at a time. A fresh checkout
// supersedes any prior poll so a re-attempt never leaves two loops racing,
// and bumps the generation so the superseded loop can never write a verdict.
func (d *Daemon) startActivationPoll(sessionID string) {
	g := d.License
	g.mu.Lock()
	if g.pollCancel != nil {
		g.pollCancel()
	}
	// Cancel-only (no timeout): the poll owns its own fast/slow deadlines —
	// the ctx dying means SUPERSEDED, nothing else.
	ctx, cancel := context.WithCancel(context.Background())
	g.pollCancel = cancel
	g.mu.Unlock()
	gen := d.beginCheckoutPoll(context.Background())
	// A fresh attempt clears the previous refusal so stale copy never
	// lingers behind a live checkout.
	d.setLicenseError(context.Background(), "")
	go d.activationPoll(ctx, gen, sessionID)
}

// beginCheckoutPoll opens a new verdict generation and clears the previous
// verdict, atomically under d.mu — the same lock every verdict write takes,
// so a superseded poll's late write can never land after this clear
// (money review 2026-08-27 F7: the two-lock check-then-write had a window).
func (d *Daemon) beginCheckoutPoll(ctx context.Context) int {
	d.mu.Lock()
	d.checkoutPollGen++
	gen := d.checkoutPollGen
	changed := d.checkoutOutcome != ""
	d.checkoutOutcome = ""
	d.mu.Unlock()
	if changed {
		d.notify(ctx)
	}
	return gen
}

// setCheckoutOutcome records the live checkout's back-out verdict and pushes
// state. The generation check and the write share one d.mu critical section:
// only the CURRENT poll may write — a superseded loop's late verdict belongs
// to a checkout that no longer exists.
func (d *Daemon) setCheckoutOutcome(ctx context.Context, gen int, v string) {
	d.mu.Lock()
	if d.checkoutPollGen != gen {
		d.mu.Unlock()
		return
	}
	changed := d.checkoutOutcome != v
	d.checkoutOutcome = v
	d.mu.Unlock()
	if changed {
		d.notify(ctx)
	}
}

// activationPoll confirms the checkout every few seconds. A pending or
// transient-error response keeps polling; a pending answer carrying declined
// records the back-out verdict; a pending answer carrying session_expired
// ends the poll — nothing can pay an expired session, and that answer (not
// any assumption about the back-out's best-effort expire) is what a verdict
// path is allowed to rest on. A typed worker refusal (seat_limit_reached,
// trial_email_used, ...) is terminal — it stops the poll and surfaces the
// code; a non-pending success persists the grant and pushes state. The FAST
// deadline (pollFor) lapsing writes the abandoned verdict (unless declined
// already stands) — and since the session may remain payable for its 24h
// life whichever verdict was written, the poll then drops to a SLOW
// reconcile cadence (reconcileEvery/reconcileFor) that still activates a
// come-back-later payment instead of stranding a paid buyer (money review
// 2026-08-27 F3+F11). Being superseded (ctx cancelled) writes nothing.
// Never logs tokens.
func (d *Daemon) activationPoll(ctx context.Context, gen int, sessionID string) {
	g := d.License
	fastUntil := time.Now().Add(g.pollFor())
	slowUntil := time.Now().Add(g.reconcileFor())
	tick := time.NewTicker(g.pollEvery())
	defer tick.Stop()
	declined, slow := false, false
	for {
		view, err := g.Client.Activate(ctx, sessionID)
		if err == nil && !view.Pending && view.Entitlement != "" {
			if serr := d.persistLicense(context.Background(), view); serr != nil {
				d.Log.Warn("activation persist failed", "err", serr)
			} else {
				d.setCheckoutOutcome(context.Background(), gen, "")
				d.Log.Info("license activated", "status", view.Status)
			}
			return
		}
		if err == nil && view.Pending && view.Declined && !declined {
			declined = true
			d.setCheckoutOutcome(context.Background(), gen, "declined")
		}
		if err == nil && view.Pending && view.SessionExpired {
			// Nothing can pay this session anymore — the worker saw it
			// expired (the back-out's expire landed, or the 24h life ended).
			// The verdict already written stands; the poll is done.
			return
		}
		var refusal *WorkerError
		if errors.As(err, &refusal) && refusal.Terminal() {
			d.setLicenseError(context.Background(), refusal.Code)
			d.Log.Warn("activation refused", "code", refusal.Code)
			return
		}
		now := time.Now()
		if now.After(slowUntil) {
			return
		}
		if !slow && now.After(fastUntil) {
			slow = true
			// The reconcile phase covers DECLINED checkouts too: the
			// back-out's expire is best-effort (a transient Stripe failure
			// is swallowed), so no branch of the money path may assume it
			// landed — a session that survived it can still be paid at
			// minute 12, and that buyer must get their grant (money review
			// 2026-08-27 F11). The expired answer above is what actually
			// ends the watch. "abandoned" never overwrites the more
			// specific declined verdict.
			if !declined {
				d.setCheckoutOutcome(context.Background(), gen, "abandoned")
			}
			tick.Reset(g.reconcileEvery())
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

// persistLicense verifies a worker-minted grant OFFLINE before writing it, then
// records the new status and pushes state. Verifying first keeps a compromised
// or buggy worker from poisoning the Keychain with an unusable token.
func (d *Daemon) persistLicense(ctx context.Context, view LicenseView) error {
	g := d.License
	keys, err := g.keyring()
	if err != nil {
		return err
	}
	payload, err := pilot.VerifyEntitlement(view.Entitlement, keys, g.now())
	if err != nil {
		return fmt.Errorf("worker returned an unverifiable entitlement: %w", err)
	}
	if payload.Install != g.Manager.InstallID {
		return errors.New("worker returned an entitlement bound to another install")
	}
	now := g.now().UTC()
	stored := pilot.StoredLicense{
		LicenseID:     view.License,
		Entitlement:   view.Entitlement,
		Status:        view.Status,
		TrialEnd:      view.TrialEnd,
		StoredAt:      now,
		LastValidated: now,
	}
	if err := g.Manager.Store.Save(ctx, stored); err != nil {
		return err
	}
	// A fresh worker-minted grant is online proof: re-arm the clock anchor so
	// first-run installs (and forgiven rollbacks) get their offline window.
	if g.Manager.Anchor != nil {
		g.Manager.Anchor.Reset(now)
	}
	d.setLicenseStatus(ctx, view.Status)
	return nil
}

// setLicenseStatus records the online status projection, clears any stale
// licensing error, and pushes fresh state (which carries license_status) to
// every SSE subscriber when it changed.
func (d *Daemon) setLicenseStatus(ctx context.Context, status string) {
	d.mu.Lock()
	changed := d.licenseStatus != status || d.licenseError != ""
	d.licenseStatus = status
	d.licenseError = ""
	d.mu.Unlock()
	if changed {
		d.notify(ctx)
	}
}

// setLicenseError records one terminal licensing refusal code (never prose,
// never an id) and pushes state so the cockpit reacts live.
func (d *Daemon) setLicenseError(ctx context.Context, code string) {
	d.mu.Lock()
	changed := d.licenseError != code
	d.licenseError = code
	d.mu.Unlock()
	if changed {
		d.notify(ctx)
	}
}

// handleLicenseQuote proxies the worker's pre-checkout consent terms (trial
// length, prices, charge date) to the paywall. Read-only public pricing — no
// install token required; a browser-only cockpit can still show honest terms.
func (d *Daemon) handleLicenseQuote(w http.ResponseWriter, r *http.Request) {
	g := d.License
	if g == nil || !g.Available {
		httpError(w, http.StatusNotImplemented, errors.New("licensing not wired"))
		return
	}
	quote, err := g.Client.Quote(r.Context())
	if err != nil {
		httpWorkerError(w, err, "the price could not be loaded — try again")
		d.Log.Warn("license quote", "err", err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(quote)
}

// handleLicenseCancel is the one-click trial cancel (consumer-law checklist c).
// The worker cancels the subscription immediately; the daemon reflects the
// lapsed status so Pro pauses at once with honest copy.
func (d *Daemon) handleLicenseCancel(w http.ResponseWriter, r *http.Request) {
	g := d.License
	if g == nil || !g.Available {
		httpError(w, http.StatusNotImplemented, errors.New("licensing not wired"))
		return
	}
	if !d.requireAuth(w, r) {
		return
	}
	if !requireJSON(w, r) {
		return
	}
	ctx := r.Context()
	stored, err := g.Manager.Store.Load(ctx)
	if errors.Is(err, pilot.ErrNoLicense) {
		httpError(w, http.StatusConflict, errors.New("no trial to cancel"))
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, errors.New("read entitlement"))
		return
	}
	view, err := g.Client.Cancel(ctx, stored.LicenseID)
	if err != nil {
		httpError(w, http.StatusBadGateway, errors.New("cancel could not complete — try again"))
		d.Log.Warn("license cancel", "err", err)
		return
	}
	stored.Status = view.Status // "lapsed"
	stored.LastValidated = g.now().UTC()
	if err := g.Manager.Store.Save(ctx, stored); err != nil {
		httpError(w, http.StatusInternalServerError, errors.New("record cancellation"))
		return
	}
	d.setLicenseStatus(ctx, stored.Status)
	writeJSON(w, http.StatusOK, map[string]string{"status": stored.Status})
}

// handleLicenseRecover forwards to the worker's uniform-202 recovery endpoint.
// The response is identical for known and unknown addresses — no enumeration.
func (d *Daemon) handleLicenseRecover(w http.ResponseWriter, r *http.Request) {
	g := d.License
	if g == nil || !g.Available {
		httpError(w, http.StatusNotImplemented, errors.New("licensing not wired"))
		return
	}
	if !d.requireAuth(w, r) {
		return
	}
	if !requireJSON(w, r) {
		return
	}
	var req struct {
		Email string `json:"email"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, errors.New(`body must be {"email": "you@example.com"}`))
		return
	}
	if err := g.Client.Recover(r.Context(), req.Email); err != nil {
		httpError(w, http.StatusBadGateway, errors.New("could not send the recovery email — try again"))
		d.Log.Warn("license recover", "err", err)
		return
	}
	// Uniform 202 whether or not the address is on file.
	writeJSON(w, http.StatusAccepted, map[string]bool{"ok": true})
}

// handleLicenseClaim redeems a magic-link token and activates the recovered
// grant on this Mac.
func (d *Daemon) handleLicenseClaim(w http.ResponseWriter, r *http.Request) {
	g := d.License
	if g == nil || !g.Available {
		httpError(w, http.StatusNotImplemented, errors.New("licensing not wired"))
		return
	}
	if !d.requireAuth(w, r) {
		return
	}
	if !requireJSON(w, r) {
		return
	}
	var req struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Token) == "" {
		httpError(w, http.StatusBadRequest, errors.New(`body must be {"token": "<magic-link token>"}`))
		return
	}
	view, err := g.Client.ClaimRecovery(r.Context(), strings.TrimSpace(req.Token))
	if err != nil {
		httpWorkerError(w, err, "this recovery link is invalid or expired — request a new one")
		d.Log.Warn("license recover claim", "err", err)
		return
	}
	if view.Entitlement == "" {
		httpError(w, http.StatusBadGateway, errors.New("recovery returned no entitlement"))
		return
	}
	if err := d.persistLicense(r.Context(), view); err != nil {
		httpError(w, http.StatusBadGateway, errors.New("recovered grant could not be stored"))
		d.Log.Warn("license recover persist", "err", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": view.Status})
}

// handleLicenseMarker records whether the native app holds its synchronizable
// no-card-trial marker. The daemon never writes that item (Swift owns it); it
// only folds the report into ladder eligibility.
func (d *Daemon) handleLicenseMarker(w http.ResponseWriter, r *http.Request) {
	g := d.License
	if g == nil {
		httpError(w, http.StatusNotImplemented, errors.New("licensing not wired"))
		return
	}
	if !d.requireAuth(w, r) {
		return
	}
	if !requireJSON(w, r) {
		return
	}
	var req struct {
		Present bool `json:"present"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, errors.New(`body must be {"present": true|false}`))
		return
	}
	g.mu.Lock()
	g.marker = req.Present
	g.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// httpEntitlementClient is the production EntitlementClient. BaseURL is the
// worker API origin (https://api.llmpilot.dev, or the local wrangler dev URL in
// the sandboxed test loop). InstallID rides on checkout, activate, and claim
// so the worker can bind tokens and count this Mac's seat.
type httpEntitlementClient struct {
	BaseURL   string
	InstallID string
	HTTP      *http.Client
}

// NewEntitlementClient builds the worker client the daemon wires on official
// builds.
func NewEntitlementClient(baseURL, installID string, httpc *http.Client) EntitlementClient {
	if httpc == nil {
		httpc = &http.Client{Timeout: 15 * time.Second}
	}
	return httpEntitlementClient{BaseURL: baseURL, InstallID: installID, HTTP: httpc}
}

func (c httpEntitlementClient) post(ctx context.Context, path string, in, out any) (int, error) {
	body, err := json.Marshal(in)
	if err != nil {
		return 0, err
	}
	url := strings.TrimRight(c.BaseURL, "/") + path
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return 0, err
	}
	defer func() { _ = resp.Body.Close() }()
	if out == nil {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		return resp.StatusCode, nil
	}
	dec := json.NewDecoder(io.LimitReader(resp.Body, 64<<10))
	if err := dec.Decode(out); err != nil && !errors.Is(err, io.EOF) {
		return resp.StatusCode, fmt.Errorf("decode %s response: %w", path, err)
	}
	return resp.StatusCode, nil
}

// get fetches one worker GET route, returning the raw body on 200 and a
// typed WorkerError otherwise.
func (c httpEntitlementClient) get(ctx context.Context, path string) (json.RawMessage, error) {
	url := strings.TrimRight(c.BaseURL, "/") + path
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		return nil, fmt.Errorf("read %s response: %w", path, err)
	}
	if resp.StatusCode != http.StatusOK {
		var e struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(body, &e)
		return nil, fmt.Errorf("%s: %w", path, &WorkerError{Code: e.Error, HTTPStatus: resp.StatusCode})
	}
	return body, nil
}

func (c httpEntitlementClient) Quote(ctx context.Context) (json.RawMessage, error) {
	return c.get(ctx, "/v1/quote")
}

// parseTrialEnd turns the worker's ISO trial_end into a time; empty → nil.
func parseTrialEnd(s string) *time.Time {
	if s == "" {
		return nil
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return nil
	}
	return &t
}

func (c httpEntitlementClient) Checkout(ctx context.Context, rung, ui string, quote json.RawMessage, remindDaysBefore int) (CheckoutResult, error) {
	var r struct {
		SessionID   string `json:"sessionId"`
		License     string `json:"license"`
		URL         string `json:"url"`
		CheckoutURL string `json:"checkoutUrl"`
		Error       string `json:"error"`
	}
	body := map[string]any{"rung": rung, "ui": ui, "install_id": c.InstallID}
	if len(quote) > 0 {
		body["quote"] = quote
	}
	if remindDaysBefore != 0 {
		body["remind_days_before"] = remindDaysBefore
	}
	code, err := c.post(ctx, "/v1/checkout", body, &r)
	if err != nil {
		return CheckoutResult{}, err
	}
	if code != http.StatusOK || r.Error != "" {
		return CheckoutResult{}, fmt.Errorf("checkout: %w", &WorkerError{Code: r.Error, HTTPStatus: code})
	}
	url := r.URL
	if url == "" {
		url = r.CheckoutURL
	}
	if r.SessionID == "" || url == "" {
		return CheckoutResult{}, errors.New("checkout: worker returned no session")
	}
	return CheckoutResult{SessionID: r.SessionID, License: r.License, URL: url}, nil
}

func (c httpEntitlementClient) Activate(ctx context.Context, sessionID string) (LicenseView, error) {
	var r struct {
		Pending        bool   `json:"pending"`
		Declined       bool   `json:"declined"`
		SessionExpired bool   `json:"session_expired"`
		License        string `json:"license"`
		Status         string `json:"status"`
		TrialEnd       string `json:"trial_end"`
		Entitlement    string `json:"entitlement"`
		Error          string `json:"error"`
	}
	code, err := c.post(ctx, "/v1/activate", map[string]string{"session_id": sessionID, "install_id": c.InstallID}, &r)
	if err != nil {
		return LicenseView{}, err
	}
	if r.Pending {
		return LicenseView{Pending: true, Status: r.Status, Declined: r.Declined, SessionExpired: r.SessionExpired}, nil
	}
	if code != http.StatusOK || r.Error != "" {
		return LicenseView{}, fmt.Errorf("activate: %w", &WorkerError{Code: r.Error, HTTPStatus: code})
	}
	return LicenseView{
		License:     r.License,
		Status:      r.Status,
		TrialEnd:    parseTrialEnd(r.TrialEnd),
		Entitlement: r.Entitlement,
	}, nil
}

func (c httpEntitlementClient) Cancel(ctx context.Context, licenseID string) (LicenseView, error) {
	var r struct {
		OK     bool   `json:"ok"`
		Status string `json:"status"`
		Error  string `json:"error"`
	}
	code, err := c.post(ctx, "/v1/cancel", map[string]string{"license": licenseID}, &r)
	if err != nil {
		return LicenseView{}, err
	}
	if code != http.StatusOK || r.Error != "" {
		return LicenseView{}, fmt.Errorf("cancel: %w", &WorkerError{Code: r.Error, HTTPStatus: code})
	}
	return LicenseView{Status: r.Status}, nil
}

func (c httpEntitlementClient) Recover(ctx context.Context, email string) error {
	// The worker floors the response at 202 for every address; a non-202 is a
	// real transport failure worth surfacing.
	code, err := c.post(ctx, "/v1/recover", map[string]string{"email": email}, nil)
	if err != nil {
		return err
	}
	if code != http.StatusAccepted {
		return fmt.Errorf("recover: %w", &WorkerError{HTTPStatus: code})
	}
	return nil
}

func (c httpEntitlementClient) ClaimRecovery(ctx context.Context, token string) (LicenseView, error) {
	var r struct {
		License     string `json:"license"`
		Status      string `json:"status"`
		TrialEnd    string `json:"trial_end"`
		Entitlement string `json:"entitlement"`
		Error       string `json:"error"`
	}
	code, err := c.post(ctx, "/v1/recover/claim", map[string]string{"token": token, "install_id": c.InstallID}, &r)
	if err != nil {
		return LicenseView{}, err
	}
	if code != http.StatusOK || r.Error != "" {
		return LicenseView{}, fmt.Errorf("claim: %w", &WorkerError{Code: r.Error, HTTPStatus: code})
	}
	return LicenseView{
		License:     r.License,
		Status:      r.Status,
		TrialEnd:    parseTrialEnd(r.TrialEnd),
		Entitlement: r.Entitlement,
	}, nil
}

// WorkerError is one typed worker refusal (seat_limit_reached,
// trial_email_used, ...). Keeping the machine code intact end to end lets
// the cockpit render the right copy instead of generic failure prose. It
// never echoes a token or id.
type WorkerError struct {
	Code       string
	HTTPStatus int
}

func (e *WorkerError) Error() string {
	if e.Code != "" {
		return e.Code
	}
	return fmt.Sprintf("HTTP %d", e.HTTPStatus)
}

// Terminal reports whether retrying the same request can ever succeed: a
// 4xx is the worker refusing the request itself, not a transient fault.
func (e *WorkerError) Terminal() bool {
	return e.HTTPStatus >= 400 && e.HTTPStatus < 500
}
