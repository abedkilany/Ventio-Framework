DO $migration$
BEGIN
  CREATE TABLE public.ventio_wave2_organizations (
    tenant_id text PRIMARY KEY, display_name text NOT NULL,
    revision bigint NOT NULL DEFAULT 1, archived boolean NOT NULL DEFAULT false);
  CREATE TABLE public.ventio_wave2_companies (
    tenant_id text NOT NULL REFERENCES public.ventio_wave2_organizations(tenant_id),
    company_id text NOT NULL, display_name text NOT NULL,
    revision bigint NOT NULL DEFAULT 1, archived boolean NOT NULL DEFAULT false,
    PRIMARY KEY(tenant_id,company_id));
  CREATE TABLE public.ventio_wave2_branches (
    tenant_id text NOT NULL, company_id text NOT NULL, branch_id text NOT NULL,
    display_name text NOT NULL, revision bigint NOT NULL DEFAULT 1,
    archived boolean NOT NULL DEFAULT false, PRIMARY KEY(tenant_id,company_id,branch_id),
    FOREIGN KEY(tenant_id,company_id) REFERENCES public.ventio_wave2_companies(tenant_id,company_id));
  CREATE TABLE public.ventio_wave2_admin_requests (
    tenant_id text NOT NULL, actor_id text NOT NULL, request_id text NOT NULL,
    request_hash text NOT NULL, result jsonb NOT NULL,
    PRIMARY KEY(tenant_id,actor_id,request_id));
  CREATE TABLE public.ventio_wave2_operations (
    operation_id text PRIMARY KEY, tenant_id text NOT NULL, company_id text NOT NULL,
    branch_id text NOT NULL, actor_id text NOT NULL, operation text NOT NULL,
    request_hash text NOT NULL, body jsonb NOT NULL, result jsonb,
    state text NOT NULL DEFAULT 'AWAITING_LOCAL_APPROVAL',
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK(operation IN ('BACKUP_NOW','APPLY_POLICY','RESTORE_PLAN','RESTORE')),
    CHECK(state IN ('AWAITING_LOCAL_APPROVAL','RUNNING','SUCCEEDED','FAILED','EXPIRED')));
  CREATE TABLE public.ventio_wave2_customization_rebases (
    tenant_id text NOT NULL, company_id text NOT NULL, branch_id text NOT NULL,
    module_id text NOT NULL, target_version text NOT NULL, doc_type text NOT NULL,
    source_version text NOT NULL, source_revision bigint NOT NULL,
    source_sha256 text NOT NULL, target_sha256 text NOT NULL, body jsonb NOT NULL,
    prepared_by text NOT NULL, credential_digest text NOT NULL, prepared_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY(tenant_id,company_id,branch_id,module_id,target_version,doc_type));
  ALTER TABLE public.ventio_wave2_jobs ADD COLUMN source_rows jsonb NOT NULL DEFAULT '[]';
  ALTER TABLE public.ventio_wave2_jobs ADD COLUMN import_id text;
  ALTER TABLE public.ventio_wave2_definitions DROP CONSTRAINT ventio_wave2_definitions_kind_check;
  ALTER TABLE public.ventio_wave2_definitions ADD CONSTRAINT ventio_wave2_definitions_kind_check
    CHECK(kind IN ('customization','saved_view','preferences','dashboard','configuration','backup_policy'));
  -- Backfill the legacy identifiers, without changing a grant or credential.
  INSERT INTO public.ventio_wave2_organizations(tenant_id,display_name)
    SELECT DISTINCT tenant_id,tenant_id FROM public.ventio_identity_branches;
  INSERT INTO public.ventio_wave2_companies(tenant_id,company_id,display_name)
    SELECT DISTINCT tenant_id,company_id,company_id FROM public.ventio_identity_branches;
  INSERT INTO public.ventio_wave2_branches(tenant_id,company_id,branch_id,display_name)
    SELECT tenant_id,company_id,branch_id,branch_id FROM public.ventio_identity_branches;
  CREATE UNIQUE INDEX ventio_wave2_activity_identity ON public.ventio_wave2_events(tenant_id,company_id,branch_id,subject_id,(detail->>'moduleId'),(detail->>'docType'),(detail->>'commandId')) WHERE event_type='RECORD_ACTIVITY';
  CREATE INDEX ventio_wave2_activity_page ON public.ventio_wave2_events
    (tenant_id,company_id,branch_id,subject_id,event_id DESC);
  CREATE INDEX ventio_wave2_operation_scope ON public.ventio_wave2_operations
    (tenant_id,company_id,branch_id,created_at DESC);
  ALTER TABLE public.ventio_wave2_organizations ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_organizations FORCE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_companies ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_companies FORCE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_branches ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_branches FORCE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_admin_requests ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_admin_requests FORCE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_operations ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_operations FORCE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_customization_rebases ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.ventio_wave2_customization_rebases FORCE ROW LEVEL SECURITY;
  REVOKE ALL ON public.ventio_wave2_organizations,public.ventio_wave2_companies,
    public.ventio_wave2_branches,public.ventio_wave2_admin_requests,
    public.ventio_wave2_operations,public.ventio_wave2_customization_rebases FROM PUBLIC;
END $migration$;
