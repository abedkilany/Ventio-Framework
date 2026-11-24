DO $migration$
BEGIN
 ALTER TABLE public.ventio_wave2_operations ADD COLUMN credential_digest text;
 ALTER TABLE public.ventio_wave2_operations ADD COLUMN offer_id text;
 ALTER TABLE public.ventio_wave2_operations ADD COLUMN offer_until timestamptz;
 ALTER TABLE public.ventio_wave2_operations ADD COLUMN scheduled_for date;
 ALTER TABLE public.ventio_wave2_operations ADD COLUMN policy_operation_id text;
 ALTER TABLE public.ventio_wave2_operations ADD COLUMN attempt integer NOT NULL DEFAULT 1 CHECK(attempt BETWEEN 1 AND 5);
 CREATE INDEX ventio_wave2_operation_schedule ON public.ventio_wave2_operations(policy_operation_id,scheduled_for,attempt);
END $migration$;
