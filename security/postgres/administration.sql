-- Included by bootstrap.sql inside its installation transaction as ventio_owner.
CREATE OR REPLACE FUNCTION ventio_security.admin_change(p jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE tenant text := p->>'tenantId'; actor text := p->>'actorId'; device text := p->>'deviceId';
  company text := p->>'companyId'; branch text := p->>'branchId'; permission_name text := p->>'permission';
  credential text := p->>'credentialId'; operation text := p->>'action'; label text := p->>'operatorLabel';
  subject text; details jsonb := '{}'; is_disabled timestamptz; revoked timestamptz; changed integer;
  value text; scopes jsonb; old_credential public.ventio_identity_credentials%ROWTYPE;
  package_module text := p->>'moduleId'; package_version text := p->>'version';
  package_hash text := p->>'packageSha256'; package_reason text := p->>'reason';
  role_key text := p->>'roleId'; role_name text := p->>'displayName';
  package_row public.ventio_extension_packages%ROWTYPE;
  dependency record; minimum_version text;

BEGIN
  PERFORM pg_advisory_xact_lock(86744321);
  IF tenant IS NULL OR label IS NULL OR operation IS NULL THEN RAISE EXCEPTION 'Missing administrative context'; END IF;
  FOREACH value IN ARRAY ARRAY[tenant,label,actor,device,company,branch,credential] LOOP
    IF value IS NOT NULL AND (length(trim(value)) < 1 OR length(value) > 256) THEN
      RAISE EXCEPTION 'Invalid identity identifier';
    END IF;
  END LOOP;
  IF role_key IS NOT NULL AND
      (role_key !~ '^[a-z][a-z0-9_.-]*$' OR length(role_key) > 128) THEN
    RAISE EXCEPTION 'Invalid role identifier';
  END IF;
  IF role_name IS NOT NULL AND length(trim(role_name)) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'Invalid role display name';
  END IF;
  IF operation = 'USER_CREATED' THEN
    IF actor IS NULL THEN RAISE EXCEPTION 'User is required'; END IF;
    INSERT INTO public.ventio_identity_users (tenant_id, actor_id) VALUES (tenant, actor);
    subject := actor;
    details := jsonb_build_object('companyId',company,'branchId',branch);
  ELSIF operation = 'BRANCH_REGISTERED' THEN
    IF company IS NULL OR branch IS NULL THEN RAISE EXCEPTION 'Scope is required'; END IF;
    INSERT INTO public.ventio_identity_branches (tenant_id, company_id, branch_id)
      VALUES (tenant, company, branch) ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS changed = ROW_COUNT;
    IF changed = 0 THEN RETURN; END IF;
    subject := branch; details := jsonb_build_object('companyId', company);
  ELSIF operation = 'ROLE_CREATED' THEN
    IF role_key IS NULL OR role_name IS NULL THEN RAISE EXCEPTION 'Role identity is required'; END IF;
    INSERT INTO public.ventio_identity_roles (tenant_id,role_id,display_name)
      VALUES (tenant,role_key,trim(role_name));
    subject := role_key; details := jsonb_build_object('displayName',trim(role_name),
      'companyId',company,'branchId',branch);
  ELSIF operation = 'ROLE_RENAMED' THEN
    IF role_key IS NULL OR role_name IS NULL THEN RAISE EXCEPTION 'Role identity is required'; END IF;
    UPDATE public.ventio_identity_roles SET display_name=trim(role_name)
      WHERE tenant_id=tenant AND role_id=role_key;
    GET DIAGNOSTICS changed = ROW_COUNT;
    IF changed = 0 THEN RAISE EXCEPTION 'Unknown role'; END IF;
    subject := role_key; details := jsonb_build_object('displayName',trim(role_name),
      'companyId',company,'branchId',branch);
  ELSIF operation = 'ROLE_DELETED' THEN
    IF role_key IS NULL THEN RAISE EXCEPTION 'Role identity is required'; END IF;
    PERFORM 1 FROM public.ventio_identity_roles
      WHERE tenant_id=tenant AND role_id=role_key FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown role'; END IF;
    IF EXISTS (SELECT FROM public.ventio_identity_role_assignments
        WHERE tenant_id=tenant AND role_id=role_key) THEN
      RAISE EXCEPTION 'Remove role assignments before deleting the role'
        USING ERRCODE='23503';
    END IF;
    DELETE FROM public.ventio_identity_role_permissions
      WHERE tenant_id=tenant AND role_id=role_key;
    DELETE FROM public.ventio_identity_roles
      WHERE tenant_id=tenant AND role_id=role_key;
    subject := role_key;
    details := jsonb_build_object('companyId',company,'branchId',branch);
  ELSIF operation IN ('ROLE_PERMISSION_GRANTED','ROLE_PERMISSION_REVOKED') THEN
    IF role_key IS NULL OR permission_name IS NULL OR
        permission_name !~ '^[a-z][a-z0-9_.]+$' OR length(permission_name)>256 THEN
      RAISE EXCEPTION 'Invalid role permission';
    END IF;
    IF operation='ROLE_PERMISSION_GRANTED' AND
        permission_name ~ '^(identity|host|system|security|recovery|authorization)\.' THEN
      RAISE EXCEPTION 'Host management permissions must be granted directly to a user'
        USING ERRCODE='42501';
    END IF;
    PERFORM 1 FROM public.ventio_identity_roles
      WHERE tenant_id=tenant AND role_id=role_key FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown role'; END IF;
    IF operation='ROLE_PERMISSION_GRANTED' THEN
      IF NOT EXISTS (SELECT FROM public.ventio_identity_role_permissions
          WHERE tenant_id=tenant AND role_id=role_key AND permission=permission_name) AND
          (SELECT count(*) FROM public.ventio_identity_role_permissions
            WHERE tenant_id=tenant AND role_id=role_key) >= 256 THEN
        RAISE EXCEPTION 'Role permission limit reached' USING ERRCODE='54000';
      END IF;
      INSERT INTO public.ventio_identity_role_permissions(tenant_id,role_id,permission)
        VALUES (tenant,role_key,permission_name) ON CONFLICT DO NOTHING;
    ELSE
      DELETE FROM public.ventio_identity_role_permissions
        WHERE tenant_id=tenant AND role_id=role_key AND permission=permission_name;
    END IF;
    GET DIAGNOSTICS changed = ROW_COUNT;
    IF changed = 0 THEN RETURN; END IF;
    subject := role_key;
    details := jsonb_build_object('permission',permission_name,
      'companyId',company,'branchId',branch);
  ELSIF operation IN ('ROLE_ASSIGNED','ROLE_UNASSIGNED') THEN
    IF actor IS NULL OR role_key IS NULL OR company IS NULL OR branch IS NULL THEN
      RAISE EXCEPTION 'Role assignment scope is required';
    END IF;
    SELECT disabled_at INTO is_disabled FROM public.ventio_identity_users
      WHERE tenant_id=tenant AND actor_id=actor FOR UPDATE;
    IF NOT FOUND OR is_disabled IS NOT NULL THEN RAISE EXCEPTION 'Unknown or disabled user'; END IF;
    PERFORM 1 FROM public.ventio_identity_roles
      WHERE tenant_id=tenant AND role_id=role_key FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown role'; END IF;
    IF operation='ROLE_ASSIGNED' THEN
      IF EXISTS (SELECT FROM public.ventio_identity_role_permissions
          WHERE tenant_id=tenant AND role_id=role_key
            AND permission='identity.roles.manage') THEN
        RAISE EXCEPTION 'Role management permission must be granted directly to a user'
          USING ERRCODE='42501';
      END IF;
      INSERT INTO public.ventio_identity_role_assignments
        (tenant_id,actor_id,company_id,branch_id,role_id)
        VALUES (tenant,actor,company,branch,role_key) ON CONFLICT DO NOTHING;
    ELSE
      DELETE FROM public.ventio_identity_role_assignments
        WHERE tenant_id=tenant AND actor_id=actor AND company_id=company
          AND branch_id=branch AND role_id=role_key;
    END IF;
    GET DIAGNOSTICS changed = ROW_COUNT;
    IF changed = 0 THEN RETURN; END IF;
    subject := actor;
    details := jsonb_build_object('roleId',role_key,'companyId',company,'branchId',branch);
  ELSIF operation IN ('EXTENSION_PACKAGE_APPROVED','EXTENSION_PACKAGE_REVOKED') THEN
    IF package_module IS NULL OR package_version IS NULL OR
        package_module !~ '^[a-z][a-z0-9]*([._-][a-z0-9]+)*$' OR
        length(package_module) > 128 OR length(package_version) > 64 OR
        package_version !~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' OR
        package_hash IS NULL OR package_hash !~ '^[0-9a-f]{64}$' THEN
      RAISE EXCEPTION 'Invalid extension release identity';
    END IF;
    -- Match the shared locks held by runtime record queries and commands. This
    -- makes release approval/revocation atomic with respect to operations that
    -- resolve the currently active package version.
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        pg_catalog.jsonb_build_array('ventio-extension-release-v1',
          tenant,package_module)::text, 0));
    SELECT * INTO package_row FROM public.ventio_extension_packages
      WHERE tenant_id=tenant AND module_id=package_module AND version=package_version
      FOR UPDATE;
    IF NOT FOUND OR package_row.package_sha256 IS DISTINCT FROM package_hash THEN
      RAISE EXCEPTION 'Extension package candidate changed or disappeared';
    END IF;
    IF operation = 'EXTENSION_PACKAGE_APPROVED' THEN
      IF package_row.status <> 'SUBMITTED' THEN
        RAISE EXCEPTION 'Only a submitted extension package can be approved';
      END IF;
      PERFORM public.ventio_validate_extension_schema_upgrade(
        tenant, package_module, package_version);
      IF EXISTS (SELECT FROM public.ventio_extension_packages prior
          WHERE prior.tenant_id=tenant AND prior.module_id=package_module
            AND prior.status IN ('APPROVED','REVOKED')
            AND (split_part(prior.version,'.',1)::numeric,
                 split_part(prior.version,'.',2)::numeric,
                 split_part(prior.version,'.',3)::numeric) >=
                (split_part(package_version,'.',1)::numeric,
                 split_part(package_version,'.',2)::numeric,
                 split_part(package_version,'.',3)::numeric)) THEN
        RAISE EXCEPTION 'Extension approval must advance the release version';
      END IF;
      FOR dependency IN
        SELECT dependency_entry.key, dependency_entry.value
        FROM jsonb_each_text(package_row.package_json->'dependencyVersions')
          AS dependency_entry(key, value)
      LOOP
        minimum_version := dependency.value;
        IF minimum_version !~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' OR
            NOT EXISTS (SELECT FROM public.ventio_extension_packages installed
              WHERE installed.tenant_id=tenant AND installed.module_id=dependency.key
                AND installed.status='APPROVED'
                AND split_part(installed.version,'.',1)::numeric =
                    split_part(minimum_version,'.',1)::numeric
                AND (split_part(minimum_version,'.',1)::numeric <> 0 OR
                     split_part(installed.version,'.',2)::numeric =
                     split_part(minimum_version,'.',2)::numeric)
                AND (split_part(installed.version,'.',1)::numeric,
                     split_part(installed.version,'.',2)::numeric,
                     split_part(installed.version,'.',3)::numeric) >=
                    (split_part(minimum_version,'.',1)::numeric,
                     split_part(minimum_version,'.',2)::numeric,
                     split_part(minimum_version,'.',3)::numeric)) THEN
          RAISE EXCEPTION 'Extension dependency is not Host-approved at a compatible version';
        END IF;
      END LOOP;
      UPDATE public.ventio_extension_packages SET status='APPROVED',
          approved_by=label, approved_at=clock_timestamp()
        WHERE tenant_id=tenant AND module_id=package_module AND version=package_version;
      INSERT INTO public.ventio_extension_package_events
        (tenant_id,module_id,version,event_type,actor_id,company_id,branch_id,package_sha256)
      VALUES (tenant,package_module,package_version,'APPROVED',label,
        package_row.submitted_company_id,package_row.submitted_branch_id,package_hash);
      details := jsonb_build_object('version',package_version,'packageSha256',package_hash);
    ELSE
      IF package_row.status <> 'APPROVED' OR package_reason IS NULL OR
          length(trim(package_reason)) NOT BETWEEN 1 AND 500 THEN
        RAISE EXCEPTION 'Only an approved release can be revoked with a reason';
      END IF;
      IF EXISTS (SELECT FROM public.ventio_extension_packages dependent
          WHERE dependent.tenant_id=tenant AND dependent.status='APPROVED'
            AND dependent.package_json->'dependencyVersions' ? package_module) THEN
        RAISE EXCEPTION 'Revoke approved dependent extensions before their dependency';
      END IF;
      UPDATE public.ventio_extension_packages SET status='REVOKED',
          revoked_by=label, revoked_at=clock_timestamp(), revoke_reason=package_reason
        WHERE tenant_id=tenant AND module_id=package_module AND version=package_version;
      INSERT INTO public.ventio_extension_package_events
        (tenant_id,module_id,version,event_type,actor_id,company_id,branch_id,package_sha256,details)
      VALUES (tenant,package_module,package_version,'REVOKED',label,
        package_row.submitted_company_id,package_row.submitted_branch_id,package_hash,
        jsonb_build_object('reason',package_reason));
      details := jsonb_build_object('version',package_version,'packageSha256',package_hash,'reason',package_reason);
    END IF;
    subject := package_module;
  ELSE
    IF operation = 'INITIAL_ADMIN_BOOTSTRAPPED' THEN
      IF NOT pg_has_role(session_user,'ventio_identity_admin','MEMBER') OR
          p-ARRAY['tenantId','operatorLabel','action','actorId','companyId',
            'branchId','deviceId','credentialId','tokenDigest','expiresAt'] <> '{}'::jsonb OR
          actor IS NULL OR company IS NULL OR branch IS NULL OR device IS NULL OR
          credential IS NULL OR p->>'tokenDigest' IS NULL OR
          p->>'tokenDigest' !~ '^[0-9a-f]{64}$' OR
          p->>'expiresAt' IS NULL OR
          (p->>'expiresAt')::timestamptz <= clock_timestamp() OR
          (p->>'expiresAt')::timestamptz > clock_timestamp()+interval '30 days' THEN
        RAISE EXCEPTION 'Invalid first administrator bootstrap request'
          USING ERRCODE='22023';
      END IF;
      IF EXISTS (SELECT FROM public.ventio_identity_users WHERE tenant_id=tenant) THEN
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
      FROM unnest(ARRAY[
        'host.status.read','host.diagnostics.read','identity.users.manage',
        'identity.devices.manage','identity.pairing.manage','identity.roles.manage'
      ]::text[]) AS permissions(permission);
      INSERT INTO public.ventio_identity_credentials
        (tenant_id,actor_id,device_id,credential_id,token_digest,expires_at,allowed_scopes)
      VALUES (tenant,actor,device,credential,p->>'tokenDigest',
        (p->>'expiresAt')::timestamptz,
        jsonb_build_array(jsonb_build_object('companyId',company,'branchId',branch,
          'permissions',jsonb_build_array('host.status.read','host.diagnostics.read',
            'identity.users.manage','identity.devices.manage','identity.pairing.manage',
            'identity.roles.manage'))));
      subject := actor;
      details := jsonb_build_object('companyId',company,'branchId',branch,
        'deviceId',device,'credentialId',credential,
        'permissions',jsonb_build_array('host.status.read','host.diagnostics.read',
          'identity.users.manage','identity.devices.manage','identity.pairing.manage',
          'identity.roles.manage'),'expiresAt',p->>'expiresAt');
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
            WHERE NOT (
              EXISTS (SELECT FROM public.ventio_identity_grants g WHERE
                g.tenant_id=tenant AND g.actor_id=actor AND g.company_id=s->>'companyId'
                AND g.branch_id=s->>'branchId' AND g.permission=requested.value)
              OR EXISTS (SELECT FROM public.ventio_identity_role_assignments a
                JOIN public.ventio_identity_role_permissions rp
                  USING (tenant_id,role_id)
                WHERE a.tenant_id=tenant AND a.actor_id=actor
                  AND a.company_id=s->>'companyId' AND a.branch_id=s->>'branchId'
                  AND rp.permission=requested.value))) THEN
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
      details := jsonb_build_object('companyId',company,'branchId',branch);
    ELSE RAISE EXCEPTION 'Unknown administrative operation';
    END CASE;
    END IF;
  END IF;
  -- session_user remains the authenticated DB login across SECURITY DEFINER.
  IF p->>'operatorActorId' IS NOT NULL THEN
    details := details || jsonb_build_object('operatorActorId',p->>'operatorActorId');
  END IF;
  INSERT INTO public.ventio_identity_audit (tenant_id, operator_label, action, subject_id, details)
    VALUES (tenant, label, operation, subject, details);
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
            AND e.action IN ('USER_DISABLED','PERMISSION_GRANTED',
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
        'USER_CREATED','USER_DISABLED','PERMISSION_GRANTED','PERMISSION_REVOKED',
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
        ('USER_CREATED','PERMISSION_GRANTED','PERMISSION_REVOKED','USER_DISABLED') OR
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
      (operation IN ('USER_CREATED','USER_DISABLED') AND
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
     (operation='USER_DISABLED' AND
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
          AND e.action IN ('USER_CREATED','USER_DISABLED','PERMISSION_GRANTED',
            'PERMISSION_REVOKED','ROLE_ASSIGNED','ROLE_UNASSIGNED')
          AND e.details->>'companyId'=p_company
          AND e.details->>'branchId'=p_branch) THEN
      RAISE EXCEPTION 'User not found' USING ERRCODE='P0002';
    END IF;
    IF target_disabled IS NOT NULL THEN
      RAISE EXCEPTION 'User not found or disabled' USING ERRCODE='P0002';
    END IF;
  END IF;

  IF operation='USER_DISABLED' THEN
    IF target_actor=credential_row.actor_id THEN
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
