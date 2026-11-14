-- Reapplied by the existing service-identity schema-upgrade bridge. This is a
-- vetted payload contract, never a client-provided SQL path.
BEGIN;
DO $protection$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY['ventio_wave2_organizations','ventio_wave2_companies','ventio_wave2_branches','ventio_wave2_admin_requests','ventio_wave2_operations','ventio_wave2_customization_rebases','ventio_wave2_definitions','ventio_wave2_revisions','ventio_wave2_jobs','ventio_wave2_events'] LOOP
    EXECUTE format('ALTER TABLE public.%I OWNER TO ventio_owner',table_name);
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',table_name);
    EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY',table_name);
    EXECUTE format('DROP POLICY IF EXISTS owner_access ON public.%I',table_name);
    EXECUTE format('CREATE POLICY owner_access ON public.%I TO ventio_owner USING(true) WITH CHECK(true)',table_name);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,ventio_runtime,ventio_identity_admin,ventio_identity_api',table_name);
  END LOOP;
END $protection$;
\ir wave2.sql
\ir wave2_identity_base.sql
\ir wave2_administration.sql
\ir wave2_customization_rebase.sql
\ir wave2_activity.sql
\ir wave2_schema_migration.sql
\ir extensions.sql
\ir runtime_check.sql
REVOKE ALL ON FUNCTION
  ventio_security.wave2_capture_record_activity(),
  ventio_security.wave2_seed_record_history(),
  ventio_security.wave2_rebase_body(jsonb,jsonb,text),
  ventio_security.wave2_settings(text,text,text),
  ventio_security.wave2_identity_snapshot_base(text,text,text),
  ventio_security.wave2_scope_active(text,text,text),
  ventio_security.wave2_register_scope(),
  ventio_security.wave2_tenant_manager(jsonb),
  ventio_security.wave2_rebase_candidate(text,text,text,text,text,text,text),
  ventio_security.wave2_settings_for_scope(text,text,text),
  ventio_security.wave2_command_admission(text,text,text,boolean),
  ventio_security.wave2_organization_snapshot(text,text,text),
  ventio_security.wave2_prepare_rebase(text,text,text,text,text,text,text,bigint,jsonb),
  ventio_security.wave2_organization_change(text,text,text,jsonb),
  ventio_security.wave2_allowed(jsonb,text,text,text),
  ventio_security.wave2_effective_package(text,text,text,jsonb,text),
  ventio_security.wave2_definitions(text,text,text,text),
  ventio_security.wave2_save_definition(text,text,text,text,text,bigint,text,jsonb),
  ventio_security.wave2_submit_job(text,text,text,text,jsonb,text,jsonb),
  ventio_security.wave2_submit_job(text,text,text,text,jsonb),
  ventio_security.wave2_jobs_list(text,text,text),
  ventio_security.wave2_cancel_job(text,text,text,text),
  ventio_security.wave2_claim_job(),
  ventio_security.wave2_finish_job(text,text,text,jsonb,boolean),
  ventio_security.wave2_record_activity(text,text,text,text,text,text,text,text,bigint,text),
  ventio_security.wave2_history(text,text,text,text,text,text,text,bigint,integer),
  ventio_security.wave2_history(text,text,text,text,text,text,text),
  ventio_security.wave2_guard_customization_upgrade()
  FROM PUBLIC,ventio_runtime,ventio_identity_admin,ventio_identity_api;
GRANT EXECUTE ON FUNCTION
  ventio_security.resolve_extension_identity(text,text,text,text,integer,text,text,text,text,text,text,bigint,jsonb),
  ventio_security.wave2_rebase_candidate(text,text,text,text,text,text,text),
  ventio_security.wave2_settings_for_scope(text,text,text),
  ventio_security.wave2_command_admission(text,text,text,boolean),
  ventio_security.wave2_organization_snapshot(text,text,text),
  ventio_security.wave2_definitions(text,text,text,text),
  ventio_security.wave2_submit_job(text,text,text,text,jsonb,text,jsonb),
  ventio_security.wave2_submit_job(text,text,text,text,jsonb),
  ventio_security.wave2_jobs_list(text,text,text),
  ventio_security.wave2_cancel_job(text,text,text,text),
  ventio_security.wave2_record_activity(text,text,text,text,text,text,text,text,bigint,text),
  ventio_security.wave2_history(text,text,text,text,text,text,text,bigint,integer),
  ventio_security.wave2_history(text,text,text,text,text,text,text)
  TO ventio_runtime;
GRANT EXECUTE ON FUNCTION
  ventio_security.wave2_prepare_rebase(text,text,text,text,text,text,text,bigint,jsonb),
  ventio_security.wave2_organization_change(text,text,text,jsonb),
  ventio_security.wave2_save_definition(text,text,text,text,text,bigint,text,jsonb),
  ventio_security.wave2_claim_job(),
  ventio_security.wave2_finish_job(text,text,text,jsonb,boolean)
  TO ventio_identity_api;
REVOKE ALL ON SEQUENCE public.ventio_wave2_events_event_id_seq
  FROM PUBLIC,ventio_runtime,ventio_identity_admin,ventio_identity_api;
COMMIT;
