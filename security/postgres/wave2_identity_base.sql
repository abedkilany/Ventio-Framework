-- Accepted identity resolver retained for archive-aware administration.
CREATE OR REPLACE FUNCTION ventio_security.wave2_identity_snapshot_base(p_digest text, p_company text, p_branch text)
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
          AND rp.permission NOT IN ('platform.organizations.manage','platform.configuration.manage','platform.customizations.manage','platform.operations.manage')
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

