-- No HTTP handler executes physical backup/restore. A current authorized
-- request is delivered to the fixed Windows operator under a private lease.
-- Machine-wide execution additionally requires local elevated approval.
CREATE OR REPLACE FUNCTION ventio_security.wave2_prepare_operation(p_digest text,p_company text,p_branch text,p_id text,p_operation text,p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE identity jsonb; saved public.ventio_wave2_operations%ROWTYPE; hashed text; body jsonb:=p_body;
 policy public.ventio_wave2_definitions%ROWTYPE; plan public.ventio_wave2_operations%ROWTYPE;
BEGIN
 identity:=ventio_security.identity_snapshot(p_digest,p_company,p_branch);
 IF NOT ventio_security.wave2_allowed(identity,p_company,p_branch,'platform.operations.manage') THEN
  RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED'); END IF;
 IF p_id IS NULL OR p_id !~ '^[0-9a-f-]{36}$' OR p_operation IS NULL OR p_operation NOT IN ('APPLY_POLICY','BACKUP_NOW','RESTORE_PLAN','RESTORE') OR
   jsonb_typeof(p_body) IS DISTINCT FROM 'object' OR octet_length(p_body::text)>2048 THEN
  RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_OPERATION'); END IF;
 IF (p_operation IN ('APPLY_POLICY','BACKUP_NOW') AND p_body<>'{}'::jsonb) OR
  (p_operation='RESTORE_PLAN' AND (p_body-ARRAY['backupName'])<>'{}'::jsonb) OR
  (p_operation='RESTORE' AND (p_body-ARRAY['backupName','planOperationId','planSha256'])<>'{}'::jsonb) OR
  (p_operation IN ('RESTORE_PLAN','RESTORE') AND (p_body->>'backupName' IS NULL OR p_body->>'backupName' !~ '^ventio-postgresql-before-upgrade-[0-9]{8}T[0-9]{9}Z-[0-9a-f]{32}$')) THEN
  RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_OPERATION'); END IF;
 hashed:=encode(sha256(convert_to(jsonb_build_array(p_operation,p_body)::text,'UTF8')),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended('wave2-operation:'||p_id,0));
 SELECT * INTO saved FROM public.ventio_wave2_operations WHERE operation_id=p_id;
 IF FOUND THEN
  IF saved.tenant_id<>identity->>'tenantId' OR saved.company_id<>p_company OR saved.branch_id<>p_branch OR saved.actor_id<>identity->>'actorId' OR saved.request_hash<>hashed THEN
   RETURN jsonb_build_object('status','CONFLICT','reasonCode','OPERATION_ID_REUSED'); END IF;
  RETURN jsonb_build_object('status','OPERATION','operationId',p_id,'state',saved.state); END IF;
 IF p_operation='APPLY_POLICY' THEN
  SELECT * INTO policy FROM public.ventio_wave2_definitions WHERE tenant_id=identity->>'tenantId' AND company_id=p_company AND branch_id=p_branch
   AND kind='backup_policy' AND owner_id='' AND definition_id='scope' FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','REJECTED','reasonCode','BACKUP_POLICY_REQUIRED'); END IF;
  body:=jsonb_build_object('policy',policy.body,'policyRevision',policy.revision,'policySha256',encode(sha256(convert_to(policy.body::text,'UTF8')),'hex'));
 ELSIF p_operation='RESTORE' THEN
  IF coalesce(p_body->>'planOperationId','') !~ '^[0-9a-f-]{36}$' OR coalesce(p_body->>'planSha256','') !~ '^[0-9a-f]{64}$' THEN
   RETURN jsonb_build_object('status','REJECTED','reasonCode','RESTORE_PLAN_REQUIRED'); END IF;
  SELECT * INTO plan FROM public.ventio_wave2_operations WHERE operation_id=p_body->>'planOperationId' AND tenant_id=identity->>'tenantId'
   AND company_id=p_company AND branch_id=p_branch AND operation='RESTORE_PLAN' AND state='SUCCEEDED' AND updated_at>clock_timestamp()-interval '1 hour';
  IF NOT FOUND OR plan.body->>'backupName' IS DISTINCT FROM p_body->>'backupName' OR plan.result->>'planSha256' IS DISTINCT FROM p_body->>'planSha256' THEN
   RETURN jsonb_build_object('status','CONFLICT','reasonCode','RESTORE_PLAN_CHANGED'); END IF;
 END IF;
 IF (SELECT count(*) FROM public.ventio_wave2_operations WHERE tenant_id=identity->>'tenantId' AND company_id=p_company AND branch_id=p_branch
  AND state IN ('AWAITING_LOCAL_APPROVAL','RUNNING'))>=20 THEN RETURN jsonb_build_object('status','REJECTED','reasonCode','OPERATION_LIMIT'); END IF;
 INSERT INTO public.ventio_wave2_operations(operation_id,tenant_id,company_id,branch_id,actor_id,operation,request_hash,body,credential_digest)
 VALUES(p_id,identity->>'tenantId',p_company,p_branch,identity->>'actorId',p_operation,hashed,body,p_digest);
 INSERT INTO public.ventio_wave2_events(tenant_id,company_id,branch_id,actor_id,event_type,subject_id,detail)
 VALUES(identity->>'tenantId',p_company,p_branch,identity->>'actorId','OPERATION_REQUESTED',p_id,jsonb_build_object('operation',p_operation));
 RETURN jsonb_build_object('status','OPERATION','operationId',p_id,'state','AWAITING_LOCAL_APPROVAL');
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_operations_list(p_digest text,p_company text,p_branch text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE identity jsonb; entries jsonb;
BEGIN
 identity:=ventio_security.identity_snapshot(p_digest,p_company,p_branch);
 IF NOT ventio_security.wave2_allowed(identity,p_company,p_branch,'platform.operations.manage') THEN RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED'); END IF;
 SELECT coalesce(jsonb_agg(item ORDER BY created_at DESC),'[]') INTO entries FROM (
  SELECT created_at,jsonb_build_object('operationId',operation_id,'operation',operation,'state',state,'actorId',actor_id,
   'body',body,'result',result,'scheduledFor',scheduled_for,'attempt',attempt,'createdAtUtc',created_at,'updatedAtUtc',updated_at) item
  FROM public.ventio_wave2_operations WHERE tenant_id=identity->>'tenantId' AND company_id=p_company AND branch_id=p_branch ORDER BY created_at DESC LIMIT 100) page;
 RETURN jsonb_build_object('status','OPERATIONS','operations',entries);
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_operation_offers()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE approved public.ventio_wave2_operations%ROWTYPE; pending public.ventio_wave2_operations%ROWTYPE;
 identity jsonb; definition jsonb; day date:=timezone('UTC',clock_timestamp())::date; latest public.ventio_wave2_operations%ROWTYPE;
 entries jsonb:='[]'; next_attempt integer;
BEGIN
 IF NOT ventio_security.recovery_guard() OR NOT pg_try_advisory_xact_lock(86744322) THEN RETURN '[]'; END IF;
 -- Only an explicitly locally approved policy arms a schedule. Each run also
 -- rechecks current credentials, direct authority, scope and policy revision.
 FOR approved IN SELECT DISTINCT ON(tenant_id,company_id,branch_id) * FROM public.ventio_wave2_operations
  WHERE operation='APPLY_POLICY' AND state='SUCCEEDED' ORDER BY tenant_id,company_id,branch_id,created_at DESC LOOP
  identity:=ventio_security.identity_snapshot(approved.credential_digest,approved.company_id,approved.branch_id);
  IF NOT ventio_security.wave2_allowed(identity,approved.company_id,approved.branch_id,'platform.operations.manage') THEN CONTINUE; END IF;
  SELECT body INTO definition FROM public.ventio_wave2_definitions WHERE tenant_id=approved.tenant_id AND company_id=approved.company_id AND branch_id=approved.branch_id
   AND owner_id='' AND kind='backup_policy' AND definition_id='scope';
  IF definition IS DISTINCT FROM approved.body->'policy' OR NOT coalesce((definition->>'enabled')::boolean,false) OR
    (timezone('UTC',clock_timestamp())::time)<(definition->>'utcTime')::time THEN CONTINUE; END IF;
  SELECT * INTO latest FROM public.ventio_wave2_operations WHERE policy_operation_id=approved.operation_id AND scheduled_for=day ORDER BY attempt DESC LIMIT 1;
  next_attempt:=1;
  IF FOUND THEN
   IF latest.state<>'FAILED' OR latest.result->>'retryable' IS DISTINCT FROM 'true' OR latest.attempt>=(definition->>'maximumAttempts')::int OR
    latest.updated_at+make_interval(mins=>(definition->>'retryMinutes')::int)>clock_timestamp() THEN CONTINUE; END IF;
   next_attempt:=latest.attempt+1;
  END IF;
  INSERT INTO public.ventio_wave2_operations(operation_id,tenant_id,company_id,branch_id,actor_id,operation,request_hash,body,credential_digest,scheduled_for,policy_operation_id,attempt)
  VALUES(gen_random_uuid()::text,approved.tenant_id,approved.company_id,approved.branch_id,approved.actor_id,'BACKUP_NOW',approved.request_hash,
   approved.body || jsonb_build_object('policyOperationId',approved.operation_id,'scheduledFor',day),approved.credential_digest,day,approved.operation_id,next_attempt);
 END LOOP;
 FOR pending IN SELECT * FROM public.ventio_wave2_operations WHERE state='AWAITING_LOCAL_APPROVAL' ORDER BY coalesce(offer_until,'-infinity'::timestamptz),created_at LIMIT 100 FOR UPDATE SKIP LOCKED LOOP
  identity:=ventio_security.identity_snapshot(pending.credential_digest,pending.company_id,pending.branch_id);
  IF (pending.body ? 'policy' AND pending.body->'policy' IS DISTINCT FROM (SELECT body FROM public.ventio_wave2_definitions WHERE tenant_id=pending.tenant_id AND company_id=pending.company_id AND branch_id=pending.branch_id AND kind='backup_policy' AND owner_id='' AND definition_id='scope')) OR
   NOT ventio_security.wave2_allowed(identity,pending.company_id,pending.branch_id,'platform.operations.manage') OR pending.created_at<clock_timestamp()-interval '1 day' THEN
   UPDATE public.ventio_wave2_operations SET state='EXPIRED',updated_at=clock_timestamp(),result=jsonb_build_object('code','AUTHORIZATION_OR_REQUEST_EXPIRED') WHERE operation_id=pending.operation_id;
   CONTINUE; END IF;
  pending.offer_id:=coalesce(pending.offer_id,gen_random_uuid()::text);pending.offer_until:=clock_timestamp()+interval '2 minutes';
  UPDATE public.ventio_wave2_operations SET offer_id=pending.offer_id,offer_until=pending.offer_until WHERE operation_id=pending.operation_id;
  entries:=entries || jsonb_build_array(jsonb_build_object('formatVersion',1,'operationId',pending.operation_id,'offerId',pending.offer_id,
   'operation',pending.operation,'tenantId',pending.tenant_id,'companyId',pending.company_id,'branchId',pending.branch_id,'requestedBy',pending.actor_id,
   'body',pending.body,'requestHash',pending.request_hash,'validUntilUtc',pending.offer_until,'scheduled',pending.scheduled_for IS NOT NULL));
 END LOOP;
 RETURN entries;
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_operation_result(p_id text,p_offer text,p_result jsonb)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE saved public.ventio_wave2_operations%ROWTYPE;
BEGIN
 IF NOT ventio_security.recovery_guard() THEN RAISE EXCEPTION 'Recovery admission required' USING ERRCODE='28000'; END IF;
 IF jsonb_typeof(p_result) IS DISTINCT FROM 'object' OR octet_length(p_result::text)>32768 OR
  (p_result-ARRAY['operationId','offerId','state','code','backupName','manifestSha256','planSha256','restoreRequiresRecovery','deletedBackups','retryable','completedAtUtc','operation','tenantId','companyId','branchId','actorId'])<>'{}'::jsonb OR
  p_result->>'state' IS NULL OR p_result->>'state' NOT IN ('RUNNING','SUCCEEDED','FAILED') OR
  p_result->>'operationId' IS DISTINCT FROM p_id OR p_result->>'offerId' IS DISTINCT FROM p_offer THEN RAISE EXCEPTION 'Invalid operation outcome' USING ERRCODE='22023'; END IF;
 SELECT * INTO saved FROM public.ventio_wave2_operations WHERE operation_id=p_id AND offer_id=p_offer FOR UPDATE;
 IF NOT FOUND THEN
  -- Restoring a prior cluster can remove the request itself. The independent
  -- protected local journal survives; admit only its fixed restore-complete
  -- result as an audit record after Recovery Authority admission resumes.
  IF p_result->>'state'<>'SUCCEEDED' OR p_result->>'operation' IS DISTINCT FROM 'RESTORE' OR
    p_result->>'code' IS DISTINCT FROM 'RESTORED_RECOVERY_AUTHORITY_RECONCILIATION_REQUIRED' OR
    NOT EXISTS(SELECT FROM public.ventio_identity_branches WHERE tenant_id=p_result->>'tenantId' AND company_id=p_result->>'companyId' AND branch_id=p_result->>'branchId') THEN RETURN false; END IF;
  INSERT INTO public.ventio_wave2_operations(operation_id,tenant_id,company_id,branch_id,actor_id,operation,request_hash,body,offer_id,state)
  VALUES(p_id,p_result->>'tenantId',p_result->>'companyId',p_result->>'branchId',p_result->>'actorId','RESTORE','reconciled-local-restore',
   jsonb_build_object('backupName',p_result->>'backupName','reconciledFromProtectedLocalJournal',true),p_offer,'RUNNING');
  SELECT * INTO saved FROM public.ventio_wave2_operations WHERE operation_id=p_id;
 END IF;
 IF saved.state IN ('SUCCEEDED','FAILED') OR (saved.state=p_result->>'state' AND saved.result=p_result) THEN RETURN true; END IF;
 -- Filesystem claim can survive service/DB downtime and lease expiry. The
 -- private offer identity still fences an old or unrelated result.
 UPDATE public.ventio_wave2_operations SET state=p_result->>'state',result=p_result,updated_at=clock_timestamp() WHERE operation_id=p_id;
 INSERT INTO public.ventio_wave2_events(tenant_id,company_id,branch_id,actor_id,event_type,subject_id,detail)
 VALUES(saved.tenant_id,saved.company_id,saved.branch_id,saved.actor_id,'OPERATION_'||(p_result->>'state'),p_id,
  jsonb_build_object('operation',saved.operation,'code',p_result->>'code','backupName',p_result->>'backupName'));
 RETURN true;
END $fn$;
