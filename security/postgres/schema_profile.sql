-- Approved migration manifest. Regenerate when adding a reviewed migration.
CREATE OR REPLACE FUNCTION ventio_security.assert_schema()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
BEGIN
  IF EXISTS (
    WITH expected(name,sha256) AS (VALUES
    ('001_records.sql','fe4cc335ef529378e89b1ba14ca31b17906147442cda6c34abd3d46fd08f90d1'),
    ('002_command_journal.sql','dd0204676b0ec9fee55ce11f48de6fe919ce5a0731b28b9be0bc09076f5aa019'),
    ('003_audit.sql','8175e7d962ac8dd9b3be4d57ca5fbb9db786ba7d7849f4b5f9233ab885f69ff5'),
    ('004_outbox.sql','6d4f775f15c43504e7d9ed622fcfe52686a7bea9a93c51bb6a797b5ef33ec390'),
    ('005_outbox_index.sql','bc98448c06687b1c5dfaf8ec74319b1e46f88681187ef2c526daaa4c67fe2f3b'),
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
