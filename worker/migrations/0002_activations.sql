-- Device-bound activation under a seat limit. licenses.install_id is the
-- checkout-time binding (the daemon sends its random install id when it
-- creates the session); activations is one row per (license, device) seat,
-- occupied only by fulfilled checkouts, recovery claims, and session-replay
-- activations under the cap. install ids are random UUIDs, never hardware
-- fingerprints.

ALTER TABLE licenses ADD COLUMN install_id TEXT;

CREATE TABLE activations (
  license_id TEXT NOT NULL,
  install_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_seen TEXT NOT NULL,   -- recovery-at-cap evicts the stalest seat
  PRIMARY KEY (license_id, install_id)
);
