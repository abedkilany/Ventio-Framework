-- Included by bootstrap.sql inside its installation transaction as ventio_owner.
CREATE OR REPLACE FUNCTION ventio_security.admin_change(p jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE tenant text := p->>'tenantId'; actor text := p->>'actorId'; device text := p->>'deviceId';
  company text := p->>'companyId'; branch text := p->>'branchId'; permission_name text := p->>'permission';
  credential text := p->>'credentialId'; operation text := p->>'action'; label text := p->>'operatorLabel';
  subject text; details jsonb := '{}'; is_disabled timestamptz; revoked timestamptz; changed integer;
  value text; scopes jsonb; old_credential public.ventio_identity_credentials%ROWTYPE;

BEGIN
  PERFORM pg_advisory_xact_lock(86744321);
  IF tenant IS NULL OR label IS NULL OR operation IS NULL THEN RAISE EXCEPTION 'Missing administrative context'; END IF;
  FOREACH value IN ARRAY ARRAY[tenant,label,actor,device,company,branch,credential] LOOP
    IF value IS NOT NULL AND (length(trim(value)) < 1 OR length(value) > 256) THEN
      RAISE EXCEPTION 'Invalid identity identifier';
    END IF;
  END LOOP;
  IF operation = 'USER_CREATED' THEN
    IF actor IS NULL THEN RAISE EXCEPTION 'User is required'; END IF;
    INSERT INTO public.ventio_identity_users (tenant_id, actor_id) VALUES (tenant, actor);
    subject := actor;
  ELSIF operation = 'BRANCH_REGISTERED' THEN
    IF company IS NULL OR branch IS NULL THEN RAISE EXCEPTION 'Scope is required'; END IF;
    INSERT INTO public.ventio_identity_branches (tenant_id, company_id, branch_id)
      VALUES (tenant, company, branch) ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS changed = ROW_COUNT;
    IF changed = 0 THEN RETURN; END IF;
    subject := branch; details := jsonb_build_object('companyId', company);
  ELSE
    IF operation = 'DEVICE_REVOKED' THEN
      SELECT actor_id INTO actor FROM public.ventio_identity_devices WHERE tenant_id = tenant AND device_id = device;
    ELSIF operation IN ('CREDENTIAL_REVOKED','CREDENTIAL_ROTATED') THEN
      SELECT actor_id INTO actor FROM public.ventio_identity_credentials WHERE tenant_id = tenant AND credential_id = CASE WHEN operation='CREDENTIAL_ROTATED' THEN p->>'previousCredentialId' ELSE credential END;
    END IF;
    IF actor IS NULL THEN RAISE EXCEPTION 'Unknown identity'; END IF;
    SELECT disabled_at INTO is_disabled FROM public.ventio_identity_users
      WHERE tenant_id = tenant AND actor_id = actor FOR UPDATE;
    IF NOT FOUND OR (is_disabled IS NOT NULL AND operation NOT IN
        ('USER_DISABLED','DEVICE_REVOKED','CREDENTIAL_REVOKED','PERMISSION_REVOKED')) THEN
      RAISE EXCEPTION 'Unknown or disabled user';
    END IF;
    CASE operation
    WHEN 'DEVICE_REGISTERED' THEN
      IF device IS NULL THEN RAISE EXCEPTION 'Device is required'; END IF;
      INSERT INTO public.ventio_identity_devices (tenant_id, actor_id, device_id) VALUES (tenant, actor, device);
      subject := device; details := jsonb_build_object('actorId', actor);
    WHEN 'CREDENTIAL_ISSUED', 'CREDENTIAL_PROVISIONED', 'CREDENTIAL_ROTATED' THEN
      IF device IS NULL OR credential IS NULL OR p->>'tokenDigest' IS NULL OR p->>'expiresAt' IS NULL THEN
        RAISE EXCEPTION 'Credential fields are required';
      END IF;
      SELECT revoked_at INTO revoked FROM public.ventio_identity_devices
        WHERE tenant_id = tenant AND actor_id = actor AND device_id = device FOR UPDATE;
      IF NOT FOUND OR revoked IS NOT NULL THEN RAISE EXCEPTION 'Unknown or revoked device'; END IF;
      IF operation='CREDENTIAL_ISSUED' AND (SELECT enforced FROM ventio_security.recovery_state) THEN
        RAISE EXCEPTION 'Scoped provisioning is required';
      END IF;
      scopes := NULL;
      IF operation = 'CREDENTIAL_PROVISIONED' THEN
        scopes := p->'allowedScopes';
        IF scopes IS NULL OR jsonb_typeof(scopes) <> 'array' OR jsonb_array_length(scopes) NOT BETWEEN 1 AND 64 THEN
          RAISE EXCEPTION 'Explicit credential scopes are required';
        END IF;
        FOR value IN SELECT x->>'companyId' FROM jsonb_array_elements(scopes) x LOOP
          IF value IS NULL THEN RAISE EXCEPTION 'Invalid credential scope'; END IF;
        END LOOP;
        IF EXISTS (SELECT FROM jsonb_array_elements(scopes) s WHERE
            s->>'branchId' IS NULL OR jsonb_typeof(s->'permissions') IS DISTINCT FROM 'array' OR
            jsonb_array_length(s->'permissions') NOT BETWEEN 1 AND 64) THEN
          RAISE EXCEPTION 'Invalid credential scope';
        END IF;
        IF EXISTS (SELECT FROM jsonb_array_elements(scopes) s
            CROSS JOIN LATERAL jsonb_array_elements_text(s->'permissions') AS requested(value)
            WHERE NOT EXISTS (SELECT FROM public.ventio_identity_grants g WHERE
              g.tenant_id=tenant AND g.actor_id=actor AND g.company_id=s->>'companyId'
              AND g.branch_id=s->>'branchId' AND g.permission=requested.value)) THEN
          RAISE EXCEPTION 'Credential scope exceeds current grants';
        END IF;
      ELSIF operation = 'CREDENTIAL_ROTATED' THEN
        SELECT * INTO old_credential FROM public.ventio_identity_credentials
          WHERE tenant_id=tenant AND credential_id=p->>'previousCredentialId' FOR UPDATE;
        IF NOT FOUND OR old_credential.actor_id<>actor OR p->>'actorId' IS DISTINCT FROM actor OR old_credential.device_id<>device OR
            old_credential.revoked_at IS NOT NULL OR old_credential.expires_at<=clock_timestamp() OR
            old_credential.token_digest IS DISTINCT FROM p->>'previousDigest' OR
            old_credential.allowed_scopes IS NULL THEN
          RAISE EXCEPTION 'Credential is not eligible for rotation';
        END IF;
        scopes := old_credential.allowed_scopes;
        UPDATE public.ventio_identity_credentials SET revoked_at=clock_timestamp()
          WHERE token_digest=old_credential.token_digest;
      END IF;
      IF operation <> 'CREDENTIAL_ISSUED' AND
          ((p->>'expiresAt')::timestamptz<=clock_timestamp() OR
           (p->>'expiresAt')::timestamptz>clock_timestamp()+interval '30 days') THEN
        RAISE EXCEPTION 'Credential expiry exceeds lifecycle policy';
      END IF;
      INSERT INTO public.ventio_identity_credentials
        (tenant_id, actor_id, device_id, credential_id, token_digest, expires_at, allowed_scopes)
        VALUES (tenant, actor, device, credential, p->>'tokenDigest', (p->>'expiresAt')::timestamptz, scopes);
      subject := credential;
      details := jsonb_build_object('actorId', actor, 'deviceId', device, 'expiresAt', p->>'expiresAt', 'previousCredentialId', p->>'previousCredentialId');
    WHEN 'PERMISSION_GRANTED', 'PERMISSION_REVOKED' THEN
      IF company IS NULL OR branch IS NULL OR permission_name IS NULL OR
          permission_name !~ '^[a-z][a-z0-9_.]+$' OR length(permission_name) > 256 THEN
        RAISE EXCEPTION 'Invalid permission grant';
      END IF;
      IF operation = 'PERMISSION_GRANTED' THEN
        INSERT INTO public.ventio_identity_grants (tenant_id, actor_id, company_id, branch_id, permission)
          VALUES (tenant, actor, company, branch, permission_name) ON CONFLICT DO NOTHING;
      ELSE
        DELETE FROM public.ventio_identity_grants WHERE tenant_id = tenant AND actor_id = actor
          AND company_id = company AND branch_id = branch AND permission = permission_name;
      END IF;
      GET DIAGNOSTICS changed = ROW_COUNT;
      IF changed = 0 THEN RETURN; END IF;
      subject := actor; details := jsonb_build_object('companyId', company, 'branchId', branch, 'permission', permission_name);
    WHEN 'DEVICE_REVOKED' THEN
      UPDATE public.ventio_identity_devices SET revoked_at = clock_timestamp()
        WHERE tenant_id = tenant AND device_id = device AND revoked_at IS NULL;
      GET DIAGNOSTICS changed = ROW_COUNT;
      IF changed = 0 THEN RETURN; END IF;
      subject := device;
    WHEN 'CREDENTIAL_REVOKED' THEN
      UPDATE public.ventio_identity_credentials SET revoked_at = clock_timestamp()
        WHERE tenant_id = tenant AND credential_id = credential AND revoked_at IS NULL;
      GET DIAGNOSTICS changed = ROW_COUNT;
      IF changed = 0 THEN RETURN; END IF;
      subject := credential;
    WHEN 'USER_DISABLED' THEN
      UPDATE public.ventio_identity_users SET disabled_at = clock_timestamp()
        WHERE tenant_id = tenant AND actor_id = actor AND disabled_at IS NULL;
      GET DIAGNOSTICS changed = ROW_COUNT;
      IF changed = 0 THEN RETURN; END IF;
      subject := actor;
    ELSE RAISE EXCEPTION 'Unknown administrative operation';
    END CASE;
  END IF;
  -- session_user remains the authenticated DB login across SECURITY DEFINER.
  INSERT INTO public.ventio_identity_audit (tenant_id, operator_label, action, subject_id, details)
    VALUES (tenant, label, operation, subject, details);
END $fn$;
