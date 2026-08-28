-- Browser-checkout back-out signal: the hosted session's cancel_url carries
-- an opaque worker-minted token; the hit records declined_at on the pending
-- license, which the daemon's activation poll reads to arm the win-back on a
-- real signal. cancel_token is single-purpose — it can only ever set
-- declined_at, never read state or mint anything. Both stay NULL on rows
-- minted before this migration.

ALTER TABLE licenses ADD COLUMN cancel_token TEXT;
ALTER TABLE licenses ADD COLUMN declined_at TEXT;
CREATE UNIQUE INDEX idx_licenses_cancel_token ON licenses(cancel_token);
-- Expire-on-mint looks up the install's prior open checkouts by install_id.
CREATE INDEX idx_licenses_install ON licenses(install_id);
