-- Device role is descriptive infrastructure metadata. Existing rows remain
-- unclassified because their original role cannot be safely inferred.
ALTER TABLE ventio_identity_devices
  ADD COLUMN device_role text CHECK (device_role IN ('HOST','CLIENT'))

-- Pairing authority is represented only by a digest. The raw one-time code is
-- generated and returned by the Host API and is never persisted.
CREATE TABLE ventio_identity_pairings (
  pairing_id text PRIMARY KEY CHECK (pairing_id ~ '^pair_[0-9a-f]{32}$'),
  pairing_digest text NOT NULL UNIQUE CHECK (pairing_digest ~ '^[0-9a-f]{64}$'),
  tenant_id text NOT NULL,
  actor_id text NOT NULL,
  company_id text NOT NULL,
  branch_id text NOT NULL,
  created_by_actor_id text NOT NULL,
  allowed_permissions text[] NOT NULL CHECK (cardinality(allowed_permissions) <= 256),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz NOT NULL CHECK (isfinite(expires_at)),
  redeemed_at timestamptz,
  redeemed_device_id text,
  revoked_at timestamptz,
  FOREIGN KEY (tenant_id, actor_id)
    REFERENCES ventio_identity_users (tenant_id, actor_id),
  FOREIGN KEY (tenant_id, created_by_actor_id)
    REFERENCES ventio_identity_users (tenant_id, actor_id),
  FOREIGN KEY (tenant_id, company_id, branch_id)
    REFERENCES ventio_identity_branches (tenant_id, company_id, branch_id),
  FOREIGN KEY (tenant_id, redeemed_device_id)
    REFERENCES ventio_identity_devices (tenant_id, device_id),
  CHECK (length(trim(actor_id)) BETWEEN 1 AND 256),
  CHECK (length(trim(company_id)) BETWEEN 1 AND 256),
  CHECK (length(trim(branch_id)) BETWEEN 1 AND 256),
  CHECK (expires_at > created_at AND expires_at <= created_at + interval '5 minutes'),
  CHECK ((redeemed_at IS NULL) = (redeemed_device_id IS NULL))
)

CREATE INDEX ventio_identity_pairings_creator_window
  ON ventio_identity_pairings
    (tenant_id, created_by_actor_id, company_id, branch_id, created_at DESC)
