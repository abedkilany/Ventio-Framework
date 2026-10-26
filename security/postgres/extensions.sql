-- Runtime package transfer is bounded metadata only. Approval and revocation
-- remain local operator actions protected by the independent recovery witness.
CREATE OR REPLACE FUNCTION ventio_security.submit_extension_package(
    p_digest text, p_tenant text, p_company text, p_branch text,
    p_module text, p_version text, p_sha256 text, p_package jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE identity jsonb; saved public.ventio_extension_packages%ROWTYPE;
BEGIN
  IF NOT ventio_security.recovery_guard() THEN RETURN NULL; END IF;
  IF p_package IS NULL OR jsonb_typeof(p_package) IS DISTINCT FROM 'object' OR
      octet_length(p_package::text) > 2097152 OR
      p_package #>> '{manifest,moduleId}' IS DISTINCT FROM p_module OR
      p_package #>> '{manifest,version}' IS DISTINCT FROM p_version OR
      p_sha256 IS NULL OR p_sha256 !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_PACKAGE');
  END IF;
  identity := ventio_security.identity_snapshot(p_digest, p_company, p_branch);
  IF identity IS NULL OR identity->>'tenantId' IS DISTINCT FROM p_tenant OR
      NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(identity->'scopeGrants') AS g(item)
        WHERE item->>'companyId'=p_company AND item->>'branchId'=p_branch
          AND item->>'permission'='extension.package.submit'
      ) THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED');
  END IF;
  INSERT INTO public.ventio_extension_packages
    (tenant_id,module_id,version,package_sha256,package_json,status,submitted_by,
     submitted_company_id,submitted_branch_id)
  VALUES (p_tenant,p_module,p_version,p_sha256,p_package,'SUBMITTED',
    identity->>'actorId',p_company,p_branch)
  ON CONFLICT (tenant_id,module_id,version) DO NOTHING;
  IF NOT FOUND THEN
    SELECT * INTO saved FROM public.ventio_extension_packages
      WHERE tenant_id=p_tenant AND module_id=p_module AND version=p_version;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status','REJECTED','reasonCode','PACKAGE_UNAVAILABLE');
    END IF;
    IF saved.package_sha256 IS DISTINCT FROM p_sha256 OR saved.package_json IS DISTINCT FROM p_package THEN
      RETURN jsonb_build_object('status','CONFLICT','reasonCode','PACKAGE_VERSION_EXISTS');
    END IF;
    IF saved.status='REVOKED' THEN
      RETURN jsonb_build_object('status','CONFLICT','reasonCode','PACKAGE_RELEASE_REVOKED');
    END IF;
    RETURN jsonb_build_object('status',saved.status,'moduleId',p_module,
      'version',p_version,'packageSha256',p_sha256);
  END IF;
  INSERT INTO public.ventio_extension_package_events
    (tenant_id,module_id,version,event_type,actor_id,company_id,branch_id,package_sha256)
  VALUES (p_tenant,p_module,p_version,'SUBMITTED',identity->>'actorId',
    p_company,p_branch,p_sha256);
  RETURN jsonb_build_object('status','SUBMITTED','moduleId',p_module,
    'version',p_version,'packageSha256',p_sha256);
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.read_approved_extension_package(
    p_digest text, p_tenant text, p_company text, p_branch text,
    p_module text, p_version text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE identity jsonb; package_row public.ventio_extension_packages%ROWTYPE;
BEGIN
  IF NOT ventio_security.recovery_guard() THEN RETURN NULL; END IF;
  identity := ventio_security.identity_snapshot(p_digest,p_company,p_branch);
  IF identity IS NULL OR identity->>'tenantId' IS DISTINCT FROM p_tenant OR
      NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(identity->'scopeGrants') AS g(item)
        WHERE item->>'companyId'=p_company AND item->>'branchId'=p_branch
          AND item->>'permission'='extension.package.read'
      ) THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED');
  END IF;
  SELECT * INTO package_row FROM public.ventio_extension_packages
    WHERE tenant_id=p_tenant AND module_id=p_module AND version=p_version
      AND status='APPROVED';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','PACKAGE_NOT_APPROVED');
  END IF;
  RETURN jsonb_build_object('status','APPROVED','moduleId',package_row.module_id,
    'version',package_row.version,'packageSha256',package_row.package_sha256,
    'package',package_row.package_json);
