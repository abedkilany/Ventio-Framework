DO $migration$
BEGIN
  IF to_regnamespace('ventio_security') IS NOT NULL AND
      to_regclass('public.ventio_extension_packages') IS NOT NULL THEN
    EXECUTE $ddl$
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
    IF saved.status IN ('REVOKED','REJECTED') THEN
      RETURN jsonb_build_object('status','CONFLICT','reasonCode','PACKAGE_RELEASE_CLOSED');
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
$ddl$;
    EXECUTE $ddl$
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
$ddl$;
    EXECUTE $ddl$
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
$ddl$;
    EXECUTE $ddl$
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
$ddl$;
    EXECUTE $ddl$
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
      'ventio.operation_inputs',
      'ventio.effect_target_id',
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
  PERFORM set_config('ventio.operation_inputs','',true);
  PERFORM set_config('ventio.effect_target_id','',true);
  PERFORM ventio_security.bind_extension_authorization(
    identity,package_row.package_json,p_digest,p_company,p_branch);
  RETURN jsonb_build_object('identity',identity,
    'package',package_row.package_json,'packageSha256',package_row.package_sha256);
END $fn$;
$ddl$;
    EXECUTE $ddl$
CREATE OR REPLACE FUNCTION ventio_security.resolve_extension_identity(
    p_digest text, p_company text, p_branch text, p_type text,
    p_version integer, p_command text, p_aggregate text,
    p_module text, p_module_version text, p_doc_type text,
    p_operation text, p_expected_revision bigint, p_operation_inputs jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE identity jsonb; package_row public.ventio_extension_packages%ROWTYPE;
        doc_type jsonb; permission text; expected_type text;
        business_operation jsonb; input_item record;
        release_reason text;
BEGIN
  FOREACH expected_type IN ARRAY ARRAY[
      'ventio.credential_digest','ventio.company_id','ventio.branch_id',
      'ventio.command_type','ventio.command_version','ventio.command_id',
      'ventio.aggregate_id','ventio.module_id','ventio.module_version',
      'ventio.doc_type','ventio.operation','ventio.expected_revision',
      'ventio.operation_inputs',
      'ventio.extension_identity_snapshot','ventio.extension_policy_snapshot',
      'ventio.extension_context_proof'] LOOP
    PERFORM set_config(expected_type, '', true);
  END LOOP;
  IF p_type IS NULL OR p_type NOT IN ('extension.record.create','extension.record.update','extension.record.delete','extension.operation.execute') OR
      p_version IS DISTINCT FROM 1 OR
      p_module IS NULL OR p_module_version IS NULL OR p_doc_type IS NULL OR
      p_command IS NULL OR p_aggregate IS NULL OR
      (p_type = 'extension.record.create' AND
        (p_operation IS DISTINCT FROM 'create' OR p_expected_revision IS NOT NULL)) OR
      (p_type = 'extension.record.update' AND
        (p_operation IS DISTINCT FROM 'update' OR
         p_expected_revision IS NULL OR p_expected_revision < 1 OR
         p_expected_revision >= 2147483647)) OR
      (p_type = 'extension.record.delete' AND
        (p_operation IS DISTINCT FROM 'delete' OR
         p_expected_revision IS NULL OR p_expected_revision < 1 OR
         p_expected_revision >= 2147483647)) OR
      (p_type = 'extension.operation.execute' AND
        (p_operation !~ '^[a-z][a-z0-9]*(\.[a-z0-9]+|_[a-z0-9]+|-[a-z0-9]+)*@[1-9][0-9]{0,2}$' OR
         p_expected_revision IS NULL OR p_expected_revision < 1 OR
         p_expected_revision >= 2147483647 OR
         jsonb_typeof(p_operation_inputs) IS DISTINCT FROM 'object' OR
         (SELECT count(*) FROM jsonb_object_keys(p_operation_inputs))>32)) OR
      (p_operation = 'create' AND p_expected_revision IS NOT NULL) OR
      p_operation IS NULL THEN
    RETURN NULL;
  END IF;
  IF p_type<>'extension.operation.execute' AND
      (jsonb_typeof(p_operation_inputs) IS DISTINCT FROM 'object' OR
       (SELECT count(*) FROM jsonb_object_keys(p_operation_inputs))<>0) THEN
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
  IF doc_type IS NULL OR jsonb_typeof(doc_type->'operations') IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('identity',identity,'package',NULL,
      'reasonCode','EXTENSION_NOT_APPROVED');
  END IF;
  IF p_type='extension.operation.execute' THEN
    SELECT item INTO business_operation
    FROM jsonb_array_elements(coalesce(doc_type->'businessOperations','[]'::jsonb)) AS declared(item)
    WHERE item->>'id'=split_part(p_operation,'@',1)
      AND item->>'version'=split_part(p_operation,'@',2)
    LIMIT 1;
    IF business_operation IS NULL THEN
      RETURN jsonb_build_object('identity',identity,'package',NULL,
        'reasonCode','EXTENSION_NOT_APPROVED');
    END IF;
    permission := business_operation->>'permission';
    FOR input_item IN
      SELECT key, value FROM jsonb_each(p_operation_inputs)
    LOOP
      IF NOT (business_operation->'inputs' ? input_item.key) OR
          jsonb_typeof(input_item.value) IN ('array','object') THEN
        RETURN jsonb_build_object('identity',identity,'package',NULL,
          'reasonCode','INVALID_PAYLOAD');
      END IF;
    END LOOP;
    FOR input_item IN
      SELECT key, value FROM jsonb_each(business_operation->'inputs')
    LOOP
      IF coalesce((input_item.value->>'required')::boolean,false) AND
          (NOT (p_operation_inputs ? input_item.key) OR
           jsonb_typeof(p_operation_inputs->input_item.key)='null') THEN
        RETURN jsonb_build_object('identity',identity,'package',NULL,
          'reasonCode','INVALID_PAYLOAD');
      END IF;
      IF p_operation_inputs ? input_item.key THEN
        IF (input_item.value->>'type'='text' AND jsonb_typeof(p_operation_inputs->input_item.key) NOT IN ('string','null')) OR
           (input_item.value->>'type' IN ('integer','decimal') AND jsonb_typeof(p_operation_inputs->input_item.key) NOT IN ('number','null')) OR
           (input_item.value->>'type'='boolean' AND jsonb_typeof(p_operation_inputs->input_item.key) NOT IN ('boolean','null')) OR
           (input_item.value->>'type' IN ('date','reference') AND jsonb_typeof(p_operation_inputs->input_item.key) NOT IN ('string','null')) OR
           (input_item.value->>'type'='text' AND input_item.value ? 'maxLength' AND length(p_operation_inputs->>input_item.key)>(input_item.value->>'maxLength')::integer) OR
           (input_item.value->>'type'='integer' AND (p_operation_inputs->>input_item.key) !~ '^-?[0-9]+$') OR
           (input_item.value->>'type'='decimal' AND input_item.value ? 'precision' AND
             (p_operation_inputs->>input_item.key)::numeric <>
               round((p_operation_inputs->>input_item.key)::numeric,(input_item.value->>'precision')::integer)) THEN
          RETURN jsonb_build_object('identity',identity,'package',NULL,
            'reasonCode','INVALID_PAYLOAD');
        END IF;
      END IF;
    END LOOP;
  ELSE
    IF NOT (doc_type->'operations' ? p_operation) THEN
      RETURN jsonb_build_object('identity',identity,'package',NULL,
        'reasonCode','EXTENSION_NOT_APPROVED');
    END IF;
    permission := doc_type->'permissions'->>p_operation;
  END IF;
  IF p_operation IN ('update','delete') OR p_type='extension.operation.execute' THEN
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
    ) OR ((p_operation IN ('update','delete') OR p_type='extension.operation.execute') AND NOT EXISTS (
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
  PERFORM set_config('ventio.operation_inputs',p_operation_inputs::text,true);
  PERFORM set_config('ventio.effect_target_id','',true);
  PERFORM ventio_security.bind_extension_authorization(
    identity,package_row.package_json,p_digest,p_company,p_branch);
  RETURN jsonb_build_object('identity',identity,
    'package',package_row.package_json,'packageSha256',package_row.package_sha256,
    'reasonCode',release_reason);
END $fn$;
$ddl$;
    EXECUTE $ddl$
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
$ddl$;
    EXECUTE $ddl$
CREATE OR REPLACE FUNCTION ventio_security.list_extension_submissions(
    p_digest text, p_tenant text, p_company text, p_branch text, p_limit integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE identity jsonb; entries jsonb;
BEGIN
  IF NOT ventio_security.recovery_guard() THEN RETURN NULL; END IF;
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 3 THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_PAGE');
  END IF;
  identity := ventio_security.identity_snapshot(p_digest,p_company,p_branch);
  IF identity IS NULL OR identity->>'tenantId' IS DISTINCT FROM p_tenant OR
      NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(identity->'scopeGrants') AS g(item)
        WHERE item->>'companyId'=p_company AND item->>'branchId'=p_branch
          AND item->>'permission'='extension.package.review'
      ) THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED');
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'moduleId',candidate.module_id,'version',candidate.version,
      'packageSha256',candidate.package_sha256,'package',candidate.package_json,
      'submittedBy',candidate.submitted_by,'submittedAt',candidate.submitted_at)
      ORDER BY candidate.submitted_at,candidate.module_id,candidate.version),'[]'::jsonb)
    INTO entries
    FROM (
      SELECT * FROM public.ventio_extension_packages
      WHERE tenant_id=p_tenant AND submitted_company_id=p_company
        AND submitted_branch_id=p_branch AND status='SUBMITTED'
        AND submitted_by IS DISTINCT FROM identity->>'actorId'
      ORDER BY submitted_at,module_id,version LIMIT p_limit
    ) candidate;
  RETURN jsonb_build_object('status','OK','entries',entries);
