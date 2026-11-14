-- Trusted Wave 2 control plane. Installed under SET LOCAL ROLE ventio_owner.
-- Private helpers are not callable by runtime or identity API logins.
CREATE OR REPLACE FUNCTION ventio_security.wave2_allowed(
    identity jsonb, company text, branch text, permission text)
RETURNS boolean LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
  SELECT identity IS NOT NULL AND EXISTS (
    SELECT FROM jsonb_array_elements(identity->'scopeGrants') g(item)
    WHERE item->>'companyId'=company AND item->>'branchId'=branch
      AND item->>'permission'=permission)
$fn$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_custom_labels(overlay jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE labels jsonb:='{}'; item record;
BEGIN
 FOR item IN SELECT f->>'labelKey' key,f->'label' value FROM jsonb_array_elements(coalesce(overlay->'fields','[]')) f
  UNION ALL SELECT overlay #>> '{properties,labelKey}',overlay #> '{properties,label}' WHERE overlay->'properties' ? 'labelKey'
  UNION ALL SELECT overlay #>> '{ui,pageTitleKey}',overlay #> '{ui,pageTitle}' WHERE overlay->'ui' ? 'pageTitleKey' LOOP
  IF labels ? item.key AND labels->item.key IS DISTINCT FROM item.value THEN RAISE EXCEPTION 'Conflicting customization labels' USING ERRCODE='23514'; END IF;
  labels:=labels||jsonb_build_object(item.key,item.value);
 END LOOP;
 RETURN labels;
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_definitions(
    p_digest text, p_company text, p_branch text, p_kind text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE identity jsonb; permission text; owner text; entries jsonb;
BEGIN
  identity := ventio_security.identity_snapshot(p_digest,p_company,p_branch);
  permission := CASE p_kind WHEN 'customization' THEN 'extension.package.read'
    WHEN 'configuration' THEN 'host.status.read' WHEN 'backup_policy' THEN 'platform.operations.manage'
    WHEN 'saved_view' THEN 'platform.workspace.use' WHEN 'preferences' THEN 'platform.workspace.use'
    WHEN 'dashboard' THEN 'platform.workspace.use' ELSE NULL END;
  IF permission IS NULL OR NOT ventio_security.wave2_allowed(identity,p_company,p_branch,permission) THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED');
  END IF;
  owner := CASE WHEN p_kind IN ('customization','configuration','backup_policy') THEN '' ELSE identity->>'actorId' END;
  SELECT coalesce(jsonb_agg(jsonb_build_object('id',definition_id,'revision',revision,
      'body',body,'updatedBy',updated_by,'updatedAtUtc',updated_at) ORDER BY definition_id),'[]') INTO entries
    FROM public.ventio_wave2_definitions WHERE tenant_id=identity->>'tenantId'
      AND company_id=p_company AND branch_id=p_branch AND owner_id=owner AND kind=p_kind;
  RETURN jsonb_build_object('status','DEFINITIONS','definitions',entries);
END $fn$;

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
        (p_body->'properties' - ARRAY['label','labelKey'])<>'{}'::jsonb OR
        jsonb_typeof(p_body->'ui') IS DISTINCT FROM 'object' OR
        (p_body->'ui' - ARRAY['listColumns','formFields','detailFields','pageTitle','pageTitleKey','pageIcon','pageOrder'])<>'{}'::jsonb THEN
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

CREATE OR REPLACE FUNCTION ventio_security.wave2_effective_package(
    p_tenant text,p_company text,p_branch text,p_base jsonb,p_sha text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE result jsonb := p_base; definitions jsonb := '[]'; doc jsonb; overlay jsonb;
BEGIN
  FOR doc IN SELECT value FROM jsonb_array_elements(p_base->'docTypes') LOOP
    SELECT body INTO overlay FROM public.ventio_wave2_definitions
      WHERE tenant_id=p_tenant AND company_id=p_company AND branch_id=p_branch
        AND owner_id='' AND kind='customization'
        AND definition_id=(p_base #>> '{manifest,moduleId}') || ':' ||
          (p_base #>> '{manifest,version}') || ':' || (doc->>'name');
    IF FOUND THEN
      IF overlay->>'baseSha256' IS DISTINCT FROM p_sha THEN
        RAISE EXCEPTION 'Customization package binding changed' USING ERRCODE='55000';
      END IF;
      result := jsonb_set(result,'{englishCatalog}',(result->'englishCatalog') ||
        coalesce((SELECT jsonb_object_agg(f.item->>'labelKey',f.item->'label') FROM jsonb_array_elements(overlay->'fields') f(item)),'{}') ||
        CASE WHEN overlay->'properties' ? 'labelKey' THEN jsonb_build_object(overlay #>> '{properties,labelKey}',overlay #> '{properties,label}') ELSE '{}'::jsonb END ||
        CASE WHEN overlay->'ui' ? 'pageTitleKey' THEN jsonb_build_object(overlay #>> '{ui,pageTitleKey}',overlay #> '{ui,pageTitle}') ELSE '{}'::jsonb END);
      doc := doc || (overlay->'properties') || jsonb_build_object(
        'fields',(doc->'fields') || (overlay->'fields'),
        'ui',coalesce(doc->'ui',jsonb_build_object(
          'listColumns',(SELECT jsonb_agg(f.item->'name') FROM
            (SELECT item FROM jsonb_array_elements(doc->'fields') f(item) LIMIT 4) f),
          'formFields',(SELECT jsonb_agg(item->'name') FROM jsonb_array_elements(doc->'fields') f(item)),
          'detailFields',(SELECT jsonb_agg(item->'name') FROM jsonb_array_elements(doc->'fields') f(item)))) || (overlay->'ui'));
    END IF;
    definitions := definitions || jsonb_build_array(doc);
  END LOOP;
  RETURN jsonb_set(result,'{docTypes}',definitions);
END $fn$;

-- Definition changes participate in the existing external recovery protocol.
DROP TRIGGER IF EXISTS wave2_definition_lock ON public.ventio_wave2_definitions;
CREATE TRIGGER wave2_definition_lock BEFORE INSERT OR UPDATE OR DELETE ON public.ventio_wave2_definitions
  FOR EACH STATEMENT EXECUTE FUNCTION ventio_security.lock_recovery_mutation();
DROP TRIGGER IF EXISTS wave2_definition_mark ON public.ventio_wave2_definitions;
CREATE TRIGGER wave2_definition_mark AFTER INSERT OR UPDATE OR DELETE ON public.ventio_wave2_definitions
  FOR EACH STATEMENT EXECUTE FUNCTION ventio_security.mark_recovery_mutation();

CREATE OR REPLACE FUNCTION ventio_security.wave2_submit_job(
    p_digest text,p_company text,p_branch text,p_job text,p_commands jsonb,p_import text,p_source_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE identity jsonb; command jsonb; hashed text; saved public.ventio_wave2_jobs%ROWTYPE;
BEGIN
  identity := ventio_security.identity_snapshot(p_digest,p_company,p_branch);
  IF NOT ventio_security.wave2_allowed(identity,p_company,p_branch,'platform.jobs.run') THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED');
  END IF;
  IF p_job IS NULL OR p_job !~ '^[0-9a-f-]{36}$' OR jsonb_typeof(p_commands) IS DISTINCT FROM 'array' OR
      jsonb_array_length(p_commands) NOT BETWEEN 1 AND 25 OR octet_length(p_commands::text)>65536 THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_JOB');
  END IF;
  FOR command IN SELECT value FROM jsonb_array_elements(p_commands) LOOP
    IF command->>'tenantId' IS DISTINCT FROM identity->>'tenantId' OR
        command->>'companyId' IS DISTINCT FROM p_company OR command->>'branchId' IS DISTINCT FROM p_branch OR
        command #>> '{clientContext,actorId}' IS DISTINCT FROM identity->>'actorId' OR command #>> '{clientContext,deviceId}' IS DISTINCT FROM identity->>'deviceId' OR
        command->>'type' NOT IN ('extension.record.create','extension.record.update','extension.operation.execute') OR
        command->>'type' IS NULL THEN
      RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_JOB_SCOPE');
    END IF;
  END LOOP;
  IF (SELECT count(DISTINCT value->>'commandId') FROM jsonb_array_elements(p_commands))<>jsonb_array_length(p_commands) THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','DUPLICATE_COMMAND_ID');
  END IF;
  IF p_import IS NULL THEN
    IF p_source_rows IS DISTINCT FROM '[]'::jsonb THEN RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_IMPORT_CORRELATION'); END IF;
  ELSE
    IF p_import !~ '^[0-9a-f-]{36}$' OR jsonb_typeof(p_source_rows) IS DISTINCT FROM 'array' OR
      jsonb_array_length(p_source_rows)<>jsonb_array_length(p_commands) OR EXISTS(
        SELECT FROM jsonb_array_elements(p_source_rows) r(item) WHERE jsonb_typeof(item)<>'number' OR item::text !~ '^[0-9]{1,6}$') THEN
      RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_IMPORT_CORRELATION'); END IF;
    IF EXISTS(SELECT FROM jsonb_array_elements(p_source_rows) r(item) WHERE (item::text)::int<2) OR
      (SELECT count(DISTINCT item) FROM jsonb_array_elements(p_source_rows) r(item))<>jsonb_array_length(p_source_rows) THEN
      RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_IMPORT_CORRELATION'); END IF;
  END IF;
  hashed := encode(sha256(convert_to(CASE WHEN p_import IS NULL THEN p_commands::text ELSE jsonb_build_array(p_commands,p_import,p_source_rows)::text END,'UTF8')),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(jsonb_build_array('wave2-actor-jobs',identity->>'tenantId',identity->>'actorId')::text,0));
  PERFORM pg_advisory_xact_lock(hashtextextended(jsonb_build_array('wave2-job',identity->>'tenantId',p_job)::text,0));
  SELECT * INTO saved FROM public.ventio_wave2_jobs WHERE tenant_id=identity->>'tenantId' AND job_id=p_job;
  IF FOUND THEN
    IF saved.request_hash<>hashed OR saved.actor_id<>identity->>'actorId' OR
        saved.device_id<>identity->>'deviceId' OR saved.company_id<>p_company OR saved.branch_id<>p_branch THEN
      RETURN jsonb_build_object('status','CONFLICT','reasonCode','JOB_ID_REUSED');
    END IF;
    RETURN jsonb_build_object('status','JOB','jobId',p_job,'state',saved.state);
  END IF;
  IF (SELECT count(*) FROM public.ventio_wave2_jobs WHERE tenant_id=identity->>'tenantId'
      AND actor_id=identity->>'actorId' AND state IN ('QUEUED','RUNNING','RETRY_WAIT'))>=20 THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','JOB_LIMIT');
  END IF;
  INSERT INTO public.ventio_wave2_jobs(tenant_id,company_id,branch_id,job_id,actor_id,device_id,
    credential_digest,request_hash,commands,import_id,source_rows,total_count)
    VALUES(identity->>'tenantId',p_company,p_branch,p_job,identity->>'actorId',identity->>'deviceId',p_digest,hashed,p_commands,p_import,p_source_rows,jsonb_array_length(p_commands));
  INSERT INTO public.ventio_wave2_events(tenant_id,company_id,branch_id,actor_id,event_type,subject_id)
    VALUES(identity->>'tenantId',p_company,p_branch,identity->>'actorId','JOB_QUEUED',p_job);
  RETURN jsonb_build_object('status','JOB','jobId',p_job,'state','QUEUED');
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_jobs_list(p_digest text,p_company text,p_branch text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE identity jsonb; entries jsonb;
BEGIN
  identity := ventio_security.identity_snapshot(p_digest,p_company,p_branch);
  IF NOT ventio_security.wave2_allowed(identity,p_company,p_branch,'platform.jobs.run') AND
      NOT ventio_security.wave2_allowed(identity,p_company,p_branch,'platform.jobs.manage') THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED');
  END IF;
  SELECT coalesce(jsonb_agg(item ORDER BY created_at DESC),'[]') INTO entries FROM (
    SELECT created_at,jsonb_build_object('jobId',job_id,'actorId',actor_id,'state',state,
      'importId',import_id,'sourceRows',source_rows,'processed',next_index,'total',total_count,'archivedAtUtc',archived_at,'attempts',attempts,
      'outcomes',outcomes,'updatedAtUtc',updated_at,
      'errorCode',(SELECT e.detail->>'code' FROM public.ventio_wave2_events e WHERE e.tenant_id=j.tenant_id
        AND e.company_id=j.company_id AND e.branch_id=j.branch_id AND e.subject_id=j.job_id AND e.event_type='JOB_FAILED'
        ORDER BY e.event_id DESC LIMIT 1)) item
    FROM public.ventio_wave2_jobs j WHERE tenant_id=identity->>'tenantId'
      AND company_id=p_company AND branch_id=p_branch AND (actor_id=identity->>'actorId' OR
        ventio_security.wave2_allowed(identity,p_company,p_branch,'platform.jobs.manage'))
    ORDER BY created_at DESC LIMIT 100) page;
  -- Command payloads, receipts containing data and credential digests are private.
  RETURN jsonb_build_object('status','JOBS','jobs',entries);
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_cancel_job(p_digest text,p_company text,p_branch text,p_job text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE identity jsonb; saved public.ventio_wave2_jobs%ROWTYPE;
BEGIN
  identity := ventio_security.identity_snapshot(p_digest,p_company,p_branch);
  IF identity IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO saved FROM public.ventio_wave2_jobs WHERE tenant_id=identity->>'tenantId' AND job_id=p_job
    AND company_id=p_company AND branch_id=p_branch FOR UPDATE;
  IF NOT FOUND OR NOT ((saved.actor_id=identity->>'actorId' AND
      ventio_security.wave2_allowed(identity,p_company,p_branch,'platform.jobs.run')) OR
      ventio_security.wave2_allowed(identity,p_company,p_branch,'platform.jobs.manage')) THEN
    RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED');
  END IF;
  IF saved.state IN ('QUEUED','RUNNING','RETRY_WAIT') THEN
    UPDATE public.ventio_wave2_jobs SET state='CANCELLED',lease_id=CASE WHEN state='RUNNING' THEN lease_id ELSE NULL END,lease_until=CASE WHEN state='RUNNING' THEN lease_until ELSE NULL END,updated_at=clock_timestamp()
      WHERE tenant_id=saved.tenant_id AND job_id=p_job;
    INSERT INTO public.ventio_wave2_events(tenant_id,company_id,branch_id,actor_id,event_type,subject_id)
      VALUES(saved.tenant_id,p_company,p_branch,identity->>'actorId','JOB_CANCELLED',p_job);
    saved.state := 'CANCELLED';
  END IF;
  RETURN jsonb_build_object('status','JOB','jobId',p_job,'state',saved.state);
END $fn$;

-- Worker-only operations: the Host owns this connection and its lease token.
-- A worker crash can repeat a command, but cannot duplicate its durable effect.
CREATE OR REPLACE FUNCTION ventio_security.wave2_claim_job()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE saved public.ventio_wave2_jobs%ROWTYPE; identity jsonb;
BEGIN
  IF NOT ventio_security.recovery_guard() THEN RETURN NULL; END IF;
  -- Terminal jobs retain identities, source-row labels, redacted outcomes and
  -- request hashes. Full commands and executable credential references expire.
  -- Stable journal receipts remain authoritative for any later command retry.
  WITH archived AS (
   UPDATE public.ventio_wave2_jobs j SET archived_at=clock_timestamp(),
    commands=(SELECT jsonb_agg(jsonb_build_object('commandId',item->'commandId','archived',true)) FROM jsonb_array_elements(j.commands) c(item)),
    credential_digest=repeat('0',64),lease_id=NULL,lease_until=NULL
   WHERE (tenant_id,job_id) IN (SELECT tenant_id,job_id FROM public.ventio_wave2_jobs
     WHERE archived_at IS NULL AND state IN ('SUCCEEDED','COMPLETED_WITH_ERRORS','FAILED','CANCELLED') AND
       updated_at<clock_timestamp()-make_interval(days=>coalesce((ventio_security.wave2_settings(tenant_id,company_id,branch_id)->>'completedJobRetentionDays')::int,30))
     ORDER BY updated_at LIMIT 50 FOR UPDATE SKIP LOCKED)
   RETURNING tenant_id,company_id,branch_id,job_id,total_count)
  INSERT INTO public.ventio_wave2_events(tenant_id,company_id,branch_id,actor_id,event_type,subject_id,detail)
   SELECT tenant_id,company_id,branch_id,'host-job-retention','JOB_ARCHIVED',job_id,jsonb_build_object('total',total_count) FROM archived;
  SELECT * INTO saved FROM public.ventio_wave2_jobs
    WHERE ((state IN ('QUEUED','RETRY_WAIT') AND available_at<=clock_timestamp()) OR
      (state='RUNNING' AND lease_until<clock_timestamp()))
      AND NOT (ventio_security.wave2_settings(tenant_id,company_id,branch_id)->>'jobsPaused')::boolean
      AND NOT (ventio_security.wave2_settings(tenant_id,company_id,branch_id)->>'maintenanceMode')::boolean
    ORDER BY available_at,created_at FOR UPDATE SKIP LOCKED LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  identity := ventio_security.identity_snapshot(saved.credential_digest,saved.company_id,saved.branch_id);
  IF identity IS NULL OR identity->>'actorId' IS DISTINCT FROM saved.actor_id OR
      identity->>'deviceId' IS DISTINCT FROM saved.device_id OR identity->>'tenantId' IS DISTINCT FROM saved.tenant_id OR
      NOT ventio_security.wave2_allowed(identity,saved.company_id,saved.branch_id,'platform.jobs.run') OR saved.attempts>=5 THEN
    UPDATE public.ventio_wave2_jobs SET state='FAILED',lease_id=NULL,lease_until=NULL,updated_at=clock_timestamp()
      WHERE tenant_id=saved.tenant_id AND job_id=saved.job_id;
    INSERT INTO public.ventio_wave2_events(tenant_id,company_id,branch_id,actor_id,event_type,subject_id,detail)
      VALUES(saved.tenant_id,saved.company_id,saved.branch_id,saved.actor_id,'JOB_FAILED',saved.job_id,
        jsonb_build_object('code',CASE WHEN saved.attempts>=5 THEN 'RETRY_LIMIT' ELSE 'EXECUTION_AUTHORIZATION_REVOKED' END));
    RETURN NULL;
  END IF;
  saved.lease_id := gen_random_uuid()::text;
  UPDATE public.ventio_wave2_jobs SET state='RUNNING',attempts=attempts+1,
    lease_id=saved.lease_id,lease_until=clock_timestamp()+interval '2 minutes',updated_at=clock_timestamp()
    WHERE tenant_id=saved.tenant_id AND job_id=saved.job_id;
  INSERT INTO public.ventio_wave2_events(tenant_id,company_id,branch_id,actor_id,event_type,subject_id,detail)
    VALUES(saved.tenant_id,saved.company_id,saved.branch_id,saved.actor_id,'JOB_ROW_CLAIMED',saved.job_id,
      jsonb_build_object('index',saved.next_index,'attempt',saved.attempts+1));
  RETURN jsonb_build_object('tenantId',saved.tenant_id,'jobId',saved.job_id,'leaseId',saved.lease_id,
    'credentialDigest',saved.credential_digest,'identity',identity,'command',saved.commands->saved.next_index);
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_finish_job(
    p_tenant text,p_job text,p_lease text,p_outcome jsonb,p_retry boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
DECLARE saved public.ventio_wave2_jobs%ROWTYPE; next_state text;
BEGIN
  IF NOT ventio_security.recovery_guard() THEN RAISE EXCEPTION 'Recovery admission denied' USING ERRCODE='28000'; END IF;
  SELECT * INTO saved FROM public.ventio_wave2_jobs WHERE tenant_id=p_tenant AND job_id=p_job FOR UPDATE;
  IF NOT FOUND OR saved.archived_at IS NOT NULL OR saved.state NOT IN ('RUNNING','CANCELLED') OR saved.lease_id IS DISTINCT FROM p_lease THEN RETURN; END IF;
  IF jsonb_typeof(p_outcome) IS DISTINCT FROM 'object' OR octet_length(p_outcome::text)>1024 OR
      (p_outcome - ARRAY['commandId','status','reasonCode'])<>'{}'::jsonb OR p_outcome->>'commandId' IS DISTINCT FROM saved.commands->saved.next_index->>'commandId' THEN
    RAISE EXCEPTION 'Invalid job outcome' USING ERRCODE='22023';
  END IF;
  IF saved.state='CANCELLED' THEN
    IF p_retry THEN p_outcome:=p_outcome || jsonb_build_object('reasonCode','CANCELLED_OUTCOME_UNKNOWN'); END IF;
    IF saved.import_id IS NOT NULL THEN p_outcome:=p_outcome || jsonb_build_object('importId',saved.import_id,'sourceRow',saved.source_rows->saved.next_index); END IF;
    UPDATE public.ventio_wave2_jobs SET outcomes=outcomes || jsonb_build_array(p_outcome),
     next_index=next_index+CASE WHEN p_retry THEN 0 ELSE 1 END,lease_id=NULL,lease_until=NULL,updated_at=clock_timestamp()
     WHERE tenant_id=p_tenant AND job_id=p_job;
    INSERT INTO public.ventio_wave2_events(tenant_id,company_id,branch_id,actor_id,event_type,subject_id,detail)
     VALUES(saved.tenant_id,saved.company_id,saved.branch_id,saved.actor_id,'JOB_CANCELLED_ROW_RESULT',p_job,p_outcome);
    RETURN;
  END IF;
  IF p_retry AND saved.attempts<5 THEN
    next_state := 'RETRY_WAIT';
  ELSE
    IF p_retry THEN p_outcome := jsonb_build_object('commandId',p_outcome->>'commandId','status','REJECTED','reasonCode','RETRY_LIMIT'); END IF;
    IF saved.import_id IS NOT NULL THEN p_outcome:=p_outcome || jsonb_build_object('importId',saved.import_id,'sourceRow',saved.source_rows->saved.next_index); END IF;
    saved.outcomes := saved.outcomes || jsonb_build_array(p_outcome);
    saved.next_index := saved.next_index+1;
    next_state := CASE WHEN saved.next_index<jsonb_array_length(saved.commands) THEN 'QUEUED'
      WHEN EXISTS (SELECT FROM jsonb_array_elements(saved.outcomes) o(item) WHERE item->>'status' IS DISTINCT FROM 'ACCEPTED')
        THEN 'COMPLETED_WITH_ERRORS' ELSE 'SUCCEEDED' END;
  END IF;
  UPDATE public.ventio_wave2_jobs SET state=next_state,next_index=saved.next_index,outcomes=saved.outcomes,
    attempts=CASE WHEN next_state='RETRY_WAIT' THEN saved.attempts ELSE 0 END,
    lease_id=NULL,lease_until=NULL,available_at=clock_timestamp()+
      CASE WHEN next_state='RETRY_WAIT' THEN make_interval(secs=>least(300,5*(2^saved.attempts)::integer)) ELSE interval '0' END,
    updated_at=clock_timestamp() WHERE tenant_id=p_tenant AND job_id=p_job;
  INSERT INTO public.ventio_wave2_events(tenant_id,company_id,branch_id,actor_id,event_type,subject_id,detail)
    VALUES(saved.tenant_id,saved.company_id,saved.branch_id,saved.actor_id,'JOB_ROW_RESULT',p_job,
      jsonb_build_object('state',next_state,'processed',saved.next_index,'outcome',p_outcome));
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_record_activity(
    p_tenant text,p_company text,p_branch text,p_actor text,p_command text,
    p_module text,p_doc text,p_record text,p_revision bigint,p_type text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ventio_security, pg_temp AS $fn$
BEGIN
  IF p_module IS DISTINCT FROM current_setting('ventio.module_id',true) OR
      p_doc IS DISTINCT FROM current_setting('ventio.doc_type',true) OR
      p_record IS DISTINCT FROM current_setting('ventio.aggregate_id',true) OR
      p_type IS DISTINCT FROM current_setting('ventio.command_type',true) OR
      NOT ventio_security.scope_allows(p_tenant,p_company,p_branch,'audit_write',p_command,p_actor,NULL) THEN
    RAISE EXCEPTION 'Activity context denied' USING ERRCODE='42501';
  END IF;
  INSERT INTO public.ventio_wave2_events(tenant_id,company_id,branch_id,actor_id,event_type,subject_id,detail)
    VALUES(p_tenant,p_company,p_branch,p_actor,'RECORD_ACTIVITY',p_record,
      jsonb_build_object('moduleId',p_module,'docType',p_doc,'revision',p_revision,'commandId',p_command,'operation',p_type,'sourceCommand',true,'operationKey',nullif(current_setting('ventio.operation',true),'')))
    ON CONFLICT(tenant_id,company_id,branch_id,subject_id,(detail->>'moduleId'),(detail->>'docType'),(detail->>'commandId')) WHERE event_type='RECORD_ACTIVITY'
    DO UPDATE SET detail=public.ventio_wave2_events.detail || EXCLUDED.detail;
END $fn$;

-- Preserve the Wave 2 v1 command-only submission contract.
CREATE OR REPLACE FUNCTION ventio_security.wave2_submit_job(p_digest text,p_company text,p_branch text,p_job text,p_commands jsonb)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
 SELECT ventio_security.wave2_submit_job(p_digest,p_company,p_branch,p_job,p_commands,NULL,'[]'::jsonb)
$fn$;
