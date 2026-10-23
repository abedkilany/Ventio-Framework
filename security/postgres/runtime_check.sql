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
      has_function_privilege(current_user, 'ventio_security.identity_snapshot(text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Unexpected runtime DDL or identity capability';
  END IF;
  FOREACH t IN ARRAY ARRAY['ventio_identity_users','ventio_identity_devices','ventio_identity_credentials',
      'ventio_identity_branches','ventio_identity_grants','ventio_identity_audit','ventio_schema_migrations'] LOOP
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
  FOREACH t IN ARRAY ARRAY['ventio_records','ventio_command_journal','ventio_audit_entries','ventio_outbox'] LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_class pc JOIN pg_catalog.pg_namespace pn ON pn.oid = pc.relnamespace
        JOIN pg_catalog.pg_roles pr ON pr.oid = pc.relowner WHERE pn.nspname = 'public' AND pc.relname = t
        AND pc.relrowsecurity AND pc.relforcerowsecurity AND pr.rolname = 'ventio_owner') THEN
      RAISE EXCEPTION 'Missing forced row security or wrong table owner';
    END IF;
    IF has_table_privilege(current_user, 'public.' || t, 'DELETE,TRUNCATE,REFERENCES,TRIGGER') THEN
      RAISE EXCEPTION 'Unexpected destructive runtime privilege';
    END IF;
    FOR c IN SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = t LOOP
      IF NOT (t = 'ventio_command_journal' AND c.column_name = 'receipt') AND
          has_column_privilege(current_user, 'public.' || t, c.column_name, 'UPDATE') THEN
        RAISE EXCEPTION 'Unexpected runtime UPDATE privilege';
      END IF;
    END LOOP;
  END LOOP;
  IF (SELECT count(*) FROM pg_catalog.pg_policy pol JOIN pg_catalog.pg_class pc ON pc.oid = pol.polrelid
      JOIN pg_catalog.pg_namespace pn ON pn.oid = pc.relnamespace WHERE pn.nspname = 'public'
      AND pc.relname IN ('ventio_records','ventio_command_journal','ventio_audit_entries','ventio_outbox')) <> 9 THEN
    RAISE EXCEPTION 'Unexpected row security policy set';
  END IF;
END $fn$;
