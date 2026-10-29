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
CREATE OR REPLACE FUNCTION ventio_security.scoped_pairing_create(
    p_digest text, p_company text, p_branch text, p_actor text,
    p_pairing_id text, p_pairing_digest text)
RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE credential_row public.ventio_identity_credentials%ROWTYPE;
        target_disabled timestamptz; created_at_value timestamptz;
        expires_at_value timestamptz; caller_permissions text[] := '{}';
        target_permissions text[] := '{}';
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
      p_pairing_id IS NULL OR p_pairing_id !~ '^pair_[0-9a-f]{32}$' OR
      p_pairing_digest IS NULL OR p_pairing_digest !~ '^[0-9a-f]{64}$' OR
      p_company IS NULL OR p_branch IS NULL OR p_actor IS NULL OR
      length(trim(p_company)) NOT BETWEEN 1 AND 256 OR
      length(trim(p_branch)) NOT BETWEEN 1 AND 256 OR
      length(trim(p_actor)) NOT BETWEEN 1 AND 256 THEN
    RAISE EXCEPTION 'Invalid pairing request' USING ERRCODE='22023';
  END IF;

  PERFORM pg_advisory_xact_lock(86744321);
  SELECT c.* INTO credential_row
    FROM public.ventio_identity_credentials c
    JOIN public.ventio_identity_users u
      ON u.tenant_id=c.tenant_id AND u.actor_id=c.actor_id
    JOIN public.ventio_identity_devices d
      ON d.tenant_id=c.tenant_id AND d.actor_id=c.actor_id AND d.device_id=c.device_id
    WHERE c.token_digest=p_digest AND c.revoked_at IS NULL
      AND c.expires_at>clock_timestamp() AND u.disabled_at IS NULL AND d.revoked_at IS NULL
    FOR SHARE OF c,u,d;
  IF NOT FOUND OR NOT ventio_security.identity_pairing_manager_allowed(
      p_digest,credential_row.tenant_id,p_company,p_branch) THEN
    RAISE EXCEPTION 'Pairing administration denied' USING ERRCODE='42501';
  END IF;

  SELECT disabled_at INTO target_disabled
    FROM public.ventio_identity_users
    WHERE tenant_id=credential_row.tenant_id AND actor_id=p_actor
    FOR UPDATE;
  IF NOT FOUND OR target_disabled IS NOT NULL OR
      (NOT EXISTS (SELECT FROM public.ventio_identity_grants g
          WHERE g.tenant_id=credential_row.tenant_id AND g.actor_id=p_actor
            AND g.company_id=p_company AND g.branch_id=p_branch) AND
       NOT EXISTS (SELECT FROM public.ventio_identity_role_assignments a
          WHERE a.tenant_id=credential_row.tenant_id AND a.actor_id=p_actor
            AND a.company_id=p_company AND a.branch_id=p_branch) AND
       NOT EXISTS (SELECT FROM public.ventio_identity_audit e
          WHERE e.tenant_id=credential_row.tenant_id AND e.subject_id=p_actor
            AND e.action IN ('USER_CREATED','USER_DISABLED','PERMISSION_GRANTED',
              'PERMISSION_REVOKED','ROLE_ASSIGNED','ROLE_UNASSIGNED')
            AND e.details->>'companyId'=p_company
            AND e.details->>'branchId'=p_branch)) THEN
    RAISE EXCEPTION 'Pairing target unavailable' USING ERRCODE='P0002';
  END IF;

  SELECT coalesce(array_agg(permission ORDER BY permission),'{}'::text[])
    INTO caller_permissions FROM (
      SELECT g.permission FROM public.ventio_identity_grants g
        WHERE g.tenant_id=credential_row.tenant_id
          AND g.actor_id=credential_row.actor_id
          AND g.company_id=p_company AND g.branch_id=p_branch
          AND EXISTS (
            SELECT FROM jsonb_array_elements(credential_row.allowed_scopes) s
            WHERE s->>'companyId'=p_company AND s->>'branchId'=p_branch
              AND s->'permissions' ? g.permission)
      UNION
      SELECT rp.permission FROM public.ventio_identity_role_assignments a
        JOIN public.ventio_identity_role_permissions rp USING (tenant_id,role_id)
        WHERE a.tenant_id=credential_row.tenant_id
          AND a.actor_id=credential_row.actor_id
          AND a.company_id=p_company AND a.branch_id=p_branch
          AND rp.permission !~ '^(identity|host|system|security|recovery|authorization)\.'
          AND EXISTS (
            SELECT FROM jsonb_array_elements(credential_row.allowed_scopes) s
            WHERE s->>'companyId'=p_company AND s->>'branchId'=p_branch
              AND s->'permissions' ? rp.permission)
    ) caller_effective;
  SELECT coalesce(array_agg(permission ORDER BY permission),'{}'::text[])
    INTO target_permissions FROM (
      SELECT g.permission FROM public.ventio_identity_grants g
        WHERE g.tenant_id=credential_row.tenant_id
          AND g.actor_id=p_actor AND g.company_id=p_company AND g.branch_id=p_branch
      UNION
      SELECT rp.permission FROM public.ventio_identity_role_assignments a
        JOIN public.ventio_identity_role_permissions rp USING (tenant_id,role_id)
        WHERE a.tenant_id=credential_row.tenant_id AND a.actor_id=p_actor
          AND a.company_id=p_company AND a.branch_id=p_branch
          AND rp.permission !~ '^(identity|host|system|security|recovery|authorization)\.'
    ) target_effective;
  IF NOT target_permissions <@ caller_permissions THEN
    RAISE EXCEPTION 'Pairing target exceeds caller authority' USING ERRCODE='42501';
  END IF;

  IF (SELECT count(*) FROM public.ventio_identity_pairings p
      WHERE p.tenant_id=credential_row.tenant_id
        AND p.created_by_actor_id=credential_row.actor_id
        AND p.company_id=p_company AND p.branch_id=p_branch
        AND p.created_at>=clock_timestamp()-interval '15 minutes')>=10 THEN
    RAISE EXCEPTION 'Pairing issue rate limit reached' USING ERRCODE='54000';
  END IF;

  created_at_value := clock_timestamp();
  expires_at_value := created_at_value + interval '5 minutes';
  INSERT INTO public.ventio_identity_pairings
    (pairing_id,pairing_digest,tenant_id,actor_id,company_id,branch_id,
     created_by_actor_id,allowed_permissions,created_at,expires_at)
    VALUES (p_pairing_id,p_pairing_digest,credential_row.tenant_id,p_actor,
      p_company,p_branch,credential_row.actor_id,target_permissions,
      created_at_value,expires_at_value);
  INSERT INTO public.ventio_identity_audit
    (tenant_id,operator_label,action,subject_id,details)
    VALUES (credential_row.tenant_id,'api:'||left(credential_row.actor_id,252),
      'PAIRING_CREATED',p_pairing_id,jsonb_build_object(
        'operatorActorId',credential_row.actor_id,'actorId',p_actor,
        'deviceRole','CLIENT','companyId',p_company,'branchId',p_branch,
        'expiresAtUtc',to_char(expires_at_value AT TIME ZONE 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')));
  RETURN expires_at_value;
END $fn$;

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
  UPDATE public.ventio_identity_pairings
    SET redeemed_at=now_value,redeemed_device_id=p_device_id
    WHERE pairing_id=pairing_row.pairing_id;
  INSERT INTO public.ventio_identity_devices
    (tenant_id,actor_id,device_id,device_role)
    VALUES (pairing_row.tenant_id,pairing_row.actor_id,p_device_id,'CLIENT');
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
        -- Activity collection is not yet enabled on this Host schema. Null is
        -- explicit; it must not be presented as a connected/offline signal.
        'lastAuthenticatedAtUtc',NULL,
        'credentials',coalesce((
          SELECT jsonb_agg(jsonb_build_object(
            'credentialId',c.credential_id,
            'state',CASE WHEN c.revoked_at IS NOT NULL THEN 'REVOKED'
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
