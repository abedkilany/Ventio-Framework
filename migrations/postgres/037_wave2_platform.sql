DO $migration$
BEGIN
  CREATE TABLE IF NOT EXISTS public.ventio_wave2_definitions (
    tenant_id text NOT NULL, company_id text NOT NULL, branch_id text NOT NULL,
    owner_id text NOT NULL, kind text NOT NULL, definition_id text NOT NULL,
    revision bigint NOT NULL CHECK (revision > 0), body jsonb NOT NULL,
    updated_by text NOT NULL, updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id,company_id,branch_id,owner_id,kind,definition_id),
    CHECK (kind IN ('customization','saved_view','preferences','dashboard','configuration')),
    CHECK (jsonb_typeof(body)='object' AND octet_length(body::text)<=65536)
  );
  CREATE TABLE IF NOT EXISTS public.ventio_wave2_revisions (
    tenant_id text NOT NULL, company_id text NOT NULL, branch_id text NOT NULL,
    owner_id text NOT NULL, kind text NOT NULL, definition_id text NOT NULL,
    revision bigint NOT NULL, request_id text NOT NULL, request_hash text NOT NULL,
    body jsonb NOT NULL, saved_by text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id,company_id,branch_id,owner_id,kind,definition_id,revision),
    UNIQUE (tenant_id,company_id,branch_id,owner_id,request_id)
  );
  CREATE TABLE IF NOT EXISTS public.ventio_wave2_jobs (
    tenant_id text NOT NULL, company_id text NOT NULL, branch_id text NOT NULL,
    job_id text NOT NULL, actor_id text NOT NULL, device_id text NOT NULL,
    credential_digest text NOT NULL CHECK (credential_digest ~ '^[0-9a-f]{64}$'),
    request_hash text NOT NULL, commands jsonb NOT NULL,
    state text NOT NULL DEFAULT 'QUEUED', next_index integer NOT NULL DEFAULT 0,
    attempts integer NOT NULL DEFAULT 0, outcomes jsonb NOT NULL DEFAULT '[]',
    lease_id text, lease_until timestamptz, available_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(), updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_id,job_id),
    CHECK (state IN ('QUEUED','RUNNING','RETRY_WAIT','SUCCEEDED','COMPLETED_WITH_ERRORS','FAILED','CANCELLED')),
    CHECK (jsonb_typeof(commands)='array' AND jsonb_array_length(commands) BETWEEN 1 AND 25),
    CHECK (next_index BETWEEN 0 AND 25 AND attempts BETWEEN 0 AND 5),
    CHECK (octet_length(commands::text)<=65536)
  );
  CREATE INDEX IF NOT EXISTS ventio_wave2_job_claim
    ON public.ventio_wave2_jobs(available_at,created_at)
    WHERE state IN ('QUEUED','RETRY_WAIT','RUNNING');
  CREATE TABLE IF NOT EXISTS public.ventio_wave2_events (
    event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id text NOT NULL, company_id text NOT NULL, branch_id text NOT NULL,
    actor_id text NOT NULL, event_type text NOT NULL, subject_id text NOT NULL,
    detail jsonb NOT NULL DEFAULT '{}', created_at timestamptz NOT NULL DEFAULT clock_timestamp()
  );
  -- Protect immediately, including the interval before security bootstrap.
  ALTER TABLE public.ventio_wave2_definitions ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_definitions FORCE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_revisions ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_revisions FORCE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_jobs ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_jobs FORCE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_events ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_events FORCE ROW LEVEL SECURITY;
  REVOKE ALL ON public.ventio_wave2_definitions, public.ventio_wave2_revisions,
    public.ventio_wave2_jobs, public.ventio_wave2_events FROM PUBLIC;
END $migration$;
