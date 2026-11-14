-- Capture the actual affected records, including declarative effect targets
-- and amendment documents, in the very same transaction as their mutations.
CREATE OR REPLACE FUNCTION ventio_security.wave2_capture_record_activity()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE identity jsonb; command text:=nullif(current_setting('ventio.command_id',true),''); operation text;
BEGIN
 IF command IS NULL THEN
  IF nullif(current_setting('ventio.wave2_schema_tenant',true),'')=NEW.tenant_id AND
    nullif(current_setting('ventio.wave2_schema_module',true),'')=NEW.module_id AND
    (pg_has_role(session_user,'ventio_identity_api','MEMBER') OR pg_has_role(session_user,'ventio_identity_admin','MEMBER')) THEN
    INSERT INTO public.ventio_wave2_events(tenant_id,company_id,branch_id,actor_id,event_type,subject_id,detail)
    VALUES(NEW.tenant_id,NEW.company_id,NEW.branch_id,coalesce(nullif(current_setting('ventio.wave2_schema_actor',true),''),'trusted-operator'),
     'RECORD_ACTIVITY',NEW.record_id,jsonb_build_object('moduleId',NEW.module_id,'docType',NEW.doc_type,'revision',NEW.revision,
     'commandId','schema:'||NEW.module_id||':'||current_setting('ventio.wave2_schema_version',true),'operation','schema.migrate'))
    ON CONFLICT(tenant_id,company_id,branch_id,subject_id,(detail->>'moduleId'),(detail->>'docType'),(detail->>'commandId')) WHERE event_type='RECORD_ACTIVITY'
    DO UPDATE SET detail=EXCLUDED.detail;
    RETURN NEW;
  END IF;
  IF pg_has_role(session_user,'ventio_identity_admin','MEMBER') OR pg_has_role(session_user,'ventio_migrator','MEMBER') THEN RETURN NEW; END IF;
  RAISE EXCEPTION 'Record activity requires an authoritative command' USING ERRCODE='42501'; END IF;
 identity:=ventio_security.identity_snapshot(nullif(current_setting('ventio.credential_digest',true),''),NEW.company_id,NEW.branch_id);
 IF identity->>'tenantId' IS DISTINCT FROM NEW.tenant_id OR NOT ventio_security.scope_allows(NEW.tenant_id,NEW.company_id,NEW.branch_id,'audit_write',command,identity->>'actorId',NULL) THEN
  RAISE EXCEPTION 'Record activity context denied' USING ERRCODE='42501'; END IF;
 operation:=current_setting('ventio.command_type',true);
 INSERT INTO public.ventio_wave2_events(tenant_id,company_id,branch_id,actor_id,event_type,subject_id,detail)
 VALUES(NEW.tenant_id,NEW.company_id,NEW.branch_id,identity->>'actorId','RECORD_ACTIVITY',NEW.record_id,
  jsonb_build_object('moduleId',NEW.module_id,'docType',NEW.doc_type,'revision',NEW.revision,'commandId',command,'operation',operation,
   'effectTarget',NEW.record_id IS DISTINCT FROM current_setting('ventio.aggregate_id',true),
   'documentStatus',NEW.document_status,'deleted',NEW.deleted_at IS NOT NULL))
 ON CONFLICT(tenant_id,company_id,branch_id,subject_id,(detail->>'moduleId'),(detail->>'docType'),(detail->>'commandId')) WHERE event_type='RECORD_ACTIVITY'
 DO UPDATE SET detail=EXCLUDED.detail;
 RETURN NEW;
END $fn$;
DROP TRIGGER IF EXISTS wave2_record_activity_capture ON public.ventio_records;
CREATE TRIGGER wave2_record_activity_capture AFTER INSERT OR UPDATE ON public.ventio_records
 FOR EACH ROW EXECUTE FUNCTION ventio_security.wave2_capture_record_activity();

-- Historical source commands can be recovered from existing immutable outbox
-- metadata. No payload fields or inferred cross-record effects are fabricated.
DROP POLICY IF EXISTS wave2_history_seed_read ON public.ventio_outbox;
CREATE POLICY wave2_history_seed_read ON public.ventio_outbox FOR SELECT TO ventio_owner
 USING(current_setting('ventio.wave2_history_seed',true)='1');
