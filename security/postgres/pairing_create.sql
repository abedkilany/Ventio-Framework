-- Idempotent Host pairing creation contract, applied by bootstrap and safe upgrade.
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

  -- An accepted request may be retried after its one-time response was lost.
  -- Resolve that request reference before the issuance rate limit so a retry
  -- cannot be mislabeled as a new rejected issuance. The lookup is scoped to
  -- the authenticated tenant, creator and branch, and never returns the code.
  IF EXISTS (SELECT FROM public.ventio_identity_pairings p
      WHERE p.pairing_id=p_pairing_id
        AND p.tenant_id=credential_row.tenant_id
        AND p.created_by_actor_id=credential_row.actor_id
        AND p.company_id=p_company AND p.branch_id=p_branch) THEN
    RAISE EXCEPTION 'Pairing request was already accepted'
      USING ERRCODE='23505';
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
            AND e.action IN ('USER_CREATED','USER_DISABLED','USER_ENABLED','PERMISSION_GRANTED',
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
