\set ON_ERROR_STOP on
-- Install only in a dedicated Ventio Framework database, after migrations.
-- The trusted cluster administrator must supply -v expected_database=NAME.
SELECT current_database() = :'expected_database' AS database_matches \gset
\if :database_matches
\else
  \echo 'Database confirmation mismatch.'
  \quit 2
\endif
BEGIN;
DO $roles$
DECLARE n text;
BEGIN
  FOREACH n IN ARRAY ARRAY['ventio_owner','ventio_runtime','ventio_identity_admin','ventio_identity_api','ventio_migrator'] LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = n) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT', n);
    ELSIF EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = n
      AND (rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) THEN
      RAISE EXCEPTION 'Unsafe pre-existing Ventio role: %', n;
    END IF;
  END LOOP;
END $roles$;
GRANT ventio_owner TO ventio_migrator WITH INHERIT FALSE, SET TRUE;
ALTER FUNCTION public.ventio_validate_extension_schema_upgrade(text,text,text)
  OWNER TO ventio_owner;
REVOKE ALL ON FUNCTION public.ventio_validate_extension_schema_upgrade(text,text,text)
  FROM PUBLIC, ventio_runtime, ventio_identity_admin, ventio_identity_api;
-- A prior recovery profile kept pgcrypto beside callable RLS functions. Move
-- that extension as the trusted cluster administrator before reducing to the
-- non-superuser owner role below.
CREATE SCHEMA IF NOT EXISTS ventio_crypto AUTHORIZATION ventio_owner;
REVOKE ALL ON SCHEMA ventio_crypto FROM PUBLIC, ventio_runtime, ventio_identity_admin, ventio_identity_api;
DO $crypto_upgrade$
DECLARE crypto_schema text; crypto_owner name;
BEGIN
  SELECT n.nspname,r.rolname INTO crypto_schema,crypto_owner
    FROM pg_catalog.pg_extension e
    JOIN pg_catalog.pg_namespace n ON n.oid=e.extnamespace
    JOIN pg_catalog.pg_roles r ON r.oid=e.extowner
    WHERE e.extname='pgcrypto';
  IF crypto_schema='ventio_security' AND crypto_owner='ventio_owner' THEN
    ALTER EXTENSION pgcrypto SET SCHEMA ventio_crypto;
  END IF;
END $crypto_upgrade$;
DO $database$
BEGIN
  EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO ventio_owner, ventio_runtime, ventio_identity_admin, ventio_identity_api, ventio_migrator', current_database());
  EXECUTE format('GRANT CREATE ON DATABASE %I TO ventio_owner', current_database());
END $database$;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO ventio_owner, ventio_runtime, ventio_identity_admin, ventio_identity_api, ventio_migrator;
GRANT CREATE ON SCHEMA public TO ventio_owner;
DO $ownership$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ventio_records','ventio_command_journal','ventio_audit_entries','ventio_outbox',
    'ventio_identity_users','ventio_identity_devices','ventio_identity_credentials','ventio_identity_branches',
    'ventio_identity_grants','ventio_identity_roles','ventio_identity_role_permissions',
    'ventio_identity_role_assignments','ventio_identity_audit','ventio_extension_packages',
    'ventio_identity_pairings','ventio_identity_device_activity',
    'ventio_extension_package_events','ventio_document_number_series',
    'ventio_schema_migrations'] LOOP
    EXECUTE format('ALTER TABLE public.%I OWNER TO ventio_owner', t);
  END LOOP;
END $ownership$;
SET LOCAL ROLE ventio_owner;
CREATE SCHEMA IF NOT EXISTS ventio_security AUTHORIZATION ventio_owner;
REVOKE ALL ON SCHEMA ventio_security FROM PUBLIC;
GRANT USAGE ON SCHEMA ventio_security TO ventio_runtime, ventio_identity_admin, ventio_identity_api;
CREATE SCHEMA IF NOT EXISTS ventio_crypto AUTHORIZATION ventio_owner;
REVOKE ALL ON SCHEMA ventio_crypto FROM PUBLIC, ventio_runtime, ventio_identity_admin, ventio_identity_api;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA ventio_crypto;
DO $crypto$
DECLARE crypto_schema text; crypto_owner name;
BEGIN
  SELECT n.nspname,r.rolname INTO crypto_schema,crypto_owner
    FROM pg_catalog.pg_extension e
    JOIN pg_catalog.pg_namespace n ON n.oid=e.extnamespace
    JOIN pg_catalog.pg_roles r ON r.oid=e.extowner
    WHERE e.extname='pgcrypto';
  IF crypto_owner IS DISTINCT FROM 'ventio_owner' OR
      crypto_schema IS DISTINCT FROM 'ventio_crypto' THEN
    RAISE EXCEPTION 'Private pgcrypto HMAC support is required';
  END IF;
  IF pg_catalog.to_regprocedure('ventio_crypto.hmac(bytea,bytea,text)') IS NULL THEN
    RAISE EXCEPTION 'Private pgcrypto HMAC support is required';
  END IF;
END $crypto$;
ALTER DEFAULT PRIVILEGES FOR ROLE ventio_owner IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE ventio_owner IN SCHEMA public REVOKE ALL ON SEQUENCES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE ventio_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, ventio_runtime, ventio_identity_admin, ventio_identity_api;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, ventio_runtime, ventio_identity_admin, ventio_identity_api;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, ventio_runtime, ventio_identity_admin, ventio_identity_api;
CREATE TABLE IF NOT EXISTS ventio_security.command_bindings (
  command_type text NOT NULL,
  command_version integer NOT NULL,
  doc_type text NOT NULL,
  create_permission text NOT NULL,
  read_permission text NOT NULL,
  module_id text NOT NULL DEFAULT 'legacy',
  PRIMARY KEY (command_type, command_version)
);
ALTER TABLE ventio_security.command_bindings
  ADD COLUMN IF NOT EXISTS module_id text NOT NULL DEFAULT 'legacy';
