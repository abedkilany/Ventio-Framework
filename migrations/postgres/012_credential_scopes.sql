ALTER TABLE ventio_identity_credentials ADD COLUMN allowed_scopes jsonb
  CHECK (allowed_scopes IS NULL OR jsonb_typeof(allowed_scopes) = 'array')
