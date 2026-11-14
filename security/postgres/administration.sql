\ir administration_change.sql


-- The Host service's scoped Identity API login may perform only this
-- recovery-admitted, one-time bootstrap operation. It cannot call the broad
-- admin_change function or mutate identity tables directly.
CREATE OR REPLACE FUNCTION ventio_security.bootstrap_first_admin(p jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE tenant text := p->>'tenantId'; actor text := p->>'actorId';
  company text := p->>'companyId'; branch text := p->>'branchId';
  device text := p->>'deviceId'; credential text := p->>'credentialId';
  request_id text := p->>'requestId';
  operator_label text := p->>'operatorLabel'; v_expires_at timestamptz := (p->>'expiresAt')::timestamptz;
  permissions text[] := ARRAY['host.status.read','host.diagnostics.read',
    'identity.users.manage','identity.devices.manage','identity.pairing.manage',
    'identity.roles.manage','extension.package.review'];
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(86744321);
  IF NOT pg_has_role(session_user,'ventio_identity_api','MEMBER') THEN
    RAISE EXCEPTION 'First administrator bootstrap caller is not authorized'
      USING ERRCODE='42501';
  END IF;
  IF NOT EXISTS (SELECT FROM ventio_security.recovery_state
      WHERE singleton AND enforced IS TRUE) THEN
    RAISE EXCEPTION 'First administrator bootstrap requires initialized Recovery Authority'
      USING ERRCODE='28000';
  END IF;
  IF NOT ventio_security.recovery_guard() THEN
    RAISE EXCEPTION 'First administrator bootstrap recovery proof is missing'
      USING ERRCODE='28000';
  END IF;
  IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR
      p-ARRAY['tenantId','actorId','companyId','branchId','deviceId',
        'credentialId','operatorLabel','tokenDigest','expiresAt','requestId'] <> '{}'::jsonb OR
      tenant IS NULL OR length(trim(tenant)) NOT BETWEEN 1 AND 256 OR
      actor IS NULL OR length(trim(actor)) NOT BETWEEN 1 AND 256 OR
      company IS NULL OR length(trim(company)) NOT BETWEEN 1 AND 256 OR
      branch IS NULL OR length(trim(branch)) NOT BETWEEN 1 AND 256 OR
      device IS NULL OR length(trim(device)) NOT BETWEEN 1 AND 256 OR
      credential IS NULL OR length(trim(credential)) NOT BETWEEN 1 AND 256 OR
      operator_label IS NULL OR
      operator_label !~ '^[A-Za-z0-9][A-Za-z0-9._ -]{0,127}$' OR
      operator_label ~* '(bearer|password|token|secret|postgresql?://)' OR
      request_id IS NULL OR request_id !~ '^[A-Za-z0-9_-]{43}$' OR
      p->>'tokenDigest' IS NULL OR
      p->>'tokenDigest' !~ '^[0-9a-f]{64}$' OR v_expires_at IS NULL OR
      v_expires_at <= clock_timestamp() OR
      v_expires_at > clock_timestamp()+interval '30 days' THEN
    RAISE EXCEPTION 'Invalid first administrator bootstrap request'
      USING ERRCODE='22023';
  END IF;
  IF EXISTS (SELECT FROM public.ventio_identity_users) THEN
    IF EXISTS (
        SELECT FROM public.ventio_identity_users u
        WHERE u.tenant_id=tenant AND u.actor_id=actor) AND
        NOT EXISTS (
          SELECT FROM public.ventio_identity_users u
          WHERE u.tenant_id IS DISTINCT FROM tenant OR
            u.actor_id IS DISTINCT FROM actor) AND
        EXISTS (
          SELECT FROM public.ventio_identity_branches b
          WHERE b.tenant_id=tenant AND b.company_id=company AND
            b.branch_id=branch) AND
        EXISTS (
          SELECT FROM public.ventio_identity_devices d
          WHERE d.tenant_id=tenant AND d.actor_id=actor AND
            d.device_id=device) AND
        EXISTS (
          SELECT FROM public.ventio_identity_credentials c
          WHERE c.tenant_id=tenant AND c.actor_id=actor AND
            c.device_id=device AND c.credential_id=credential AND
            c.token_digest=p->>'tokenDigest' AND c.expires_at=v_expires_at AND
            c.allowed_scopes=jsonb_build_array(jsonb_build_object(
              'companyId',company,'branchId',branch,'permissions',to_jsonb(permissions)))) AND
        (SELECT array_agg(g.permission ORDER BY g.permission)
          FROM public.ventio_identity_grants g
          WHERE g.tenant_id=tenant AND g.actor_id=actor AND
            g.company_id=company AND g.branch_id=branch)=
          ARRAY['extension.package.review','host.diagnostics.read','host.status.read',
            'identity.devices.manage','identity.pairing.manage',
            'identity.roles.manage','identity.users.manage']::text[] AND
        EXISTS (
          SELECT FROM public.ventio_identity_audit a
          WHERE a.tenant_id=tenant AND
            a.action='INITIAL_ADMIN_BOOTSTRAPPED' AND a.subject_id=actor AND
            a.details->>'bootstrapRequestId'=request_id AND
            a.details->>'companyId'=company AND
            a.details->>'branchId'=branch AND
            a.details->>'deviceId'=device AND
            a.details->>'credentialId'=credential AND
            (a.details->>'expiresAt')::timestamptz=v_expires_at) THEN
      RETURN;
    END IF;
    RAISE EXCEPTION 'Initial administrator has already been provisioned'
      USING ERRCODE='42501';
  END IF;
  INSERT INTO public.ventio_identity_users(tenant_id,actor_id)
    VALUES (tenant,actor);
  INSERT INTO public.ventio_identity_branches(tenant_id,company_id,branch_id)
    VALUES (tenant,company,branch) ON CONFLICT DO NOTHING;
  INSERT INTO public.ventio_identity_devices(tenant_id,actor_id,device_id)
    VALUES (tenant,actor,device);
  INSERT INTO public.ventio_identity_grants
    (tenant_id,actor_id,company_id,branch_id,permission)
  SELECT tenant,actor,company,branch,permission
    FROM unnest(permissions) AS grants(permission);
  INSERT INTO public.ventio_identity_credentials
    (tenant_id,actor_id,device_id,credential_id,token_digest,expires_at,allowed_scopes)
  VALUES (tenant,actor,device,credential,p->>'tokenDigest',v_expires_at,
    jsonb_build_array(jsonb_build_object('companyId',company,'branchId',branch,
      'permissions',to_jsonb(permissions))));
  INSERT INTO public.ventio_identity_audit
    (tenant_id,operator_label,action,subject_id,details)
  VALUES (tenant,operator_label,'INITIAL_ADMIN_BOOTSTRAPPED',actor,
    jsonb_build_object('companyId',company,'branchId',branch,'deviceId',device,
      'credentialId',credential,'permissions',to_jsonb(permissions),
      'expiresAt',v_expires_at,'bootstrapRequestId',request_id));
END $fn$;

-- The remote administration surface is deliberately narrower than the local
-- trusted operator function above. It rechecks a direct, credential-bounded
-- management grant in the same transaction as the mutation.
CREATE OR REPLACE FUNCTION ventio_security.identity_role_manager_allowed(
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
      AND u.disabled_at IS NULL AND d.revoked_at IS NULL
    FOR SHARE OF c,u,d;
  IF NOT FOUND OR (credential_row.allowed_scopes IS NOT NULL AND NOT EXISTS (
      SELECT FROM jsonb_array_elements(credential_row.allowed_scopes) s
      WHERE s->>'companyId'=p_company AND s->>'branchId'=p_branch
        AND s->'permissions' ? 'identity.roles.manage')) THEN
    RETURN false;
  END IF;
  RETURN EXISTS (
    SELECT FROM public.ventio_identity_grants g
    WHERE g.tenant_id=p_tenant AND g.actor_id=credential_row.actor_id
      AND g.company_id=p_company AND g.branch_id=p_branch
      AND g.permission='identity.roles.manage');
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.identity_roles_snapshot(
    p_digest text, p_company text, p_branch text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE credential_row public.ventio_identity_credentials%ROWTYPE;
        role_data jsonb;
BEGIN
  IF NOT pg_has_role(session_user,'ventio_runtime','MEMBER') OR
      p_company IS NULL OR p_branch IS NULL OR
      length(trim(p_company)) NOT BETWEEN 1 AND 256 OR
      length(trim(p_branch)) NOT BETWEEN 1 AND 256 OR
      NOT ventio_security.recovery_guard() THEN
    RETURN NULL;
  END IF;
  SELECT * INTO credential_row FROM public.ventio_identity_credentials
    WHERE token_digest=p_digest AND revoked_at IS NULL
      AND expires_at>clock_timestamp();
  IF NOT FOUND OR NOT ventio_security.identity_role_manager_allowed(
      p_digest,credential_row.tenant_id,p_company,p_branch) THEN
    RETURN NULL;
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'roleId',r.role_id,
      'displayName',r.display_name,
      'permissions',coalesce((SELECT jsonb_agg(rp.permission ORDER BY rp.permission)
        FROM public.ventio_identity_role_permissions rp
        WHERE rp.tenant_id=r.tenant_id AND rp.role_id=r.role_id
          AND rp.permission !~ '^(identity|host|system|security|recovery|authorization)\.'),'[]'::jsonb),
      'assignedActorIds',coalesce((SELECT jsonb_agg(a.actor_id ORDER BY a.actor_id)
        FROM public.ventio_identity_role_assignments a
        WHERE a.tenant_id=r.tenant_id AND a.role_id=r.role_id
          AND a.company_id=p_company AND a.branch_id=p_branch),'[]'::jsonb)
      ) ORDER BY r.display_name,r.role_id),'[]'::jsonb)
    INTO role_data FROM public.ventio_identity_roles r
    WHERE r.tenant_id=credential_row.tenant_id
      AND (NOT EXISTS (SELECT FROM public.ventio_identity_role_assignments any_scope
            WHERE any_scope.tenant_id=r.tenant_id AND any_scope.role_id=r.role_id)
        OR EXISTS (SELECT FROM public.ventio_identity_role_assignments here
            WHERE here.tenant_id=r.tenant_id AND here.role_id=r.role_id
              AND here.company_id=p_company AND here.branch_id=p_branch));
  RETURN jsonb_build_object('tenantId',credential_row.tenant_id,
    'companyId',p_company,'branchId',p_branch,'roles',role_data);
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.scoped_admin_change(
    p_digest text, p_company text, p_branch text, p_change jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE credential_row public.ventio_identity_credentials%ROWTYPE;
        operation text := p_change->>'action'; role_key text := p_change->>'roleId';
        assignment_scope record; has_assignments boolean := false; change jsonb;
BEGIN
  IF NOT pg_has_role(session_user,'ventio_identity_api','MEMBER') OR
      pg_has_role(session_user,'ventio_identity_admin','MEMBER') OR
      EXISTS (SELECT FROM pg_catalog.pg_roles r WHERE r.rolname=session_user
        AND (r.rolsuper OR r.rolbypassrls OR r.rolcreatedb OR
          r.rolcreaterole OR r.rolreplication)) OR
      pg_has_role(session_user,'ventio_owner','MEMBER') OR
      pg_has_role(session_user,'ventio_migrator','MEMBER') OR
      jsonb_typeof(p_change) IS DISTINCT FROM 'object' OR
      operation IS NULL OR operation NOT IN ('ROLE_CREATED','ROLE_RENAMED','ROLE_DELETED',
        'ROLE_PERMISSION_GRANTED','ROLE_PERMISSION_REVOKED','ROLE_ASSIGNED','ROLE_UNASSIGNED') OR
      p_change ?| ARRAY['tenantId','operatorLabel','deviceId','credentialId',
        'tokenDigest','allowedScopes','expiresAt','package','packageSha256'] OR
      p_company IS NULL OR p_branch IS NULL OR
      length(trim(p_company)) NOT BETWEEN 1 AND 256 OR
      length(trim(p_branch)) NOT BETWEEN 1 AND 256 OR
      (operation IN ('ROLE_ASSIGNED','ROLE_UNASSIGNED') AND
        (p_change->>'actorId' IS NULL OR
         length(trim(p_change->>'actorId')) NOT BETWEEN 1 AND 256)) OR
      (operation NOT IN ('ROLE_ASSIGNED','ROLE_UNASSIGNED') AND p_change ? 'actorId') THEN
    RAISE EXCEPTION 'Invalid scoped role administration request' USING ERRCODE='22023';
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
  IF NOT FOUND OR NOT ventio_security.identity_role_manager_allowed(
      p_digest,credential_row.tenant_id,p_company,p_branch) THEN
    RAISE EXCEPTION 'Role management denied' USING ERRCODE='42501';
  END IF;

  IF operation IN ('ROLE_PERMISSION_GRANTED','ROLE_PERMISSION_REVOKED',
      'ROLE_RENAMED','ROLE_DELETED') THEN
    IF role_key IS NULL THEN
      RAISE EXCEPTION 'Role is required' USING ERRCODE='22023';
    END IF;
    PERFORM 1 FROM public.ventio_identity_roles
      WHERE tenant_id=credential_row.tenant_id AND role_id=role_key FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown role' USING ERRCODE='P0002'; END IF;
    PERFORM 1 FROM public.ventio_identity_role_assignments
      WHERE tenant_id=credential_row.tenant_id AND role_id=role_key FOR UPDATE;
    FOR assignment_scope IN
      SELECT DISTINCT company_id,branch_id
      FROM public.ventio_identity_role_assignments
      WHERE tenant_id=credential_row.tenant_id AND role_id=role_key
      ORDER BY company_id,branch_id
    LOOP
      has_assignments := true;
      IF NOT ventio_security.identity_role_manager_allowed(
          p_digest,credential_row.tenant_id,
          assignment_scope.company_id,assignment_scope.branch_id) THEN
        RAISE EXCEPTION 'Role affects a scope outside the manager authority'
          USING ERRCODE='42501';
      END IF;
    END LOOP;
    IF NOT has_assignments AND NOT ventio_security.identity_role_manager_allowed(
        p_digest,credential_row.tenant_id,p_company,p_branch) THEN
      RAISE EXCEPTION 'Role management denied' USING ERRCODE='42501';
    END IF;
  END IF;

  IF operation IN ('ROLE_ASSIGNED','ROLE_UNASSIGNED') THEN
    IF p_change->>'companyId' IS DISTINCT FROM p_company OR
        p_change->>'branchId' IS DISTINCT FROM p_branch OR
        p_change->>'actorId' IS NULL THEN
      RAISE EXCEPTION 'Role assignment must use the authorized exact scope'
        USING ERRCODE='42501';
    END IF;
    PERFORM 1 FROM public.ventio_identity_roles
      WHERE tenant_id=credential_row.tenant_id AND role_id=role_key FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown role' USING ERRCODE='P0002'; END IF;
    IF operation='ROLE_ASSIGNED' AND EXISTS (
        SELECT FROM public.ventio_identity_role_permissions rp
        WHERE rp.tenant_id=credential_row.tenant_id AND rp.role_id=role_key
          AND rp.permission ~ '^(identity|host|system|security|recovery|authorization)\.') THEN
      RAISE EXCEPTION 'Host management permissions cannot be assigned through a role'
        USING ERRCODE='42501';
    END IF;
  END IF;

  change := p_change || jsonb_build_object(
    'tenantId',credential_row.tenant_id,
    'operatorLabel','api:' || left(credential_row.actor_id,252),
    'operatorActorId',credential_row.actor_id,
    'companyId',p_company,'branchId',p_branch);
  IF operation NOT IN ('ROLE_ASSIGNED','ROLE_UNASSIGNED') THEN
    change := change - 'actorId';
  END IF;
  PERFORM ventio_security.admin_change(change);
END $fn$;

-- The remote user-management surface is intentionally separate from both the
-- trusted local admin_change function and the role-only scoped function above.
-- A caller must carry a direct, credential-bounded grant for this exact branch.
CREATE OR REPLACE FUNCTION ventio_security.identity_users_manager_allowed(
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
      AND u.disabled_at IS NULL AND d.revoked_at IS NULL
    FOR SHARE OF c,u,d;
  IF NOT FOUND OR credential_row.allowed_scopes IS NULL OR NOT EXISTS (
      SELECT FROM jsonb_array_elements(credential_row.allowed_scopes) s
      WHERE s->>'companyId'=p_company AND s->>'branchId'=p_branch
        AND s->'permissions' ? 'identity.users.manage') THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT FROM public.ventio_identity_grants g
    WHERE g.tenant_id=p_tenant AND g.actor_id=credential_row.actor_id
      AND g.company_id=p_company AND g.branch_id=p_branch
      AND g.permission='identity.users.manage');
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.identity_users_snapshot(
    p_digest text, p_company text, p_branch text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE credential_row public.ventio_identity_credentials%ROWTYPE;
        user_data jsonb;
BEGIN
  IF NOT pg_has_role(session_user,'ventio_runtime','MEMBER') OR
      p_company IS NULL OR p_branch IS NULL OR
      length(trim(p_company)) NOT BETWEEN 1 AND 256 OR
      length(trim(p_branch)) NOT BETWEEN 1 AND 256 OR
      NOT ventio_security.recovery_guard() THEN
    RETURN NULL;
  END IF;

  SELECT * INTO credential_row FROM public.ventio_identity_credentials
    WHERE token_digest=p_digest AND revoked_at IS NULL
      AND expires_at>clock_timestamp();
  IF NOT FOUND OR NOT ventio_security.identity_users_manager_allowed(
      p_digest,credential_row.tenant_id,p_company,p_branch) THEN
    RETURN NULL;
  END IF;

  WITH scoped_users AS (
    SELECT u.actor_id, u.disabled_at
    FROM public.ventio_identity_users u
    WHERE u.tenant_id=credential_row.tenant_id
      AND (
        EXISTS (SELECT FROM public.ventio_identity_grants g
          WHERE g.tenant_id=u.tenant_id AND g.actor_id=u.actor_id
            AND g.company_id=p_company AND g.branch_id=p_branch)
        OR EXISTS (SELECT FROM public.ventio_identity_role_assignments a
          WHERE a.tenant_id=u.tenant_id AND a.actor_id=u.actor_id
            AND a.company_id=p_company AND a.branch_id=p_branch)
        OR EXISTS (SELECT FROM public.ventio_identity_audit e
          WHERE e.tenant_id=u.tenant_id AND e.action='USER_CREATED'
            AND e.subject_id=u.actor_id
            AND e.details->>'companyId'=p_company
            AND e.details->>'branchId'=p_branch)
        OR EXISTS (SELECT FROM public.ventio_identity_audit e
          WHERE e.tenant_id=u.tenant_id
            AND e.action IN ('USER_DISABLED','USER_ENABLED','PERMISSION_GRANTED',
              'PERMISSION_REVOKED','ROLE_ASSIGNED','ROLE_UNASSIGNED')
            AND e.subject_id=u.actor_id
            AND e.details->>'companyId'=p_company
            AND e.details->>'branchId'=p_branch)
      )
    ORDER BY u.actor_id
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'actorId',u.actor_id,
      'state',CASE WHEN u.disabled_at IS NULL THEN 'ACTIVE' ELSE 'DISABLED' END,
      'directPermissions',coalesce((
        SELECT jsonb_agg(g.permission ORDER BY g.permission)
        FROM public.ventio_identity_grants g
        WHERE g.tenant_id=credential_row.tenant_id AND g.actor_id=u.actor_id
          AND g.company_id=p_company AND g.branch_id=p_branch
      ),'[]'::jsonb),
      'roles',coalesce((
        SELECT jsonb_agg(r.role_id ORDER BY r.display_name,r.role_id)
        FROM public.ventio_identity_role_assignments a
        JOIN public.ventio_identity_roles r
          ON r.tenant_id=a.tenant_id AND r.role_id=a.role_id
        WHERE a.tenant_id=credential_row.tenant_id AND a.actor_id=u.actor_id
          AND a.company_id=p_company AND a.branch_id=p_branch
      ),'[]'::jsonb)
    ) ORDER BY u.actor_id),'[]'::jsonb)
  INTO user_data FROM scoped_users u;

  RETURN jsonb_build_object('tenantId',credential_row.tenant_id,
    'companyId',p_company,'branchId',p_branch,'items',user_data);
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.identity_users_audit_snapshot(
    p_digest text, p_company text, p_branch text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE credential_row public.ventio_identity_credentials%ROWTYPE;
        event_data jsonb;
BEGIN
  IF NOT pg_has_role(session_user,'ventio_runtime','MEMBER') OR
      p_company IS NULL OR p_branch IS NULL OR
      length(trim(p_company)) NOT BETWEEN 1 AND 256 OR
      length(trim(p_branch)) NOT BETWEEN 1 AND 256 OR
      NOT ventio_security.recovery_guard() THEN
    RETURN NULL;
  END IF;

  SELECT * INTO credential_row FROM public.ventio_identity_credentials
    WHERE token_digest=p_digest AND revoked_at IS NULL
      AND expires_at>clock_timestamp();
  IF NOT FOUND OR NOT ventio_security.identity_users_manager_allowed(
      p_digest,credential_row.tenant_id,p_company,p_branch) THEN
    RETURN NULL;
  END IF;

  WITH recent_events AS (
    SELECT e.id,e.occurred_at,e.action,e.subject_id,e.details
    FROM public.ventio_identity_audit e
    WHERE e.tenant_id=credential_row.tenant_id
      AND e.details->>'companyId'=p_company
      AND e.details->>'branchId'=p_branch
      AND e.action IN (
        'USER_CREATED','USER_DISABLED','USER_ENABLED','PERMISSION_GRANTED','PERMISSION_REVOKED',
        'ROLE_CREATED','ROLE_RENAMED','ROLE_DELETED',
        'ROLE_PERMISSION_GRANTED','ROLE_PERMISSION_REVOKED',
        'ROLE_ASSIGNED','ROLE_UNASSIGNED')
    ORDER BY e.id DESC
    LIMIT 100
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'eventId',e.id::text,
      'occurredAtUtc',to_char(e.occurred_at AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'action',e.action,
      'subjectId',CASE
        WHEN e.subject_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' AND
             e.subject_id !~ '^[A-Za-z0-9_-]{43,128}$' AND
             e.subject_id !~* '(bearer|password|token|secret|postgresql?://)'
          THEN e.subject_id
        ELSE '[redacted]'
      END,
      'operator',CASE
        WHEN e.details->>'operatorActorId' ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' AND
             e.details->>'operatorActorId' !~ '^[A-Za-z0-9_-]{43,128}$' AND
             e.details->>'operatorActorId' !~* '(bearer|password|token|secret|postgresql?://)'
          THEN e.details->>'operatorActorId'
        ELSE 'Host administrator'
      END
    ) ORDER BY e.id DESC),'[]'::jsonb)
  INTO event_data FROM recent_events e;

  RETURN jsonb_build_object('tenantId',credential_row.tenant_id,
    'companyId',p_company,'branchId',p_branch,'events',event_data);