END $fn$;
$ddl$;
    EXECUTE $ddl$
CREATE OR REPLACE FUNCTION ventio_security.review_extension_submission(
    p_digest text, p_tenant text, p_company text, p_branch text,
    p_module text, p_version text, p_sha256 text, p_decision text, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE identity jsonb; candidate public.ventio_extension_packages%ROWTYPE;
BEGIN
  IF NOT pg_has_role(session_user,'ventio_identity_api','MEMBER') OR
      pg_has_role(session_user,'ventio_identity_admin','MEMBER') OR
      pg_has_role(session_user,'ventio_owner','MEMBER') OR
      pg_has_role(session_user,'ventio_migrator','MEMBER') OR
      NOT ventio_security.recovery_guard() THEN
    RAISE EXCEPTION 'Extension review caller is not authorized'
      USING ERRCODE='42501';
  END IF;
  IF p_decision NOT IN ('APPROVE','REJECT') OR
      p_module !~ '^[a-z][a-z0-9]*([._-][a-z0-9]+)*$' OR length(p_module)>128 OR
      p_version !~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' OR
      p_sha256 !~ '^[0-9a-f]{64}$' OR
      (p_decision='REJECT' AND length(trim(coalesce(p_reason,''))) NOT BETWEEN 1 AND 500) OR
      (p_decision='APPROVE' AND coalesce(p_reason,'')<>'') THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_REVIEW');
  END IF;
  identity := ventio_security.identity_snapshot(p_digest,p_company,p_branch);
  IF identity IS NULL OR identity->>'tenantId' IS DISTINCT FROM p_tenant OR
      NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(identity->'scopeGrants') AS g(item)
        WHERE item->>'companyId'=p_company AND item->>'branchId'=p_branch
          AND item->>'permission'='extension.package.review'
      ) THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED');
  END IF;
  SELECT * INTO candidate FROM public.ventio_extension_packages
    WHERE tenant_id=p_tenant AND module_id=p_module AND version=p_version
      AND submitted_company_id=p_company AND submitted_branch_id=p_branch
      FOR UPDATE;
  IF NOT FOUND OR candidate.status<>'SUBMITTED' OR
      candidate.package_sha256 IS DISTINCT FROM p_sha256 THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','CANDIDATE_CHANGED');
  END IF;
  IF candidate.submitted_by=identity->>'actorId' THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','SELF_REVIEW_FORBIDDEN');
  END IF;
  PERFORM ventio_security.admin_change(jsonb_build_object(
    'tenantId',p_tenant,'operatorLabel',identity->>'actorId',
    'action',CASE WHEN p_decision='APPROVE'
      THEN 'EXTENSION_PACKAGE_APPROVED' ELSE 'EXTENSION_PACKAGE_REJECTED' END,
    'moduleId',p_module,'version',p_version,'packageSha256',p_sha256,
    'reason',CASE WHEN p_decision='REJECT' THEN trim(p_reason) ELSE NULL END));
  RETURN jsonb_build_object('status',CASE WHEN p_decision='APPROVE'
    THEN 'APPROVED' ELSE 'REJECTED' END,'moduleId',p_module,
    'version',p_version,'packageSha256',p_sha256);
