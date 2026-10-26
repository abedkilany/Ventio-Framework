DO $migration$
BEGIN
  ALTER TABLE public.ventio_records
    ADD COLUMN module_id text NOT NULL DEFAULT 'legacy'
    CHECK (module_id ~ '^[a-z][a-z0-9]*([._-][a-z0-9]+)*$');

  ALTER TABLE public.ventio_records NO FORCE ROW LEVEL SECURITY;
  UPDATE public.ventio_records SET module_id='com.ventio.maintenance'
    WHERE doc_type='MaintenanceRequest';
  UPDATE public.ventio_records SET module_id='com.ventio.inspection'
    WHERE doc_type='EquipmentInspection';
  ALTER TABLE public.ventio_records FORCE ROW LEVEL SECURITY;

  ALTER TABLE public.ventio_records
    DROP CONSTRAINT ventio_records_pkey;

  ALTER TABLE public.ventio_records
    ADD CONSTRAINT ventio_records_pkey
    PRIMARY KEY (tenant_id, company_id, branch_id, module_id, doc_type, record_id);
END
$migration$
