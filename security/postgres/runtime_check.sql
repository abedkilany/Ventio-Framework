-- Fail closed if a login has gained privileges outside the supported profile.
CREATE OR REPLACE FUNCTION ventio_security.assert_runtime()
RETURNS void LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE r record; t text; c record;
BEGIN
  PERFORM ventio_security.assert_schema();
  IF NOT pg_has_role(session_user, 'ventio_runtime', 'MEMBER') OR
     NOT pg_has_role(current_user, 'ventio_runtime', 'MEMBER') THEN
    RAISE EXCEPTION 'Host requires the restricted runtime role';
  END IF;
  FOR r IN SELECT * FROM pg_catalog.pg_roles WHERE rolname IN (session_user, current_user) LOOP
    IF r.rolsuper OR r.rolbypassrls OR r.rolcreatedb OR r.rolcreaterole OR r.rolreplication THEN
      RAISE EXCEPTION 'Overprivileged Host login';
    END IF;
  END LOOP;
  IF EXISTS (SELECT FROM pg_catalog.pg_roles role_entry WHERE role_entry.rolname NOT IN (session_user, 'ventio_runtime')
      AND pg_has_role(session_user, role_entry.oid, 'MEMBER')) THEN
    RAISE EXCEPTION 'Unexpected runtime role membership';
  END IF;
  IF has_database_privilege(current_user, current_database(), 'CREATE') OR
      has_database_privilege(current_user, current_database(), 'TEMP') OR
      has_schema_privilege(current_user, 'public', 'CREATE') OR
      has_schema_privilege(current_user, 'ventio_security', 'CREATE') OR
      has_function_privilege(current_user, 'ventio_security.admin_change(jsonb)', 'EXECUTE') OR
      has_function_privilege(current_user, 'ventio_security.identity_snapshot(text,text,text)', 'EXECUTE') OR
      has_function_privilege(current_user,
        'ventio_security.bind_extension_authorization(jsonb,jsonb,text,text,text)', 'EXECUTE') OR
      has_function_privilege(current_user,
        'ventio_security.cached_extension_authorization(text,text,text)', 'EXECUTE') OR
      has_function_privilege(current_user,
        'ventio_security.extension_authorization_payload(jsonb,jsonb,text,text,text)', 'EXECUTE') OR
      has_function_privilege(current_user,
        'ventio_security.extension_policy(jsonb,text)', 'EXECUTE') OR
      has_function_privilege(current_user,
        'ventio_security.identity_role_manager_allowed(text,text,text,text)', 'EXECUTE') OR
      has_function_privilege(current_user,
        'ventio_security.scoped_admin_change(text,text,text,jsonb)', 'EXECUTE') OR
      has_function_privilege(current_user,
        'ventio_security.scoped_device_revoke(text,text,text,text)', 'EXECUTE') OR
      has_function_privilege(current_user,
        'public.ventio_validate_extension_schema_upgrade(text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Unexpected runtime DDL or identity capability';
  END IF;
  IF has_function_privilege(current_user,'ventio_security.wave2_operation_offers()','EXECUTE') OR
      has_function_privilege(current_user,'ventio_security.wave2_prepare_operation(text,text,text,text,text,jsonb)','EXECUTE') OR
      has_function_privilege(current_user,'ventio_security.wave2_operation_result(text,text,jsonb)','EXECUTE') OR
      has_function_privilege(current_user,'ventio_security.wave2_identity_snapshot_base(text,text,text)','EXECUTE') OR
      has_function_privilege(current_user,'ventio_security.wave2_prepare_rebase(text,text,text,text,text,text,text,bigint,jsonb)','EXECUTE') OR
      has_function_privilege(current_user,'ventio_security.wave2_organization_change(text,text,text,jsonb)','EXECUTE') OR
      has_function_privilege(current_user,'ventio_security.wave2_save_definition(text,text,text,text,text,bigint,text,jsonb)','EXECUTE') OR
      has_function_privilege(current_user,'ventio_security.wave2_claim_job()','EXECUTE') OR
      has_function_privilege(current_user,'ventio_security.wave2_finish_job(text,text,text,jsonb,boolean)','EXECUTE') OR
      has_function_privilege(current_user,'ventio_security.wave2_effective_package(text,text,text,jsonb,text)','EXECUTE') THEN
    RAISE EXCEPTION 'Unexpected Wave 2 private capability';
  END IF;
  FOREACH t IN ARRAY ARRAY['ventio_identity_users','ventio_identity_devices','ventio_identity_credentials',
      'ventio_identity_branches','ventio_identity_grants','ventio_identity_roles',
      'ventio_identity_role_permissions','ventio_identity_role_assignments',
      'ventio_identity_audit','ventio_identity_pairings','ventio_identity_device_activity',
      'ventio_extension_packages',
      'ventio_extension_package_events','ventio_wave2_definitions','ventio_wave2_revisions',
      'ventio_wave2_jobs','ventio_wave2_events','ventio_wave2_organizations','ventio_wave2_companies',
      'ventio_wave2_branches','ventio_wave2_admin_requests','ventio_wave2_operations','ventio_wave2_customization_rebases','ventio_schema_migrations'] LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_class pc JOIN pg_catalog.pg_namespace pn ON pn.oid = pc.relnamespace
        WHERE pn.nspname = 'public' AND pc.relname = t AND pc.relrowsecurity AND pc.relforcerowsecurity) THEN
      RAISE EXCEPTION 'Missing protection on private state';
    END IF;
    IF has_any_column_privilege(current_user, 'public.' || t, 'SELECT,INSERT,UPDATE,REFERENCES') OR
       has_table_privilege(current_user, 'public.' || t, 'DELETE,TRUNCATE,TRIGGER') THEN
      RAISE EXCEPTION 'Runtime has direct access to protected identity or migration state';
    END IF;
  END LOOP;
  FOR r IN SELECT pc.oid FROM pg_catalog.pg_class pc JOIN pg_catalog.pg_namespace pn ON pn.oid = pc.relnamespace
      WHERE pn.nspname = 'ventio_security' AND pc.relkind IN ('r','p') LOOP
    IF has_any_column_privilege(current_user, r.oid, 'SELECT,INSERT,UPDATE,REFERENCES') OR
        has_table_privilege(current_user, r.oid, 'DELETE,TRUNCATE,TRIGGER') THEN
      RAISE EXCEPTION 'Runtime has access to private security metadata';
    END IF;
  END LOOP;
  FOREACH t IN ARRAY ARRAY['ventio_records','ventio_command_journal','ventio_audit_entries','ventio_outbox',
      'ventio_document_number_series'] LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_class pc JOIN pg_catalog.pg_namespace pn ON pn.oid = pc.relnamespace
        JOIN pg_catalog.pg_roles pr ON pr.oid = pc.relowner WHERE pn.nspname = 'public' AND pc.relname = t
        AND pc.relrowsecurity AND pc.relforcerowsecurity AND pr.rolname = 'ventio_owner') THEN
      RAISE EXCEPTION 'Missing forced row security or wrong table owner';
    END IF;
    IF has_table_privilege(current_user, 'public.' || t, 'DELETE,TRUNCATE,REFERENCES,TRIGGER') THEN
      RAISE EXCEPTION 'Unexpected destructive runtime privilege';
    END IF;
    FOR c IN SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = t LOOP
      IF NOT ((t = 'ventio_command_journal' AND
          c.column_name IN ('receipt', 'scope_cursor')) OR
          (t = 'ventio_records' AND
          c.column_name IN ('revision', 'record_data', 'updated_at', 'deleted_at', 'document_status')) OR
          (t = 'ventio_document_number_series' AND c.column_name='next_number')) AND
          has_column_privilege(current_user, 'public.' || t, c.column_name, 'UPDATE') THEN
        RAISE EXCEPTION 'Unexpected runtime UPDATE privilege';
      END IF;
    END LOOP;
  END LOOP;
  IF EXISTS(WITH expected(table_name,policy_name,role_name,command) AS (VALUES
      ('ventio_records','runtime_select','ventio_runtime','r'),
      ('ventio_records','runtime_insert','ventio_runtime','a'),
      ('ventio_records','runtime_update','ventio_runtime','w'),
      ('ventio_command_journal','runtime_select','ventio_runtime','r'),
      ('ventio_command_journal','runtime_insert','ventio_runtime','a'),
      ('ventio_command_journal','runtime_update','ventio_runtime','w'),
      ('ventio_audit_entries','runtime_select','ventio_runtime','r'),
      ('ventio_audit_entries','runtime_insert','ventio_runtime','a'),
      ('ventio_outbox','runtime_select','ventio_runtime','r'),
      ('ventio_outbox','runtime_insert','ventio_runtime','a'),
      ('ventio_document_number_series','runtime_series_select','ventio_runtime','r'),
      ('ventio_document_number_series','runtime_series_insert','ventio_runtime','a'),
      ('ventio_document_number_series','runtime_series_update','ventio_runtime','w'),
      ('ventio_document_number_series','owner_access','ventio_owner','*'),
      ('ventio_records','extension_migration_select','ventio_owner','r'),
      ('ventio_records','extension_migration_update','ventio_owner','w'),
      ('ventio_records','wave2_scoped_migration_select','ventio_owner','r'),
      ('ventio_records','wave2_scoped_migration_update','ventio_owner','w'),
      ('ventio_outbox','wave2_history_seed_read','ventio_owner','r'),
      ('ventio_command_journal','wave2_history_seed_journal','ventio_owner','r'),
      ('ventio_audit_entries','wave2_history_seed_audit','ventio_owner','r')), actual AS (
    SELECT pc.relname table_name,pol.polname policy_name,pol.polroles,pol.polcmd,pol.polpermissive
    FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class pc ON pc.oid=pol.polrelid
    JOIN pg_catalog.pg_namespace pn ON pn.oid=pc.relnamespace WHERE pn.nspname='public' AND
     pc.relname IN ('ventio_records','ventio_command_journal','ventio_audit_entries','ventio_outbox','ventio_document_number_series'))
    SELECT FROM expected e FULL JOIN actual a USING(table_name,policy_name)
    WHERE e.role_name IS NULL OR a.polroles IS DISTINCT FROM ARRAY[(SELECT oid FROM pg_catalog.pg_roles WHERE rolname=e.role_name)] OR
      a.polcmd::text IS DISTINCT FROM e.command OR a.polpermissive IS DISTINCT FROM true) THEN
    RAISE EXCEPTION 'Unexpected row security policy set';
  END IF;
END $fn$;
