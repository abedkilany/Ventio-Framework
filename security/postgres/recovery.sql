-- Included by bootstrap as the non-login owner. No external witness is in dumps.
CREATE TABLE IF NOT EXISTS ventio_security.recovery_state (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  enforced boolean NOT NULL DEFAULT false,
  authority_id text NOT NULL DEFAULT 'unconfigured'
);
INSERT INTO ventio_security.recovery_state(singleton) VALUES(true) ON CONFLICT DO NOTHING;
ALTER TABLE ventio_security.recovery_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE ventio_security.recovery_state FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS owner_access ON ventio_security.recovery_state;
CREATE POLICY owner_access ON ventio_security.recovery_state TO ventio_owner USING(true) WITH CHECK(true);

CREATE OR REPLACE FUNCTION ventio_security.recovery_fingerprint()
RETURNS text LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
  SELECT encode(sha256(convert_to(jsonb_build_array(
    (SELECT to_jsonb(s) FROM ventio_security.recovery_state s),
    (SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text) FROM public.ventio_identity_users t),
    (SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text) FROM public.ventio_identity_devices t),
    (SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text) FROM public.ventio_identity_credentials t),
    (SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text) FROM public.ventio_identity_branches t),
    (SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text) FROM public.ventio_identity_grants t),
    (SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text) FROM public.ventio_identity_audit t)
  )::text, 'UTF8')), 'hex')
$fn$;

CREATE OR REPLACE FUNCTION ventio_security.recovery_snapshot()
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
BEGIN
  PERFORM pg_advisory_xact_lock_shared(86744321);
  RETURN ventio_security.recovery_fingerprint();
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.admit_recovery(p_fingerprint text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
BEGIN
  PERFORM pg_advisory_xact_lock_shared(86744321);
  IF NOT (SELECT enforced FROM ventio_security.recovery_state) OR
      p_fingerprint IS NULL OR p_fingerprint !~ '^[0-9a-f]{64}$' OR
      p_fingerprint IS DISTINCT FROM ventio_security.recovery_fingerprint() THEN
    RAISE EXCEPTION 'Recovery admission denied' USING ERRCODE='28000';
  END IF;
  PERFORM set_config('ventio.recovery_proof', p_fingerprint, true);
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.recovery_guard()
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
BEGIN
  PERFORM pg_advisory_xact_lock_shared(86744321);
  IF NOT (SELECT enforced FROM ventio_security.recovery_state) THEN
    -- Unconfigured databases support isolated historical fixtures only. The
    -- production launcher always calls admit_recovery and rejects this state.
    RETURN true;
  END IF;
  RETURN nullif(current_setting('ventio.recovery_proof',true),'') IS NOT NULL AND
    current_setting('ventio.recovery_proof',true) = ventio_security.recovery_fingerprint();
END $fn$;

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
  UPDATE ventio_security.recovery_state SET enforced=true, authority_id=p_authority;
  INSERT INTO public.ventio_identity_audit(tenant_id,operator_label,action,subject_id,details)
    SELECT tenant_id,p_label,'RECOVERY_REENROLLMENT_REQUIRED',p_authority,'{}'::jsonb
    FROM public.ventio_identity_users GROUP BY tenant_id;
END $fn$;
