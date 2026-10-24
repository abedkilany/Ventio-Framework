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
  FOREACH n IN ARRAY ARRAY['ventio_owner','ventio_runtime','ventio_identity_admin','ventio_migrator'] LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = n) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT', n);
    ELSIF EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = n
      AND (rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) THEN
      RAISE EXCEPTION 'Unsafe pre-existing Ventio role: %', n;
    END IF;
  END LOOP;
END $roles$;
GRANT ventio_owner TO ventio_migrator WITH INHERIT FALSE, SET TRUE;
-- A prior recovery profile kept pgcrypto beside callable RLS functions. Move
-- that extension as the trusted cluster administrator before reducing to the
-- non-superuser owner role below.
CREATE SCHEMA IF NOT EXISTS ventio_crypto AUTHORIZATION ventio_owner;
REVOKE ALL ON SCHEMA ventio_crypto FROM PUBLIC, ventio_runtime, ventio_identity_admin;
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
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO ventio_owner, ventio_runtime, ventio_identity_admin, ventio_migrator', current_database());
  EXECUTE format('GRANT CREATE ON DATABASE %I TO ventio_owner', current_database());
END $database$;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO ventio_owner, ventio_runtime, ventio_identity_admin, ventio_migrator;
GRANT CREATE ON SCHEMA public TO ventio_owner;
DO $ownership$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ventio_records','ventio_command_journal','ventio_audit_entries','ventio_outbox',
    'ventio_identity_users','ventio_identity_devices','ventio_identity_credentials','ventio_identity_branches',
    'ventio_identity_grants','ventio_identity_audit','ventio_extension_packages',
    'ventio_extension_package_events','ventio_schema_migrations'] LOOP
    EXECUTE format('ALTER TABLE public.%I OWNER TO ventio_owner', t);
  END LOOP;
END $ownership$;
SET LOCAL ROLE ventio_owner;
CREATE SCHEMA IF NOT EXISTS ventio_security AUTHORIZATION ventio_owner;
REVOKE ALL ON SCHEMA ventio_security FROM PUBLIC;
GRANT USAGE ON SCHEMA ventio_security TO ventio_runtime, ventio_identity_admin;
CREATE SCHEMA IF NOT EXISTS ventio_crypto AUTHORIZATION ventio_owner;
REVOKE ALL ON SCHEMA ventio_crypto FROM PUBLIC, ventio_runtime, ventio_identity_admin;
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
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, ventio_runtime, ventio_identity_admin;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, ventio_runtime, ventio_identity_admin;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, ventio_runtime, ventio_identity_admin;
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
    'public.ventio_identity_audit','public.ventio_extension_packages',
    'public.ventio_extension_package_events','public.ventio_schema_migrations','ventio_security.command_bindings'] LOOP
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
        scope_grants jsonb := '[]'::jsonb;
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
  FOR g IN SELECT company_id, branch_id, permission FROM public.ventio_identity_grants
    WHERE tenant_id = c.tenant_id AND actor_id = c.actor_id
      AND (p_company IS NULL OR company_id = p_company)
      AND (p_branch IS NULL OR branch_id = p_branch)
      AND (c.allowed_scopes IS NULL OR EXISTS (
        SELECT FROM jsonb_array_elements(c.allowed_scopes) s
        WHERE s->>'companyId' = company_id AND s->>'branchId' = branch_id
          AND s->'permissions' ? permission))
    ORDER BY company_id, branch_id, permission FOR SHARE LOOP
    companies := array_append(companies, g.company_id);
    branches := array_append(branches, g.branch_id);
    permissions := array_append(permissions, g.permission);
    scope_grants := scope_grants || jsonb_build_array(jsonb_build_object(
      'companyId', g.company_id, 'branchId', g.branch_id, 'permission', g.permission));
  END LOOP;
  RETURN jsonb_build_object('tenantId', c.tenant_id, 'actorId', c.actor_id, 'deviceId', c.device_id,
    'companyIds', companies, 'branchIds', branches, 'permissions', permissions,
    'scopeGrants', scope_grants);
END $fn$;

\ir extensions.sql

-- The context contains a confidential proof handle, not trusted scope claims.
-- Policies revalidate it against current identity/grants on EVERY statement.
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
DECLARE identity jsonb; binding ventio_security.command_bindings%ROWTYPE;
        package_row public.ventio_extension_packages%ROWTYPE;
        dynamic_doc_type jsonb; target_doc_type jsonb;
        command_type text; dynamic_operation text; dynamic_module text;
        dynamic_version text; dynamic_name text; operation_permission text;
        read_permission text; can_create boolean; can_read boolean;
