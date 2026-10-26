DO $migration$
BEGIN
  ALTER TABLE public.ventio_command_journal
    ADD COLUMN scope_cursor bigint;

  IF EXISTS (
    SELECT FROM public.ventio_command_journal
    WHERE receipt ? 'scopeCursor'
      AND NOT coalesce(
        receipt->>'scopeCursor' ~ '^scope-v1-[1-9][0-9]{0,18}$',
        false
      )
  ) THEN
    RAISE EXCEPTION 'Invalid stored scope cursor prevents safe migration';
  END IF;

  UPDATE public.ventio_command_journal
  SET scope_cursor = substring(receipt->>'scopeCursor'
    FROM '^scope-v1-([1-9][0-9]{0,18})$')::bigint
  WHERE receipt ? 'scopeCursor';

  ALTER TABLE public.ventio_command_journal
    ADD CONSTRAINT command_journal_scope_cursor_receipt
    CHECK (
      (scope_cursor IS NULL AND NOT (receipt ? 'scopeCursor')) OR
      (scope_cursor IS NOT NULL AND scope_cursor > 0 AND
       receipt->>'scopeCursor' IS NOT NULL AND
       receipt->>'scopeCursor' = 'scope-v1-' || scope_cursor::text)
    );

  CREATE UNIQUE INDEX command_journal_scope_cursor
    ON public.ventio_command_journal
      (tenant_id, company_id, branch_id, scope_cursor DESC)
    WHERE scope_cursor IS NOT NULL;
END
$migration$
