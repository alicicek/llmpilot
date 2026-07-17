package pilot

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/alicicek/llmpilot/internal/switcher"
)

const (
	EntitlementKeychainService = "dev.llmpilot.entitlement"
	EntitlementKeychainAccount = "current"
	DefaultValidationInterval  = 7 * 24 * time.Hour
	DefaultOfflineGrace        = 30 * 24 * time.Hour
)

// StoredLicense is the entitlement record the daemon owns end to end. The
// daemon is the SOLE writer and reader of the dev.llmpilot.entitlement Keychain
// item, which stays NON-synchronizable forever (advisor verdict 2026-07-12): a
// synchronizable item lives in the data-protection keychain, which this
// stdin-based /usr/bin/security adapter cannot see, so a native-written
// synchronizable twin would be invisible here and split the money path. The
// native app therefore never writes this item — multi-Mac activation is email
// recovery, and the no-card-trial marker is a SEPARATE native-owned
// synchronizable item under its own service (dev.llmpilot.trial-marker).
type StoredLicense struct {
	LicenseID string `json:"license"`
	// Entitlement is the Ed25519-signed capability token, never a secret.
	Entitlement string `json:"entitlement"`
	Status      string `json:"status"`
	// TrialEnd is the worker's trial boundary (the card-charge instant); nil
	// outside a trial. The signed entitlement expiry is trial_end + grace, so
	// this is the honest "charged on" date the paywall and Settings show.
	TrialEnd      *time.Time `json:"trial_end,omitempty"`
	StoredAt      time.Time  `json:"stored_at"`
	LastValidated time.Time  `json:"last_validated"`
}

type LicenseStore interface {
	Load(context.Context) (StoredLicense, error)
	Save(context.Context, StoredLicense) error
}

var ErrNoLicense = errors.New("no entitlement stored")

// KeychainLicenseStore uses llmpilot's hardened stdin-based Keychain adapter.
// The entitlement is a signed capability, never a Stripe or signing secret.
type KeychainLicenseStore struct {
	Keychain *switcher.Keychain
}

func (s KeychainLicenseStore) Load(ctx context.Context) (StoredLicense, error) {
	var out StoredLicense
	if s.Keychain == nil {
		return out, ErrNoLicense
	}
	raw, err := s.Keychain.GetAccount(ctx, EntitlementKeychainService, EntitlementKeychainAccount)
	if err != nil {
		if errors.Is(err, switcher.ErrNotFound) {
			return out, ErrNoLicense
		}
		return out, err
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return out, fmt.Errorf("decode stored entitlement: %w", err)
	}
	if out.LicenseID == "" || out.Entitlement == "" {
		return StoredLicense{}, ErrNoLicense
	}
	return out, nil
}

func (s KeychainLicenseStore) Save(ctx context.Context, license StoredLicense) error {
	if s.Keychain == nil {
		return ErrNoLicense
	}
	raw, err := json.Marshal(license)
	if err != nil {
		return err
	}
	return s.Keychain.Set(ctx, EntitlementKeychainService, EntitlementKeychainAccount, raw)
}

type HTTPDoer interface {
	Do(*http.Request) (*http.Response, error)
}

// LicenseManager owns offline verification plus infrequent online status
// refresh. Ordinary feature checks never perform network I/O.
type LicenseManager struct {
	Store LicenseStore
	Keys  map[string][]byte
	// InstallID is this machine's identity; a token minted for another
	// install fails closed. Empty means unwired (source builds) and refuses
	// every token, never skips the check.
	InstallID string
	// Anchor is the forward-only clock high-water mark; when it reports a
	// rollback (or is missing on disk) offline access fails closed until an
	// online revalidate. nil skips the check (unit fixtures only — production
	// wiring always sets it).
	Anchor        *TimeAnchor
	ValidateURL   string
	HTTP          HTTPDoer
	Now           func() time.Time
	OfflineGrace  time.Duration
	CheckInterval time.Duration
}

func (m *LicenseManager) now() time.Time {
	if m.Now != nil {
		return m.Now()
	}
	return time.Now()
}

func (m *LicenseManager) verifyKeys() (map[string]ed25519.PublicKey, error) {
	if m.Keys != nil {
		out := make(map[string]ed25519.PublicKey, len(m.Keys))
		for id, raw := range m.Keys {
			if len(raw) != ed25519.PublicKeySize {
				return nil, ErrInvalidEntitlement
			}
			out[id] = ed25519.PublicKey(raw)
		}
		return out, nil
	}
	return EmbeddedKeyring()
}

