DO $migration$
BEGIN
ALTER TABLE public.ventio_identity_users ADD COLUMN is_owner boolean NOT NULL DEFAULT false;
WITH initial AS (
  SELECT DISTINCT ON (tenant_id) tenant_id,subject_id
  FROM public.ventio_identity_audit WHERE action='INITIAL_ADMIN_BOOTSTRAPPED'
  ORDER BY tenant_id,id
)
UPDATE public.ventio_identity_users u SET is_owner=true FROM initial a
WHERE u.tenant_id=a.tenant_id AND u.actor_id=a.subject_id;
CREATE UNIQUE INDEX ventio_single_owner_per_tenant ON public.ventio_identity_users(tenant_id) WHERE is_owner;
IF to_regnamespace('ventio_security') IS NOT NULL THEN
  EXECUTE $ddl$
CREATE OR REPLACE FUNCTION ventio_security.identity_snapshot(p_digest text, p_company text, p_branch text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE c public.ventio_identity_credentials%ROWTYPE;
        u public.ventio_identity_users%ROWTYPE;
        d public.ventio_identity_devices%ROWTYPE;
        g record; companies text[] := '{}'; branches text[] := '{}'; permissions text[] := '{}';
        scope_grants jsonb := '[]'::jsonb; role_assignments jsonb := '[]'::jsonb;
BEGIN
  IF NOT ventio_security.recovery_guard() THEN RETURN NULL; END IF;
  IF p_digest IS NULL OR p_digest !~ '^[0-9a-f]{64}$' THEN RETURN NULL; END IF;
  SELECT * INTO c FROM public.ventio_identity_credentials WHERE token_digest = p_digest;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO u FROM public.ventio_identity_users
    WHERE tenant_id = c.tenant_id AND actor_id = c.actor_id FOR SHARE;
  IF NOT FOUND OR u.disabled_at IS NOT NULL THEN RETURN NULL; END IF;
  SELECT * INTO d FROM public.ventio_identity_devices
    WHERE tenant_id = c.tenant_id AND actor_id = c.actor_id AND device_id = c.device_id FOR SHARE;
  IF NOT FOUND OR d.revoked_at IS NOT NULL THEN RETURN NULL; END IF;
  SELECT * INTO c FROM public.ventio_identity_credentials WHERE token_digest = p_digest FOR SHARE;
  IF NOT FOUND OR c.revoked_at IS NOT NULL OR c.expires_at <= clock_timestamp() THEN RETURN NULL; END IF;
  -- Owner authority is read from the protected user row, never from a token
  -- claim or a caller-supplied permission. New approved packages are included
  -- on every request; the original credential ceiling does not freeze Owner.
  IF u.is_owner THEN
    SELECT array_agg(DISTINCT permission ORDER BY permission) INTO permissions
    FROM (
      SELECT unnest(ARRAY['*','host.status.read','host.diagnostics.read',
        'identity.users.manage','identity.devices.manage','identity.pairing.manage',
        'identity.roles.manage','extension.package.read','extension.package.submit',
        'extension.package.review']) AS permission
      UNION SELECT create_permission FROM ventio_security.command_bindings
      UNION SELECT read_permission FROM ventio_security.command_bindings
      UNION SELECT permission FROM public.ventio_identity_grants WHERE tenant_id=c.tenant_id
      UNION SELECT permission FROM public.ventio_identity_role_permissions WHERE tenant_id=c.tenant_id
      UNION SELECT value #>> '{}' FROM public.ventio_extension_packages p
        CROSS JOIN LATERAL jsonb_path_query(p.package_json, '$.** ? (@.type() == "string")') value
        WHERE p.tenant_id=c.tenant_id AND p.status='APPROVED'
          AND (value #>> '{}') ~ '^extension\.[a-z0-9_.]+$'
    ) known WHERE permission IS NOT NULL;
    FOR g IN SELECT company_id,branch_id FROM public.ventio_identity_branches b
      WHERE b.tenant_id=c.tenant_id
        AND (p_company IS NULL OR b.company_id=p_company)
        AND (p_branch IS NULL OR b.branch_id=p_branch)
      ORDER BY company_id,branch_id
    LOOP
      companies := array_append(companies,g.company_id);
      branches := array_append(branches,g.branch_id);
      SELECT scope_grants || coalesce(jsonb_agg(jsonb_build_object(
        'companyId',g.company_id,'branchId',g.branch_id,'permission',permission)), '[]'::jsonb)
        INTO scope_grants FROM unnest(permissions) permission;
    END LOOP;
    RETURN jsonb_build_object('tenantId',c.tenant_id,'actorId',c.actor_id,'deviceId',c.device_id,
      'companyIds',companies,'branchIds',branches,'permissions',permissions,
      'scopeGrants',scope_grants,'roles','[]'::jsonb,'isOwner',true);
  END IF;
  -- Locks prevent an in-flight command from racing a role or grant revocation.
  PERFORM 1 FROM public.ventio_identity_grants
    WHERE tenant_id=c.tenant_id AND actor_id=c.actor_id FOR SHARE;
  PERFORM 1 FROM public.ventio_identity_role_assignments a
    JOIN public.ventio_identity_roles r USING (tenant_id,role_id)
    WHERE a.tenant_id=c.tenant_id AND a.actor_id=c.actor_id
      AND (p_company IS NULL OR a.company_id=p_company)
      AND (p_branch IS NULL OR a.branch_id=p_branch)
    FOR SHARE OF a,r;
  FOR g IN
    SELECT effective.company_id,effective.branch_id,effective.permission
    FROM (
      SELECT company_id,branch_id,permission FROM public.ventio_identity_grants
        WHERE tenant_id=c.tenant_id AND actor_id=c.actor_id
      UNION
      SELECT a.company_id,a.branch_id,rp.permission
        FROM public.ventio_identity_role_assignments a
        JOIN public.ventio_identity_role_permissions rp
          USING (tenant_id,role_id)
        WHERE a.tenant_id=c.tenant_id AND a.actor_id=c.actor_id
          AND rp.permission !~ '^(identity|host|system|security|recovery|authorization)\.'
    ) effective
    WHERE (p_company IS NULL OR effective.company_id=p_company)
      AND (p_branch IS NULL OR effective.branch_id=p_branch)
      AND (c.allowed_scopes IS NULL OR EXISTS (
        SELECT FROM jsonb_array_elements(c.allowed_scopes) s
        WHERE s->>'companyId'=effective.company_id
          AND s->>'branchId'=effective.branch_id
          AND s->'permissions' ? effective.permission))
    ORDER BY effective.company_id,effective.branch_id,effective.permission
  LOOP
    companies := array_append(companies, g.company_id);
    branches := array_append(branches, g.branch_id);
    permissions := array_append(permissions, g.permission);
    scope_grants := scope_grants || jsonb_build_array(jsonb_build_object(
      'companyId', g.company_id, 'branchId', g.branch_id, 'permission', g.permission));
  END LOOP;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'roleId',r.role_id,'displayName',r.display_name,
      'companyId',a.company_id,'branchId',a.branch_id)
      ORDER BY a.company_id,a.branch_id,r.display_name,r.role_id),'[]'::jsonb)
    INTO role_assignments
    FROM public.ventio_identity_role_assignments a
    JOIN public.ventio_identity_roles r USING (tenant_id,role_id)
    WHERE a.tenant_id=c.tenant_id AND a.actor_id=c.actor_id
      AND (p_company IS NULL OR a.company_id=p_company)
      AND (p_branch IS NULL OR a.branch_id=p_branch)
      AND (c.allowed_scopes IS NULL OR EXISTS (
        SELECT FROM jsonb_array_elements(c.allowed_scopes) s
        WHERE s->>'companyId'=a.company_id AND s->>'branchId'=a.branch_id
          AND s->'permissions' ?| ARRAY(SELECT rp.permission
            FROM public.ventio_identity_role_permissions rp
            WHERE rp.tenant_id=a.tenant_id AND rp.role_id=a.role_id)));
  RETURN jsonb_build_object('tenantId', c.tenant_id, 'actorId', c.actor_id, 'deviceId', c.device_id,
    'companyIds', companies, 'branchIds', branches, 'permissions', permissions,
    'scopeGrants', scope_grants, 'roles', role_assignments);
