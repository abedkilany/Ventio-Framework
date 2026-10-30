-- Included by bootstrap as the non-login owner. No external witness is in dumps.
CREATE TABLE IF NOT EXISTS ventio_security.recovery_state (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  enforced boolean NOT NULL DEFAULT false,
  authority_id text NOT NULL DEFAULT 'unconfigured',
  generation bigint NOT NULL DEFAULT 0 CHECK (generation >= 0)
);
ALTER TABLE ventio_security.recovery_state
  ADD COLUMN IF NOT EXISTS generation bigint NOT NULL DEFAULT 0;
INSERT INTO ventio_security.recovery_state(singleton) VALUES(true) ON CONFLICT DO NOTHING;
ALTER TABLE ventio_security.recovery_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE ventio_security.recovery_state FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS owner_access ON ventio_security.recovery_state;
CREATE POLICY owner_access ON ventio_security.recovery_state TO ventio_owner USING(true) WITH CHECK(true);

CREATE OR REPLACE FUNCTION ventio_security.recovery_fingerprint()
RETURNS text LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp
SET TimeZone = 'UTC' AS $fn$
  SELECT encode(sha256(convert_to(jsonb_build_array(
    (SELECT to_jsonb(s) FROM ventio_security.recovery_state s),
    (SELECT jsonb_agg(jsonb_build_array(name,sha256) ORDER BY name)
      FROM public.ventio_schema_migrations)
  )::text, 'UTF8')), 'hex')
$fn$;

CREATE OR REPLACE FUNCTION ventio_security.recovery_snapshot()
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
BEGIN
  PERFORM pg_advisory_xact_lock_shared(86744321);
  RETURN ventio_security.recovery_fingerprint();
END $fn$;

-- Remove the legacy fingerprint-only admission function. Bootstrap reapplies
-- the narrow function ACL after installing the current recovery functions.
DROP FUNCTION IF EXISTS ventio_security.admit_recovery(text);