END $fn$;

-- The runtime can browse approved package summaries only within its current
-- authenticated tenant/company/branch scope. Package bodies remain behind the
-- exact-version read function above.
CREATE OR REPLACE FUNCTION ventio_security.list_approved_extension_packages(
    p_digest text, p_tenant text, p_company text, p_branch text,
    p_after_module text, p_after_version text, p_limit integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE identity jsonb; entries jsonb; has_more boolean;
BEGIN
  IF NOT ventio_security.recovery_guard() THEN RETURN NULL; END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 50 OR
      ((p_after_module IS NULL) <> (p_after_version IS NULL)) OR
      (p_after_module IS NOT NULL AND (
        p_after_module !~ '^[a-z][a-z0-9]*([._-][a-z0-9]+)*$' OR
        length(p_after_module) > 128 OR
        p_after_version !~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
      )) THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_PAGE');
  END IF;
  identity := ventio_security.identity_snapshot(p_digest,p_company,p_branch);
  IF identity IS NULL OR identity->>'tenantId' IS DISTINCT FROM p_tenant OR
      NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(identity->'scopeGrants') AS g(item)
        WHERE item->>'companyId'=p_company AND item->>'branchId'=p_branch
          AND item->>'permission'='extension.package.read'
      ) THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED');
  END IF;

  WITH page AS MATERIALIZED (
    SELECT module_id, version, package_sha256,
      coalesce(package_json #>> '{manifest,displayName}', module_id) AS display_name,
      package_json #>> '{manifest,description}' AS description
    FROM public.ventio_extension_packages
    WHERE tenant_id=p_tenant AND status='APPROVED'
      AND (p_after_module IS NULL OR (module_id,version)>(p_after_module,p_after_version))
    ORDER BY module_id,version
    LIMIT p_limit + 1
  ), ranked AS (
    SELECT *, row_number() OVER (ORDER BY module_id,version) AS position
    FROM page
  )
  SELECT count(*) > p_limit,
    coalesce(jsonb_agg(jsonb_build_object(
      'moduleId',module_id,'version',version,'packageSha256',package_sha256,
      'displayName',display_name,'description',description
    ) ORDER BY module_id,version) FILTER (WHERE position <= p_limit),'[]'::jsonb)
    INTO has_more,entries
  FROM ranked;
  RETURN jsonb_build_object('status','APPROVED','packages',entries,'hasMore',has_more);
END $fn$;

-- An approved package remains available as immutable release history, but only
-- the newest approved release may authorize live record operations. A newer
-- revoked release is a high-water mark too: older packages must not silently
-- become active again after revocation.
CREATE OR REPLACE FUNCTION ventio_security.extension_release_reason(
    p_tenant text, p_module text, p_version text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp AS $fn$
DECLARE newer_status text;
BEGIN
  SELECT newer.status INTO newer_status
  FROM public.ventio_extension_packages AS newer
  WHERE newer.tenant_id=p_tenant AND newer.module_id=p_module
    AND newer.status IN ('APPROVED','REVOKED')
    AND (split_part(newer.version,'.',1)::numeric,
         split_part(newer.version,'.',2)::numeric,
         split_part(newer.version,'.',3)::numeric) >
        (split_part(p_version,'.',1)::numeric,
         split_part(p_version,'.',2)::numeric,
         split_part(p_version,'.',3)::numeric)
  ORDER BY split_part(newer.version,'.',1)::numeric DESC,
           split_part(newer.version,'.',2)::numeric DESC,
           split_part(newer.version,'.',3)::numeric DESC
  LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF newer_status='REVOKED' THEN RETURN 'EXTENSION_REVOKED'; END IF;
  RETURN 'UPGRADE_REQUIRED';
END $fn$;

-- Bind a read-only record query to a live exact-scope identity and an approved
-- package. The returned metadata is later hash-checked by the Host process.
CREATE OR REPLACE FUNCTION ventio_security.resolve_extension_read_identity(
    p_digest text, p_company text, p_branch text, p_module text,
    p_module_version text, p_doc_type text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE identity jsonb; package_row public.ventio_extension_packages%ROWTYPE;
        doc_type jsonb; permission text; expected_type text;
        release_reason text;
BEGIN
  FOREACH expected_type IN ARRAY ARRAY[
      'ventio.credential_digest','ventio.company_id','ventio.branch_id',
      'ventio.command_type','ventio.command_version','ventio.command_id',
      'ventio.aggregate_id','ventio.module_id','ventio.module_version',
      'ventio.doc_type','ventio.operation','ventio.expected_revision',
      'ventio.extension_identity_snapshot','ventio.extension_policy_snapshot',
      'ventio.extension_context_proof'] LOOP
    PERFORM set_config(expected_type, '', true);
  END LOOP;
  IF p_module IS NULL OR p_module !~ '^[a-z][a-z0-9]*([._-][a-z0-9]+)*$' OR
      p_module_version IS NULL OR p_doc_type IS NULL OR
      p_doc_type !~ '^[A-Z][A-Za-z0-9_]*$' THEN
    RETURN NULL;
  END IF;
  identity := ventio_security.identity_snapshot(p_digest,p_company,p_branch);
  IF identity IS NULL THEN RETURN NULL; END IF;
  -- Shared release locks allow normal queries to run concurrently while
  -- serializing them with operator approval and revocation.
  PERFORM pg_catalog.pg_advisory_xact_lock_shared(
    pg_catalog.hashtextextended(
      pg_catalog.jsonb_build_array('ventio-extension-release-v1',
        identity->>'tenantId',p_module)::text, 0));
  SELECT * INTO package_row FROM public.ventio_extension_packages
    WHERE tenant_id=identity->>'tenantId' AND module_id=p_module
      AND version=p_module_version AND status='APPROVED'
    FOR SHARE;
  IF NOT FOUND OR jsonb_typeof(package_row.package_json->'docTypes') IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('identity',identity,'package',NULL,
      'reasonCode','EXTENSION_NOT_APPROVED');
  END IF;
  release_reason := ventio_security.extension_release_reason(
    identity->>'tenantId',p_module,p_module_version);
  IF release_reason IS NOT NULL THEN
    RETURN jsonb_build_object('identity',identity,'package',NULL,
      'reasonCode',release_reason);
  END IF;
  SELECT item INTO doc_type
  FROM jsonb_array_elements(package_row.package_json->'docTypes') AS entries(item)
  WHERE item->>'name'=p_doc_type AND item->>'moduleId'=p_module
  LIMIT 1;
  IF doc_type IS NULL OR jsonb_typeof(doc_type->'operations') IS DISTINCT FROM 'array' OR
      NOT (doc_type->'operations' ? 'read') THEN
    RETURN jsonb_build_object('identity',identity,'package',NULL,
      'reasonCode','EXTENSION_NOT_APPROVED');
  END IF;
  permission := doc_type->'permissions'->>'read';
  IF permission IS NULL OR permission NOT LIKE
      'extension.' || regexp_replace(p_module,'[^a-z0-9]+','_','g') || '.%' THEN
    RETURN jsonb_build_object('identity',identity,'package',NULL,
      'reasonCode','EXTENSION_NOT_APPROVED');
  END IF;
  IF NOT EXISTS (
      SELECT FROM jsonb_array_elements(identity->'scopeGrants') AS grants(item)
      WHERE item->>'companyId'=p_company AND item->>'branchId'=p_branch
        AND item->>'permission'=permission
    ) THEN
    RETURN jsonb_build_object('identity',identity,'package',NULL,
      'reasonCode','PERMISSION_DENIED');
  END IF;
  PERFORM set_config('ventio.credential_digest',p_digest,true);
  PERFORM set_config('ventio.company_id',p_company,true);
  PERFORM set_config('ventio.branch_id',p_branch,true);
  PERFORM set_config('ventio.command_type','extension.record.query',true);
  PERFORM set_config('ventio.command_version','1',true);
  PERFORM set_config('ventio.command_id','',true);
  PERFORM set_config('ventio.aggregate_id','',true);
  PERFORM set_config('ventio.module_id',p_module,true);
  PERFORM set_config('ventio.module_version',p_module_version,true);
  PERFORM set_config('ventio.doc_type',p_doc_type,true);
  PERFORM set_config('ventio.operation','read',true);
  PERFORM set_config('ventio.expected_revision','',true);
  PERFORM ventio_security.bind_extension_authorization(
    identity,package_row.package_json,p_digest,p_company,p_branch);
  RETURN jsonb_build_object('identity',identity,
    'package',package_row.package_json,'packageSha256',package_row.package_sha256);
END $fn$;

-- Resolve a generic record command against a Host-approved declarative package.
-- The package row is locked in the command transaction so revocation cannot
-- race an accepted write. No metadata in this package is executable code.
CREATE OR REPLACE FUNCTION ventio_security.resolve_extension_identity(
    p_digest text, p_company text, p_branch text, p_type text,
    p_version integer, p_command text, p_aggregate text,
    p_module text, p_module_version text, p_doc_type text,
    p_operation text, p_expected_revision bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE identity jsonb; package_row public.ventio_extension_packages%ROWTYPE;
        doc_type jsonb; permission text; expected_type text;
        release_reason text;
BEGIN
  FOREACH expected_type IN ARRAY ARRAY[
      'ventio.credential_digest','ventio.company_id','ventio.branch_id',
      'ventio.command_type','ventio.command_version','ventio.command_id',
      'ventio.aggregate_id','ventio.module_id','ventio.module_version',
      'ventio.doc_type','ventio.operation','ventio.expected_revision',
      'ventio.extension_identity_snapshot','ventio.extension_policy_snapshot',
      'ventio.extension_context_proof'] LOOP
    PERFORM set_config(expected_type, '', true);
  END LOOP;
  IF p_type IS NULL OR p_type NOT IN ('extension.record.create','extension.record.update') OR
      p_version IS DISTINCT FROM 1 OR
      p_module IS NULL OR p_module_version IS NULL OR p_doc_type IS NULL OR
      p_command IS NULL OR p_aggregate IS NULL OR
      (p_type = 'extension.record.create' AND
        (p_operation IS DISTINCT FROM 'create' OR p_expected_revision IS NOT NULL)) OR
      (p_type = 'extension.record.update' AND
        (p_operation IS DISTINCT FROM 'update' OR
         p_expected_revision IS NULL OR p_expected_revision < 1 OR
         p_expected_revision >= 2147483647)) OR
      (p_operation = 'create' AND p_expected_revision IS NOT NULL) OR
      p_operation IS NULL THEN
    RETURN NULL;
  END IF;
  identity := ventio_security.identity_snapshot(p_digest,p_company,p_branch);
  IF identity IS NULL THEN RETURN NULL; END IF;
  -- Keep the release high-water mark stable until the command commits.
  PERFORM pg_catalog.pg_advisory_xact_lock_shared(
    pg_catalog.hashtextextended(
      pg_catalog.jsonb_build_array('ventio-extension-release-v1',
        identity->>'tenantId',p_module)::text, 0));
  SELECT * INTO package_row FROM public.ventio_extension_packages
    WHERE tenant_id=identity->>'tenantId' AND module_id=p_module
      AND version=p_module_version AND status='APPROVED'
    FOR SHARE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('identity',identity,'package',NULL,
      'reasonCode','EXTENSION_NOT_APPROVED');
  END IF;
  release_reason := ventio_security.extension_release_reason(
    identity->>'tenantId',p_module,p_module_version);
  -- Keep the reviewed package and proof context available to the command
  -- journal path. It may return an already accepted receipt for an identical
  -- retry; new effects are rejected after that replay check.
  IF jsonb_typeof(package_row.package_json->'docTypes') IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('identity',identity,'package',NULL,
      'reasonCode','EXTENSION_NOT_APPROVED');
  END IF;
  SELECT item INTO doc_type
  FROM jsonb_array_elements(package_row.package_json->'docTypes') AS rows(item)
  WHERE item->>'name'=p_doc_type AND item->>'moduleId'=p_module
  LIMIT 1;
  IF doc_type IS NULL OR
      jsonb_typeof(doc_type->'operations') IS DISTINCT FROM 'array' OR
      NOT (doc_type->'operations' ? p_operation) THEN
    RETURN jsonb_build_object('identity',identity,'package',NULL,
      'reasonCode','EXTENSION_NOT_APPROVED');
  END IF;
  permission := doc_type->'permissions'->>p_operation;
  IF p_operation='update' THEN
    IF doc_type->'permissions'->>'read' IS NULL OR
        doc_type->'permissions'->>'read' NOT LIKE
          'extension.' || regexp_replace(p_module,'[^a-z0-9]+','_','g') || '.%' THEN
      RETURN jsonb_build_object('identity',identity,'package',NULL,
        'reasonCode','EXTENSION_NOT_APPROVED');
    END IF;
  END IF;
  IF permission IS NULL OR permission NOT LIKE
      'extension.' || regexp_replace(p_module,'[^a-z0-9]+','_','g') || '.%' THEN
    RETURN jsonb_build_object('identity',identity,'package',NULL,
      'reasonCode','EXTENSION_NOT_APPROVED');
  END IF;
  IF NOT EXISTS (
      SELECT FROM jsonb_array_elements(identity->'scopeGrants') AS grants(item)
      WHERE item->>'companyId'=p_company AND item->>'branchId'=p_branch
        AND item->>'permission'=permission
    ) OR (p_operation='update' AND NOT EXISTS (
      SELECT FROM jsonb_array_elements(identity->'scopeGrants') AS grants(item)
      WHERE item->>'companyId'=p_company AND item->>'branchId'=p_branch
        AND item->>'permission'=doc_type->'permissions'->>'read'
    )) THEN
    RETURN jsonb_build_object('identity',identity,'package',NULL,
      'reasonCode','PERMISSION_DENIED');
  END IF;
  PERFORM set_config('ventio.credential_digest',p_digest,true);
  PERFORM set_config('ventio.company_id',p_company,true);
  PERFORM set_config('ventio.branch_id',p_branch,true);
  PERFORM set_config('ventio.command_type',p_type,true);
  PERFORM set_config('ventio.command_version',p_version::text,true);
  PERFORM set_config('ventio.command_id',p_command,true);
  PERFORM set_config('ventio.aggregate_id',p_aggregate,true);
  PERFORM set_config('ventio.module_id',p_module,true);
  PERFORM set_config('ventio.module_version',p_module_version,true);
  PERFORM set_config('ventio.doc_type',p_doc_type,true);
  PERFORM set_config('ventio.operation',p_operation,true);
  PERFORM set_config('ventio.expected_revision',coalesce(p_expected_revision::text,''),true);
  PERFORM ventio_security.bind_extension_authorization(
    identity,package_row.package_json,p_digest,p_company,p_branch);
  RETURN jsonb_build_object('identity',identity,
    'package',package_row.package_json,'packageSha256',package_row.package_sha256,
    'reasonCode',release_reason);
END $fn$;

-- The administration login may inspect a candidate, but can neither read the
-- package table directly nor approve arbitrary package bytes.
CREATE OR REPLACE FUNCTION ventio_security.read_extension_submission(
    p_tenant text, p_module text, p_version text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE package_row public.ventio_extension_packages%ROWTYPE;
BEGIN
  IF NOT pg_has_role(session_user,'ventio_identity_admin','MEMBER') THEN
    RAISE EXCEPTION 'Extension review requires the restricted administration login'
      USING ERRCODE='42501';
  END IF;
  SELECT * INTO package_row FROM public.ventio_extension_packages
    WHERE tenant_id=p_tenant AND module_id=p_module AND version=p_version
      AND status='SUBMITTED';
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('status',package_row.status,'moduleId',package_row.module_id,
    'version',package_row.version,'packageSha256',package_row.package_sha256,
    'package',package_row.package_json);
END $fn$;