END $fn$;

-- The return type changed from void when Host-generated IDs were introduced.
-- Recreate the function inside the bootstrap transaction so reruns on existing
-- installations receive the same non-disclosing create contract.
DROP FUNCTION IF EXISTS ventio_security.scoped_user_admin_change(
  text,text,text,jsonb);
CREATE FUNCTION ventio_security.scoped_user_admin_change(
    p_digest text, p_company text, p_branch text, p_change jsonb)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE credential_row public.ventio_identity_credentials%ROWTYPE;
        operation text := p_change->>'action'; target_actor text := p_change->>'actorId';
        permission_name text := p_change->>'permission'; target_disabled timestamptz;
        change jsonb;
BEGIN
  IF NOT pg_has_role(session_user,'ventio_identity_api','MEMBER') OR
      pg_has_role(session_user,'ventio_identity_admin','MEMBER') OR
      EXISTS (SELECT FROM pg_catalog.pg_roles r WHERE r.rolname=session_user
        AND (r.rolsuper OR r.rolbypassrls OR r.rolcreatedb OR
          r.rolcreaterole OR r.rolreplication)) OR
      pg_has_role(session_user,'ventio_owner','MEMBER') OR
      pg_has_role(session_user,'ventio_migrator','MEMBER') OR
      jsonb_typeof(p_change) IS DISTINCT FROM 'object' OR
      operation IS NULL OR operation NOT IN
        ('USER_CREATED','PERMISSION_GRANTED','PERMISSION_REVOKED','USER_DISABLED','USER_ENABLED') OR
      p_change ?| ARRAY['tenantId','operatorLabel','operatorActorId','deviceId',
        'credentialId','tokenDigest','allowedScopes','expiresAt','package',
        'packageSha256','companyId','branchId'] OR
      p_company IS NULL OR p_branch IS NULL OR
      length(trim(p_company)) NOT BETWEEN 1 AND 256 OR
      length(trim(p_branch)) NOT BETWEEN 1 AND 256 OR
      (operation='USER_CREATED' AND p_change ? 'actorId') OR
      (operation<>'USER_CREATED' AND
        (target_actor IS NULL OR
         length(trim(target_actor)) NOT BETWEEN 1 AND 256)) OR
      (operation IN ('USER_CREATED','USER_DISABLED','USER_ENABLED') AND
        (p_change ? 'permission' OR p_change ? 'extra')) OR
      (operation IN ('PERMISSION_GRANTED','PERMISSION_REVOKED') AND
        (permission_name IS NULL OR
         permission_name !~ '^[a-z][a-z0-9_.]+$' OR
         length(permission_name)>256 OR
         permission_name ~ '^(identity|host|system|security|recovery|authorization)\.')) OR
      (operation NOT IN ('PERMISSION_GRANTED','PERMISSION_REVOKED') AND
        p_change ? 'permission') THEN
    RAISE EXCEPTION 'Invalid scoped user administration request' USING ERRCODE='22023';
  END IF;
  IF (operation='USER_CREATED' AND
      p_change-ARRAY['action']<>'{}'::jsonb) OR
     (operation IN ('PERMISSION_GRANTED','PERMISSION_REVOKED') AND
      p_change-ARRAY['action','actorId','permission']<>'{}'::jsonb) OR
     (operation IN ('USER_DISABLED','USER_ENABLED') AND
      p_change-ARRAY['action','actorId']<>'{}'::jsonb) THEN
    RAISE EXCEPTION 'Unexpected user administration field' USING ERRCODE='22023';
  END IF;

  -- Serialize the authority check, scope checks and mutation with the existing
  -- identity administration lock so another identity change cannot race them.
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
  IF NOT FOUND OR NOT ventio_security.identity_users_manager_allowed(
      p_digest,credential_row.tenant_id,p_company,p_branch) THEN
    RAISE EXCEPTION 'User management denied' USING ERRCODE='42501';
  END IF;

  IF operation='USER_CREATED' THEN
    -- Caller-controlled IDs would let a branch administrator probe the
    -- tenant-global identity keyspace. Generate the ID only inside this
    -- authorized, serialized transaction and return it to this manager.
    LOOP
      target_actor := 'usr_' || encode(ventio_crypto.gen_random_bytes(16),'hex');
      EXIT WHEN NOT EXISTS (SELECT FROM public.ventio_identity_users
        WHERE tenant_id=credential_row.tenant_id AND actor_id=target_actor);
    END LOOP;
  ELSE
    SELECT disabled_at INTO target_disabled
      FROM public.ventio_identity_users
      WHERE tenant_id=credential_row.tenant_id AND actor_id=target_actor
      FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'User not found or disabled' USING ERRCODE='P0002';
    END IF;
    -- Actor IDs are tenant-global. Do not let an administrator distinguish an
    -- unknown ID from an ID active only in another company/branch.
    IF NOT EXISTS (SELECT FROM public.ventio_identity_grants g
        WHERE g.tenant_id=credential_row.tenant_id AND g.actor_id=target_actor
          AND g.company_id=p_company AND g.branch_id=p_branch) AND
       NOT EXISTS (SELECT FROM public.ventio_identity_role_assignments a
        WHERE a.tenant_id=credential_row.tenant_id AND a.actor_id=target_actor
          AND a.company_id=p_company AND a.branch_id=p_branch) AND
       NOT EXISTS (SELECT FROM public.ventio_identity_audit e
        WHERE e.tenant_id=credential_row.tenant_id AND e.subject_id=target_actor
          AND e.action IN ('USER_CREATED','USER_DISABLED','USER_ENABLED','PERMISSION_GRANTED',
            'PERMISSION_REVOKED','ROLE_ASSIGNED','ROLE_UNASSIGNED')
          AND e.details->>'companyId'=p_company
          AND e.details->>'branchId'=p_branch) THEN
      RAISE EXCEPTION 'User not found' USING ERRCODE='P0002';
    END IF;
    IF (operation='USER_ENABLED' AND target_disabled IS NULL) OR
       (operation<>'USER_ENABLED' AND target_disabled IS NOT NULL) THEN
      RAISE EXCEPTION 'User not found or disabled' USING ERRCODE='P0002';
    END IF;
  END IF;

  IF operation IN ('USER_DISABLED','USER_ENABLED') THEN
    IF operation='USER_DISABLED' AND target_actor=credential_row.actor_id THEN
      RAISE EXCEPTION 'An administrator cannot disable their own account'
        USING ERRCODE='42501';
    END IF;
    IF EXISTS (SELECT FROM public.ventio_identity_grants g
        WHERE g.tenant_id=credential_row.tenant_id AND g.actor_id=target_actor
          AND (g.company_id,g.branch_id) IS DISTINCT FROM (p_company,p_branch)) OR
       EXISTS (SELECT FROM public.ventio_identity_role_assignments a
        WHERE a.tenant_id=credential_row.tenant_id AND a.actor_id=target_actor
          AND (a.company_id,a.branch_id) IS DISTINCT FROM (p_company,p_branch)) OR
       EXISTS (SELECT FROM public.ventio_identity_credentials c
        JOIN public.ventio_identity_devices d
          ON d.tenant_id=c.tenant_id AND d.actor_id=c.actor_id AND d.device_id=c.device_id
        WHERE c.tenant_id=credential_row.tenant_id AND c.actor_id=target_actor
          AND c.revoked_at IS NULL AND c.expires_at>clock_timestamp()
          AND d.revoked_at IS NULL
          AND (c.allowed_scopes IS NULL OR EXISTS (
            SELECT FROM jsonb_array_elements(c.allowed_scopes) s
            WHERE s->>'companyId' IS DISTINCT FROM p_company OR
              s->>'branchId' IS DISTINCT FROM p_branch))) THEN
      -- Keep an out-of-scope authority/credential ceiling indistinguishable
      -- from a missing target. The branch manager already knows the subject is
      -- listed in this branch; do not reveal any other branch's state.
      RAISE EXCEPTION 'User not found or disabled' USING ERRCODE='P0002';
    END IF;
  END IF;

  change := p_change || jsonb_build_object(
    'actorId',target_actor,
    'tenantId',credential_row.tenant_id,
    'operatorLabel','api:' || left(credential_row.actor_id,252),
    'operatorActorId',credential_row.actor_id,
    'companyId',p_company,'branchId',p_branch);
  PERFORM ventio_security.admin_change(change);
  IF operation='USER_CREATED' THEN RETURN target_actor; END IF;
  RETURN NULL;
END $fn$;
