CREATE OR REPLACE FUNCTION ventio_security.account_session_refresh(p_digest text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE
  c public.ventio_identity_credentials%ROWTYPE;
  parent_expiry timestamptz;
  expiry timestamptz;
BEGIN
  PERFORM pg_advisory_xact_lock(86744321);

  IF NOT ventio_security.account_credential_valid(p_digest) THEN
    RAISE EXCEPTION 'Session refresh denied' USING ERRCODE='42501';
  END IF;

  SELECT * INTO c
  FROM public.ventio_identity_credentials
  WHERE token_digest=p_digest FOR UPDATE;

  IF NOT FOUND OR c.login_parent_id IS NULL THEN
    RAISE EXCEPTION 'Session refresh denied' USING ERRCODE='42501';
  END IF;

  SELECT expires_at INTO parent_expiry
  FROM public.ventio_identity_credentials
  WHERE tenant_id=c.tenant_id
    AND actor_id=c.actor_id
    AND device_id=c.device_id
    AND credential_id=c.login_parent_id
    AND revoked_at IS NULL
  FOR SHARE;

  IF parent_expiry IS NULL OR parent_expiry<=clock_timestamp() THEN
    RAISE EXCEPTION 'Session refresh denied' USING ERRCODE='42501';
  END IF;

  expiry:=least(parent_expiry,clock_timestamp()+make_interval(hours=>ventio_security.account_lease_hours(c.tenant_id)));

  UPDATE public.ventio_identity_credentials
  SET expires_at=expiry
  WHERE token_digest=p_digest;

  RETURN jsonb_build_object(
    'tenantId',c.tenant_id,
    'actorId',c.actor_id,
    'deviceId',c.device_id,
    'expiresAt',expiry,
    'identity',ventio_security.identity_snapshot(p_digest,NULL,NULL)
  );
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.account_session_logout(p_digest text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
BEGIN
  PERFORM pg_advisory_xact_lock(86744321);

  IF NOT ventio_security.recovery_guard() THEN
    RAISE EXCEPTION 'Session logout denied' USING ERRCODE='42501';
  END IF;

  UPDATE public.ventio_identity_credentials
  SET revoked_at=coalesce(revoked_at,clock_timestamp())
  WHERE token_digest=p_digest
    AND login_parent_id IS NOT NULL;

  RETURN jsonb_build_object('signedOut',true);
END $fn$;

REVOKE ALL ON FUNCTION
  ventio_security.account_session_refresh(text),
  ventio_security.account_session_logout(text)
FROM PUBLIC,ventio_runtime,ventio_identity_admin,ventio_identity_api;

GRANT EXECUTE ON FUNCTION
  ventio_security.account_session_refresh(text),
  ventio_security.account_session_logout(text)
TO ventio_identity_api;
