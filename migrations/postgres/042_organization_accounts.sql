DO $migration$
BEGIN
-- Additive only. Existing identities, credentials and business data are retained.
-- Existing organizations deliberately remain unowned until explicit local recovery.
ALTER TABLE public.ventio_identity_users
  ADD COLUMN IF NOT EXISTS is_owner boolean NOT NULL DEFAULT false,
  ADD COLUMN username text,
  ADD COLUMN password_hash text,
  ADD COLUMN password_version integer NOT NULL DEFAULT 0,
  ADD COLUMN organization_wide boolean NOT NULL DEFAULT false,
  ADD COLUMN login_failures integer NOT NULL DEFAULT 0,
  ADD COLUMN login_locked_until timestamptz;
CREATE UNIQUE INDEX ventio_one_organization_owner
  ON public.ventio_identity_users(tenant_id) WHERE is_owner;
CREATE UNIQUE INDEX ventio_organization_username
  ON public.ventio_identity_users(tenant_id,lower(username)) WHERE username IS NOT NULL;
ALTER TABLE public.ventio_identity_users ADD CONSTRAINT ventio_account_login_shape CHECK (
  (username IS NULL AND password_hash IS NULL) OR
  (username ~ '^[A-Za-z0-9][A-Za-z0-9_.@-]{2,63}$' AND
   password_hash ~ '^pbkdf2-sha256:600000:[A-Za-z0-9_-]{43}:[A-Za-z0-9_-]{43}$'));
ALTER TABLE public.ventio_identity_credentials
  ADD COLUMN login_parent_id text,
  ADD COLUMN login_password_version integer;
ALTER TABLE public.ventio_identity_credentials ADD CONSTRAINT ventio_login_parent
  FOREIGN KEY (tenant_id,login_parent_id)
  REFERENCES public.ventio_identity_credentials(tenant_id,credential_id);

END $migration$;
