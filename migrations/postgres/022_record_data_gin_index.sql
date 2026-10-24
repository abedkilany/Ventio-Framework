CREATE INDEX IF NOT EXISTS ventio_records_record_data_gin_idx
  ON public.ventio_records USING gin (record_data jsonb_path_ops);