END $fn$;
$ddl$;
    EXECUTE $ddl$
CREATE OR REPLACE FUNCTION ventio_security.get_extension_submission_scoped(
    p_digest text, p_tenant text, p_company text, p_branch text,
    p_module text, p_version text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE identity jsonb; candidate public.ventio_extension_packages%ROWTYPE;
BEGIN
  IF NOT ventio_security.recovery_guard() THEN RETURN NULL; END IF;
  identity := ventio_security.identity_snapshot(p_digest,p_company,p_branch);
  IF identity IS NULL OR identity->>'tenantId' IS DISTINCT FROM p_tenant OR
      NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(identity->'scopeGrants') AS g(item)
        WHERE item->>'companyId'=p_company AND item->>'branchId'=p_branch
          AND item->>'permission'='extension.package.review'
      ) THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED');
  END IF;
  SELECT * INTO candidate FROM public.ventio_extension_packages
    WHERE tenant_id=p_tenant AND submitted_company_id=p_company
      AND submitted_branch_id=p_branch AND module_id=p_module AND version=p_version
      AND status='SUBMITTED';
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('status',candidate.status,'moduleId',candidate.module_id,
    'version',candidate.version,'packageSha256',candidate.package_sha256,
    'package',candidate.package_json,'submittedBy',candidate.submitted_by,
    'submittedAt',candidate.submitted_at);