END $fn$;
$ddl$;
END IF;
IF to_regnamespace('ventio_security') IS NOT NULL THEN
  EXECUTE $ddl$
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
    'identity.roles.manage','extension.package.read','extension.package.submit',
    'extension.package.review'];
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
        WHERE u.tenant_id=tenant AND u.actor_id=actor AND u.is_owner) AND
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
          ARRAY['extension.package.read','extension.package.review',
            'extension.package.submit','host.diagnostics.read','host.status.read',
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
  INSERT INTO public.ventio_identity_users(tenant_id,actor_id,is_owner)
    VALUES (tenant,actor,true);
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
$ddl$;
END IF;
IF to_regnamespace('ventio_security') IS NOT NULL THEN
  EXECUTE $ddl$
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
  IF FOUND AND EXISTS (SELECT FROM public.ventio_identity_users u
      WHERE u.tenant_id=credential_row.tenant_id AND u.actor_id=credential_row.actor_id AND u.is_owner)
      AND EXISTS (SELECT FROM public.ventio_identity_branches b
        WHERE b.tenant_id=p_tenant AND b.company_id=p_company AND b.branch_id=p_branch) THEN
    RETURN true;
  END IF;
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
$ddl$;
END IF;
IF to_regnamespace('ventio_security') IS NOT NULL THEN
  EXECUTE $ddl$
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
  IF FOUND AND EXISTS (SELECT FROM public.ventio_identity_users u
      WHERE u.tenant_id=credential_row.tenant_id AND u.actor_id=credential_row.actor_id AND u.is_owner)
      AND EXISTS (SELECT FROM public.ventio_identity_branches b
        WHERE b.tenant_id=p_tenant AND b.company_id=p_company AND b.branch_id=p_branch) THEN
    RETURN true;
  END IF;
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
$ddl$;
END IF;
IF to_regnamespace('ventio_security') IS NOT NULL THEN
  EXECUTE $ddl$
CREATE OR REPLACE FUNCTION ventio_security.scoped_user_admin_change(
    p_digest text, p_company text, p_branch text, p_change jsonb)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE credential_row public.ventio_identity_credentials%ROWTYPE;
        operation text := p_change->>'action'; target_actor text := p_change->>'actorId';
        permission_name text := p_change->>'permission'; target_disabled timestamptz;
        change jsonb; caller_owner boolean := false;
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
         length(permission_name)>256)) OR
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

  SELECT is_owner INTO caller_owner FROM public.ventio_identity_users
    WHERE tenant_id=credential_row.tenant_id AND actor_id=credential_row.actor_id;
  IF operation IN ('PERMISSION_GRANTED','PERMISSION_REVOKED') AND
      permission_name ~ '^(identity|host|system|security|recovery|authorization)\.' AND NOT caller_owner THEN
    RAISE EXCEPTION 'Only Owner may manage administrative permissions' USING ERRCODE='42501';
  END IF;
  IF NOT caller_owner AND EXISTS (SELECT FROM public.ventio_identity_users
      WHERE tenant_id=credential_row.tenant_id AND actor_id=target_actor AND is_owner) THEN
    RAISE EXCEPTION 'Owner account cannot be managed by another user' USING ERRCODE='42501';
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
  -- An explicit Owner decision updates existing credentials for this same
  -- branch, so the user does not need to enroll again after each new grant.
  IF caller_owner AND operation IN ('PERMISSION_GRANTED','PERMISSION_REVOKED') THEN
    UPDATE public.ventio_identity_credentials c SET allowed_scopes=(
      SELECT jsonb_agg(CASE WHEN s->>'companyId'=p_company AND s->>'branchId'=p_branch
        THEN jsonb_set(s,'{permissions}',(SELECT coalesce(jsonb_agg(v ORDER BY v),'[]'::jsonb)
          FROM (SELECT DISTINCT v FROM (
            SELECT jsonb_array_elements_text(s->'permissions') v
            UNION SELECT permission_name WHERE operation='PERMISSION_GRANTED'
          ) permission_values WHERE operation='PERMISSION_GRANTED' OR v<>permission_name) unique_values))
        ELSE s END) FROM jsonb_array_elements(c.allowed_scopes) s)
      WHERE c.tenant_id=credential_row.tenant_id AND c.actor_id=target_actor
        AND c.allowed_scopes IS NOT NULL AND c.revoked_at IS NULL;
  END IF;
  IF operation='USER_CREATED' THEN RETURN target_actor; END IF;
  RETURN NULL;
