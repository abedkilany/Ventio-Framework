-- Fixed, non-destructive release migration of separately owned overlays.
CREATE OR REPLACE FUNCTION ventio_security.wave2_rebase_body(p_old jsonb,p_target jsonb,p_sha text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE doc jsonb; names jsonb; ui jsonb; key text; layout jsonb;
BEGIN
 SELECT item INTO doc FROM jsonb_array_elements(p_target->'docTypes') d(item) WHERE item->>'name'=p_old->>'docType';
 IF EXISTS(SELECT FROM jsonb_each(ventio_security.wave2_custom_labels(p_old)) l WHERE p_target->'englishCatalog' ? l.key AND p_target->'englishCatalog'->l.key IS DISTINCT FROM l.value) THEN
  RAISE EXCEPTION 'Customization label collides with target release' USING ERRCODE='23514'; END IF;
 IF doc IS NULL OR doc->'permissions'->>'read' IS NULL OR doc->'permissions'->>'update' IS NULL OR
   EXISTS(SELECT FROM jsonb_array_elements(p_old->'fields') f(item) WHERE
    item->>'readPermission' IS DISTINCT FROM doc->'permissions'->>'read' OR
    item->>'writePermission' IS DISTINCT FROM doc->'permissions'->>'update' OR
    EXISTS(SELECT FROM jsonb_array_elements(doc->'fields') b(item) WHERE b.item->>'name'=f.item->>'name')) OR
   jsonb_array_length(doc->'fields')+jsonb_array_length(p_old->'fields')>100 THEN
  RAISE EXCEPTION 'Incompatible customization rebase' USING ERRCODE='23514'; END IF;
 SELECT coalesce(jsonb_agg(item->'name'),'[]') INTO names FROM jsonb_array_elements(p_old->'fields') f(item);
 ui:=p_old->'ui';
 FOREACH key IN ARRAY ARRAY['listColumns','formFields','detailFields'] LOOP
  layout:=doc->'ui'->key;
  IF layout IS NULL THEN
   SELECT coalesce(jsonb_agg(item->'name'),'[]') INTO layout FROM
     (SELECT item FROM jsonb_array_elements(doc->'fields') f(item) LIMIT CASE WHEN key='listColumns' THEN 4 ELSE 100 END) fields;
  END IF;
  ui:=jsonb_set(ui,ARRAY[key],layout || names);
 END LOOP;
 RETURN p_old || jsonb_build_object('moduleVersion',p_target #>> '{manifest,version}','baseSha256',p_sha,'ui',ui);
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_rebase_candidate(p_digest text,p_company text,p_branch text,p_module text,p_source text,p_target text,p_doc text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE identity jsonb; source public.ventio_wave2_definitions%ROWTYPE; target public.ventio_extension_packages%ROWTYPE;
BEGIN
 identity:=ventio_security.identity_snapshot(p_digest,p_company,p_branch);
 IF NOT ventio_security.wave2_allowed(identity,p_company,p_branch,'platform.customizations.manage') OR
    NOT ventio_security.wave2_allowed(identity,p_company,p_branch,'extension.package.review') THEN
  RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED'); END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(jsonb_build_array('ventio-extension-release-v1',identity->>'tenantId',p_module)::text,0));
 SELECT * INTO source FROM public.ventio_wave2_definitions WHERE tenant_id=identity->>'tenantId' AND company_id=p_company AND branch_id=p_branch
  AND owner_id='' AND kind='customization' AND definition_id=p_module||':'||p_source||':'||p_doc FOR SHARE;
 SELECT * INTO target FROM public.ventio_extension_packages WHERE tenant_id=identity->>'tenantId' AND module_id=p_module AND version=p_target
   AND status='SUBMITTED' AND submitted_company_id=p_company AND submitted_branch_id=p_branch FOR SHARE;
 -- A reviewer in each affected branch may prepare against a candidate submitted
 -- in another branch only when the credential also covers that submission.
 IF target.module_id IS NULL THEN
  SELECT * INTO target FROM public.ventio_extension_packages WHERE tenant_id=identity->>'tenantId' AND module_id=p_module AND version=p_target AND status='SUBMITTED' FOR SHARE;
  IF target.module_id IS NOT NULL AND NOT ventio_security.wave2_allowed(ventio_security.identity_snapshot(p_digest,NULL,NULL),target.submitted_company_id,target.submitted_branch_id,'extension.package.review') THEN target:=NULL; END IF;
 END IF;
 IF source.body IS NULL OR target.package_json IS NULL OR
   (split_part(p_target,'.',1)::numeric,split_part(p_target,'.',2)::numeric,split_part(p_target,'.',3)::numeric)<=
   (split_part(p_source,'.',1)::numeric,split_part(p_source,'.',2)::numeric,split_part(p_source,'.',3)::numeric) THEN
  RETURN jsonb_build_object('status','CONFLICT','reasonCode','REBASE_RELEASE_UNAVAILABLE'); END IF;
 RETURN jsonb_build_object('status','REBASE_CANDIDATE','source',source.body,'sourceRevision',source.revision,
  'package',target.package_json,'packageSha256',target.package_sha256,
  'body',ventio_security.wave2_rebase_body(source.body,target.package_json,target.package_sha256));
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_prepare_rebase(p_digest text,p_company text,p_branch text,p_module text,p_source text,p_target text,p_doc text,p_revision bigint,p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE candidate jsonb; identity jsonb;
BEGIN
 candidate:=ventio_security.wave2_rebase_candidate(p_digest,p_company,p_branch,p_module,p_source,p_target,p_doc);
 IF candidate->>'status'<>'REBASE_CANDIDATE' THEN RETURN candidate; END IF;
 IF (candidate->>'sourceRevision')::bigint<>p_revision OR candidate->'body' IS DISTINCT FROM p_body THEN
  RETURN jsonb_build_object('status','CONFLICT','reasonCode','REBASE_CHANGED'); END IF;
 identity:=ventio_security.identity_snapshot(p_digest,p_company,p_branch);
 INSERT INTO public.ventio_wave2_customization_rebases(tenant_id,company_id,branch_id,module_id,target_version,doc_type,
  source_version,source_revision,source_sha256,target_sha256,body,prepared_by,credential_digest)
 VALUES(identity->>'tenantId',p_company,p_branch,p_module,p_target,p_doc,p_source,p_revision,candidate #>> '{source,baseSha256}',
  candidate->>'packageSha256',p_body,identity->>'actorId',p_digest)
 ON CONFLICT(tenant_id,company_id,branch_id,module_id,target_version,doc_type) DO UPDATE SET
  source_version=EXCLUDED.source_version,source_revision=EXCLUDED.source_revision,source_sha256=EXCLUDED.source_sha256,
  target_sha256=EXCLUDED.target_sha256,body=EXCLUDED.body,prepared_by=EXCLUDED.prepared_by,credential_digest=EXCLUDED.credential_digest,prepared_at=clock_timestamp();
 INSERT INTO public.ventio_wave2_events(tenant_id,company_id,branch_id,actor_id,event_type,subject_id,detail)
 VALUES(identity->>'tenantId',p_company,p_branch,identity->>'actorId','CUSTOMIZATION_REBASE_PREPARED',p_module||':'||p_target||':'||p_doc,
  jsonb_build_object('sourceVersion',p_source,'sourceRevision',p_revision,'targetSha256',candidate->>'packageSha256'));
 RETURN jsonb_build_object('status','REBASE_PREPARED','targetVersion',p_target);
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_guard_customization_upgrade()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE previous_version text; source public.ventio_wave2_definitions%ROWTYPE; prepared public.ventio_wave2_customization_rebases%ROWTYPE;
 identity jsonb; target_id text; actual bigint; request text; hashed text;
BEGIN
 IF NEW.status<>'APPROVED' OR (TG_OP='UPDATE' AND OLD.status='APPROVED') THEN RETURN NEW; END IF;
 SELECT version INTO previous_version FROM public.ventio_extension_packages WHERE tenant_id=NEW.tenant_id AND module_id=NEW.module_id
  AND version<>NEW.version AND status IN ('APPROVED','REVOKED') ORDER BY
   split_part(version,'.',1)::numeric DESC,split_part(version,'.',2)::numeric DESC,split_part(version,'.',3)::numeric DESC LIMIT 1;
 FOR source IN SELECT * FROM public.ventio_wave2_definitions WHERE tenant_id=NEW.tenant_id AND kind='customization' AND owner_id=''
  AND body->>'moduleId'=NEW.module_id AND body->>'moduleVersion'=previous_version ORDER BY company_id,branch_id,definition_id FOR UPDATE LOOP
  SELECT * INTO prepared FROM public.ventio_wave2_customization_rebases WHERE tenant_id=source.tenant_id AND company_id=source.company_id
   AND branch_id=source.branch_id AND module_id=NEW.module_id AND target_version=NEW.version AND doc_type=source.body->>'docType' FOR UPDATE;
  identity:=ventio_security.identity_snapshot(prepared.credential_digest,source.company_id,source.branch_id);
  IF prepared.body IS NULL OR prepared.source_version IS DISTINCT FROM previous_version OR prepared.source_revision<>source.revision OR prepared.source_sha256<>source.body->>'baseSha256' OR
    prepared.target_sha256<>NEW.package_sha256 OR prepared.body IS DISTINCT FROM ventio_security.wave2_rebase_body(source.body,NEW.package_json,NEW.package_sha256) OR
    identity->>'actorId' IS DISTINCT FROM prepared.prepared_by OR NOT ventio_security.wave2_allowed(identity,source.company_id,source.branch_id,'platform.customizations.manage') THEN
   RAISE EXCEPTION 'Every affected customization requires a current compatible release rebase' USING ERRCODE='23514',CONSTRAINT='wave2_customization_upgrade_guard'; END IF;
  target_id:=NEW.module_id||':'||NEW.version||':'||(source.body->>'docType');
  IF EXISTS(SELECT FROM public.ventio_wave2_definitions WHERE tenant_id=source.tenant_id AND company_id=source.company_id AND branch_id=source.branch_id
   AND owner_id='' AND kind='customization' AND definition_id=target_id) THEN RAISE EXCEPTION 'Target customization already exists' USING ERRCODE='23514'; END IF;
  INSERT INTO public.ventio_wave2_definitions VALUES(source.tenant_id,source.company_id,source.branch_id,'','customization',target_id,1,prepared.body,prepared.prepared_by,clock_timestamp());
  request:=gen_random_uuid()::text;
  hashed:=encode(sha256(convert_to(prepared.body::text,'UTF8')),'hex');
  INSERT INTO public.ventio_wave2_revisions(tenant_id,company_id,branch_id,owner_id,kind,definition_id,revision,request_id,request_hash,body,saved_by)
   VALUES(source.tenant_id,source.company_id,source.branch_id,'','customization',target_id,1,request,hashed,prepared.body,prepared.prepared_by);
  INSERT INTO public.ventio_wave2_events(tenant_id,company_id,branch_id,actor_id,event_type,subject_id,detail)
   VALUES(source.tenant_id,source.company_id,source.branch_id,prepared.prepared_by,'CUSTOMIZATION_REBASED',target_id,
    jsonb_build_object('sourceVersion',previous_version,'sourceRevision',source.revision,'targetSha256',NEW.package_sha256));
  -- Immutable revision history retains the old overlay. Only the active
  -- definition moves forward, so repeated upgrades remain within the bound.
  DELETE FROM public.ventio_wave2_definitions WHERE tenant_id=source.tenant_id AND company_id=source.company_id
   AND branch_id=source.branch_id AND owner_id='' AND kind='customization' AND definition_id=source.definition_id AND revision=source.revision;
 END LOOP;
 RETURN NEW;
END $fn$;
DROP TRIGGER IF EXISTS wave2_customization_upgrade_guard ON public.ventio_extension_packages;
CREATE TRIGGER wave2_customization_upgrade_guard BEFORE INSERT OR UPDATE OF status ON public.ventio_extension_packages
 FOR EACH ROW EXECUTE FUNCTION ventio_security.wave2_guard_customization_upgrade();

DROP TRIGGER IF EXISTS wave2_rebase_lock ON public.ventio_wave2_customization_rebases;
CREATE TRIGGER wave2_rebase_lock BEFORE INSERT OR UPDATE OR DELETE ON public.ventio_wave2_customization_rebases
 FOR EACH STATEMENT EXECUTE FUNCTION ventio_security.lock_recovery_mutation();
DROP TRIGGER IF EXISTS wave2_rebase_mark ON public.ventio_wave2_customization_rebases;
CREATE TRIGGER wave2_rebase_mark AFTER INSERT OR UPDATE OR DELETE ON public.ventio_wave2_customization_rebases
 FOR EACH STATEMENT EXECUTE FUNCTION ventio_security.mark_recovery_mutation();