DROP POLICY IF EXISTS wave2_history_seed_journal ON public.ventio_command_journal;
CREATE POLICY wave2_history_seed_journal ON public.ventio_command_journal FOR SELECT TO ventio_owner
 USING(current_setting('ventio.wave2_history_seed',true)='1');
DROP POLICY IF EXISTS wave2_history_seed_audit ON public.ventio_audit_entries;
CREATE POLICY wave2_history_seed_audit ON public.ventio_audit_entries FOR SELECT TO ventio_owner
 USING(current_setting('ventio.wave2_history_seed',true)='1');
CREATE OR REPLACE FUNCTION ventio_security.wave2_seed_record_history()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE last_id bigint; high_id bigint;
BEGIN
 PERFORM set_config('ventio.wave2_history_seed','1',true);
 SELECT coalesce((result->>'outboxId')::bigint,0) INTO last_id FROM public.ventio_wave2_admin_requests
  WHERE tenant_id='__platform__' AND actor_id='__migration__' AND request_id='wave2-history-seed';
 last_id:=coalesce(last_id,0);
 SELECT coalesce(max(outbox_id),last_id) INTO high_id FROM public.ventio_outbox;
 INSERT INTO public.ventio_wave2_events(tenant_id,company_id,branch_id,actor_id,event_type,subject_id,detail,created_at)
 SELECT o.tenant_id,o.company_id,o.branch_id,j.actor_id,'RECORD_ACTIVITY',o.payload->>'aggregateId',
  jsonb_build_object('moduleId',coalesce(o.payload->>'moduleId',b.module_id),'docType',coalesce(o.payload->>'docType',b.doc_type),
   'revision',o.payload->'recordRevision','commandId',o.command_id,'operation',o.payload->>'operation','historicalSource',true),o.inserted_at
 FROM public.ventio_outbox o JOIN public.ventio_command_journal j ON j.tenant_id=o.tenant_id AND j.company_id=o.company_id AND j.branch_id=o.branch_id AND j.command_id=o.command_id
 LEFT JOIN public.ventio_audit_entries a ON a.tenant_id=o.tenant_id AND a.company_id=o.company_id AND a.branch_id=o.branch_id AND a.command_id=o.command_id
 LEFT JOIN LATERAL (SELECT min(module_id) module_id,min(doc_type) doc_type FROM ventio_security.command_bindings
   WHERE command_type=a.event_type HAVING count(DISTINCT (module_id,doc_type))=1) b ON true
 WHERE o.outbox_id>last_id AND o.outbox_id<=high_id AND o.payload->>'aggregateId' IS NOT NULL AND coalesce(o.payload->>'moduleId',b.module_id) IS NOT NULL
 ON CONFLICT(tenant_id,company_id,branch_id,subject_id,(detail->>'moduleId'),(detail->>'docType'),(detail->>'commandId')) WHERE event_type='RECORD_ACTIVITY' DO NOTHING;
 INSERT INTO public.ventio_wave2_admin_requests VALUES('__platform__','__migration__','wave2-history-seed','internal',jsonb_build_object('outboxId',high_id))
 ON CONFLICT(tenant_id,actor_id,request_id) DO UPDATE SET result=EXCLUDED.result;
 PERFORM set_config('ventio.wave2_history_seed','',true);
END $fn$;
SELECT ventio_security.wave2_seed_record_history();

