-- Management privileges are direct and credential bounded. Business role
-- managers cannot manufacture platform administration through a role.
CREATE OR REPLACE FUNCTION ventio_security.wave2_allowed(identity jsonb, company text, branch text, permission text)
RETURNS boolean LANGUAGE sql SECURITY DEFINER
SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
 SELECT identity IS NOT NULL AND EXISTS(SELECT FROM jsonb_array_elements(identity->'scopeGrants') g(item)
   WHERE item->>'companyId'=company AND item->>'branchId'=branch AND item->>'permission'=permission)
 AND (permission NOT IN ('platform.organizations.manage','platform.configuration.manage',
   'platform.customizations.manage','platform.operations.manage') OR EXISTS(
   SELECT FROM public.ventio_identity_grants g WHERE g.tenant_id=identity->>'tenantId'
    AND g.actor_id=identity->>'actorId' AND g.company_id=company AND g.branch_id=branch AND g.permission=permission))
$fn$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_scope_active(p_tenant text,p_company text,p_branch text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE archived_value boolean;
BEGIN
 SELECT archived INTO archived_value FROM public.ventio_wave2_organizations WHERE tenant_id=p_tenant FOR SHARE;
 IF coalesce(archived_value,false) THEN RETURN false; END IF;
 SELECT archived INTO archived_value FROM public.ventio_wave2_companies WHERE tenant_id=p_tenant AND company_id=p_company FOR SHARE;
 IF coalesce(archived_value,false) THEN RETURN false; END IF;
 SELECT archived INTO archived_value FROM public.ventio_wave2_branches
   WHERE tenant_id=p_tenant AND company_id=p_company AND branch_id=p_branch FOR SHARE;
 RETURN NOT coalesce(archived_value,false);
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_register_scope()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
BEGIN
 IF NOT ventio_security.wave2_scope_active(NEW.tenant_id,NEW.company_id,NEW.branch_id) THEN
   RAISE EXCEPTION 'Archived organization scope' USING ERRCODE='42501';
 END IF;
 INSERT INTO public.ventio_wave2_organizations(tenant_id,display_name) VALUES(NEW.tenant_id,NEW.tenant_id) ON CONFLICT DO NOTHING;
 INSERT INTO public.ventio_wave2_companies(tenant_id,company_id,display_name) VALUES(NEW.tenant_id,NEW.company_id,NEW.company_id) ON CONFLICT DO NOTHING;
 INSERT INTO public.ventio_wave2_branches(tenant_id,company_id,branch_id,display_name)
   VALUES(NEW.tenant_id,NEW.company_id,NEW.branch_id,NEW.branch_id) ON CONFLICT DO NOTHING;
 RETURN NEW;
END $fn$;
DROP TRIGGER IF EXISTS wave2_register_scope ON public.ventio_identity_branches;
CREATE TRIGGER wave2_register_scope AFTER INSERT ON public.ventio_identity_branches
 FOR EACH ROW EXECUTE FUNCTION ventio_security.wave2_register_scope();

-- The original current-user/device/credential/role/ceiling checks are preserved
-- in wave2_identity_snapshot_base (generated from the accepted implementation).
CREATE OR REPLACE FUNCTION ventio_security.identity_snapshot(p_digest text,p_company text,p_branch text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE identity jsonb; grants jsonb; roles jsonb;
BEGIN
 identity:=ventio_security.wave2_identity_snapshot_base(p_digest,p_company,p_branch);
 IF identity IS NULL THEN RETURN NULL; END IF;
 SELECT coalesce(jsonb_agg(item ORDER BY item->>'companyId',item->>'branchId',item->>'permission'),'[]') INTO grants
 FROM jsonb_array_elements(identity->'scopeGrants') g(item)
 WHERE ventio_security.wave2_scope_active(identity->>'tenantId',item->>'companyId',item->>'branchId');
 SELECT coalesce(jsonb_agg(item),'[]') INTO roles FROM jsonb_array_elements(coalesce(identity->'roles','[]')) r(item)
 WHERE ventio_security.wave2_scope_active(identity->>'tenantId',item->>'companyId',item->>'branchId');
 RETURN identity || jsonb_build_object('scopeGrants',grants,'roles',roles,
  'companyIds',(SELECT coalesce(jsonb_agg(DISTINCT item->>'companyId'),'[]') FROM jsonb_array_elements(grants) g(item)),
  'branchIds',(SELECT coalesce(jsonb_agg(DISTINCT item->>'branchId'),'[]') FROM jsonb_array_elements(grants) g(item)),
  'permissions',(SELECT coalesce(jsonb_agg(DISTINCT item->>'permission'),'[]') FROM jsonb_array_elements(grants) g(item)));
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_tenant_manager(identity jsonb)
RETURNS boolean LANGUAGE sql SECURITY DEFINER
SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
 SELECT identity IS NOT NULL AND NOT EXISTS(SELECT FROM public.ventio_identity_branches b
  WHERE b.tenant_id=identity->>'tenantId'
  AND (EXISTS(SELECT FROM public.ventio_identity_grants g WHERE g.tenant_id=b.tenant_id AND g.company_id=b.company_id AND g.branch_id=b.branch_id)
    OR EXISTS(SELECT FROM public.ventio_identity_role_assignments a WHERE a.tenant_id=b.tenant_id AND a.company_id=b.company_id AND a.branch_id=b.branch_id))
  AND NOT ventio_security.wave2_allowed(identity,b.company_id,b.branch_id,'platform.organizations.manage'))
$fn$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_organization_snapshot(p_digest text,p_company text,p_branch text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE identity jsonb; tenant_manager boolean; entities jsonb;
BEGIN
 identity:=ventio_security.wave2_identity_snapshot_base(p_digest,NULL,NULL);
 IF NOT ventio_security.wave2_allowed(identity,p_company,p_branch,'platform.organizations.manage') OR
    NOT ventio_security.wave2_scope_active(identity->>'tenantId',p_company,p_branch) THEN
  RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED'); END IF;
 tenant_manager:=ventio_security.wave2_tenant_manager(identity);
 SELECT coalesce(jsonb_agg(item ORDER BY kind,id),'[]') INTO entities FROM (
  SELECT 'organization' kind,o.tenant_id id,jsonb_build_object('kind','organization','id',o.tenant_id,'parentId',NULL,
   'displayName',o.display_name,'revision',o.revision,'archived',o.archived) item
   FROM public.ventio_wave2_organizations o WHERE o.tenant_id=identity->>'tenantId'
  UNION ALL
  SELECT 'company',c.company_id,jsonb_build_object('kind','company','id',c.company_id,'parentId',NULL,
   'displayName',c.display_name,'revision',c.revision,'archived',c.archived)
   FROM public.ventio_wave2_companies c WHERE c.tenant_id=identity->>'tenantId' AND (tenant_manager OR EXISTS(
    SELECT FROM public.ventio_identity_branches b WHERE b.tenant_id=c.tenant_id AND b.company_id=c.company_id
     AND ventio_security.wave2_allowed(identity,b.company_id,b.branch_id,'platform.organizations.manage')))
  UNION ALL
  SELECT 'branch',b.branch_id,jsonb_build_object('kind','branch','id',b.branch_id,'parentId',b.company_id,
   'displayName',b.display_name,'revision',b.revision,'archived',b.archived)
   FROM public.ventio_wave2_branches b WHERE b.tenant_id=identity->>'tenantId' AND (tenant_manager OR
    ventio_security.wave2_allowed(identity,b.company_id,b.branch_id,'platform.organizations.manage'))) all_entities;
 RETURN jsonb_build_object('status','ORGANIZATION','entities',entities,'canCreateCompany',tenant_manager);
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_organization_change(p_digest text,p_company text,p_branch text,p_change jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE identity jsonb; kind text:=p_change->>'kind'; id text:=p_change->>'id'; parent text:=p_change->>'parentId';
 title text:=p_change->>'displayName'; expected bigint; actual bigint; archived_value boolean;
 tenant_manager boolean; request_hash text; saved public.ventio_wave2_admin_requests%ROWTYPE; result jsonb;
BEGIN
 identity:=ventio_security.wave2_identity_snapshot_base(p_digest,NULL,NULL);
 IF NOT ventio_security.wave2_allowed(identity,p_company,p_branch,'platform.organizations.manage') OR
    NOT ventio_security.wave2_scope_active(identity->>'tenantId',p_company,p_branch) THEN
  RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED'); END IF;
 IF jsonb_typeof(p_change) IS DISTINCT FROM 'object' OR
    (p_change-ARRAY['kind','id','parentId','displayName','archived','expectedRevision','requestId'])<>'{}'::jsonb OR
    kind IS NULL OR kind NOT IN ('organization','company','branch') OR id IS NULL OR id !~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$' OR
    title IS NULL OR length(trim(title)) NOT BETWEEN 1 AND 120 OR jsonb_typeof(p_change->'archived') IS DISTINCT FROM 'boolean' OR
    (p_change->>'expectedRevision') IS NULL OR (p_change->>'expectedRevision') !~ '^[0-9]{1,18}$' OR
    (p_change->>'requestId') IS NULL OR (p_change->>'requestId') !~ '^[0-9a-f-]{36}$' THEN
  RETURN jsonb_build_object('status','REJECTED','reasonCode','INVALID_ORGANIZATION_CHANGE'); END IF;
 expected:=(p_change->>'expectedRevision')::bigint; archived_value:=(p_change->>'archived')::boolean;
 request_hash:=encode(sha256(convert_to(p_change::text,'UTF8')),'hex');
 SELECT * INTO saved FROM public.ventio_wave2_admin_requests WHERE tenant_id=identity->>'tenantId'
  AND actor_id=identity->>'actorId' AND request_id=p_change->>'requestId';
 IF FOUND THEN
  IF saved.request_hash<>request_hash THEN RETURN jsonb_build_object('status','CONFLICT','reasonCode','REQUEST_ID_REUSED'); END IF;
  RETURN saved.result; END IF;
 tenant_manager:=ventio_security.wave2_tenant_manager(identity);
 IF kind='organization' THEN
  IF id IS DISTINCT FROM identity->>'tenantId' OR NOT tenant_manager THEN RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED'); END IF;
  IF archived_value AND EXISTS(SELECT FROM public.ventio_identity_users WHERE tenant_id=id) THEN
   RETURN jsonb_build_object('status','REJECTED','reasonCode','ORGANIZATION_IN_USE'); END IF;
  SELECT revision INTO actual FROM public.ventio_wave2_organizations WHERE tenant_id=id FOR UPDATE;
 ELSIF kind='company' THEN
  IF NOT tenant_manager AND (NOT EXISTS(SELECT FROM public.ventio_identity_branches b WHERE b.tenant_id=identity->>'tenantId' AND b.company_id=id) OR
    EXISTS(SELECT FROM public.ventio_identity_branches b WHERE b.tenant_id=identity->>'tenantId' AND b.company_id=id
      AND NOT ventio_security.wave2_allowed(identity,b.company_id,b.branch_id,'platform.organizations.manage'))) THEN
   RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED'); END IF;
  IF archived_value AND (id=p_company OR EXISTS(SELECT FROM public.ventio_wave2_branches b
    WHERE b.tenant_id=identity->>'tenantId' AND b.company_id=id AND NOT b.archived)) THEN
   RETURN jsonb_build_object('status','REJECTED','reasonCode','COMPANY_IN_USE'); END IF;
  SELECT revision INTO actual FROM public.ventio_wave2_companies WHERE tenant_id=identity->>'tenantId' AND company_id=id FOR UPDATE;
 ELSE
  IF parent IS NULL OR NOT EXISTS(SELECT FROM public.ventio_wave2_companies c WHERE c.tenant_id=identity->>'tenantId' AND c.company_id=parent AND NOT c.archived) THEN
   RETURN jsonb_build_object('status','REJECTED','reasonCode','PARENT_UNAVAILABLE'); END IF;
  IF NOT ventio_security.wave2_allowed(identity,parent,id,'platform.organizations.manage') AND NOT (tenant_manager AND NOT EXISTS(
    SELECT FROM public.ventio_identity_grants g WHERE g.tenant_id=identity->>'tenantId' AND g.company_id=parent AND g.branch_id=id)
    AND NOT EXISTS(SELECT FROM public.ventio_identity_role_assignments a WHERE a.tenant_id=identity->>'tenantId' AND a.company_id=parent AND a.branch_id=id)) THEN
   RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED'); END IF;
  IF archived_value AND parent=p_company AND id=p_branch THEN RETURN jsonb_build_object('status','REJECTED','reasonCode','CURRENT_SCOPE_IN_USE'); END IF;
  SELECT revision INTO actual FROM public.ventio_wave2_branches WHERE tenant_id=identity->>'tenantId' AND company_id=parent AND branch_id=id FOR UPDATE;
 END IF;
 IF coalesce(actual,0)<>expected THEN RETURN jsonb_build_object('status','CONFLICT','reasonCode','ENTITY_CHANGED','revision',coalesce(actual,0)); END IF;
 actual:=coalesce(actual,0)+1;
 IF kind='organization' THEN
  INSERT INTO public.ventio_wave2_organizations VALUES(id,title,actual,archived_value)
   ON CONFLICT(tenant_id) DO UPDATE SET display_name=EXCLUDED.display_name,revision=EXCLUDED.revision,archived=EXCLUDED.archived;
 ELSIF kind='company' THEN
  INSERT INTO public.ventio_wave2_companies VALUES(identity->>'tenantId',id,title,actual,archived_value)
   ON CONFLICT(tenant_id,company_id) DO UPDATE SET display_name=EXCLUDED.display_name,revision=EXCLUDED.revision,archived=EXCLUDED.archived;
 ELSE
  INSERT INTO public.ventio_wave2_branches VALUES(identity->>'tenantId',parent,id,title,actual,archived_value)
   ON CONFLICT(tenant_id,company_id,branch_id) DO UPDATE SET display_name=EXCLUDED.display_name,revision=EXCLUDED.revision,archived=EXCLUDED.archived;
  IF NOT archived_value THEN INSERT INTO public.ventio_identity_branches VALUES(identity->>'tenantId',parent,id) ON CONFLICT DO NOTHING; END IF;
 END IF;
 result:=jsonb_build_object('status','SAVED','revision',actual,'requestId',p_change->>'requestId');
 INSERT INTO public.ventio_wave2_admin_requests VALUES(identity->>'tenantId',identity->>'actorId',p_change->>'requestId',request_hash,result);
 INSERT INTO public.ventio_wave2_events(tenant_id,company_id,branch_id,actor_id,event_type,subject_id,detail)
 VALUES(identity->>'tenantId',p_company,p_branch,identity->>'actorId','ORGANIZATION_CHANGED',id,
  jsonb_build_object('kind',kind,'parentId',parent,'revision',actual,'archived',archived_value));
 RETURN result;
END $fn$;

DO $triggers$
DECLARE t text;
BEGIN
 FOREACH t IN ARRAY ARRAY['ventio_wave2_organizations','ventio_wave2_companies','ventio_wave2_branches'] LOOP
  EXECUTE format('DROP TRIGGER IF EXISTS wave2_entity_lock ON public.%I',t);
  EXECUTE format('CREATE TRIGGER wave2_entity_lock BEFORE UPDATE OR DELETE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION ventio_security.lock_recovery_mutation()',t);
  EXECUTE format('DROP TRIGGER IF EXISTS wave2_entity_mark ON public.%I',t);
  EXECUTE format('CREATE TRIGGER wave2_entity_mark AFTER UPDATE OR DELETE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION ventio_security.mark_recovery_mutation()',t);
 END LOOP;
END $triggers$;

CREATE OR REPLACE FUNCTION ventio_security.wave2_settings(p_tenant text,p_company text,p_branch text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
 SELECT jsonb_build_object('maintenanceMode',false,'jobsPaused',false,'defaultPageSize',50,'maxImportRows',500) ||
  coalesce((SELECT body FROM public.ventio_wave2_definitions WHERE tenant_id=p_tenant AND company_id=p_company
   AND branch_id=p_branch AND kind='configuration' AND owner_id='' ORDER BY definition_id LIMIT 1),'{}')
$fn$;
CREATE OR REPLACE FUNCTION ventio_security.wave2_settings_for_scope(p_digest text,p_company text,p_branch text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE identity jsonb;
BEGIN
 identity:=ventio_security.identity_snapshot(p_digest,p_company,p_branch);
 IF identity IS NULL OR jsonb_array_length(identity->'scopeGrants')=0 THEN
  RETURN jsonb_build_object('status','REJECTED','reasonCode','PERMISSION_DENIED'); END IF;
 RETURN jsonb_build_object('status','SETTINGS','settings',ventio_security.wave2_settings(identity->>'tenantId',p_company,p_branch));
END $fn$;
CREATE OR REPLACE FUNCTION ventio_security.wave2_command_admission(p_digest text,p_company text,p_branch text,p_job boolean)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE identity jsonb; settings jsonb;
BEGIN
 identity:=ventio_security.identity_snapshot(p_digest,p_company,p_branch);
 IF identity IS NULL OR jsonb_array_length(identity->'scopeGrants')=0 THEN RETURN 'AUTHORIZATION_CHANGED'; END IF;
 settings:=ventio_security.wave2_settings(identity->>'tenantId',p_company,p_branch);
 IF (settings->>'maintenanceMode')::boolean THEN RETURN 'HOST_MAINTENANCE'; END IF;
 IF p_job AND (settings->>'jobsPaused')::boolean THEN RETURN 'HOST_JOBS_PAUSED'; END IF;
 RETURN NULL;
END $fn$;
