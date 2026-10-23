-- Approved migration manifest. Regenerate when adding a reviewed migration.
CREATE OR REPLACE FUNCTION ventio_security.assert_schema()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
BEGIN
  IF EXISTS (
    WITH expected(name,sha256) AS (VALUES
    ('001_records.sql','736d63fd6f013cac931a123064dd8e7a391609132175a15853bd6acca8a00d2b'),
    ('002_command_journal.sql','8888d684aa63ab10c8bc9874aca6b402be4b4099c3774115309fa85f4983210a'),
    ('003_audit.sql','b1565095ec74e58b0a42591bd1ed0b5b50b84bf922871a5fb8500755274009ad'),
    ('004_outbox.sql','718e8fb1171512d46e3445625352e15594ddcd351a8b7b5f8d57ba6bf4f8784f'),
    ('005_outbox_index.sql','33a3e6db19db32504a7ab312ec8286bc3c03e11a5dc42ea35d67281854bb154a'),
    ('006_identity_users.sql','69a4e68bde95a61d5acdba9fdcc6ece38736081e9538d8b45d23292ffaa68563'),
    ('007_identity_devices.sql','0ab66284bdec5a9d3f6abbe61807c81faa8e2141598c6d9d0d9fb709f73da876'),
    ('008_identity_credentials.sql','1466d2718e759fe30d1c5c3d62f9f69a3b9f4848450600dee24aadffb0fff801'),
    ('009_identity_branches.sql','bbeab3db3acfc185b109219cfe520b3b561d36e15355aa041ba1b0647a06e1af'),
    ('010_identity_grants.sql','cb6c1204a66c63291aae46f339d8023a2bf00d0f459241e5bd3a09e9f65f714c'),
    ('011_identity_audit.sql','07729fcf2d65b0fc2a8489ec797239d88a0d3c70a74969d709e4480eb41cfe5a'),
    ('012_credential_scopes.sql','9f1bd3caa7689b1bfce9bfbb927012cfc69ca8449b4c8d53d77370ccfa5ffa3f'))
    SELECT FROM expected e FULL JOIN public.ventio_schema_migrations m USING(name)
    WHERE e.sha256 IS DISTINCT FROM m.sha256
  ) THEN
    RAISE EXCEPTION 'Unsupported Host schema manifest' USING ERRCODE='55000';
  END IF;
END $fn$;
