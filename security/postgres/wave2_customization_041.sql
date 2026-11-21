-- Forward correction for release 041. Preserve the published base contract.
-- CREATE OR REPLACE preserves the existing function owner and execution ACL.
CREATE OR REPLACE FUNCTION ventio_security.wave2_save_definition(
    p_digest text, p_company text, p_branch text, p_kind text, p_id text,
    p_expected bigint, p_request text, p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE identity jsonb; permission text; owner text; actual bigint; request_hash text;
  previous public.ventio_wave2_revisions%ROWTYPE; old_body jsonb;
  base public.ventio_extension_packages%ROWTYPE; labels jsonb; doc jsonb; field jsonb; old_field jsonb;
BEGIN
  IF NOT ventio_security.recovery_guard() THEN RETURN NULL; END IF;
  identity := ventio_security.identity_snapshot(p_digest,p_company,p_branch);
  permission := CASE p_kind WHEN 'customization' THEN 'platform.customizations.manage'
    WHEN 'configuration' THEN 'platform.configuration.manage' WHEN 'backup_policy' THEN 'platform.operations.manage'
    WHEN 'saved_view' THEN 'platform.workspace.use' WHEN 'preferences' THEN 'platform.workspace.use'
    WHEN 'dashboard' THEN 'platform.workspace.use' ELSE NULL END;
  IF permission IS NULL OR NOT ventio_security.wave2_allowed(identity,p_company,p_branch,permission) THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED');
  END IF;
  IF p_id IS NULL OR length(p_id)>256 OR p_id !~ '^[A-Za-z0-9_.:-]+$' OR
      p_request IS NULL OR p_request !~ '^[0-9a-f-]{36}$' OR p_expected IS NULL OR p_expected<0 OR
      jsonb_typeof(p_body) IS DISTINCT FROM 'object' OR octet_length(p_body::text)>65536 OR
      p_body->>'contractVersion' IS DISTINCT FROM '1' THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_DEFINITION');
  END IF;
  owner := CASE WHEN p_kind IN ('customization','configuration','backup_policy') THEN '' ELSE identity->>'actorId' END;
  PERFORM pg_advisory_xact_lock(hashtextextended(jsonb_build_array('wave2-definition',
    identity->>'tenantId',p_company,p_branch,owner)::text,0));
  request_hash := encode(sha256(convert_to(jsonb_build_array(p_kind,p_id,p_expected,p_body)::text,'UTF8')),'hex');
  SELECT * INTO previous FROM public.ventio_wave2_revisions WHERE tenant_id=identity->>'tenantId'
    AND company_id=p_company AND branch_id=p_branch AND owner_id=owner AND request_id=p_request;
  IF FOUND THEN
    IF previous.request_hash<>request_hash THEN
      RETURN jsonb_build_object('status','CONFLICT','reasonCode','REQUEST_ID_REUSED');
    END IF;
    RETURN jsonb_build_object('status','SAVED','revision',previous.revision,'requestId',p_request);
  END IF;
  SELECT revision,body INTO actual,old_body FROM public.ventio_wave2_definitions
    WHERE tenant_id=identity->>'tenantId' AND company_id=p_company AND branch_id=p_branch
      AND owner_id=owner AND kind=p_kind AND definition_id=p_id FOR UPDATE;
  IF coalesce(actual,0)<>p_expected THEN
    RETURN jsonb_build_object('status','CONFLICT','reasonCode','DEFINITION_CHANGED','revision',coalesce(actual,0));
  END IF;
  IF actual IS NULL AND (SELECT count(*) FROM public.ventio_wave2_definitions
      WHERE tenant_id=identity->>'tenantId' AND company_id=p_company AND branch_id=p_branch
        AND owner_id=owner AND kind=p_kind)>=100 THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','DEFINITION_LIMIT');
  END IF;
  IF p_kind IN ('configuration','backup_policy') AND p_id<>'scope' THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_DEFINITION_ID'); END IF;
  IF p_kind='configuration' THEN
    IF (p_body-ARRAY['contractVersion','displayName','maintenanceNotice','maintenanceMode','jobsPaused','defaultPageSize','maxImportRows','completedJobRetentionDays'])<>'{}'::jsonb OR
      jsonb_typeof(p_body->'displayName') IS DISTINCT FROM 'string' OR length(p_body->>'displayName') NOT BETWEEN 1 AND 120 OR
      jsonb_typeof(p_body->'maintenanceNotice') IS DISTINCT FROM 'string' OR length(p_body->>'maintenanceNotice')>1000 OR
      (p_body ? 'maintenanceMode' AND jsonb_typeof(p_body->'maintenanceMode')<>'boolean') OR
      (p_body ? 'jobsPaused' AND jsonb_typeof(p_body->'jobsPaused')<>'boolean') OR
      (p_body ? 'defaultPageSize' AND (jsonb_typeof(p_body->'defaultPageSize') IS DISTINCT FROM 'number' OR (p_body->>'defaultPageSize') !~ '^[0-9]{1,3}$')) OR
      (p_body ? 'maxImportRows' AND (jsonb_typeof(p_body->'maxImportRows') IS DISTINCT FROM 'number' OR (p_body->>'maxImportRows') !~ '^[0-9]{1,3}$')) OR
      (p_body ? 'completedJobRetentionDays' AND (jsonb_typeof(p_body->'completedJobRetentionDays') IS DISTINCT FROM 'number' OR (p_body->>'completedJobRetentionDays') !~ '^[0-9]{1,4}$')) THEN
      RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_CONFIGURATION'); END IF;
    IF coalesce((p_body->>'defaultPageSize')::int,50) NOT BETWEEN 1 AND 100 OR coalesce((p_body->>'maxImportRows')::int,500) NOT BETWEEN 1 AND 500 OR coalesce((p_body->>'completedJobRetentionDays')::int,30) NOT BETWEEN 1 AND 3650 THEN
      RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_CONFIGURATION'); END IF;
  ELSIF p_kind='backup_policy' THEN
    IF (p_body-ARRAY['contractVersion','enabled','utcTime','retainDays','retainCopies','maximumAttempts','retryMinutes'])<>'{}'::jsonb OR
      jsonb_typeof(p_body->'enabled') IS DISTINCT FROM 'boolean' OR (p_body->>'utcTime') IS NULL OR
      (p_body->>'utcTime') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' OR
      coalesce(p_body->>'retainDays','') !~ '^[0-9]{1,4}$' OR coalesce(p_body->>'retainCopies','') !~ '^[0-9]{1,4}$' OR
      coalesce(p_body->>'maximumAttempts','') !~ '^[0-9]$' OR coalesce(p_body->>'retryMinutes','') !~ '^[0-9]{1,4}$' THEN
      RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_BACKUP_POLICY'); END IF;
    IF (p_body->>'retainDays')::int NOT BETWEEN 1 AND 3650 OR (p_body->>'retainCopies')::int NOT BETWEEN 2 AND 1000 OR
      (p_body->>'maximumAttempts')::int NOT BETWEEN 1 AND 5 OR (p_body->>'retryMinutes')::int NOT BETWEEN 5 AND 1440 THEN
      RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_BACKUP_POLICY'); END IF;
  END IF;
  IF p_kind='customization' THEN
    IF (p_body - ARRAY['contractVersion','moduleId','moduleVersion','docType','baseSha256','fields','properties','ui'])<>'{}'::jsonb OR
        p_id IS DISTINCT FROM (p_body->>'moduleId') || ':' || (p_body->>'moduleVersion') || ':' || (p_body->>'docType') OR
        jsonb_typeof(p_body->'fields') IS DISTINCT FROM 'array' OR jsonb_array_length(p_body->'fields')>20 OR
        jsonb_typeof(p_body->'properties') IS DISTINCT FROM 'object' OR
        ((p_body->'properties') - ARRAY['label','labelKey'])<>'{}'::jsonb OR
        jsonb_typeof(p_body->'ui') IS DISTINCT FROM 'object' OR
        ((p_body->'ui') - ARRAY['listColumns','formFields','detailFields','pageTitle','pageTitleKey','pageIcon','pageOrder'])<>'{}'::jsonb THEN
      RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_CUSTOMIZATION');
    END IF;
    -- Serialize edits with release approval/revocation, then effective reads.
    PERFORM pg_advisory_xact_lock(hashtextextended(jsonb_build_array('ventio-extension-release-v1',
      identity->>'tenantId',p_body->>'moduleId')::text,0));
    SELECT * INTO base FROM public.ventio_extension_packages
      WHERE tenant_id=identity->>'tenantId' AND module_id=p_body->>'moduleId'
        AND version=p_body->>'moduleVersion' AND status='APPROVED' FOR SHARE;
    IF NOT FOUND OR base.package_sha256 IS DISTINCT FROM p_body->>'baseSha256' OR
        ventio_security.extension_release_reason(identity->>'tenantId',base.module_id,base.version) IS NOT NULL THEN
      RETURN jsonb_build_object('status','CONFLICT','reasonCode','CUSTOMIZATION_BASE_CHANGED');
    END IF;
    SELECT item INTO doc FROM jsonb_array_elements(base.package_json->'docTypes') d(item)
      WHERE item->>'name'=p_body->>'docType';
    IF doc IS NULL OR doc->'permissions'->>'read' IS NULL OR doc->'permissions'->>'update' IS NULL OR
        jsonb_array_length(doc->'fields')+jsonb_array_length(p_body->'fields')>100 THEN
      RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_CUSTOMIZATION');
    END IF;
    labels:=ventio_security.wave2_custom_labels(p_body);
    IF EXISTS(SELECT FROM jsonb_each(labels) l WHERE base.package_json->'englishCatalog' ? l.key AND base.package_json->'englishCatalog'->l.key IS DISTINCT FROM l.value) OR
      EXISTS(SELECT FROM public.ventio_wave2_definitions d CROSS JOIN LATERAL jsonb_each(ventio_security.wave2_custom_labels(d.body)) l
        WHERE d.tenant_id=identity->>'tenantId' AND d.company_id=p_company AND d.branch_id=p_branch AND d.owner_id='' AND d.kind='customization'
         AND d.definition_id<>p_id AND d.body->>'moduleId'=base.module_id AND d.body->>'moduleVersion'=base.version
         AND labels ? l.key AND labels->l.key IS DISTINCT FROM l.value) THEN
      RETURN jsonb_build_object('status','REJECTED','reasonCode','CUSTOMIZATION_LABEL_COLLISION'); END IF;
    FOR field IN SELECT value FROM jsonb_array_elements(p_body->'fields') LOOP
      IF (field - ARRAY['name','type','required','label','labelKey','maxLength','precision','readPermission','writePermission'])<>'{}'::jsonb OR
          field->>'name' IS NULL OR field->>'name' !~ '^custom_[A-Za-z0-9_]{1,73}$' OR
          field->>'type' NOT IN ('text','long_text','integer','decimal','boolean','date','datetime') OR
          field->>'type' IS NULL OR field->>'required' IS DISTINCT FROM 'false' OR
          field->>'readPermission' IS DISTINCT FROM doc->'permissions'->>'read' OR
          field->>'writePermission' IS DISTINCT FROM doc->'permissions'->>'update' OR
          EXISTS (SELECT FROM jsonb_array_elements(doc->'fields') f(item) WHERE item->>'name'=field->>'name') OR
          (SELECT count(*) FROM jsonb_array_elements(p_body->'fields') f(item) WHERE item->>'name'=field->>'name')<>1 THEN
        RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_CUSTOMIZATION');
      END IF;
    END LOOP;
    FOR old_field IN SELECT value FROM jsonb_array_elements(coalesce(old_body->'fields','[]')) LOOP
      IF NOT EXISTS (SELECT FROM jsonb_array_elements(p_body->'fields') f(item)
          WHERE (item - ARRAY['label','labelKey'])=(old_field - ARRAY['label','labelKey'])) THEN
        RETURN jsonb_build_object('status','REJECTED','reasonCode','CUSTOMIZATION_MIGRATION_REQUIRED');
      END IF;
    END LOOP;
  END IF;
  actual := coalesce(actual,0)+1;
  INSERT INTO public.ventio_wave2_definitions VALUES
    (identity->>'tenantId',p_company,p_branch,owner,p_kind,p_id,actual,p_body,identity->>'actorId',clock_timestamp())
    ON CONFLICT (tenant_id,company_id,branch_id,owner_id,kind,definition_id)
    DO UPDATE SET revision=EXCLUDED.revision,body=EXCLUDED.body,updated_by=EXCLUDED.updated_by,updated_at=EXCLUDED.updated_at;
  INSERT INTO public.ventio_wave2_revisions
    (tenant_id,company_id,branch_id,owner_id,kind,definition_id,revision,request_id,request_hash,body,saved_by)
    VALUES (identity->>'tenantId',p_company,p_branch,owner,p_kind,p_id,actual,p_request,request_hash,p_body,identity->>'actorId');
  INSERT INTO public.ventio_wave2_events(tenant_id,company_id,branch_id,actor_id,event_type,subject_id,detail)
    VALUES(identity->>'tenantId',p_company,p_branch,identity->>'actorId','DEFINITION_SAVED',p_id,
      jsonb_build_object('kind',p_kind,'revision',actual));
  RETURN jsonb_build_object('status','SAVED','revision',actual,'requestId',p_request);
END $fn$;
