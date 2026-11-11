-- Same-device credential replacement is a durable, two-phase transition.
-- Only a trusted Windows broker can prepare it; the registered Client must
-- claim it over its existing credential and acknowledge with the replacement.

ALTER TABLE public.ventio_identity_credential_reissues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ventio_identity_credential_reissues FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS owner_access ON public.ventio_identity_credential_reissues;
CREATE POLICY owner_access ON public.ventio_identity_credential_reissues
  TO ventio_owner USING (true) WITH CHECK (true);
REVOKE ALL ON TABLE public.ventio_identity_credential_reissues
  FROM PUBLIC, ventio_runtime, ventio_identity_admin, ventio_identity_api;

CREATE OR REPLACE FUNCTION ventio_security.trusted_windows_credential_reissue_prepare(
    p_operator_digest text, p_tenant text, p_operator_actor text,
    p_company text, p_branch text, p_device text, p_target_actor text,
    p_source_credential_id text, p_operation_id text,
    p_replacement_credential_id text, p_replacement_digest text,
    p_delivery_ciphertext bytea, p_permissions text[], p_approved_removals text[],
    p_windows_admin_tag text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE operator_row public.ventio_identity_credentials%ROWTYPE;
        device_row public.ventio_identity_devices%ROWTYPE;
        source_row public.ventio_identity_credentials%ROWTYPE;
        prior_row public.ventio_identity_credential_reissues%ROWTYPE;
        current_permissions text[] := '{}';
        source_permissions text[] := '{}';
        required_removals text[] := '{}';
        additions text[] := '{}';
        created_at_value timestamptz;
        expires_at_value timestamptz;
BEGIN
  IF NOT pg_has_role(session_user,'ventio_identity_api','MEMBER') OR
      pg_has_role(session_user,'ventio_identity_admin','MEMBER') OR
      pg_has_role(session_user,'ventio_owner','MEMBER') OR
      pg_has_role(session_user,'ventio_migrator','MEMBER') OR
      EXISTS (SELECT FROM pg_catalog.pg_roles r WHERE r.rolname=session_user
        AND (r.rolsuper OR r.rolbypassrls OR r.rolcreatedb OR
          r.rolcreaterole OR r.rolreplication)) OR
      NOT ventio_security.recovery_guard() OR
      p_operator_digest IS NULL OR p_operator_digest !~ '^[0-9a-f]{64}$' OR
      p_tenant IS NULL OR length(trim(p_tenant)) NOT BETWEEN 1 AND 256 OR
      p_operator_actor IS NULL OR length(trim(p_operator_actor)) NOT BETWEEN 1 AND 256 OR
      p_company IS NULL OR length(trim(p_company)) NOT BETWEEN 1 AND 256 OR
      p_branch IS NULL OR length(trim(p_branch)) NOT BETWEEN 1 AND 256 OR
      p_device IS NULL OR p_device !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$' OR
      p_device ~ '^[A-Za-z0-9_-]{43,128}$' OR
      p_target_actor IS NULL OR length(trim(p_target_actor)) NOT BETWEEN 1 AND 256 OR
      p_source_credential_id IS NULL OR length(trim(p_source_credential_id)) NOT BETWEEN 1 AND 256 OR
      p_operation_id IS NULL OR p_operation_id !~ '^reissue_[0-9a-f]{32}$' OR
      p_replacement_credential_id IS NULL OR p_replacement_credential_id !~ '^cred_[0-9a-f]{32}$' OR
      p_replacement_digest IS NULL OR p_replacement_digest !~ '^[0-9a-f]{64}$' OR
      p_delivery_ciphertext IS NULL OR octet_length(p_delivery_ciphertext) NOT BETWEEN 1 AND 8192 OR
      p_windows_admin_tag IS NULL OR p_windows_admin_tag !~ '^[0-9a-f]{16}$' OR
      p_permissions IS NULL OR cardinality(p_permissions) NOT BETWEEN 1 AND 128 OR
      cardinality(ARRAY(SELECT DISTINCT x FROM unnest(p_permissions) x)) <> cardinality(p_permissions) OR
      EXISTS (SELECT FROM unnest(p_permissions) x WHERE x IS NULL OR
        x !~ '^[a-z][a-z0-9_.]{0,255}$') OR
      p_approved_removals IS NULL OR cardinality(p_approved_removals)>128 OR
      cardinality(ARRAY(SELECT DISTINCT x FROM unnest(p_approved_removals) x)) <> cardinality(p_approved_removals) OR
      EXISTS (SELECT FROM unnest(p_approved_removals) x WHERE x IS NULL OR
        x !~ '^[a-z][a-z0-9_.]{0,255}$') THEN
    RAISE EXCEPTION 'Invalid trusted credential reissue request' USING ERRCODE='22023';
  END IF;

  PERFORM pg_advisory_xact_lock(86744321);
  SELECT c.* INTO operator_row
    FROM public.ventio_identity_credentials c
    JOIN public.ventio_identity_users u USING (tenant_id,actor_id)
    JOIN public.ventio_identity_devices d
      ON d.tenant_id=c.tenant_id AND d.actor_id=c.actor_id AND d.device_id=c.device_id
    WHERE c.token_digest=p_operator_digest AND c.actor_id=p_operator_actor
      AND c.revoked_at IS NULL AND c.expires_at>clock_timestamp()
      AND u.disabled_at IS NULL AND d.revoked_at IS NULL
    FOR SHARE OF c,u,d;
  IF NOT FOUND OR operator_row.tenant_id IS DISTINCT FROM p_tenant OR
      NOT ventio_security.identity_device_manager_allowed(
        p_operator_digest,p_tenant,p_company,p_branch) THEN
    RAISE EXCEPTION 'Credential reissue operator denied' USING ERRCODE='42501';
  END IF;

  -- Stable operation references reconcile lost responses. A duplicate request
  -- never creates a second transition and never returns a newly generated token.
  SELECT * INTO prior_row FROM public.ventio_identity_credential_reissues r
    WHERE r.operation_id=p_operation_id FOR UPDATE;
  IF FOUND THEN
    IF prior_row.tenant_id IS DISTINCT FROM p_tenant OR
        prior_row.operator_actor_id IS DISTINCT FROM p_operator_actor OR
        prior_row.company_id IS DISTINCT FROM p_company OR
        prior_row.branch_id IS DISTINCT FROM p_branch OR
        prior_row.device_id IS DISTINCT FROM p_device OR
        prior_row.actor_id IS DISTINCT FROM p_target_actor OR
        prior_row.source_credential_id IS DISTINCT FROM p_source_credential_id OR
        prior_row.allowed_permissions IS DISTINCT FROM p_permissions OR
        prior_row.approved_removals IS DISTINCT FROM p_approved_removals THEN
      RAISE EXCEPTION 'Credential reissue reference conflict' USING ERRCODE='23505';
    END IF;
    RETURN jsonb_build_object('operationId',prior_row.operation_id,
      'state',prior_row.state,'tenantId',prior_row.tenant_id,
      'actorId',prior_row.actor_id,'deviceId',prior_row.device_id,
      'companyId',prior_row.company_id,'branchId',prior_row.branch_id,
      'credentialId',prior_row.replacement_credential_id,
      'permissions',to_jsonb(prior_row.allowed_permissions),
      'expiresAtUtc',to_char(prior_row.expires_at AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
  END IF;

  SELECT d.* INTO device_row FROM public.ventio_identity_devices d
    JOIN public.ventio_identity_users u USING (tenant_id,actor_id)
    WHERE d.tenant_id=p_tenant AND d.device_id=p_device
      AND d.revoked_at IS NULL AND u.disabled_at IS NULL
      AND ((EXISTS (SELECT FROM public.ventio_identity_grants g
          WHERE g.tenant_id=d.tenant_id AND g.actor_id=d.actor_id
            AND g.company_id=p_company AND g.branch_id=p_branch)) OR
        (EXISTS (SELECT FROM public.ventio_identity_role_assignments a
          WHERE a.tenant_id=d.tenant_id AND a.actor_id=d.actor_id
            AND a.company_id=p_company AND a.branch_id=p_branch)))
    FOR UPDATE OF d;
  IF NOT FOUND OR device_row.actor_id IS DISTINCT FROM p_target_actor THEN
    RAISE EXCEPTION 'Target device unavailable' USING ERRCODE='P0002';
  END IF;
  SELECT c.* INTO source_row FROM public.ventio_identity_credentials c
    WHERE c.tenant_id=p_tenant AND c.actor_id=device_row.actor_id
      AND c.device_id=p_device AND c.credential_id=p_source_credential_id
      AND c.revoked_at IS NULL AND c.expires_at>clock_timestamp()
    FOR UPDATE;
  IF NOT FOUND OR source_row.allowed_scopes IS NULL OR
      jsonb_typeof(source_row.allowed_scopes)<>'array' OR
      jsonb_array_length(source_row.allowed_scopes)<>1 OR
      source_row.allowed_scopes->0->>'companyId' IS DISTINCT FROM p_company OR
      source_row.allowed_scopes->0->>'branchId' IS DISTINCT FROM p_branch OR
      jsonb_typeof(source_row.allowed_scopes->0->'permissions')<>'array' THEN
    RAISE EXCEPTION 'Source credential unavailable or out of scope' USING ERRCODE='42501';
  END IF;
  SELECT coalesce(array_agg(DISTINCT permission ORDER BY permission),'{}'::text[])
    INTO current_permissions FROM (
      SELECT g.permission FROM public.ventio_identity_grants g
        WHERE g.tenant_id=p_tenant AND g.actor_id=device_row.actor_id
          AND g.company_id=p_company AND g.branch_id=p_branch
      UNION
      SELECT rp.permission FROM public.ventio_identity_role_assignments a
        JOIN public.ventio_identity_role_permissions rp USING (tenant_id,role_id)
        WHERE a.tenant_id=p_tenant AND a.actor_id=device_row.actor_id
          AND a.company_id=p_company AND a.branch_id=p_branch) effective;
  SELECT coalesce(array_agg(DISTINCT permission ORDER BY permission),'{}'::text[])
    INTO source_permissions FROM jsonb_array_elements_text(
      source_row.allowed_scopes->0->'permissions') permission;
  IF NOT (p_permissions <@ current_permissions) THEN
    RAISE EXCEPTION 'Requested permission is not currently granted' USING ERRCODE='42501';
  END IF;
  SELECT coalesce(array_agg(permission ORDER BY permission),'{}'::text[])
    INTO required_removals FROM unnest(source_permissions) permission
    WHERE permission=ANY(current_permissions) AND NOT permission=ANY(p_permissions);
  IF required_removals IS DISTINCT FROM p_approved_removals THEN
    RAISE EXCEPTION 'Permission removal requires explicit approval' USING ERRCODE='42501';
  END IF;
  SELECT coalesce(array_agg(permission ORDER BY permission),'{}'::text[])
    INTO additions FROM unnest(p_permissions) permission
    WHERE NOT permission=ANY(source_permissions);
  IF EXISTS (SELECT FROM unnest(additions) permission WHERE
      permission ~ '^(identity|host|system|security|recovery|authorization)\.') THEN
    RAISE EXCEPTION 'New management permissions require a separate authorization' USING ERRCODE='42501';
  END IF;
  INSERT INTO public.ventio_identity_audit
    (tenant_id,operator_label,action,subject_id,details)
    SELECT r.tenant_id,'api:'||p_operator_actor,
      'CREDENTIAL_REISSUE_EXPIRED',r.device_id,jsonb_build_object(
        'operationId',r.operation_id,'deviceId',r.device_id,
        'actorId',r.actor_id,'companyId',r.company_id,
        'branchId',r.branch_id,'reason','PENDING_WINDOW_ELAPSED')
      FROM public.ventio_identity_credential_reissues r
      WHERE r.tenant_id=p_tenant AND r.device_id=p_device
        AND r.state='PREPARED' AND r.expires_at<=clock_timestamp();
  UPDATE public.ventio_identity_credential_reissues
    SET state='EXPIRED',delivery_ciphertext=NULL
    WHERE tenant_id=p_tenant AND device_id=p_device
      AND state='PREPARED' AND expires_at<=clock_timestamp();
  IF EXISTS (SELECT FROM public.ventio_identity_credential_reissues r
      WHERE r.tenant_id=p_tenant AND r.device_id=p_device AND r.state='PREPARED') THEN
    RAISE EXCEPTION 'Credential reissue already pending' USING ERRCODE='55P03';
  END IF;

  created_at_value := clock_timestamp();
  expires_at_value := created_at_value + interval '15 minutes';
  INSERT INTO public.ventio_identity_credential_reissues (
    operation_id,tenant_id,actor_id,device_id,company_id,branch_id,
    operator_actor_id,source_credential_id,replacement_credential_id,
    replacement_token_digest,allowed_permissions,approved_removals,
    delivery_ciphertext,created_at,expires_at)
  VALUES (p_operation_id,p_tenant,device_row.actor_id,p_device,p_company,p_branch,
    p_operator_actor,p_source_credential_id,p_replacement_credential_id,
    p_replacement_digest,p_permissions,p_approved_removals,
    p_delivery_ciphertext,created_at_value,expires_at_value);
  INSERT INTO public.ventio_identity_audit
    (tenant_id,operator_label,action,subject_id,details)
  VALUES (p_tenant,'windows-admin:'||p_windows_admin_tag,
    'CREDENTIAL_REISSUE_PREPARED',p_device,jsonb_build_object(
      'operationId',p_operation_id,'operatorActorId',p_operator_actor,
      'actorId',device_row.actor_id,'deviceId',p_device,
      'sourceCredentialId',p_source_credential_id,
      'replacementCredentialId',p_replacement_credential_id,
      'companyId',p_company,'branchId',p_branch,
      'permissions',to_jsonb(p_permissions),
      'approvedRemovals',to_jsonb(p_approved_removals),
      'windowsAdministratorApproved',true,
      'expiresAtUtc',to_char(expires_at_value AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')));
  RETURN jsonb_build_object('operationId',p_operation_id,'state','PREPARED',
    'tenantId',p_tenant,'actorId',device_row.actor_id,'deviceId',p_device,
    'companyId',p_company,'branchId',p_branch,
    'credentialId',p_replacement_credential_id,
    'permissions',to_jsonb(p_permissions),
    'expiresAtUtc',to_char(expires_at_value AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.credential_reissue_claim(
    p_source_digest text, p_operation_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE source_row public.ventio_identity_credentials%ROWTYPE;
        reissue_row public.ventio_identity_credential_reissues%ROWTYPE;
        current_permissions text[] := '{}';
BEGIN
  IF NOT pg_has_role(session_user,'ventio_identity_api','MEMBER') OR
      pg_has_role(session_user,'ventio_identity_admin','MEMBER') OR
      pg_has_role(session_user,'ventio_owner','MEMBER') OR
      pg_has_role(session_user,'ventio_migrator','MEMBER') OR
      EXISTS (SELECT FROM pg_catalog.pg_roles r WHERE r.rolname=session_user
        AND (r.rolsuper OR r.rolbypassrls OR r.rolcreatedb OR
          r.rolcreaterole OR r.rolreplication)) OR
      NOT ventio_security.recovery_guard() OR
      p_source_digest IS NULL OR p_source_digest !~ '^[0-9a-f]{64}$' OR
      p_operation_id IS NULL OR p_operation_id !~ '^reissue_[0-9a-f]{32}$' THEN
    RAISE EXCEPTION 'Invalid credential reissue claim' USING ERRCODE='22023';
  END IF;
  SELECT c.* INTO source_row FROM public.ventio_identity_credentials c
    JOIN public.ventio_identity_users u USING (tenant_id,actor_id)
    JOIN public.ventio_identity_devices d
      ON d.tenant_id=c.tenant_id AND d.actor_id=c.actor_id AND d.device_id=c.device_id
    WHERE c.token_digest=p_source_digest AND c.revoked_at IS NULL
      AND c.expires_at>clock_timestamp() AND u.disabled_at IS NULL
      AND d.revoked_at IS NULL FOR SHARE OF c,u,d;
  IF NOT FOUND THEN RAISE EXCEPTION 'Credential unavailable' USING ERRCODE='42501'; END IF;
  SELECT r.* INTO reissue_row FROM public.ventio_identity_credential_reissues r
    WHERE r.operation_id=p_operation_id AND r.tenant_id=source_row.tenant_id
      AND r.actor_id=source_row.actor_id AND r.device_id=source_row.device_id
      AND r.source_credential_id=source_row.credential_id
      AND r.state='PREPARED' AND r.expires_at>clock_timestamp()
    FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Credential reissue unavailable' USING ERRCODE='P0002'; END IF;
  IF NOT EXISTS (SELECT FROM public.ventio_identity_devices d
      WHERE d.tenant_id=reissue_row.tenant_id AND d.device_id=reissue_row.device_id
        AND d.actor_id=reissue_row.actor_id AND d.revoked_at IS NULL) OR
      NOT EXISTS (SELECT FROM public.ventio_identity_users u
        WHERE u.tenant_id=reissue_row.tenant_id AND u.actor_id=reissue_row.actor_id
          AND u.disabled_at IS NULL) THEN
    RAISE EXCEPTION 'Credential reissue target unavailable' USING ERRCODE='P0002';
  END IF;
  SELECT coalesce(array_agg(DISTINCT permission ORDER BY permission),'{}'::text[])
    INTO current_permissions FROM (
      SELECT g.permission FROM public.ventio_identity_grants g
        WHERE g.tenant_id=reissue_row.tenant_id AND g.actor_id=reissue_row.actor_id
          AND g.company_id=reissue_row.company_id AND g.branch_id=reissue_row.branch_id
      UNION
      SELECT rp.permission FROM public.ventio_identity_role_assignments a
        JOIN public.ventio_identity_role_permissions rp USING (tenant_id,role_id)
        WHERE a.tenant_id=reissue_row.tenant_id AND a.actor_id=reissue_row.actor_id
          AND a.company_id=reissue_row.company_id AND a.branch_id=reissue_row.branch_id) effective;
  IF NOT (reissue_row.allowed_permissions <@ current_permissions) THEN
    RAISE EXCEPTION 'Credential reissue no longer authorized' USING ERRCODE='42501';
  END IF;
  RETURN jsonb_build_object('operationId',reissue_row.operation_id,
    'state','PREPARED',
    'tenantId',reissue_row.tenant_id,'actorId',reissue_row.actor_id,
    'deviceId',reissue_row.device_id,'companyId',reissue_row.company_id,
    'branchId',reissue_row.branch_id,
    'credentialId',reissue_row.replacement_credential_id,
    'permissions',to_jsonb(reissue_row.allowed_permissions),
    'expiresAtUtc',to_char(reissue_row.expires_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'deliveryCiphertext',translate(
      encode(reissue_row.delivery_ciphertext,'base64'),E'\r\n',''));
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.credential_reissue_pending_claim(
    p_source_digest text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE source_row public.ventio_identity_credentials%ROWTYPE;
        operation_id_value text;
BEGIN
  IF NOT pg_has_role(session_user,'ventio_identity_api','MEMBER') OR
      pg_has_role(session_user,'ventio_identity_admin','MEMBER') OR
      pg_has_role(session_user,'ventio_owner','MEMBER') OR
      pg_has_role(session_user,'ventio_migrator','MEMBER') OR
      EXISTS (SELECT FROM pg_catalog.pg_roles r WHERE r.rolname=session_user
        AND (r.rolsuper OR r.rolbypassrls OR r.rolcreatedb OR
          r.rolcreaterole OR r.rolreplication)) OR
      NOT ventio_security.recovery_guard() OR
      p_source_digest IS NULL OR p_source_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid credential reissue poll' USING ERRCODE='22023';
  END IF;
  SELECT c.* INTO source_row FROM public.ventio_identity_credentials c
    JOIN public.ventio_identity_users u USING (tenant_id,actor_id)
    JOIN public.ventio_identity_devices d
      ON d.tenant_id=c.tenant_id AND d.actor_id=c.actor_id AND d.device_id=c.device_id
    WHERE c.token_digest=p_source_digest AND c.revoked_at IS NULL
      AND c.expires_at>clock_timestamp() AND u.disabled_at IS NULL
      AND d.revoked_at IS NULL FOR SHARE OF c,u,d;
  IF NOT FOUND THEN RAISE EXCEPTION 'Credential unavailable' USING ERRCODE='42501'; END IF;
  SELECT r.operation_id INTO operation_id_value
    FROM public.ventio_identity_credential_reissues r
    WHERE r.tenant_id=source_row.tenant_id AND r.actor_id=source_row.actor_id
      AND r.device_id=source_row.device_id
      AND r.source_credential_id=source_row.credential_id
      AND r.state='PREPARED' AND r.expires_at>clock_timestamp()
    LIMIT 1;
  IF operation_id_value IS NULL THEN RETURN jsonb_build_object('state','NONE'); END IF;
  RETURN ventio_security.credential_reissue_claim(p_source_digest,operation_id_value);
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.credential_reissue_finalize(
    p_replacement_digest text, p_operation_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE reissue_row public.ventio_identity_credential_reissues%ROWTYPE;
        current_permissions text[] := '{}';
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
      p_replacement_digest IS NULL OR p_replacement_digest !~ '^[0-9a-f]{64}$' OR
      p_operation_id IS NULL OR p_operation_id !~ '^reissue_[0-9a-f]{32}$' THEN
    RAISE EXCEPTION 'Invalid credential reissue acknowledgment' USING ERRCODE='22023';
  END IF;
  PERFORM pg_advisory_xact_lock(86744321);
  SELECT r.* INTO reissue_row FROM public.ventio_identity_credential_reissues r
    WHERE r.operation_id=p_operation_id
      AND r.replacement_token_digest=p_replacement_digest
    FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Credential reissue unavailable' USING ERRCODE='P0002'; END IF;
  IF reissue_row.state='FINALIZED' THEN
    RETURN jsonb_build_object('operationId',reissue_row.operation_id,
      'state','FINALIZED','tenantId',reissue_row.tenant_id,
      'actorId',reissue_row.actor_id,'deviceId',reissue_row.device_id,
      'companyId',reissue_row.company_id,'branchId',reissue_row.branch_id,
      'credentialId',reissue_row.replacement_credential_id);
  END IF;
  IF reissue_row.state<>'PREPARED' THEN
    RETURN jsonb_build_object('operationId',reissue_row.operation_id,
      'state',reissue_row.state,'tenantId',reissue_row.tenant_id,
      'actorId',reissue_row.actor_id,'deviceId',reissue_row.device_id,
      'companyId',reissue_row.company_id,'branchId',reissue_row.branch_id,
      'credentialId',reissue_row.replacement_credential_id);
  END IF;
  IF reissue_row.expires_at<=clock_timestamp() THEN
    UPDATE public.ventio_identity_credential_reissues
      SET state='EXPIRED',delivery_ciphertext=NULL
      WHERE operation_id=p_operation_id;
    INSERT INTO public.ventio_identity_audit
      (tenant_id,operator_label,action,subject_id,details)
      VALUES (reissue_row.tenant_id,'api:'||reissue_row.operator_actor_id,
        'CREDENTIAL_REISSUE_EXPIRED',reissue_row.device_id,jsonb_build_object(
          'operationId',p_operation_id,'deviceId',reissue_row.device_id,
          'actorId',reissue_row.actor_id,'companyId',reissue_row.company_id,
          'branchId',reissue_row.branch_id));
    RETURN jsonb_build_object('operationId',p_operation_id,'state','EXPIRED');
  END IF;
  IF NOT EXISTS (SELECT FROM public.ventio_identity_users u
      JOIN public.ventio_identity_devices d USING (tenant_id,actor_id)
      WHERE u.tenant_id=reissue_row.tenant_id AND u.actor_id=reissue_row.actor_id
        AND u.disabled_at IS NULL AND d.device_id=reissue_row.device_id
        AND d.revoked_at IS NULL) OR
      NOT EXISTS (SELECT FROM public.ventio_identity_credentials c
        WHERE c.tenant_id=reissue_row.tenant_id AND c.actor_id=reissue_row.actor_id
          AND c.device_id=reissue_row.device_id
          AND c.credential_id=reissue_row.source_credential_id
          AND c.revoked_at IS NULL AND c.expires_at>clock_timestamp()) THEN
    UPDATE public.ventio_identity_credential_reissues
      SET state='REJECTED',delivery_ciphertext=NULL
      WHERE operation_id=p_operation_id;
    RETURN jsonb_build_object('operationId',p_operation_id,'state','REJECTED');
  END IF;
  SELECT coalesce(array_agg(DISTINCT permission ORDER BY permission),'{}'::text[])
    INTO current_permissions FROM (
      SELECT g.permission FROM public.ventio_identity_grants g
        WHERE g.tenant_id=reissue_row.tenant_id AND g.actor_id=reissue_row.actor_id
          AND g.company_id=reissue_row.company_id AND g.branch_id=reissue_row.branch_id
      UNION
      SELECT rp.permission FROM public.ventio_identity_role_assignments a
        JOIN public.ventio_identity_role_permissions rp USING (tenant_id,role_id)
        WHERE a.tenant_id=reissue_row.tenant_id AND a.actor_id=reissue_row.actor_id
          AND a.company_id=reissue_row.company_id AND a.branch_id=reissue_row.branch_id) effective;
  IF NOT (reissue_row.allowed_permissions <@ current_permissions) THEN
    UPDATE public.ventio_identity_credential_reissues
      SET state='REJECTED',delivery_ciphertext=NULL
      WHERE operation_id=p_operation_id;
    INSERT INTO public.ventio_identity_audit
      (tenant_id,operator_label,action,subject_id,details)
      VALUES (reissue_row.tenant_id,'api:'||reissue_row.operator_actor_id,
        'CREDENTIAL_REISSUE_REJECTED',reissue_row.device_id,jsonb_build_object(
          'operationId',p_operation_id,'deviceId',reissue_row.device_id,
          'actorId',reissue_row.actor_id,'companyId',reissue_row.company_id,
          'branchId',reissue_row.branch_id,'reason','CURRENT_GRANT_CHANGED'));
    RETURN jsonb_build_object('operationId',p_operation_id,'state','REJECTED');
  END IF;
  expires_value := clock_timestamp()+interval '30 days';
  UPDATE public.ventio_identity_credentials
    SET revoked_at=clock_timestamp()
    WHERE tenant_id=reissue_row.tenant_id AND actor_id=reissue_row.actor_id
      AND device_id=reissue_row.device_id
      AND credential_id=reissue_row.source_credential_id AND revoked_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Source credential changed' USING ERRCODE='P0002'; END IF;
  INSERT INTO public.ventio_identity_credentials
    (tenant_id,actor_id,device_id,credential_id,token_digest,expires_at,allowed_scopes)
  VALUES (reissue_row.tenant_id,reissue_row.actor_id,reissue_row.device_id,
    reissue_row.replacement_credential_id,p_replacement_digest,expires_value,
    jsonb_build_array(jsonb_build_object('companyId',reissue_row.company_id,
      'branchId',reissue_row.branch_id,
      'permissions',to_jsonb(reissue_row.allowed_permissions))));
  UPDATE public.ventio_identity_credential_reissues
    SET state='FINALIZED',delivery_ciphertext=NULL,finalized_at=clock_timestamp()
    WHERE operation_id=p_operation_id;
  INSERT INTO public.ventio_identity_audit
    (tenant_id,operator_label,action,subject_id,details)
    VALUES (reissue_row.tenant_id,'api:'||reissue_row.operator_actor_id,
      'CREDENTIAL_REISSUE_FINALIZED',reissue_row.device_id,jsonb_build_object(
        'operationId',p_operation_id,'deviceId',reissue_row.device_id,
        'actorId',reissue_row.actor_id,
        'sourceCredentialId',reissue_row.source_credential_id,
        'credentialId',reissue_row.replacement_credential_id,
        'companyId',reissue_row.company_id,'branchId',reissue_row.branch_id,
        'permissions',to_jsonb(reissue_row.allowed_permissions),
        'expiresAtUtc',to_char(expires_value AT TIME ZONE 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')));
  RETURN jsonb_build_object('operationId',p_operation_id,'state','FINALIZED',
    'tenantId',reissue_row.tenant_id,'actorId',reissue_row.actor_id,
    'deviceId',reissue_row.device_id,'companyId',reissue_row.company_id,
    'branchId',reissue_row.branch_id,
    'credentialId',reissue_row.replacement_credential_id);
END $fn$;

REVOKE ALL ON FUNCTION ventio_security.trusted_windows_credential_reissue_prepare(
    text,text,text,text,text,text,text,text,text,text,text,bytea,text[],text[],text)
  FROM PUBLIC, ventio_runtime, ventio_identity_admin, ventio_identity_api;
GRANT EXECUTE ON FUNCTION ventio_security.trusted_windows_credential_reissue_prepare(
    text,text,text,text,text,text,text,text,text,text,text,bytea,text[],text[],text)
  TO ventio_identity_api;
REVOKE ALL ON FUNCTION ventio_security.credential_reissue_claim(text,text)
  FROM PUBLIC, ventio_runtime, ventio_identity_admin, ventio_identity_api;
GRANT EXECUTE ON FUNCTION ventio_security.credential_reissue_claim(text,text)
  TO ventio_identity_api;
REVOKE ALL ON FUNCTION ventio_security.credential_reissue_pending_claim(text)
  FROM PUBLIC, ventio_runtime, ventio_identity_admin, ventio_identity_api;
GRANT EXECUTE ON FUNCTION ventio_security.credential_reissue_pending_claim(text)
  TO ventio_identity_api;
REVOKE ALL ON FUNCTION ventio_security.credential_reissue_finalize(text,text)
  FROM PUBLIC, ventio_runtime, ventio_identity_admin, ventio_identity_api;
GRANT EXECUTE ON FUNCTION ventio_security.credential_reissue_finalize(text,text)
  TO ventio_identity_api;
-- The Client API checks the approved migration manifest before exposing the
-- pending envelope. This SECURITY DEFINER assertion returns no schema data.
GRANT EXECUTE ON FUNCTION ventio_security.assert_schema()
  TO ventio_identity_api;

-- Make every transition-state mutation part of the independent Recovery
-- Authority generation, including upgrades where bootstrap.sql is not replayed.
DROP TRIGGER IF EXISTS ventio_recovery_lock ON public.ventio_identity_credential_reissues;
CREATE TRIGGER ventio_recovery_lock
  BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE
  ON public.ventio_identity_credential_reissues
  FOR EACH STATEMENT EXECUTE FUNCTION ventio_security.lock_recovery_mutation();
DROP TRIGGER IF EXISTS ventio_recovery_mark ON public.ventio_identity_credential_reissues;
CREATE TRIGGER ventio_recovery_mark
  AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE
  ON public.ventio_identity_credential_reissues
  FOR EACH STATEMENT EXECUTE FUNCTION ventio_security.mark_recovery_mutation();