CREATE OR REPLACE FUNCTION ventio_security.wave2_history(p_digest text,p_company text,p_branch text,p_module text,p_version text,p_doc text,p_record text,p_before bigint,p_limit integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE resolved jsonb; entries jsonb; next_id bigint; has_more boolean; before_time timestamptz; next_time timestamptz;
BEGIN
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR (p_before IS NOT NULL AND p_before<1) THEN RAISE EXCEPTION 'Invalid activity cursor' USING ERRCODE='22023'; END IF;
 resolved:=ventio_security.resolve_extension_read_identity(p_digest,p_company,p_branch,p_module,p_version,p_doc);
 IF resolved->'package' IS NULL OR resolved->'package'='null'::jsonb THEN RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED'); END IF;
 IF p_before IS NOT NULL THEN
  SELECT created_at INTO before_time FROM public.ventio_wave2_events WHERE event_id=p_before AND tenant_id=resolved #>> '{identity,tenantId}'
   AND company_id=p_company AND branch_id=p_branch AND subject_id=p_record AND event_type='RECORD_ACTIVITY' AND detail->>'moduleId'=p_module AND detail->>'docType'=p_doc;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invalid activity cursor' USING ERRCODE='22023'; END IF;
 END IF;
 SELECT coalesce(jsonb_agg(item ORDER BY created_at DESC,event_id DESC),'[]'),(array_agg(event_id ORDER BY created_at,event_id))[1] INTO entries,next_id FROM (
  SELECT event_id,created_at,jsonb_build_object('eventId',event_id::text,'actorId',actor_id,'occurredAtUtc',created_at,
   'revision',detail->'revision','commandId',detail->'commandId','operation',detail->'operation',
   'effectTarget',detail->'effectTarget','historicalSource',detail->'historicalSource','documentStatus',detail->'documentStatus','deleted',detail->'deleted','operationKey',detail->'operationKey','sourceCommand',detail->'sourceCommand') item
  FROM public.ventio_wave2_events WHERE tenant_id=resolved #>> '{identity,tenantId}' AND company_id=p_company AND branch_id=p_branch
   AND event_type='RECORD_ACTIVITY' AND subject_id=p_record AND detail->>'moduleId'=p_module AND detail->>'docType'=p_doc
   AND (p_before IS NULL OR (created_at,event_id)<(before_time,p_before)) ORDER BY created_at DESC,event_id DESC LIMIT p_limit) page;
 SELECT created_at INTO next_time FROM public.ventio_wave2_events WHERE event_id=next_id;
 SELECT EXISTS(SELECT FROM public.ventio_wave2_events WHERE tenant_id=resolved #>> '{identity,tenantId}' AND company_id=p_company AND branch_id=p_branch
   AND event_type='RECORD_ACTIVITY' AND subject_id=p_record AND detail->>'moduleId'=p_module AND detail->>'docType'=p_doc AND (created_at,event_id)<(next_time,next_id)) INTO has_more;
 RETURN jsonb_build_object('status','HISTORY','entries',entries,'hasMore',has_more,'nextCursor',CASE WHEN has_more THEN next_id::text ELSE NULL END,
  'historicalCoverage','SOURCE_COMMANDS_BEFORE_WAVE2_CAPTURE');
END $fn$;
CREATE OR REPLACE FUNCTION ventio_security.wave2_history(p_digest text,p_company text,p_branch text,p_module text,p_version text,p_doc text,p_record text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
 SELECT ventio_security.wave2_history(p_digest,p_company,p_branch,p_module,p_version,p_doc,p_record,NULL,100)
$fn$;

-- The non-login owner can migrate only the tenant/module selected inside the
-- private validator. Runtime remains subject to its ordinary signed RLS proof.
DROP POLICY IF EXISTS wave2_scoped_migration_select ON public.ventio_records;
CREATE POLICY wave2_scoped_migration_select ON public.ventio_records FOR SELECT TO ventio_owner
 USING(pg_has_role(session_user,'ventio_identity_api','MEMBER') AND tenant_id=nullif(current_setting('ventio.wave2_schema_tenant',true),'') AND module_id=nullif(current_setting('ventio.wave2_schema_module',true),''));
DROP POLICY IF EXISTS wave2_scoped_migration_update ON public.ventio_records;
CREATE POLICY wave2_scoped_migration_update ON public.ventio_records FOR UPDATE TO ventio_owner
 USING(pg_has_role(session_user,'ventio_identity_api','MEMBER') AND tenant_id=nullif(current_setting('ventio.wave2_schema_tenant',true),'') AND module_id=nullif(current_setting('ventio.wave2_schema_module',true),''))
 WITH CHECK(pg_has_role(session_user,'ventio_identity_api','MEMBER') AND tenant_id=nullif(current_setting('ventio.wave2_schema_tenant',true),'') AND module_id=nullif(current_setting('ventio.wave2_schema_module',true),''));