func (m *LicenseManager) Allowed(ctx context.Context, feature string, now time.Time) bool {
	if m.Anchor != nil {
		m.Anchor.Observe(now)
		if m.Anchor.Regressed(now) {
			return false
		}
	}
	stored, err := m.Store.Load(ctx)
	if err != nil || stored.Status == "revoked" || stored.Status == "lapsed" {
		return false
	}
	keys, err := m.verifyKeys()
	if err != nil {
		return false
	}
	payload, err := VerifyEntitlement(stored.Entitlement, keys, now)
	if err != nil || !payload.Allows(feature, now) {
		return false
	}
	if payload.Install != m.InstallID || m.InstallID == "" {
		return false
	}
	grace := m.OfflineGrace
	if grace == 0 {
		grace = DefaultOfflineGrace
	}
	// The offline window anchors ONLY to the signed issued_at: StoredAt and
	// LastValidated are unsigned Keychain JSON anyone can edit, so they are
	// display metadata, never authorization inputs. A future issued_at is not
	// refused here — it cannot be forged, and clock rollback is the time
	// anchor's job — so a slow local clock never bricks a fresh purchase.
	return now.Before(payload.IssuedAt.Add(grace))
}

// Due is weekly with stable ±12h jitter derived from the opaque license id.
// Stable jitter survives restarts without another state file.
func (m *LicenseManager) Due(ctx context.Context, now time.Time) bool {
	stored, err := m.Store.Load(ctx)
	if err != nil || stored.Status == "revoked" || stored.Status == "lapsed" {
		return false
	}
	// A rollback hold only clears through the authoritative online check, so
	// it makes that check due immediately.
	if m.Anchor != nil && m.Anchor.Regressed(now) {
		return true
	}
	interval := m.CheckInterval
	if interval == 0 {
		interval = DefaultValidationInterval
	}
	digest := sha256.Sum256([]byte(stored.LicenseID))
	jitter := time.Duration(int(digest[0])-128) * (12 * time.Hour) / 128
	// The cadence anchors to the signed issued_at (the worker re-signs on
	// every validate, so it advances weekly). An unverifiable token — expired
	// trial included — is due immediately: the online check is what can
	// refresh or lapse it. Unsigned StoredAt/LastValidated stay out of the
	// decision entirely.
	keys, err := m.verifyKeys()
	if err != nil {
		return true
	}
	payload, err := VerifyEntitlement(stored.Entitlement, keys, now)
	if err != nil {
		return true
	}
	anchor := payload.IssuedAt
	return anchor.After(now) || !now.Before(anchor.Add(interval+jitter))
}

func (m *LicenseManager) Revalidate(ctx context.Context) (string, error) {
	stored, err := m.Store.Load(ctx)
	if err != nil {
		return "", err
	}
	body, err := json.Marshal(map[string]string{"license": stored.LicenseID, "install_id": m.InstallID})
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, m.ValidateURL, bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	client := m.HTTP
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		return "", fmt.Errorf("entitlement validate: HTTP %d", resp.StatusCode)
	}
	var result struct {
		Status      string `json:"status"`
		Entitlement string `json:"entitlement"`
	}
	dec := json.NewDecoder(io.LimitReader(resp.Body, 64<<10))
	if err := dec.Decode(&result); err != nil {
		return "", fmt.Errorf("decode entitlement validation: %w", err)
	}
	switch result.Status {
	case "revoked", "lapsed":
		stored.Status = result.Status
		stored.LastValidated = m.now().UTC()
	case "trialing", "lifetime":
		if result.Entitlement == "" {
			return "", errors.New("entitlement validation omitted token")
		}
		keys, err := m.verifyKeys()
		if err != nil {
			return "", err
		}
		payload, err := VerifyEntitlement(result.Entitlement, keys, m.now())
		if err != nil {
			return "", fmt.Errorf("validate returned bad entitlement: %w", err)
		}
		if payload.Install != m.InstallID {
			return "", fmt.Errorf("validate returned an entitlement bound to another install")
		}
		stored.Status = result.Status
		stored.Entitlement = result.Entitlement
		stored.LastValidated = m.now().UTC()
	default:
		return "", fmt.Errorf("unknown entitlement status %q", result.Status)
	}
	if err := m.Store.Save(ctx, stored); err != nil {
		return "", err
	}
	// Any authoritative server answer — revoked included — re-arms the clock
	// anchor and forgives a latched rollback.
	if m.Anchor != nil {
		m.Anchor.Reset(m.now())
	}
	return result.Status, nil
}
