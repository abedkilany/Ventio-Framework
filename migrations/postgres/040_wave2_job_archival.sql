DO $migration$
BEGIN
 ALTER TABLE public.ventio_wave2_jobs ADD COLUMN archived_at timestamptz;
 ALTER TABLE public.ventio_wave2_jobs ADD COLUMN total_count integer;
 UPDATE public.ventio_wave2_jobs SET total_count=jsonb_array_length(commands);
 ALTER TABLE public.ventio_wave2_jobs ALTER COLUMN total_count SET NOT NULL;
 ALTER TABLE public.ventio_wave2_jobs ADD CHECK(total_count BETWEEN 1 AND 25);
 CREATE INDEX ventio_wave2_job_archival ON public.ventio_wave2_jobs(updated_at) WHERE archived_at IS NULL AND state IN ('SUCCEEDED','COMPLETED_WITH_ERRORS','FAILED','CANCELLED');
 CREATE INDEX ventio_wave2_activity_chronology ON public.ventio_wave2_events
  (tenant_id,company_id,branch_id,subject_id,(detail->>'moduleId'),(detail->>'docType'),created_at DESC,event_id DESC)
  WHERE event_type='RECORD_ACTIVITY';
END $migration$;