CREATE OR REPLACE FUNCTION ventio_security.admit_recovery(
    p_fingerprint text, p_authority_id text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE state ventio_security.recovery_state%ROWTYPE; proof text;
BEGIN
  PERFORM pg_advisory_xact_lock_shared(86744321);
  SELECT * INTO state FROM ventio_security.recovery_state WHERE singleton;
  IF state.enforced IS DISTINCT FROM true OR
      p_fingerprint IS NULL OR p_fingerprint !~ '^[0-9a-f]{64}$' OR
      p_authority_id IS NULL OR p_authority_id !~ '^[A-Za-z0-9_-]{43}$' OR
      p_authority_id IS DISTINCT FROM state.authority_id OR
      p_fingerprint IS DISTINCT FROM ventio_security.recovery_fingerprint() THEN
    RAISE EXCEPTION 'Recovery admission denied' USING ERRCODE='28000';
  END IF;
  proof := encode(ventio_crypto.hmac(
    convert_to(jsonb_build_array(current_database(), pg_backend_pid(),
      txid_current(), p_fingerprint)::text, 'UTF8'),
    convert_to(p_authority_id, 'UTF8'), 'sha256'), 'hex');
  PERFORM set_config('ventio.recovery_fingerprint', p_fingerprint, true);
  PERFORM set_config('ventio.recovery_proof', proof, true);
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.recovery_guard()
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE state ventio_security.recovery_state%ROWTYPE;
        fingerprint text; proof text; expected text;
BEGIN
  PERFORM pg_advisory_xact_lock_shared(86744321);
  SELECT * INTO state FROM ventio_security.recovery_state WHERE singleton;
  IF NOT state.enforced THEN
    -- Unconfigured databases support isolated historical fixtures only. The
    -- production launcher always calls admit_recovery and rejects this state.
    RETURN true;
  END IF;
  fingerprint := nullif(current_setting('ventio.recovery_fingerprint',true),'');
  proof := nullif(current_setting('ventio.recovery_proof',true),'');
  IF fingerprint IS NULL OR fingerprint !~ '^[0-9a-f]{64}$' OR
      proof IS NULL OR proof !~ '^[0-9a-f]{64}$' THEN
    RETURN false;
  END IF;
  expected := encode(ventio_crypto.hmac(
    convert_to(jsonb_build_array(current_database(), pg_backend_pid(),
      txid_current(), fingerprint)::text, 'UTF8'),
    convert_to(state.authority_id, 'UTF8'), 'sha256'), 'hex');
  RETURN proof = expected;
END $fn$;

-- Changes to authority-bearing rows serialize with admitted work, then advance
-- one protected generation per statement. Runtime callers cannot write these
-- tables; direct privileged writes still invalidate the independent witness.
CREATE OR REPLACE FUNCTION ventio_security.lock_recovery_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
BEGIN
  PERFORM pg_advisory_xact_lock(86744321);
  RETURN NULL;
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.mark_recovery_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
BEGIN
  UPDATE ventio_security.recovery_state
    SET generation=generation+1
    WHERE singleton AND enforced;
  RETURN NULL;
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.protect_recovery_state_row()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
BEGIN
  PERFORM pg_advisory_xact_lock(86744321);
  IF TG_OP='UPDATE' THEN
    NEW.generation := OLD.generation + 1;
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Recovery state rows cannot be deleted' USING ERRCODE='55000';
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.reject_recovery_state_truncate()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
BEGIN
  PERFORM pg_advisory_xact_lock(86744321);
  RAISE EXCEPTION 'Recovery state cannot be truncated' USING ERRCODE='55000';
END $fn$;

DROP TRIGGER IF EXISTS ventio_recovery_state_row ON ventio_security.recovery_state;
CREATE TRIGGER ventio_recovery_state_row
  BEFORE UPDATE OR DELETE ON ventio_security.recovery_state
  FOR EACH ROW EXECUTE FUNCTION ventio_security.protect_recovery_state_row();
DROP TRIGGER IF EXISTS ventio_recovery_state_truncate ON ventio_security.recovery_state;
CREATE TRIGGER ventio_recovery_state_truncate
  BEFORE TRUNCATE ON ventio_security.recovery_state
  FOR EACH STATEMENT EXECUTE FUNCTION ventio_security.reject_recovery_state_truncate();

CREATE OR REPLACE FUNCTION ventio_security.guard_extension_registry_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE protected_change boolean := false;
BEGIN
  IF TG_OP='INSERT' THEN
    protected_change := NEW.status IN ('APPROVED','REVOKED');
  ELSIF TG_OP='UPDATE' THEN
    protected_change := OLD.status IN ('APPROVED','REVOKED') OR
      NEW.status IN ('APPROVED','REVOKED');
  ELSIF TG_OP='DELETE' THEN
    protected_change := OLD.status IN ('APPROVED','REVOKED');
  END IF;
  IF protected_change THEN
    PERFORM pg_advisory_xact_lock(86744321);
    UPDATE ventio_security.recovery_state
      SET generation=generation+1
      WHERE singleton AND enforced;
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.guard_extension_event_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE event_name text;
BEGIN
  event_name := CASE WHEN TG_OP='DELETE' THEN OLD.event_type ELSE NEW.event_type END;
  IF event_name IN ('APPROVED','REVOKED') THEN
    PERFORM pg_advisory_xact_lock(86744321);
    UPDATE ventio_security.recovery_state
      SET generation=generation+1
      WHERE singleton AND enforced;
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $fn$;

-- Device-authentication telemetry is intentionally excluded: it is not an
-- authorization input and must not advance Recovery Authority generations.
DO $recovery_triggers$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'ventio_identity_users','ventio_identity_devices',
    'ventio_identity_credentials','ventio_identity_branches',
    'ventio_identity_grants','ventio_identity_roles',
    'ventio_identity_role_permissions','ventio_identity_role_assignments',
    'ventio_identity_audit','ventio_identity_pairings',
    'ventio_schema_migrations'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS ventio_recovery_lock ON public.%I', t);
    EXECUTE format('CREATE TRIGGER ventio_recovery_lock '
      'BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON public.%I '
      'FOR EACH STATEMENT EXECUTE FUNCTION ventio_security.lock_recovery_mutation()', t);
    EXECUTE format('DROP TRIGGER IF EXISTS ventio_recovery_mark ON public.%I', t);
    EXECUTE format('CREATE TRIGGER ventio_recovery_mark '
      'AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON public.%I '
      'FOR EACH STATEMENT EXECUTE FUNCTION ventio_security.mark_recovery_mutation()', t);
  END LOOP;

  DROP TRIGGER IF EXISTS ventio_recovery_extension_registry ON public.ventio_extension_packages;
  CREATE TRIGGER ventio_recovery_extension_registry
    BEFORE INSERT OR UPDATE OR DELETE ON public.ventio_extension_packages
    FOR EACH ROW EXECUTE FUNCTION ventio_security.guard_extension_registry_mutation();
  DROP TRIGGER IF EXISTS ventio_recovery_extension_registry_truncate ON public.ventio_extension_packages;
  CREATE TRIGGER ventio_recovery_extension_registry_truncate
    BEFORE TRUNCATE ON public.ventio_extension_packages
    FOR EACH STATEMENT EXECUTE FUNCTION ventio_security.lock_recovery_mutation();
  DROP TRIGGER IF EXISTS ventio_recovery_extension_registry_truncate_mark ON public.ventio_extension_packages;
  CREATE TRIGGER ventio_recovery_extension_registry_truncate_mark
    AFTER TRUNCATE ON public.ventio_extension_packages
    FOR EACH STATEMENT EXECUTE FUNCTION ventio_security.mark_recovery_mutation();

  DROP TRIGGER IF EXISTS ventio_recovery_extension_events ON public.ventio_extension_package_events;
  CREATE TRIGGER ventio_recovery_extension_events
    BEFORE INSERT OR UPDATE OR DELETE ON public.ventio_extension_package_events
    FOR EACH ROW EXECUTE FUNCTION ventio_security.guard_extension_event_mutation();
  DROP TRIGGER IF EXISTS ventio_recovery_extension_events_truncate ON public.ventio_extension_package_events;
  CREATE TRIGGER ventio_recovery_extension_events_truncate
    BEFORE TRUNCATE ON public.ventio_extension_package_events
    FOR EACH STATEMENT EXECUTE FUNCTION ventio_security.lock_recovery_mutation();
  DROP TRIGGER IF EXISTS ventio_recovery_extension_events_truncate_mark ON public.ventio_extension_package_events;
  CREATE TRIGGER ventio_recovery_extension_events_truncate_mark
    AFTER TRUNCATE ON public.ventio_extension_package_events
    FOR EACH STATEMENT EXECUTE FUNCTION ventio_security.mark_recovery_mutation();
END $recovery_triggers$;

CREATE OR REPLACE FUNCTION ventio_security.reset_recovery(p_authority text, p_label text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
BEGIN
  IF p_authority IS NULL OR p_authority !~ '^[A-Za-z0-9_-]{43}$' OR
      p_label IS NULL OR length(trim(p_label)) NOT BETWEEN 1 AND 256 THEN
    RAISE EXCEPTION 'Invalid recovery reset context';
  END IF;
  PERFORM pg_advisory_xact_lock(86744321);
  UPDATE public.ventio_identity_credentials SET revoked_at=coalesce(revoked_at,clock_timestamp());
  UPDATE public.ventio_identity_devices SET revoked_at=coalesce(revoked_at,clock_timestamp());
  DELETE FROM public.ventio_identity_grants;
  DELETE FROM public.ventio_identity_role_assignments;
  DELETE FROM public.ventio_identity_role_permissions;
  DELETE FROM public.ventio_identity_roles;
  UPDATE ventio_security.recovery_state SET enforced=true, authority_id=p_authority;
  INSERT INTO public.ventio_identity_audit(tenant_id,operator_label,action,subject_id,details)
    SELECT tenant_id,p_label,'RECOVERY_REENROLLMENT_REQUIRED',p_authority,'{}'::jsonb
    FROM public.ventio_identity_users GROUP BY tenant_id;
END $fn$;