BEGIN
  IF p_company IS DISTINCT FROM nullif(current_setting('ventio.company_id', true), '') OR
     p_branch IS DISTINCT FROM nullif(current_setting('ventio.branch_id', true), '') THEN RETURN false; END IF;
  command_type := current_setting('ventio.command_type', true);
  IF command_type IN ('extension.record.create','extension.record.update','extension.record.query') THEN
    dynamic_operation := nullif(current_setting('ventio.operation',true),'');
    dynamic_module := nullif(current_setting('ventio.module_id',true),'');
    dynamic_version := nullif(current_setting('ventio.module_version',true),'');
    dynamic_name := nullif(current_setting('ventio.doc_type',true),'');
    IF dynamic_module IS NULL OR dynamic_version IS NULL OR dynamic_name IS NULL OR
        (command_type='extension.record.create' AND dynamic_operation IS DISTINCT FROM 'create') OR
        (command_type='extension.record.update' AND dynamic_operation IS DISTINCT FROM 'update') OR
        (command_type='extension.record.query' AND dynamic_operation IS DISTINCT FROM 'read') THEN
      RETURN false;
    END IF;
    identity := ventio_security.identity_snapshot(
      nullif(current_setting('ventio.credential_digest',true),''),p_company,p_branch);
    IF identity IS NULL OR identity->>'tenantId' IS DISTINCT FROM p_tenant OR
        NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements(identity->'scopeGrants') AS grants(item)
          WHERE item->>'companyId'=p_company AND item->>'branchId'=p_branch
        ) THEN RETURN false; END IF;
    SELECT * INTO package_row FROM public.ventio_extension_packages
      WHERE tenant_id=p_tenant AND module_id=dynamic_module
        AND version=dynamic_version AND status='APPROVED'
      FOR SHARE;
    IF NOT FOUND OR jsonb_typeof(package_row.package_json->'docTypes') IS DISTINCT FROM 'array' THEN
      RETURN false;
    END IF;
    SELECT item INTO dynamic_doc_type
    FROM jsonb_array_elements(package_row.package_json->'docTypes') AS entries(item)
    WHERE item->>'moduleId'=dynamic_module AND item->>'name'=dynamic_name
    LIMIT 1;
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
      SELECT item INTO target_doc_type
      FROM jsonb_array_elements(package_row.package_json->'docTypes') AS entries(item)
      WHERE item->>'moduleId'=dynamic_module AND item->>'name'=p_subject
      LIMIT 1;
      IF target_doc_type IS NULL THEN RETURN false; END IF;
      read_permission := target_doc_type->'permissions'->>'read';
      IF read_permission IS NULL OR read_permission NOT LIKE
          'extension.' || regexp_replace(dynamic_module,'[^a-z0-9]+','_','g') || '.%' THEN
        RETURN false;
      END IF;
      RETURN identity->'permissions' ? read_permission;
    END IF;
    IF p_mode='record_insert' THEN
      RETURN dynamic_operation='create' AND can_create AND p_subject=dynamic_name
        AND nullif(current_setting('ventio.aggregate_id',true),'') IS NOT NULL;
    END IF;
    IF p_mode='record_update' THEN
      RETURN dynamic_operation='update' AND can_create AND p_subject=dynamic_name;
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
DROP POLICY IF EXISTS runtime_select ON public.ventio_records;
DROP POLICY IF EXISTS runtime_insert ON public.ventio_records;
CREATE POLICY runtime_select ON public.ventio_records FOR SELECT TO ventio_runtime
  USING (ventio_security.scope_allows(tenant_id, company_id, branch_id, 'record_read', doc_type)
    AND module_id = current_setting('ventio.module_id',true));
CREATE POLICY runtime_insert ON public.ventio_records FOR INSERT TO ventio_runtime
  WITH CHECK (ventio_security.scope_allows(tenant_id, company_id, branch_id, 'record_insert', doc_type)
    AND module_id = current_setting('ventio.module_id',true)
    AND record_id = current_setting('ventio.aggregate_id', true));
DROP POLICY IF EXISTS runtime_update ON public.ventio_records;
CREATE POLICY runtime_update ON public.ventio_records FOR UPDATE TO ventio_runtime
  USING (ventio_security.scope_allows(tenant_id, company_id, branch_id, 'record_update', doc_type)
    AND module_id = current_setting('ventio.module_id',true)
    AND record_id = current_setting('ventio.aggregate_id', true)
    AND revision = nullif(current_setting('ventio.expected_revision',true),'')::integer)
  WITH CHECK (ventio_security.scope_allows(tenant_id, company_id, branch_id, 'record_update', doc_type)
    AND module_id = current_setting('ventio.module_id',true)
    AND record_id = current_setting('ventio.aggregate_id', true)
    AND revision = nullif(current_setting('ventio.expected_revision',true),'')::integer + 1);
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
GRANT UPDATE (revision, record_data, updated_at) ON public.ventio_records TO ventio_runtime;
GRANT UPDATE (receipt, scope_cursor) ON public.ventio_command_journal TO ventio_runtime;
GRANT USAGE ON SEQUENCE public.ventio_audit_entries_audit_id_seq, public.ventio_outbox_outbox_id_seq TO ventio_runtime;
\ir administration.sql
\ir schema_profile.sql
\ir runtime_check.sql
REVOKE ALL ON ALL TABLES IN SCHEMA ventio_security FROM PUBLIC, ventio_runtime, ventio_identity_admin;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA ventio_security FROM PUBLIC, ventio_runtime, ventio_identity_admin;
GRANT EXECUTE ON FUNCTION ventio_security.resolve_identity(text,text,text,text,integer,text,text),
  ventio_security.scope_allows(text,text,text,text,text,text,text), ventio_security.assert_runtime(), ventio_security.assert_schema(),
  ventio_security.admit_recovery(text,text),
  ventio_security.resolve_extension_read_identity(text,text,text,text,text,text),
  ventio_security.resolve_extension_identity(text,text,text,text,integer,text,text,text,text,text,text,bigint),
  ventio_security.submit_extension_package(text,text,text,text,text,text,text,jsonb),
  ventio_security.read_approved_extension_package(text,text,text,text,text,text)
  TO ventio_runtime;
GRANT EXECUTE ON FUNCTION ventio_security.admin_change(jsonb), ventio_security.recovery_snapshot(),
  ventio_security.reset_recovery(text,text),
  ventio_security.read_extension_submission(text,text,text),
  ventio_security.assert_schema() TO ventio_identity_admin;
COMMIT;