-- Protected tables also default-deny runtime access if an ACL is accidentally
-- broadened. Only the non-login owner used by vetted functions has a policy.
DO $protected$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['public.ventio_identity_users','public.ventio_identity_devices',
    'public.ventio_identity_credentials','public.ventio_identity_branches','public.ventio_identity_grants',
    'public.ventio_identity_roles','public.ventio_identity_role_permissions',
    'public.ventio_identity_role_assignments','public.ventio_identity_device_activity',
    'public.ventio_identity_audit','public.ventio_identity_pairings',
    'public.ventio_extension_packages',
    'public.ventio_extension_package_events','public.ventio_document_number_series',
    'public.ventio_schema_migrations','ventio_security.command_bindings'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS owner_access ON %s', t);
    EXECUTE format('CREATE POLICY owner_access ON %s TO ventio_owner USING (true) WITH CHECK (true)', t);
  END LOOP;
END $protected$;
INSERT INTO ventio_security.command_bindings
  (command_type,command_version,doc_type,create_permission,read_permission,module_id) VALUES
  ('maintenance.create', 1, 'MaintenanceRequest', 'maintenance.create', 'maintenance.read','com.ventio.maintenance'),
  ('inspection.create', 1, 'EquipmentInspection', 'inspection.create', 'inspection.read','com.ventio.inspection')
ON CONFLICT (command_type,command_version) DO UPDATE
  SET module_id=EXCLUDED.module_id;

\ir recovery.sql

-- Private identity reader. All locks survive until the caller's transaction ends.
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
  -- Activity is non-authority telemetry stored separately from Recovery-
  -- protected identity rows, so normal authentication never advances the
  -- Recovery Authority generation or grants clients table write access.
  INSERT INTO public.ventio_identity_device_activity AS activity
    (tenant_id,device_id,actor_id,last_authenticated_at,authentication_count)
    VALUES (c.tenant_id,c.device_id,c.actor_id,clock_timestamp(),1)
    ON CONFLICT (tenant_id,device_id) DO UPDATE
      SET last_authenticated_at=EXCLUDED.last_authenticated_at,
          authentication_count=activity.authentication_count+1
      WHERE activity.actor_id=EXCLUDED.actor_id
        AND activity.last_authenticated_at<clock_timestamp()-interval '1 minute';
  -- This single-row telemetry table is deliberately not part of the Recovery
  -- Authority mutation set. It grants no authority and stores no credentials.
  INSERT INTO public.ventio_identity_device_activity
    (tenant_id,device_id,actor_id,last_authenticated_at,authentication_count)
    VALUES (c.tenant_id,c.device_id,c.actor_id,clock_timestamp(),1)
    ON CONFLICT (tenant_id,device_id) DO UPDATE
      SET last_authenticated_at=EXCLUDED.last_authenticated_at,
          authentication_count=public.ventio_identity_device_activity.authentication_count+1
      WHERE public.ventio_identity_device_activity.actor_id=EXCLUDED.actor_id
        AND public.ventio_identity_device_activity.last_authenticated_at
          < clock_timestamp()-interval '1 minute';
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

-- Cache the identity and package policy already resolved by the trusted
-- extension resolver. RLS calls scope_allows once per row, so re-reading and
-- rebuilding the principal for every row creates avoidable N+1 database work.
-- The cache is transaction, backend, role, and exact-scope bound with a private
-- HMAC; callers cannot manufacture authorization by setting custom GUCs.
CREATE OR REPLACE FUNCTION ventio_security.extension_policy(p_package jsonb, p_module text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
  SELECT coalesce(jsonb_object_agg(item->>'name', jsonb_build_object(
    'moduleId',item->>'moduleId',
    'operations',coalesce(item->'operations','[]'::jsonb) || coalesce((
      SELECT jsonb_agg((operation->>'id') || '@' || (operation->>'version'))
      FROM jsonb_array_elements(coalesce(item->'businessOperations','[]'::jsonb)) AS declared(operation)
    ),'[]'::jsonb),
    'permissions',coalesce(item->'permissions','{}'::jsonb) || coalesce((
      SELECT jsonb_object_agg((operation->>'id') || '@' || (operation->>'version'),
        operation->'permission')
      FROM jsonb_array_elements(coalesce(item->'businessOperations','[]'::jsonb)) AS declared(operation)
    ),'{}'::jsonb),
    'businessOperations',coalesce(item->'businessOperations','[]'::jsonb),
    'fields',coalesce(item->'fields','[]'::jsonb),
    'naming',item->'naming')), '{}'::jsonb)
  FROM jsonb_array_elements(p_package->'docTypes') AS rows(item)
  WHERE item->>'moduleId'=p_module
$fn$;

CREATE OR REPLACE FUNCTION ventio_security.extension_authorization_payload(
    p_identity jsonb, p_policy jsonb, p_digest text, p_company text, p_branch text)
RETURNS text LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
  SELECT jsonb_build_array(
    'ventio-extension-authorization-v1', current_database(), session_user,
    current_user, pg_backend_pid(), pg_current_xact_id()::text,
    p_digest, p_company, p_branch,
    nullif(current_setting('ventio.command_type',true),''),
    nullif(current_setting('ventio.command_version',true),''),
    nullif(current_setting('ventio.command_id',true),''),
    nullif(current_setting('ventio.aggregate_id',true),''),
    nullif(current_setting('ventio.module_id',true),''),
    nullif(current_setting('ventio.module_version',true),''),
    nullif(current_setting('ventio.doc_type',true),''),
    nullif(current_setting('ventio.operation',true),''),
    nullif(current_setting('ventio.expected_revision',true),''),
    nullif(current_setting('ventio.operation_inputs',true),''),
    p_identity, p_policy
  )::text
$fn$;

CREATE OR REPLACE FUNCTION ventio_security.bind_extension_authorization(
    p_identity jsonb, p_package jsonb, p_digest text,
    p_company text, p_branch text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE state ventio_security.recovery_state%ROWTYPE;
        scoped_identity jsonb; policy jsonb; item_count integer; unique_count integer;
        payload text; proof text; module_id text; cache_key bytea;
BEGIN
  PERFORM set_config('ventio.extension_identity_snapshot','',true);
  PERFORM set_config('ventio.extension_policy_snapshot','',true);
  PERFORM set_config('ventio.extension_context_proof','',true);
  SELECT * INTO state FROM ventio_security.recovery_state WHERE singleton;
  -- Unenrolled databases are test/development profiles and must use the
  -- original live identity lookup. Never sign a cache with a public default.
  IF state.enforced IS DISTINCT FROM true OR state.authority_id !~ '^[A-Za-z0-9_-]{43}$' OR
      p_identity IS NULL OR p_package IS NULL OR p_digest !~ '^[0-9a-f]{64}$' OR
      p_company IS NULL OR p_branch IS NULL OR
      p_digest IS DISTINCT FROM nullif(current_setting('ventio.credential_digest',true),'') OR
      p_company IS DISTINCT FROM nullif(current_setting('ventio.company_id',true),'') OR
      p_branch IS DISTINCT FROM nullif(current_setting('ventio.branch_id',true),'') THEN
    RETURN false;
  END IF;
  module_id := nullif(current_setting('ventio.module_id',true),'');
  IF module_id IS NULL OR p_identity->>'tenantId' IS NULL OR
      jsonb_typeof(p_package->'docTypes') IS DISTINCT FROM 'array' OR
      NOT EXISTS (
        SELECT FROM jsonb_array_elements(p_identity->'scopeGrants') AS grants(item)
        WHERE item->>'companyId'=p_company AND item->>'branchId'=p_branch
      ) OR p_package->'manifest'->>'moduleId' IS DISTINCT FROM module_id OR
      p_package->'manifest'->>'version' IS DISTINCT FROM
        nullif(current_setting('ventio.module_version',true),'') THEN
    RETURN false;
  END IF;
  SELECT count(*)::integer,count(DISTINCT item->>'name')::integer
    INTO item_count,unique_count
    FROM jsonb_array_elements(p_package->'docTypes') AS rows(item)
    WHERE item->>'moduleId'=module_id;
  IF item_count NOT BETWEEN 1 AND 64 OR item_count<>unique_count THEN RETURN false; END IF;
  policy := ventio_security.extension_policy(p_package,module_id);
  IF NOT (policy ? nullif(current_setting('ventio.doc_type',true),'')) THEN
    RETURN false;
  END IF;
  scoped_identity := jsonb_build_object(
    'tenantId',p_identity->'tenantId','actorId',p_identity->'actorId',
    'deviceId',p_identity->'deviceId','permissions',p_identity->'permissions',
    'scopeGrants',p_identity->'scopeGrants');
  payload := ventio_security.extension_authorization_payload(
    scoped_identity,policy,p_digest,p_company,p_branch);
  cache_key := ventio_crypto.hmac(
    convert_to('ventio-extension-cache-key-v1','UTF8'),
    convert_to(state.authority_id,'UTF8'),'sha256');
  proof := encode(ventio_crypto.hmac(convert_to(payload,'UTF8'),
    cache_key,'sha256'),'hex');
  PERFORM set_config('ventio.extension_identity_snapshot',scoped_identity::text,true);
  PERFORM set_config('ventio.extension_policy_snapshot',policy::text,true);
  PERFORM set_config('ventio.extension_context_proof',proof,true);
  RETURN true;
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.cached_extension_authorization(
    p_tenant text, p_company text, p_branch text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE state ventio_security.recovery_state%ROWTYPE;
        identity jsonb; policy jsonb; payload text; expected text; proof text;
        digest text; cache_key bytea;
BEGIN
  SELECT * INTO state FROM ventio_security.recovery_state WHERE singleton;
  IF state.enforced IS DISTINCT FROM true OR state.authority_id !~ '^[A-Za-z0-9_-]{43}$' THEN
    RETURN NULL;
  END IF;
  digest := nullif(current_setting('ventio.credential_digest',true),'');
  proof := nullif(current_setting('ventio.extension_context_proof',true),'');
  IF digest IS NULL OR digest !~ '^[0-9a-f]{64}$' OR proof IS NULL OR proof !~ '^[0-9a-f]{64}$' OR
      p_company IS DISTINCT FROM nullif(current_setting('ventio.company_id',true),'') OR
      p_branch IS DISTINCT FROM nullif(current_setting('ventio.branch_id',true),'') THEN
    RETURN NULL;
  END IF;
  BEGIN
    identity := nullif(current_setting('ventio.extension_identity_snapshot',true),'')::jsonb;
    policy := nullif(current_setting('ventio.extension_policy_snapshot',true),'')::jsonb;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN NULL;
  END;
  IF identity IS NULL OR policy IS NULL THEN RETURN NULL; END IF;
  payload := ventio_security.extension_authorization_payload(
    identity,policy,digest,p_company,p_branch);
  cache_key := ventio_crypto.hmac(
    convert_to('ventio-extension-cache-key-v1','UTF8'),
    convert_to(state.authority_id,'UTF8'),'sha256');
  expected := encode(ventio_crypto.hmac(convert_to(payload,'UTF8'),
    cache_key,'sha256'),'hex');
  IF proof IS DISTINCT FROM expected THEN RETURN NULL; END IF;
  IF jsonb_typeof(identity) IS DISTINCT FROM 'object' OR
      identity->>'tenantId' IS DISTINCT FROM p_tenant OR
      jsonb_typeof(identity->'scopeGrants') IS DISTINCT FROM 'array' OR
      jsonb_typeof(policy) IS DISTINCT FROM 'object' OR
      NOT EXISTS (
        SELECT FROM jsonb_array_elements(identity->'scopeGrants') AS grants(item)
        WHERE item->>'companyId'=p_company AND item->>'branchId'=p_branch
      ) THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object('identity',identity,'policy',policy);
END $fn$;

\ir extensions.sql

-- Legacy command bindings re-read identity in policy evaluation. Extension
-- resolvers additionally bind a private, transaction-local authorization cache
-- that scope_allows authenticates before using for each returned row.
CREATE OR REPLACE FUNCTION ventio_security.resolve_identity(p_digest text, p_company text, p_branch text,
    p_type text, p_version integer, p_command text, p_aggregate text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE result jsonb;
BEGIN
  -- Clear before validation: a failed reauthentication cannot retain prior context.
  PERFORM set_config('ventio.credential_digest', '', true);
  PERFORM set_config('ventio.company_id', '', true);
  PERFORM set_config('ventio.branch_id', '', true);
  PERFORM set_config('ventio.command_type', '', true);
  PERFORM set_config('ventio.command_version', '', true);
  PERFORM set_config('ventio.command_id', '', true);
  PERFORM set_config('ventio.aggregate_id', '', true);
  PERFORM set_config('ventio.module_id', '', true);
  PERFORM set_config('ventio.extension_identity_snapshot', '', true);
  PERFORM set_config('ventio.extension_policy_snapshot', '', true);
  PERFORM set_config('ventio.extension_context_proof', '', true);
  result := ventio_security.identity_snapshot(p_digest, p_company, p_branch);
  IF result IS NOT NULL AND p_company IS NOT NULL AND p_branch IS NOT NULL THEN
    PERFORM set_config('ventio.credential_digest', p_digest, true);
    PERFORM set_config('ventio.company_id', p_company, true);
    PERFORM set_config('ventio.branch_id', p_branch, true);
    PERFORM set_config('ventio.command_type', coalesce(p_type, ''), true);
    PERFORM set_config('ventio.command_version', coalesce(p_version::text, ''), true);
    PERFORM set_config('ventio.command_id', coalesce(p_command, ''), true);
    PERFORM set_config('ventio.aggregate_id', coalesce(p_aggregate, ''), true);
    PERFORM set_config('ventio.module_id', coalesce((
      SELECT module_id FROM ventio_security.command_bindings
      WHERE command_type=p_type AND command_version=p_version
    ), ''), true);
  END IF;
  RETURN result;
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.scope_allows(p_tenant text, p_company text, p_branch text,
    p_mode text, p_subject text DEFAULT NULL, p_actor text DEFAULT NULL, p_device text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE identity jsonb; cached_context jsonb; policy jsonb;
        binding ventio_security.command_bindings%ROWTYPE;
        package_row public.ventio_extension_packages%ROWTYPE;
        dynamic_doc_type jsonb; target_doc_type jsonb;
        command_type text; dynamic_operation text; dynamic_module text;
        dynamic_version text; dynamic_name text; operation_permission text;
        read_permission text; can_create boolean; can_read boolean;
BEGIN
  IF p_company IS DISTINCT FROM nullif(current_setting('ventio.company_id', true), '') OR
     p_branch IS DISTINCT FROM nullif(current_setting('ventio.branch_id', true), '') THEN RETURN false; END IF;
  command_type := current_setting('ventio.command_type', true);
  IF command_type IN ('extension.record.create','extension.record.update','extension.record.delete','extension.record.query','extension.operation.execute') THEN
    dynamic_operation := nullif(current_setting('ventio.operation',true),'');
    dynamic_module := nullif(current_setting('ventio.module_id',true),'');
    dynamic_version := nullif(current_setting('ventio.module_version',true),'');
    dynamic_name := nullif(current_setting('ventio.doc_type',true),'');
    IF dynamic_module IS NULL OR dynamic_version IS NULL OR dynamic_name IS NULL OR
        (command_type='extension.record.create' AND dynamic_operation IS DISTINCT FROM 'create') OR
        (command_type='extension.record.update' AND dynamic_operation IS DISTINCT FROM 'update') OR
        (command_type='extension.record.delete' AND dynamic_operation IS DISTINCT FROM 'delete') OR
        (command_type='extension.record.query' AND dynamic_operation IS DISTINCT FROM 'read') OR
        (command_type='extension.operation.execute' AND
          (dynamic_operation IS NULL OR dynamic_operation !~ '^[a-z][a-z0-9]*(\.[a-z0-9]+|_[a-z0-9]+|-[a-z0-9]+)*@[1-9][0-9]{0,2}$')) THEN
      RETURN false;
    END IF;
    cached_context := ventio_security.cached_extension_authorization(
      p_tenant,p_company,p_branch);
    IF cached_context IS NOT NULL THEN
      identity := cached_context->'identity';
      policy := cached_context->'policy';
    ELSE
      -- A present but invalid cache is a rejected context, not permission to
      -- fall back to mutable caller-supplied authorization claims.
      IF nullif(current_setting('ventio.extension_identity_snapshot',true),'') IS NOT NULL OR
          nullif(current_setting('ventio.extension_policy_snapshot',true),'') IS NOT NULL OR
          nullif(current_setting('ventio.extension_context_proof',true),'') IS NOT NULL THEN
        RETURN false;
      END IF;
      identity := ventio_security.identity_snapshot(
        nullif(current_setting('ventio.credential_digest',true),''),p_company,p_branch);
    END IF;
    IF identity IS NULL OR identity->>'tenantId' IS DISTINCT FROM p_tenant OR
        NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements(identity->'scopeGrants') AS grants(item)
          WHERE item->>'companyId'=p_company AND item->>'branchId'=p_branch
        ) THEN RETURN false; END IF;
    IF cached_context IS NULL THEN
      SELECT * INTO package_row FROM public.ventio_extension_packages
        WHERE tenant_id=p_tenant AND module_id=dynamic_module
          AND version=dynamic_version AND status='APPROVED'
        FOR SHARE;
      IF NOT FOUND OR jsonb_typeof(package_row.package_json->'docTypes') IS DISTINCT FROM 'array' THEN
        RETURN false;
      END IF;
      policy := ventio_security.extension_policy(package_row.package_json,dynamic_module);
    END IF;
    dynamic_doc_type := policy->dynamic_name;
    IF dynamic_doc_type->>'moduleId' IS DISTINCT FROM dynamic_module THEN
      dynamic_doc_type := NULL;
    END IF;
    IF dynamic_doc_type IS NULL THEN RETURN false; END IF;
    operation_permission := dynamic_doc_type->'permissions'->>dynamic_operation;
    read_permission := dynamic_doc_type->'permissions'->>'read';
    IF operation_permission IS NULL OR operation_permission NOT LIKE
        'extension.' || regexp_replace(dynamic_module,'[^a-z0-9]+','_','g') || '.%' OR
        (read_permission IS NOT NULL AND read_permission NOT LIKE
          'extension.' || regexp_replace(dynamic_module,'[^a-z0-9]+','_','g') || '.%') THEN
      RETURN false;
    END IF;
    can_create := identity->'permissions' ? operation_permission;
    can_read := read_permission IS NOT NULL AND identity->'permissions' ? read_permission;
    IF p_mode='record_read' THEN
      IF p_subject=dynamic_name THEN
        RETURN can_read;
      END IF;
      target_doc_type := policy->p_subject;
      IF target_doc_type->>'moduleId' IS DISTINCT FROM dynamic_module THEN
        target_doc_type := NULL;
      END IF;
      IF target_doc_type IS NULL THEN RETURN false; END IF;
      read_permission := target_doc_type->'permissions'->>'read';
      IF read_permission IS NULL OR read_permission NOT LIKE
          'extension.' || regexp_replace(dynamic_module,'[^a-z0-9]+','_','g') || '.%' THEN
        RETURN false;
      END IF;
      RETURN identity->'permissions' ? read_permission;
    END IF;
    IF p_mode='record_reference_guard' THEN
      IF dynamic_operation <> 'delete' OR p_subject=dynamic_name THEN
        RETURN false;
      END IF;
      target_doc_type := policy->p_subject;
      IF target_doc_type->>'moduleId' IS DISTINCT FROM dynamic_module OR
          NOT (identity->'permissions' ? operation_permission) THEN
        RETURN false;
      END IF;
      RETURN EXISTS (
        SELECT 1 FROM jsonb_array_elements(
          coalesce(target_doc_type->'fields','[]'::jsonb)) AS fields(item)
        WHERE item->>'type'='reference'
          AND item->>'referenceTo'=dynamic_name
      );
    END IF;
    IF p_mode='record_insert' THEN
      RETURN dynamic_operation='create' AND can_create AND p_subject=dynamic_name
        AND nullif(current_setting('ventio.aggregate_id',true),'') IS NOT NULL;
    END IF;
    IF p_mode='record_amend_insert' THEN
      RETURN dynamic_operation ~ '@[1-9][0-9]{0,2}$' AND can_create
        AND p_subject=dynamic_name
        AND p_actor=nullif(current_setting('ventio.command_id',true),'')
        AND identity->'permissions' ? (dynamic_doc_type->'permissions'->>'create')
        AND EXISTS (
          SELECT FROM jsonb_array_elements(dynamic_doc_type->'businessOperations') AS ops(item)
          CROSS JOIN LATERAL jsonb_array_elements(ops.item->'effects') AS effects(effect)
          WHERE (ops.item->>'id') || '@' || (ops.item->>'version')=dynamic_operation
            AND effects.effect->>'type'='document.amend'
        );
    END IF;
    IF p_mode='record_update' THEN
      RETURN (dynamic_operation IN ('update','delete') AND can_create AND p_subject=dynamic_name) OR
        (dynamic_operation ~ '@[1-9][0-9]{0,2}$' AND can_create AND
          EXISTS (SELECT FROM jsonb_array_elements(dynamic_doc_type->'businessOperations') AS ops(item)
            CROSS JOIN LATERAL jsonb_array_elements(ops.item->'effects') AS effects(effect)
            WHERE (ops.item->>'id') || '@' || (ops.item->>'version')=dynamic_operation
      AND effects.effect->>'type' IN ('document.allocate_number','document.transition','record.increment','record.increment_rows','document.amend')
              AND p_subject=dynamic_name));
    END IF;
    IF p_mode='record_effect_update' THEN
      IF dynamic_operation !~ '@[1-9][0-9]{0,2}$' OR NOT can_create THEN RETURN false; END IF;
      RETURN EXISTS (
        SELECT FROM jsonb_array_elements(dynamic_doc_type->'businessOperations') AS ops(item)
        CROSS JOIN LATERAL jsonb_array_elements(ops.item->'effects') AS effects(effect)
        WHERE (ops.item->>'id') || '@' || (ops.item->>'version')=dynamic_operation
          AND effects.effect->>'type' IN ('record.increment','record.increment_rows')
          AND effects.effect->>'targetDocType'=p_subject
          AND p_actor=CASE WHEN effects.effect->>'type'='record.increment_rows'
            THEN nullif(current_setting('ventio.effect_target_id',true),'')
            ELSE ((nullif(current_setting('ventio.operation_inputs',true),'')::jsonb)
              ->>(effects.effect->>'targetIdInput')) END
          AND identity->'permissions' ? ((policy->p_subject)->'permissions'->>'read')
          AND identity->'permissions' ? ((policy->p_subject)->'permissions'->>'update')
          AND EXISTS (
            SELECT FROM jsonb_array_elements(coalesce((policy->p_subject)->'fields','[]'::jsonb)) AS fields(field)
            WHERE fields.field->>'name'=effects.effect->>'field'
              AND (fields.field->>'readPermission' IS NULL OR
                   identity->'permissions' ? (fields.field->>'readPermission'))
              AND (fields.field->>'writePermission' IS NULL OR
                   identity->'permissions' ? (fields.field->>'writePermission'))
          )
      );
    END IF;
    IF p_mode='series_allocate' THEN
      RETURN can_create AND p_subject=dynamic_name
        AND jsonb_typeof(dynamic_doc_type->'naming')='object'
        AND EXISTS (SELECT FROM jsonb_array_elements(dynamic_doc_type->'businessOperations') AS ops(item)
          CROSS JOIN LATERAL jsonb_array_elements(ops.item->'effects') AS effects(effect)
          WHERE (ops.item->>'id') || '@' || (ops.item->>'version')=dynamic_operation
            AND effects.effect->>'type'='document.allocate_number'
            AND effects.effect->>'field'=dynamic_doc_type->'naming'->>'field');
    END IF;
    IF p_mode IN ('record_transition_source','record_transition_target') THEN
      IF NOT can_create OR dynamic_operation !~ '@[1-9][0-9]{0,2}$' THEN RETURN false; END IF;
      RETURN EXISTS (
        SELECT FROM jsonb_array_elements(dynamic_doc_type->'businessOperations') AS ops(item)
        CROSS JOIN LATERAL jsonb_array_elements(ops.item->'effects') AS effects(effect)
        WHERE (ops.item->>'id') || '@' || (ops.item->>'version')=dynamic_operation
          AND effects.effect->>'type'='document.transition'
          AND p_subject=dynamic_name
          AND (p_mode<>'record_transition_target' OR effects.effect->>'targetStatus'=p_actor)
          AND (p_mode<>'record_transition_source' OR
            (effects.effect->>'targetStatus'='1' AND p_actor='0') OR
            (effects.effect->>'targetStatus'='2' AND p_actor='1'))
      );
    END IF;
    IF p_mode='journal_read' THEN RETURN can_create; END IF;
    IF p_mode IN ('journal_write','audit_write','outbox_write') THEN
      RETURN can_create AND p_subject=nullif(current_setting('ventio.command_id',true),'')
        AND (p_actor IS NULL OR p_actor=identity->>'actorId')
        AND (p_device IS NULL OR p_device=identity->>'deviceId');
    END IF;
    IF p_mode='event_read' THEN
      RETURN can_read AND p_subject IN ('extension.record.changed',command_type);
    END IF;
    RETURN false;
  END IF;
  SELECT b.* INTO binding FROM ventio_security.command_bindings AS b
    WHERE b.command_type = current_setting('ventio.command_type', true)
      AND b.command_version::text = current_setting('ventio.command_version', true);
  IF NOT FOUND THEN RETURN false; END IF;
  identity := ventio_security.identity_snapshot(nullif(current_setting('ventio.credential_digest', true), ''), p_company, p_branch);
  IF identity IS NULL OR identity->>'tenantId' IS DISTINCT FROM p_tenant OR
      NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(identity->'scopeGrants') AS grant_rows(grant_row)
        WHERE grant_row->>'companyId' = p_company AND grant_row->>'branchId' = p_branch
      ) THEN RETURN false; END IF;
  can_create := identity->'permissions' ? binding.create_permission;
  can_read := can_create OR identity->'permissions' ? binding.read_permission;
  IF p_mode = 'record_read' THEN
    RETURN can_read AND p_subject = binding.doc_type
      AND current_setting('ventio.module_id',true)=binding.module_id;
  END IF;
  IF p_mode = 'record_insert' THEN
    RETURN can_create AND p_subject = binding.doc_type
      AND current_setting('ventio.module_id',true)=binding.module_id
      AND current_setting('ventio.aggregate_id', true) IS NOT NULL;
  END IF;
  IF p_mode = 'journal_read' THEN RETURN can_create; END IF;
  IF p_mode IN ('journal_write', 'audit_write', 'outbox_write') THEN
    RETURN can_create AND p_subject = nullif(current_setting('ventio.command_id', true), '')
      AND (p_actor IS NULL OR p_actor = identity->>'actorId')
      AND (p_device IS NULL OR p_device = identity->>'deviceId');
  END IF;
  IF p_mode = 'event_read' THEN
    RETURN can_read AND p_subject IN (binding.command_type, binding.doc_type || '.created');
  END IF;
  RETURN false;
END $fn$;

ALTER TABLE public.ventio_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ventio_records FORCE ROW LEVEL SECURITY;
ALTER TABLE public.ventio_command_journal ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ventio_command_journal FORCE ROW LEVEL SECURITY;
ALTER TABLE public.ventio_audit_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ventio_audit_entries FORCE ROW LEVEL SECURITY;
ALTER TABLE public.ventio_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ventio_outbox FORCE ROW LEVEL SECURITY;
ALTER TABLE public.ventio_document_number_series ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ventio_document_number_series FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS runtime_select ON public.ventio_records;
DROP POLICY IF EXISTS runtime_insert ON public.ventio_records;
CREATE POLICY runtime_select ON public.ventio_records FOR SELECT TO ventio_runtime
  USING ((ventio_security.scope_allows(tenant_id, company_id, branch_id, 'record_read', doc_type)
      OR ventio_security.scope_allows(tenant_id, company_id, branch_id, 'record_reference_guard', doc_type))
    AND module_id = current_setting('ventio.module_id',true)
    AND (deleted_at IS NULL OR
      (current_setting('ventio.operation',true)='delete'
        AND record_id=current_setting('ventio.aggregate_id',true))));
CREATE POLICY runtime_insert ON public.ventio_records FOR INSERT TO ventio_runtime
  WITH CHECK (module_id = current_setting('ventio.module_id',true)
    AND ((ventio_security.scope_allows(tenant_id, company_id, branch_id, 'record_insert', doc_type)
      AND record_id = current_setting('ventio.aggregate_id', true))
      OR (ventio_security.scope_allows(tenant_id, company_id, branch_id,
          'record_amend_insert', doc_type, record_id)
        AND record_id = current_setting('ventio.command_id', true))));
DROP POLICY IF EXISTS runtime_update ON public.ventio_records;
CREATE POLICY runtime_update ON public.ventio_records FOR UPDATE TO ventio_runtime
  USING ((ventio_security.scope_allows(tenant_id, company_id, branch_id, 'record_update', doc_type)
    AND module_id = current_setting('ventio.module_id',true)
    AND record_id = current_setting('ventio.aggregate_id', true)
    AND revision = nullif(current_setting('ventio.expected_revision',true),'')::integer)
    OR (ventio_security.scope_allows(tenant_id, company_id, branch_id, 'record_transition_source', doc_type, document_status::text)
      AND module_id = current_setting('ventio.module_id',true)
      AND record_id = current_setting('ventio.aggregate_id', true)
      AND revision = nullif(current_setting('ventio.expected_revision',true),'')::integer)
    OR (ventio_security.scope_allows(tenant_id, company_id, branch_id, 'record_effect_update', doc_type, record_id)
      AND module_id = current_setting('ventio.module_id',true)))
  WITH CHECK (
    (ventio_security.scope_allows(tenant_id, company_id, branch_id, 'record_update', doc_type)
      AND module_id = current_setting('ventio.module_id',true)
      AND record_id = current_setting('ventio.aggregate_id', true)
      AND revision = nullif(current_setting('ventio.expected_revision',true),'')::integer + 1
      AND ((current_setting('ventio.operation',true)='update' AND deleted_at IS NULL AND document_status=0)
        OR (current_setting('ventio.command_type',true)='extension.operation.execute' AND deleted_at IS NULL AND document_status=0)
        OR (current_setting('ventio.operation',true)='delete'
          AND deleted_at IS NOT NULL AND document_status=0)))
    OR (ventio_security.scope_allows(tenant_id, company_id, branch_id, 'record_effect_update', doc_type, record_id)
      AND module_id = current_setting('ventio.module_id',true))
    OR (ventio_security.scope_allows(tenant_id, company_id, branch_id, 'record_transition_target', doc_type, document_status::text)
      AND module_id = current_setting('ventio.module_id',true)
      AND record_id = current_setting('ventio.aggregate_id', true)
      AND revision = nullif(current_setting('ventio.expected_revision',true),'')::integer + 1));
DROP POLICY IF EXISTS runtime_series_select ON public.ventio_document_number_series;
CREATE POLICY runtime_series_select ON public.ventio_document_number_series
  FOR SELECT TO ventio_runtime
  USING (ventio_security.scope_allows(tenant_id,company_id,branch_id,
      'series_allocate',doc_type)
    AND module_id=current_setting('ventio.module_id',true)
    AND doc_type=current_setting('ventio.doc_type',true));
DROP POLICY IF EXISTS runtime_series_insert ON public.ventio_document_number_series;
CREATE POLICY runtime_series_insert ON public.ventio_document_number_series
  FOR INSERT TO ventio_runtime
  WITH CHECK (ventio_security.scope_allows(tenant_id,company_id,branch_id,
      'series_allocate',doc_type)
    AND module_id=current_setting('ventio.module_id',true)
    AND doc_type=current_setting('ventio.doc_type',true));
DROP POLICY IF EXISTS runtime_series_update ON public.ventio_document_number_series;
CREATE POLICY runtime_series_update ON public.ventio_document_number_series
  FOR UPDATE TO ventio_runtime
  USING (ventio_security.scope_allows(tenant_id,company_id,branch_id,
      'series_allocate',doc_type)
    AND module_id=current_setting('ventio.module_id',true)
    AND doc_type=current_setting('ventio.doc_type',true))
  WITH CHECK (ventio_security.scope_allows(tenant_id,company_id,branch_id,
      'series_allocate',doc_type)
    AND module_id=current_setting('ventio.module_id',true)
    AND doc_type=current_setting('ventio.doc_type',true));
-- Reviewed schema migrations run only inside the fixed extension approval
-- function. The owner is NOLOGIN; its record access is enabled only when that
-- function is called by the restricted identity-administration role.
DROP POLICY IF EXISTS extension_migration_select ON public.ventio_records;
CREATE POLICY extension_migration_select ON public.ventio_records FOR SELECT TO ventio_owner
  USING (pg_has_role(session_user,'ventio_identity_admin','MEMBER'));
DROP POLICY IF EXISTS extension_migration_update ON public.ventio_records;
CREATE POLICY extension_migration_update ON public.ventio_records FOR UPDATE TO ventio_owner
  USING (pg_has_role(session_user,'ventio_identity_admin','MEMBER'))
  WITH CHECK (pg_has_role(session_user,'ventio_identity_admin','MEMBER'));
DROP POLICY IF EXISTS runtime_select ON public.ventio_command_journal;
DROP POLICY IF EXISTS runtime_insert ON public.ventio_command_journal;
DROP POLICY IF EXISTS runtime_update ON public.ventio_command_journal;
CREATE POLICY runtime_select ON public.ventio_command_journal FOR SELECT TO ventio_runtime
  USING (ventio_security.scope_allows(tenant_id, company_id, branch_id, 'journal_read'));
CREATE POLICY runtime_insert ON public.ventio_command_journal FOR INSERT TO ventio_runtime
  WITH CHECK (ventio_security.scope_allows(tenant_id, company_id, branch_id, 'journal_write', command_id, actor_id, device_id));
CREATE POLICY runtime_update ON public.ventio_command_journal FOR UPDATE TO ventio_runtime
  USING (ventio_security.scope_allows(tenant_id, company_id, branch_id, 'journal_write', command_id, actor_id, device_id))
  WITH CHECK (ventio_security.scope_allows(tenant_id, company_id, branch_id, 'journal_write', command_id, actor_id, device_id));
DROP POLICY IF EXISTS runtime_select ON public.ventio_audit_entries;
DROP POLICY IF EXISTS runtime_insert ON public.ventio_audit_entries;
CREATE POLICY runtime_select ON public.ventio_audit_entries FOR SELECT TO ventio_runtime
  USING (ventio_security.scope_allows(tenant_id, company_id, branch_id, 'event_read', event_type));
CREATE POLICY runtime_insert ON public.ventio_audit_entries FOR INSERT TO ventio_runtime
  WITH CHECK (ventio_security.scope_allows(tenant_id, company_id, branch_id, 'audit_write', command_id, actor_id));
DROP POLICY IF EXISTS runtime_select ON public.ventio_outbox;
DROP POLICY IF EXISTS runtime_insert ON public.ventio_outbox;
CREATE POLICY runtime_select ON public.ventio_outbox FOR SELECT TO ventio_runtime
  USING (ventio_security.scope_allows(tenant_id, company_id, branch_id, 'event_read', event_type));
CREATE POLICY runtime_insert ON public.ventio_outbox FOR INSERT TO ventio_runtime
  WITH CHECK (ventio_security.scope_allows(tenant_id, company_id, branch_id, 'outbox_write', command_id));
GRANT SELECT, INSERT ON public.ventio_records, public.ventio_command_journal,
  public.ventio_audit_entries, public.ventio_outbox TO ventio_runtime;
GRANT UPDATE (revision, record_data, updated_at, deleted_at, document_status) ON public.ventio_records TO ventio_runtime;
GRANT UPDATE (receipt, scope_cursor) ON public.ventio_command_journal TO ventio_runtime;
GRANT SELECT, INSERT ON public.ventio_document_number_series TO ventio_runtime;
GRANT UPDATE (next_number) ON public.ventio_document_number_series TO ventio_runtime;
GRANT USAGE ON SEQUENCE public.ventio_audit_entries_audit_id_seq, public.ventio_outbox_outbox_id_seq TO ventio_runtime;
\ir administration.sql
\ir pairing.sql
\ir schema_profile.sql
\ir runtime_check.sql
REVOKE ALL ON ALL TABLES IN SCHEMA ventio_security FROM PUBLIC, ventio_runtime, ventio_identity_admin, ventio_identity_api;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA ventio_security FROM PUBLIC, ventio_runtime, ventio_identity_admin, ventio_identity_api;
GRANT EXECUTE ON FUNCTION ventio_security.resolve_identity(text,text,text,text,integer,text,text),
  ventio_security.scope_allows(text,text,text,text,text,text,text), ventio_security.assert_runtime(), ventio_security.assert_schema(),
  ventio_security.admit_recovery(text,text),
  ventio_security.resolve_extension_read_identity(text,text,text,text,text,text),
  ventio_security.resolve_extension_identity(text,text,text,text,integer,text,text,text,text,text,text,bigint,jsonb),
  ventio_security.submit_extension_package(text,text,text,text,text,text,text,jsonb),
  ventio_security.read_approved_extension_package(text,text,text,text,text,text),
  ventio_security.list_approved_extension_packages(text,text,text,text,text,text,integer),
  ventio_security.identity_roles_snapshot(text,text,text),
  ventio_security.identity_users_snapshot(text,text,text),
  ventio_security.identity_users_audit_snapshot(text,text,text),
  ventio_security.identity_devices_snapshot(text,text,text)
  TO ventio_runtime;
GRANT EXECUTE ON FUNCTION ventio_security.admin_change(jsonb),
  ventio_security.admit_recovery(text,text),
  ventio_security.recovery_snapshot(),
  ventio_security.reset_recovery(text,text),
  ventio_security.read_extension_submission(text,text,text),
  public.ventio_validate_extension_schema_upgrade(text,text,text),
  ventio_security.assert_schema() TO ventio_identity_admin;
GRANT EXECUTE ON FUNCTION
  ventio_security.scoped_admin_change(text,text,text,jsonb),
  ventio_security.scoped_user_admin_change(text,text,text,jsonb),
  ventio_security.scoped_pairing_create(text,text,text,text,text,text),
  ventio_security.scoped_pairing_redeem(text,text,text,text),
  ventio_security.scoped_device_revoke(text,text,text,text),
  ventio_security.scoped_device_credential_rotate(text,text,text,text,text,text,text),
  ventio_security.admit_recovery(text,text),
  ventio_security.recovery_snapshot(),
  ventio_security.initialize_first_host_recovery(text),
  ventio_security.reconcile_pending_first_admin(text,text,text,text,text,text,text,text,text,timestamp with time zone),
  ventio_security.bootstrap_first_admin(jsonb)
  TO ventio_identity_api;
-- pgcrypto functions are extension members and may remain owned by the cluster
-- bootstrap login even though the extension is assigned to ventio_owner. Reset
-- the temporary SET ROLE before hardening their ACLs. Only SECURITY DEFINER
-- functions owned by ventio_owner need to call these crypto primitives.
RESET ROLE;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA ventio_crypto
  FROM PUBLIC, ventio_runtime, ventio_identity_admin, ventio_identity_api;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ventio_crypto TO ventio_owner;
COMMIT;