END $fn$;
$ddl$;
    EXECUTE 'REVOKE EXECUTE ON FUNCTION
      ventio_security.submit_extension_package(text,text,text,text,text,text,text,jsonb),
      ventio_security.read_approved_extension_package(text,text,text,text,text,text),
      ventio_security.list_approved_extension_packages(text,text,text,text,text,text,integer),
      ventio_security.extension_release_reason(text,text,text),
      ventio_security.resolve_extension_read_identity(text,text,text,text,text,text),
      ventio_security.resolve_extension_identity(text,text,text,text,integer,text,text,text,text,text,text,bigint,jsonb),
      ventio_security.read_extension_submission(text,text,text),
      ventio_security.list_extension_submissions(text,text,text,text,integer),
      ventio_security.review_extension_submission(text,text,text,text,text,text,text,text,text),
      ventio_security.get_extension_submission_scoped(text,text,text,text,text,text)
      FROM PUBLIC, ventio_runtime, ventio_identity_admin, ventio_identity_api';
    EXECUTE 'GRANT EXECUTE ON FUNCTION
      ventio_security.submit_extension_package(text,text,text,text,text,text,text,jsonb),
      ventio_security.read_approved_extension_package(text,text,text,text,text,text),
      ventio_security.list_approved_extension_packages(text,text,text,text,text,text,integer),
      ventio_security.resolve_extension_read_identity(text,text,text,text,text,text),
      ventio_security.resolve_extension_identity(text,text,text,text,integer,text,text,text,text,text,text,bigint,jsonb)
      TO ventio_runtime';
    EXECUTE 'GRANT EXECUTE ON FUNCTION
      ventio_security.read_extension_submission(text,text,text)
      TO ventio_identity_admin';
    EXECUTE 'GRANT EXECUTE ON FUNCTION
      ventio_security.list_extension_submissions(text,text,text,text,integer),
      ventio_security.review_extension_submission(text,text,text,text,text,text,text,text,text),
      ventio_security.get_extension_submission_scoped(text,text,text,text,text,text)
      TO ventio_identity_api';
  END IF;
END $migration$;
