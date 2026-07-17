-- Entitlement store + webhook claim ledger. D1 is authoritative for license
-- state; Stripe is authoritative for money. Emails exist ONLY for receipt
-- recovery and the pre-charge trial reminder — never listed, never joined
-- outward, logs carry license ids only.

CREATE TABLE webhook_events (
  id TEXT PRIMARY KEY,        -- Stripe event id (evt_...)
  type TEXT NOT NULL,
  received_at TEXT NOT NULL,
  processed_at TEXT,
  outcome TEXT NOT NULL       -- pending | ok | ignored | error:<reason>
);

CREATE TABLE licenses (
  id TEXT PRIMARY KEY,        -- lic_<random>, minted at checkout creation
  email TEXT,                 -- receipt email (recovery path)
  customer_id TEXT,
  subscription_id TEXT,
  session_id TEXT,
  status TEXT NOT NULL,       -- pending | trialing | lifetime | lapsed | revoked
  rung TEXT NOT NULL,         -- full | discount_trial | nocard_trial
  trial_end TEXT,
  cancel_at TEXT,
  reminder_sent_at TEXT,
  entitlement TEXT,           -- last signed token (re-served by validate)
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  revoked_at TEXT
);
CREATE INDEX idx_licenses_email ON licenses(email);
CREATE INDEX idx_licenses_subscription ON licenses(subscription_id);
CREATE INDEX idx_licenses_session ON licenses(session_id);

CREATE TABLE recovery_requests (
  token_hash TEXT PRIMARY KEY,
  email_hash TEXT NOT NULL,
  license_id TEXT,
  expires_at TEXT NOT NULL,
  claimed_at TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_recovery_expires ON recovery_requests(expires_at);

CREATE TABLE request_rate_limits (
  key_hash TEXT NOT NULL,
  window_start TEXT NOT NULL,
  attempts INTEGER NOT NULL,
  PRIMARY KEY (key_hash, window_start)
);

CREATE TABLE payments (
  id TEXT PRIMARY KEY,        -- payment intent / invoice / refund id
  license_id TEXT,            -- '' when unattributed (needs_manual_review)
  kind TEXT NOT NULL,         -- purchase | trial_start | refund | dispute | duplicate
  currency TEXT,
  amount INTEGER,
  billing_reason TEXT,
  status TEXT NOT NULL,       -- paid | refunded | partial_refund | needs_manual_review
  created_at TEXT NOT NULL
);