END $fn$;
$ddl$;
END IF;
IF to_regnamespace('ventio_security') IS NOT NULL THEN
  EXECUTE $ddl$
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
  IF FOUND AND EXISTS (SELECT FROM public.ventio_identity_users u
      WHERE u.tenant_id=credential_row.tenant_id AND u.actor_id=credential_row.actor_id AND u.is_owner)
      AND EXISTS (SELECT FROM public.ventio_identity_branches b
        WHERE b.tenant_id=p_tenant AND b.company_id=p_company AND b.branch_id=p_branch) THEN
    RETURN true;
  END IF;
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
$ddl$;
END IF;
IF to_regnamespace('ventio_security') IS NOT NULL THEN
  EXECUTE $ddl$
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
  IF FOUND AND EXISTS (SELECT FROM public.ventio_identity_users u
      WHERE u.tenant_id=credential_row.tenant_id AND u.actor_id=credential_row.actor_id AND u.is_owner)
      AND EXISTS (SELECT FROM public.ventio_identity_branches b
        WHERE b.tenant_id=p_tenant AND b.company_id=p_company AND b.branch_id=p_branch) THEN
    RETURN true;
  END IF;
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
$ddl$;
END IF;
IF to_regnamespace('ventio_security') IS NOT NULL THEN
  EXECUTE $ddl$
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
  IF NOT target_permissions <@ caller_permissions AND NOT EXISTS (
      SELECT FROM public.ventio_identity_users u WHERE u.tenant_id=credential_row.tenant_id
        AND u.actor_id=credential_row.actor_id AND u.is_owner) THEN
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
$ddl$;
END IF;
END
$migration$;
