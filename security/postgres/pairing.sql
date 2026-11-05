-- Included by bootstrap.sql as ventio_owner after administration.sql.

CREATE OR REPLACE FUNCTION ventio_security.identity_pairing_manager_allowed(
    p_digest text, p_tenant text, p_company text, p_branch text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE credential_row public.ventio_identity_credentials%ROWTYPE;
BEGIN
  IF NOT ventio_security.recovery_guard() OR
      p_digest IS NULL OR p_digest !~ '^[0-9a-f]{64}$' OR
      p_tenant IS NULL OR p_company IS NULL OR p_branch IS NULL OR
      length(trim(p_company)) NOT BETWEEN 1 AND 256 OR
      length(trim(p_branch)) NOT BETWEEN 1 AND 256 THEN
    RETURN false;
  END IF;
  SELECT c.* INTO credential_row
    FROM public.ventio_identity_credentials c
    JOIN public.ventio_identity_users u
      ON u.tenant_id=c.tenant_id AND u.actor_id=c.actor_id
    JOIN public.ventio_identity_devices d
      ON d.tenant_id=c.tenant_id AND d.actor_id=c.actor_id AND d.device_id=c.device_id
    WHERE c.token_digest=p_digest AND c.tenant_id=p_tenant
      AND c.revoked_at IS NULL AND c.expires_at>clock_timestamp()
      AND u.disabled_at IS NULL AND d.revoked_at IS NULL;
  IF NOT FOUND OR credential_row.allowed_scopes IS NULL OR NOT EXISTS (
      SELECT FROM jsonb_array_elements(credential_row.allowed_scopes) s
      WHERE s->>'companyId'=p_company AND s->>'branchId'=p_branch
        AND s->'permissions' ? 'identity.pairing.manage') THEN
    RETURN false;
  END IF;
  RETURN EXISTS (
    SELECT FROM public.ventio_identity_grants g
    WHERE g.tenant_id=p_tenant AND g.actor_id=credential_row.actor_id
      AND g.company_id=p_company AND g.branch_id=p_branch
      AND g.permission='identity.pairing.manage');
END $fn$;

-- The raw pairing code is deliberately absent from every SQL argument. Only
-- its digest, plus a fixed CLIENT role and one exact branch, enter the database.
\ir pairing_create.sql

-- Redemption consumes the pairing row, registers a CLIENT and inserts one
-- device-bound credential atomically. The lease is fixed at 30 days, matching
-- the existing Host credential lifecycle ceiling.
CREATE OR REPLACE FUNCTION ventio_security.scoped_pairing_redeem(
    p_pairing_digest text, p_device_id text, p_credential_id text,
    p_credential_digest text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE pairing_row public.ventio_identity_pairings%ROWTYPE;
        user_disabled timestamptz; now_value timestamptz;
        expires_value timestamptz; scopes jsonb;
BEGIN
  IF NOT pg_has_role(session_user,'ventio_identity_api','MEMBER') OR
      pg_has_role(session_user,'ventio_identity_admin','MEMBER') OR
      pg_has_role(session_user,'ventio_owner','MEMBER') OR
      pg_has_role(session_user,'ventio_migrator','MEMBER') OR
      EXISTS (SELECT FROM pg_catalog.pg_roles r WHERE r.rolname=session_user
        AND (r.rolsuper OR r.rolbypassrls OR r.rolcreatedb OR
          r.rolcreaterole OR r.rolreplication)) OR
      NOT ventio_security.recovery_guard() OR
      p_pairing_digest IS NULL OR p_pairing_digest !~ '^[0-9a-f]{64}$' OR
      p_device_id IS NULL OR p_device_id !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' OR
      p_device_id ~ '^[A-Za-z0-9_-]{43,128}$' OR
      p_credential_id IS NULL OR p_credential_id !~ '^cred_[0-9a-f]{32}$' OR
      p_credential_digest IS NULL OR p_credential_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid pairing redemption request' USING ERRCODE='22023';
  END IF;
  PERFORM pg_advisory_xact_lock(86744321);
  SELECT * INTO pairing_row FROM public.ventio_identity_pairings
    WHERE pairing_digest=p_pairing_digest
      AND redeemed_at IS NULL AND revoked_at IS NULL
      AND expires_at>clock_timestamp()
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pairing credential unavailable' USING ERRCODE='P0002';
  END IF;
  SELECT disabled_at INTO user_disabled FROM public.ventio_identity_users
    WHERE tenant_id=pairing_row.tenant_id AND actor_id=pairing_row.actor_id
    FOR SHARE;
  IF NOT FOUND OR user_disabled IS NOT NULL THEN
    RAISE EXCEPTION 'Pairing credential unavailable' USING ERRCODE='P0002';
  END IF;
  IF EXISTS (SELECT FROM public.ventio_identity_devices d
      WHERE d.tenant_id=pairing_row.tenant_id AND d.device_id=p_device_id) THEN
    RAISE EXCEPTION 'Device identity already exists' USING ERRCODE='23505';
  END IF;

  now_value := clock_timestamp();
  expires_value := now_value + interval '30 days';
  scopes := jsonb_build_array(jsonb_build_object(
    'companyId',pairing_row.company_id,'branchId',pairing_row.branch_id,
    'permissions',to_jsonb(pairing_row.allowed_permissions)));
  INSERT INTO public.ventio_identity_devices
    (tenant_id,actor_id,device_id,device_role)
    VALUES (pairing_row.tenant_id,pairing_row.actor_id,p_device_id,'CLIENT');
  -- The pairing table references the enrolled device, so create the device
  -- before recording the redemption. Both writes remain in this transaction.
  UPDATE public.ventio_identity_pairings
    SET redeemed_at=now_value,redeemed_device_id=p_device_id
    WHERE pairing_id=pairing_row.pairing_id;
  INSERT INTO public.ventio_identity_credentials
    (tenant_id,actor_id,device_id,credential_id,token_digest,expires_at,allowed_scopes)
    VALUES (pairing_row.tenant_id,pairing_row.actor_id,p_device_id,
      p_credential_id,p_credential_digest,expires_value,scopes);
  INSERT INTO public.ventio_identity_audit
    (tenant_id,operator_label,action,subject_id,details)
    VALUES (pairing_row.tenant_id,'api:pairing',
      'DEVICE_ENROLLED',p_device_id,jsonb_build_object(
        'pairingId',pairing_row.pairing_id,'actorId',pairing_row.actor_id,
        'deviceRole','CLIENT','companyId',pairing_row.company_id,
        'branchId',pairing_row.branch_id,
        'credentialId',p_credential_id,
        'expiresAtUtc',to_char(expires_value AT TIME ZONE 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')));
  RETURN jsonb_build_object(
    'tenantId',pairing_row.tenant_id,'actorId',pairing_row.actor_id,
    'deviceId',p_device_id,'deviceRole','CLIENT',
    'credentialId',p_credential_id,'companyId',pairing_row.company_id,
    'branchId',pairing_row.branch_id,
    'expiresAtUtc',to_char(expires_value AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.identity_device_manager_allowed(
    p_digest text, p_tenant text, p_company text, p_branch text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE credential_row public.ventio_identity_credentials%ROWTYPE;
BEGIN
  IF NOT ventio_security.recovery_guard() OR
      p_digest IS NULL OR p_digest !~ '^[0-9a-f]{64}$' OR
      p_tenant IS NULL OR p_company IS NULL OR p_branch IS NULL OR
      length(trim(p_company)) NOT BETWEEN 1 AND 256 OR
      length(trim(p_branch)) NOT BETWEEN 1 AND 256 THEN
    RETURN false;
  END IF;
  SELECT c.* INTO credential_row
    FROM public.ventio_identity_credentials c
    JOIN public.ventio_identity_users u
      ON u.tenant_id=c.tenant_id AND u.actor_id=c.actor_id
    JOIN public.ventio_identity_devices d
      ON d.tenant_id=c.tenant_id AND d.actor_id=c.actor_id AND d.device_id=c.device_id
    WHERE c.token_digest=p_digest AND c.tenant_id=p_tenant
      AND c.revoked_at IS NULL AND c.expires_at>clock_timestamp()
      AND u.disabled_at IS NULL AND d.revoked_at IS NULL;
  IF NOT FOUND OR credential_row.allowed_scopes IS NULL OR NOT EXISTS (
      SELECT FROM jsonb_array_elements(credential_row.allowed_scopes) s
      WHERE s->>'companyId'=p_company AND s->>'branchId'=p_branch
        AND s->'permissions' ? 'identity.devices.manage') THEN
    RETURN false;
  END IF;
  RETURN EXISTS (
    SELECT FROM public.ventio_identity_grants g
    WHERE g.tenant_id=p_tenant AND g.actor_id=credential_row.actor_id
      AND g.company_id=p_company AND g.branch_id=p_branch
      AND g.permission='identity.devices.manage');
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.identity_devices_snapshot(
    p_digest text, p_company text, p_branch text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE credential_row public.ventio_identity_credentials%ROWTYPE;
        items jsonb;
BEGIN
  IF NOT ventio_security.recovery_guard() OR
      p_digest IS NULL OR p_digest !~ '^[0-9a-f]{64}$' OR
      p_company IS NULL OR p_branch IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT c.* INTO credential_row
    FROM public.ventio_identity_credentials c
    JOIN public.ventio_identity_users u
      ON u.tenant_id=c.tenant_id AND u.actor_id=c.actor_id
    JOIN public.ventio_identity_devices d
      ON d.tenant_id=c.tenant_id AND d.actor_id=c.actor_id AND d.device_id=c.device_id
    WHERE c.token_digest=p_digest AND c.revoked_at IS NULL
      AND c.expires_at>clock_timestamp() AND u.disabled_at IS NULL
      AND d.revoked_at IS NULL
    FOR SHARE OF c,u,d;
  IF NOT FOUND OR NOT ventio_security.identity_device_manager_allowed(
      p_digest,credential_row.tenant_id,p_company,p_branch) THEN
    RETURN NULL;
  END IF;

  SELECT coalesce(jsonb_agg(device_item ORDER BY created_at DESC,device_id),
      '[]'::jsonb) INTO items
    FROM (
      SELECT jsonb_build_object(
        'deviceId',d.device_id,
        'actorId',d.actor_id,
        'role',coalesce(d.device_role,'UNKNOWN'),
        'registrationState',CASE WHEN d.revoked_at IS NULL
          THEN 'REGISTERED' ELSE 'REVOKED' END,
        'registeredAtUtc',to_char(d.created_at AT TIME ZONE 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
        -- Last successful authentication is informational only. It is not an
        -- online/offline signal; the timestamp is recorded at most once/minute.
        'lastAuthenticatedAtUtc',(SELECT to_char(activity.last_authenticated_at AT TIME ZONE 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
          FROM public.ventio_identity_device_activity activity
          WHERE activity.tenant_id=d.tenant_id AND activity.device_id=d.device_id
            AND activity.actor_id=d.actor_id),
        'credentials',coalesce((
          SELECT jsonb_agg(jsonb_build_object(
            'credentialId',c.credential_id,
            'state',CASE WHEN EXISTS (
                SELECT FROM public.ventio_identity_audit rotated
                WHERE rotated.tenant_id=c.tenant_id
                  AND rotated.action='CREDENTIAL_ROTATED'
                  AND rotated.details->>'previousCredentialId'=c.credential_id)
              THEN 'ROTATED'
              WHEN c.revoked_at IS NOT NULL THEN 'REVOKED'
              WHEN c.expires_at<=clock_timestamp() THEN 'EXPIRED'
              ELSE 'ACTIVE' END,
            'expiresAtUtc',to_char(c.expires_at AT TIME ZONE 'UTC',
              'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
            'revokedAtUtc',CASE WHEN c.revoked_at IS NULL THEN NULL ELSE
              to_char(c.revoked_at AT TIME ZONE 'UTC',
                'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') END
          ) ORDER BY c.issued_at DESC,c.credential_id)
          FROM public.ventio_identity_credentials c
          WHERE c.tenant_id=d.tenant_id AND c.actor_id=d.actor_id
            AND c.device_id=d.device_id AND (
              c.allowed_scopes IS NULL OR EXISTS (
                SELECT FROM jsonb_array_elements(c.allowed_scopes) scope
                WHERE scope->>'companyId'=p_company
                  AND scope->>'branchId'=p_branch))
        ),'[]'::jsonb)
      ) AS device_item,d.device_id,d.created_at
      FROM public.ventio_identity_devices d
      WHERE d.tenant_id=credential_row.tenant_id AND (
        EXISTS (SELECT FROM public.ventio_identity_grants g
          WHERE g.tenant_id=d.tenant_id AND g.actor_id=d.actor_id
            AND g.company_id=p_company AND g.branch_id=p_branch) OR
        EXISTS (SELECT FROM public.ventio_identity_role_assignments a
          WHERE a.tenant_id=d.tenant_id AND a.actor_id=d.actor_id
            AND a.company_id=p_company AND a.branch_id=p_branch))
      ORDER BY d.created_at DESC,d.device_id
      LIMIT 1000
    ) scoped_devices;

  RETURN jsonb_build_object(
    'tenantId',credential_row.tenant_id,
    'companyId',p_company,
    'branchId',p_branch,
    'items',items)::text;
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.scoped_device_revoke(
    p_digest text, p_company text, p_branch text, p_device text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE credential_row public.ventio_identity_credentials%ROWTYPE;
        target_device public.ventio_identity_devices%ROWTYPE;
BEGIN
  IF NOT pg_has_role(session_user,'ventio_identity_api','MEMBER') OR
      pg_has_role(session_user,'ventio_identity_admin','MEMBER') OR
      pg_has_role(session_user,'ventio_owner','MEMBER') OR
      pg_has_role(session_user,'ventio_migrator','MEMBER') OR
      EXISTS (SELECT FROM pg_catalog.pg_roles r WHERE r.rolname=session_user
        AND (r.rolsuper OR r.rolbypassrls OR r.rolcreatedb OR
          r.rolcreaterole OR r.rolreplication)) OR
      NOT ventio_security.recovery_guard() OR
      p_digest IS NULL OR p_digest !~ '^[0-9a-f]{64}$' OR
      p_company IS NULL OR p_branch IS NULL OR
      p_device IS NULL OR
      p_device !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$' OR
      p_device ~ '^[A-Za-z0-9_-]{43,128}$' THEN
    RAISE EXCEPTION 'Invalid device revocation request' USING ERRCODE='22023';
  END IF;
  PERFORM pg_advisory_xact_lock(86744321);
  SELECT c.* INTO credential_row
    FROM public.ventio_identity_credentials c
    JOIN public.ventio_identity_users u
      ON u.tenant_id=c.tenant_id AND u.actor_id=c.actor_id
    JOIN public.ventio_identity_devices d
      ON d.tenant_id=c.tenant_id AND d.actor_id=c.actor_id AND d.device_id=c.device_id
    WHERE c.token_digest=p_digest AND c.revoked_at IS NULL
      AND c.expires_at>clock_timestamp() AND u.disabled_at IS NULL
      AND d.revoked_at IS NULL
    FOR SHARE OF c,u,d;
  IF NOT FOUND OR NOT ventio_security.identity_device_manager_allowed(
      p_digest,credential_row.tenant_id,p_company,p_branch) THEN
    RAISE EXCEPTION 'Device administration denied' USING ERRCODE='42501';
  END IF;

  SELECT d.* INTO target_device
    FROM public.ventio_identity_devices d
    WHERE d.tenant_id=credential_row.tenant_id AND d.device_id=p_device
      AND d.revoked_at IS NULL AND (
        EXISTS (SELECT FROM public.ventio_identity_grants g
          WHERE g.tenant_id=d.tenant_id AND g.actor_id=d.actor_id
            AND g.company_id=p_company AND g.branch_id=p_branch) OR
        EXISTS (SELECT FROM public.ventio_identity_role_assignments a
          WHERE a.tenant_id=d.tenant_id AND a.actor_id=d.actor_id
            AND a.company_id=p_company AND a.branch_id=p_branch))
    FOR UPDATE OF d;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Device unavailable' USING ERRCODE='P0002';
  END IF;

  -- A branch-scoped administrator cannot revoke a device whose active
  -- credential ceiling includes another branch. Keep that impact opaque.
  IF EXISTS (SELECT FROM public.ventio_identity_credentials c
      WHERE c.tenant_id=target_device.tenant_id
        AND c.actor_id=target_device.actor_id
        AND c.device_id=target_device.device_id
        AND c.revoked_at IS NULL AND c.expires_at>clock_timestamp()
        AND (c.allowed_scopes IS NULL AND (
          EXISTS (SELECT FROM public.ventio_identity_grants g
            WHERE g.tenant_id=c.tenant_id AND g.actor_id=c.actor_id
              AND (g.company_id,g.branch_id) IS DISTINCT FROM (p_company,p_branch)) OR
          EXISTS (SELECT FROM public.ventio_identity_role_assignments a
            WHERE a.tenant_id=c.tenant_id AND a.actor_id=c.actor_id
              AND (a.company_id,a.branch_id) IS DISTINCT FROM (p_company,p_branch))) OR
          (c.allowed_scopes IS NOT NULL AND EXISTS (
            SELECT FROM jsonb_array_elements(c.allowed_scopes) scope
            WHERE scope->>'companyId' IS DISTINCT FROM p_company OR
              scope->>'branchId' IS DISTINCT FROM p_branch)))) THEN
    RAISE EXCEPTION 'Device scope exceeds requested branch'
      USING ERRCODE='42501';
  END IF;

  UPDATE public.ventio_identity_devices
    SET revoked_at=clock_timestamp()
    WHERE tenant_id=target_device.tenant_id AND device_id=target_device.device_id;
  UPDATE public.ventio_identity_credentials
    SET revoked_at=clock_timestamp()
    WHERE tenant_id=target_device.tenant_id AND actor_id=target_device.actor_id
      AND device_id=target_device.device_id AND revoked_at IS NULL;
  INSERT INTO public.ventio_identity_audit
    (tenant_id,operator_label,action,subject_id,details)
    VALUES (credential_row.tenant_id,
      CASE WHEN credential_row.actor_id ~ '^usr_[0-9a-f]{32}$'
        THEN 'api:'||credential_row.actor_id ELSE 'Host administrator' END,
      'DEVICE_REVOKED',target_device.device_id,jsonb_build_object(
        'operatorActorId',credential_row.actor_id,
        'deviceId',target_device.device_id,
        'companyId',p_company,'branchId',p_branch));
  RETURN true;
END $fn$;

-- Rotate one exact-branch device credential without exposing its prior token.
-- The replacement inherits the prior credential's full (single-branch) scope
-- ceiling. The new bearer is generated by Host and only its digest reaches SQL.
CREATE OR REPLACE FUNCTION ventio_security.scoped_device_credential_rotate(
    p_digest text, p_company text, p_branch text, p_device text,
    p_previous_credential_id text, p_credential_id text,
    p_credential_digest text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE manager_row public.ventio_identity_credentials%ROWTYPE;
        target_row public.ventio_identity_credentials%ROWTYPE;
        device_row public.ventio_identity_devices%ROWTYPE;
        expires_value timestamptz;
BEGIN
  IF NOT pg_has_role(session_user,'ventio_identity_api','MEMBER') OR
      pg_has_role(session_user,'ventio_identity_admin','MEMBER') OR
      pg_has_role(session_user,'ventio_owner','MEMBER') OR
      pg_has_role(session_user,'ventio_migrator','MEMBER') OR
      EXISTS (SELECT FROM pg_catalog.pg_roles r WHERE r.rolname=session_user
        AND (r.rolsuper OR r.rolbypassrls OR r.rolcreatedb OR
          r.rolcreaterole OR r.rolreplication)) OR
      NOT ventio_security.recovery_guard() OR
      p_digest IS NULL OR p_digest !~ '^[0-9a-f]{64}$' OR
      p_company IS NULL OR p_branch IS NULL OR
      p_device IS NULL OR p_device !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$' OR
      p_device ~ '^[A-Za-z0-9_-]{43,128}$' OR
      p_previous_credential_id IS NULL OR
      length(trim(p_previous_credential_id)) NOT BETWEEN 1 AND 256 OR
      p_credential_id IS NULL OR p_credential_id !~ '^cred_[0-9a-f]{32}$' OR
      p_credential_digest IS NULL OR p_credential_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid device credential rotation request'
      USING ERRCODE='22023';
  END IF;
  PERFORM pg_advisory_xact_lock(86744321);
  SELECT c.* INTO manager_row
    FROM public.ventio_identity_credentials c
    JOIN public.ventio_identity_users u
      ON u.tenant_id=c.tenant_id AND u.actor_id=c.actor_id
    JOIN public.ventio_identity_devices d
      ON d.tenant_id=c.tenant_id AND d.actor_id=c.actor_id AND d.device_id=c.device_id
    WHERE c.token_digest=p_digest AND c.revoked_at IS NULL
      AND c.expires_at>clock_timestamp() AND u.disabled_at IS NULL
      AND d.revoked_at IS NULL
    FOR SHARE OF c,u,d;
  IF NOT FOUND OR NOT ventio_security.identity_device_manager_allowed(
      p_digest,manager_row.tenant_id,p_company,p_branch) THEN
    RAISE EXCEPTION 'Device administration denied' USING ERRCODE='42501';
  END IF;

  SELECT d.* INTO device_row
    FROM public.ventio_identity_devices d
    WHERE d.tenant_id=manager_row.tenant_id AND d.device_id=p_device
      AND d.revoked_at IS NULL AND (
        EXISTS (SELECT FROM public.ventio_identity_grants g
          WHERE g.tenant_id=d.tenant_id AND g.actor_id=d.actor_id
            AND g.company_id=p_company AND g.branch_id=p_branch) OR
        EXISTS (SELECT FROM public.ventio_identity_role_assignments a
          WHERE a.tenant_id=d.tenant_id AND a.actor_id=d.actor_id
            AND a.company_id=p_company AND a.branch_id=p_branch))
    FOR UPDATE OF d;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Device unavailable' USING ERRCODE='P0002';
  END IF;

  SELECT c.* INTO target_row FROM public.ventio_identity_credentials c
    WHERE c.tenant_id=device_row.tenant_id AND c.actor_id=device_row.actor_id
      AND c.device_id=device_row.device_id
      AND c.credential_id=p_previous_credential_id
      AND c.revoked_at IS NULL AND c.expires_at>clock_timestamp()
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active device credential unavailable' USING ERRCODE='P0002';
  END IF;
  IF target_row.allowed_scopes IS NULL OR
      jsonb_typeof(target_row.allowed_scopes)<>'array' OR
      jsonb_array_length(target_row.allowed_scopes)<>1 OR
      target_row.allowed_scopes->0->>'companyId' IS DISTINCT FROM p_company OR
      target_row.allowed_scopes->0->>'branchId' IS DISTINCT FROM p_branch THEN
    RAISE EXCEPTION 'Credential scope exceeds requested branch'
      USING ERRCODE='42501';
  END IF;
  IF target_row.allowed_scopes->0->'permissions' IS NULL OR
      jsonb_typeof(target_row.allowed_scopes->0->'permissions')<>'array' THEN
    RAISE EXCEPTION 'Invalid credential scope' USING ERRCODE='22023';
  END IF;

  expires_value := clock_timestamp()+interval '30 days';
  UPDATE public.ventio_identity_credentials
    SET revoked_at=clock_timestamp()
    WHERE token_digest=target_row.token_digest AND revoked_at IS NULL;
  INSERT INTO public.ventio_identity_credentials
    (tenant_id,actor_id,device_id,credential_id,token_digest,expires_at,allowed_scopes)
    VALUES (target_row.tenant_id,target_row.actor_id,target_row.device_id,
      p_credential_id,p_credential_digest,expires_value,target_row.allowed_scopes);
  INSERT INTO public.ventio_identity_audit
    (tenant_id,operator_label,action,subject_id,details)
    VALUES (manager_row.tenant_id,
      CASE WHEN manager_row.actor_id ~ '^usr_[0-9a-f]{32}$'
        THEN 'api:'||manager_row.actor_id ELSE 'Host administrator' END,
      'CREDENTIAL_ROTATED',p_device,jsonb_build_object(
        'operatorActorId',manager_row.actor_id,'deviceId',p_device,
        'companyId',p_company,'branchId',p_branch,
        'previousCredentialId',target_row.credential_id,
        'credentialId',p_credential_id,
        'expiresAtUtc',to_char(expires_value AT TIME ZONE 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')));
  RETURN jsonb_build_object(
    'tenantId',target_row.tenant_id,'actorId',target_row.actor_id,
    'deviceId',target_row.device_id,'credentialId',p_credential_id,
    'companyId',p_company,'branchId',p_branch,
    'expiresAtUtc',to_char(expires_value AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
END $fn$;
