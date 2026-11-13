-- Approved migration manifest. Regenerate when adding a reviewed migration.
ALTER TABLE public.host_schema_upgrade_receipts
  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.host_schema_upgrade_receipts
  FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS owner_access ON public.host_schema_upgrade_receipts;
CREATE POLICY owner_access ON public.host_schema_upgrade_receipts
  TO ventio_owner USING (true) WITH CHECK (true);
REVOKE ALL ON public.host_schema_upgrade_receipts
  FROM PUBLIC, ventio_runtime, ventio_identity_admin, ventio_identity_api;

CREATE OR REPLACE FUNCTION ventio_security.assert_schema()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_catalog.pg_extension e
      JOIN pg_catalog.pg_namespace n ON n.oid=e.extnamespace
      JOIN pg_catalog.pg_roles r ON r.oid=e.extowner
    WHERE e.extname='pgcrypto' AND n.nspname='ventio_crypto'
      AND r.rolname='ventio_owner'
      AND pg_catalog.to_regprocedure('ventio_crypto.hmac(bytea,bytea,text)') IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Unsupported private recovery proof profile' USING ERRCODE='55000';
  END IF;
  IF has_schema_privilege('ventio_runtime','ventio_crypto','USAGE') OR
      has_schema_privilege('ventio_identity_admin','ventio_crypto','USAGE') THEN
    RAISE EXCEPTION 'Recovery HMAC schema is exposed to an operational role' USING ERRCODE='55000';
  END IF;
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
    ('012_credential_scopes.sql','9f1bd3caa7689b1bfce9bfbb927012cfc69ca8449b4c8d53d77370ccfa5ffa3f'),
    ('013_extension_packages.sql','022108cf3b76cdd76ca30e73fefa179e63f1184e3f1d6275ce41a11ab34ace62'),
    ('014_extension_package_events.sql','825151c5e2da7bc8627a46e09cfe9e3cde72d93048990ee7e699363c423c5b04'),
    ('015_scope_cursor_index.sql','538b674ee6c3d95b2a91ccc7d64c1410dc68bd56a2c635ade9dcf5a40fd339a9'),
    ('016_module_scoped_records.sql','2b8647c77d86302de77de972f24ed764ebd50893254edb8d2f725968bf508467'),
    ('017_identity_roles.sql','b76d8cd46b430341682a294321e9f89903a2b7a846df7b51c331022797b40171'),
    ('018_identity_role_permissions.sql','2c118263c8787f6173a59130cec890d5d75a6266515caecb83f8e4ee0d655192'),
    ('019_identity_role_assignments.sql','011c2e61e247513113391354da08c7dfced6fc7c6fc37886381fe4eb450dc767'),
    ('020_approved_extension_registry.sql','1912702210d1b699acd1672a0c61bae03384c1aabbf6d861b162faf7616c3ace'),
    ('021_extension_update_compatibility.sql','2044a1974db26f0cb61b24b248249d04689bf767ab55377389dff51902324a9e'),
    ('022_record_data_gin_index.sql','adf1f0791da08c757552d9eb2b306e0e6c15f0c363c08c265434234dec944872'),
    ('023_governed_document_state.sql','8c130e7c9071f3a862be3331dad96a3823c3688164419bc9bd9502575ce60e89'),
    ('024_document_number_series.sql','3b07f8e0638e0148bf24500eb026a3ad10f80be0bd576217205a3a2fb965f26a'),
    ('025_identity_audit_scope_index.sql','6462163d7a01ee0abadb1ffad8ac340c468c6b91cc9a403044fe8dc715357bb5'),
    ('026_identity_pairing.sql','2f2a71d5086622d4f7fad971e1f7c3404d05e8e5705cc48e418b6c3f34eaa7df'),
    ('027_identity_pairings.sql','568eb70d6cb2e961da4d4e12e9e6b29764aebda5f1ac7e3acf574a79e677f046'),
    ('028_identity_pairing_rate_index.sql','42b3a71d92420deb65be566c67d1b8d04d8ed47bfd55b20d0cb0928183eb7ace'),
    ('029_identity_device_activity.sql','f5b1160fa5120c46d095bde4c45ce23460dea9960177f5eafe7a4f5e0423a63b'),
    ('030_identity_user_enable.sql','9260ac0d93b708479b5602238d1a5573bad0030036cce2cc71797e6c4570df53'),
    ('031_identity_credential_reissues.sql','29435344e0d7525d6904452e4eb1658cb395946aa26d8596e71a7c1005fc354b'),
    ('032_identity_credential_reissue_pending.sql','4c5964e34287764cfd29cd747342a4abd88d2518490840164de207720031769d'),
    ('033_host_schema_upgrade_receipts.sql','b0059094eaa85547205b6e65f565733190cf0c061f9766fbd6d1f7158b4c1255'),
    ('034_extension_package_rejection.sql','6f835b3d8f2231435f2b39daea9512a23023a7eceb9edfc7f52d8a3007fa4595'),
    ('035_scoped_extension_approval.sql','b3c3ff19de81b8b24b3f6987863dfc96ffe6210a3e632d973940762d37e0d514'),
    ('036_scoped_extension_runtime.sql','50147943077d691d9ac9685eb34efaf062c2022fe88a652de2cd480211fa5244'),
    ('037_wave2_platform.sql','f06236bcd2bc9a9e1fa69bc8d11ccf78a6a0c65283d894508227393f347c15c3')),
    legacy(name,sha256) AS (VALUES
      ('026_identity_pairing.sql','af5f7a72fd9affc38c1ead156ca607dd89308998035985fa0259ae4e2cf39421'),
      ('027_identity_pairings.sql','a7ef70e7f6ea623e39dd668b5506bc5a1ddd641a0fee8d99aba2f9273541c9c6'),
      ('028_identity_pairing_rate_index.sql','6c975a92942a3e53abe50da9441f94b9fb7b68f2bda5932792c610814dcd6f68'))
    SELECT FROM expected e FULL JOIN public.ventio_schema_migrations m USING(name)
    WHERE e.sha256 IS DISTINCT FROM m.sha256 AND NOT EXISTS (
      SELECT FROM legacy l WHERE l.name=m.name AND l.sha256=m.sha256)
  ) THEN
    RAISE EXCEPTION 'Unsupported Host schema manifest' USING ERRCODE='55000';
  END IF;
END $fn$;
