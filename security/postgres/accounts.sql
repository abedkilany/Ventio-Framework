-- Organization accounts extend the existing credential and recovery authority.
-- This file is applied by both fresh bootstrap and the protected upgrade bridge.
CREATE OR REPLACE FUNCTION ventio_security.account_credential_valid(p_digest text)
RETURNS boolean LANGUAGE sql SECURITY DEFINER
SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
 SELECT ventio_security.recovery_guard() AND EXISTS(
  SELECT FROM public.ventio_identity_credentials c
  JOIN public.ventio_identity_users u USING(tenant_id,actor_id)
  JOIN public.ventio_identity_devices d USING(tenant_id,actor_id,device_id)
  WHERE c.token_digest=p_digest AND c.revoked_at IS NULL AND c.expires_at>clock_timestamp()
   AND u.disabled_at IS NULL AND d.revoked_at IS NULL
   AND (u.password_hash IS NULL OR (c.login_password_version=u.password_version AND EXISTS(
    SELECT FROM public.ventio_identity_credentials parent
    WHERE parent.tenant_id=c.tenant_id AND parent.actor_id=c.actor_id
     AND parent.device_id=c.device_id AND parent.credential_id=c.login_parent_id
     AND parent.login_parent_id IS NULL AND parent.revoked_at IS NULL
     AND parent.expires_at>clock_timestamp()))))
$fn$;

-- Only the Host's scoped API identity can retrieve a verifier. The root device
-- credential proves enrollment and is never admitted to normal API operations
-- once the account has a password. A session cannot be used as enrollment proof.
CREATE OR REPLACE FUNCTION ventio_security.account_login_material(p_digest text,p_tenant text,p_username text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE result jsonb;
BEGIN
 IF NOT ventio_security.recovery_guard() THEN RETURN NULL; END IF;
 SELECT jsonb_build_object('actorId',u.actor_id,'passwordHash',u.password_hash,
   'version',u.password_version,'deviceId',c.device_id) INTO result
 FROM public.ventio_identity_credentials c
 JOIN public.ventio_identity_users u USING(tenant_id,actor_id)
 JOIN public.ventio_identity_devices d USING(tenant_id,actor_id,device_id)
 WHERE c.token_digest=p_digest AND c.tenant_id=p_tenant AND lower(u.username)=lower(p_username)
  AND u.password_hash IS NOT NULL AND u.disabled_at IS NULL AND d.revoked_at IS NULL
  AND (u.login_locked_until IS NULL OR u.login_locked_until<=clock_timestamp())
  AND c.login_parent_id IS NULL AND c.revoked_at IS NULL AND c.expires_at>clock_timestamp();
 RETURN result;
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.account_login_issue(
 p_digest text,p_tenant text,p_username text,p_expected_hash text,p_token_digest text,p_id text,p_success boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE c public.ventio_identity_credentials%ROWTYPE; u public.ventio_identity_users%ROWTYPE;
 expiry timestamptz; result jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(86744321);
 IF NOT ventio_security.recovery_guard() OR p_token_digest !~ '^[0-9a-f]{64}$'
  OR p_id !~ '^login_[A-Za-z0-9_-]{43}$' THEN
  RAISE EXCEPTION 'Sign in denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO c FROM public.ventio_identity_credentials WHERE token_digest=p_digest FOR SHARE;
 SELECT * INTO u FROM public.ventio_identity_users
  WHERE tenant_id=c.tenant_id AND actor_id=c.actor_id FOR SHARE;
 IF ventio_security.account_login_material(p_digest,p_tenant,p_username) IS NULL
  OR u.password_hash IS DISTINCT FROM p_expected_hash THEN
  RAISE EXCEPTION 'Sign in denied' USING ERRCODE='42501'; END IF;
 IF NOT p_success THEN
  UPDATE public.ventio_identity_users SET login_failures=CASE WHEN login_locked_until<=clock_timestamp() THEN 1 ELSE login_failures+1 END,
   login_locked_until=CASE WHEN login_failures>=4 THEN clock_timestamp()+interval '15 minutes' ELSE login_locked_until END
   WHERE tenant_id=c.tenant_id AND actor_id=c.actor_id;
  INSERT INTO public.ventio_identity_audit(tenant_id,operator_label,action,subject_id,details)
   VALUES(c.tenant_id,'account-sign-in','ACCOUNT_SIGN_IN_DENIED',c.actor_id,'{}');
  RETURN NULL;
 END IF;
 UPDATE public.ventio_identity_users SET login_failures=0,login_locked_until=NULL WHERE tenant_id=c.tenant_id AND actor_id=c.actor_id;
 expiry:=least(c.expires_at,clock_timestamp()+interval '8 hours');
 INSERT INTO public.ventio_identity_credentials
  (tenant_id,actor_id,device_id,credential_id,token_digest,expires_at,allowed_scopes,login_parent_id,login_password_version)
 VALUES(c.tenant_id,c.actor_id,c.device_id,p_id,p_token_digest,expiry,(SELECT jsonb_agg(scope||jsonb_build_object('permissions',jsonb_build_array('*'))) FROM jsonb_array_elements(c.allowed_scopes) scope),c.credential_id,u.password_version);
 result:=ventio_security.identity_snapshot(p_token_digest,NULL,NULL);
 INSERT INTO public.ventio_identity_audit(tenant_id,operator_label,action,subject_id,details)
 VALUES(c.tenant_id,'account:'||left(c.actor_id,240),'ACCOUNT_SIGNED_IN',c.actor_id,
  jsonb_build_object('deviceId',c.device_id,'expiresAt',expiry));
 RETURN jsonb_build_object('tenantId',c.tenant_id,'actorId',c.actor_id,'deviceId',c.device_id,
  'username',u.username,'expiresAt',expiry,'identity',result);
END $fn$;

CREATE OR REPLACE FUNCTION ventio_security.account_current_hash(p_digest text)
RETURNS text LANGUAGE sql SECURITY DEFINER
SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
 SELECT u.password_hash FROM public.ventio_identity_credentials c
 JOIN public.ventio_identity_users u USING(tenant_id,actor_id)
 WHERE c.token_digest=p_digest AND ventio_security.account_credential_valid(p_digest)
$fn$;
REVOKE ALL ON FUNCTION ventio_security.account_current_hash(text) FROM PUBLIC,ventio_runtime,ventio_identity_admin,ventio_identity_api;
GRANT EXECUTE ON FUNCTION ventio_security.account_current_hash(text) TO ventio_identity_api;

-- Protect the Owner even from broad maintenance admin_change and future APIs.
-- Database service/migration identities are a separate OS trust boundary.
CREATE OR REPLACE FUNCTION ventio_security.protect_organization_owner()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
BEGIN
 IF OLD.is_owner AND (TG_OP='DELETE' OR NEW.is_owner IS DISTINCT FROM true
   OR NEW.disabled_at IS NOT NULL OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
   OR NEW.actor_id IS DISTINCT FROM OLD.actor_id) THEN
  RAISE EXCEPTION 'Organization Owner is protected' USING ERRCODE='42501'; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END $fn$;
DROP TRIGGER IF EXISTS protect_organization_owner ON public.ventio_identity_users;
CREATE TRIGGER protect_organization_owner BEFORE UPDATE OR DELETE ON public.ventio_identity_users
 FOR EACH ROW EXECUTE FUNCTION ventio_security.protect_organization_owner();

CREATE OR REPLACE FUNCTION ventio_security.account_change(p_digest text,p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE identity jsonb; tenant text; actor text; target public.ventio_identity_users%ROWTYPE;
 owner_account boolean; operation text:=p->>'action'; current_hash text;
BEGIN
 PERFORM pg_advisory_xact_lock(86744321);
 identity:=ventio_security.identity_snapshot(p_digest,NULL,NULL);
 IF identity IS NULL THEN RAISE EXCEPTION 'Account management denied' USING ERRCODE='42501'; END IF;
 tenant:=identity->>'tenantId'; actor:=identity->>'actorId';
 SELECT is_owner,password_hash INTO owner_account,current_hash FROM public.ventio_identity_users
  WHERE tenant_id=tenant AND actor_id=actor FOR SHARE;
 SELECT * INTO target FROM public.ventio_identity_users
  WHERE tenant_id=tenant AND actor_id=coalesce(p->>'actorId',actor) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Account management denied' USING ERRCODE='42501'; END IF;
 IF operation='SELF' THEN
  RETURN jsonb_build_object('actorId',actor,'username',(SELECT username FROM public.ventio_identity_users WHERE tenant_id=tenant AND actor_id=actor),
    'isOwner',owner_account,'needsPassword',current_hash IS NULL);
 END IF;
 IF operation='SET_LOGIN' THEN
  IF target.actor_id=actor THEN
   IF current_hash IS NOT NULL AND current_hash IS DISTINCT FROM p->>'expectedHash' THEN
    RAISE EXCEPTION 'Current password required' USING ERRCODE='42501'; END IF;
  ELSIF target.is_owner OR NOT owner_account THEN
   -- Delegates may reset only ordinary accounts, in a scope they fully manage.
   IF target.is_owner OR EXISTS(SELECT FROM public.ventio_identity_grants g
      WHERE g.tenant_id=tenant AND g.actor_id=target.actor_id
       AND (g.permission ~ '^(identity|host|system|security|recovery|authorization)\.' OR g.permission ~ '^platform\..*\.manage$'))
     OR target.organization_wide
     OR NOT ventio_security.identity_users_manager_allowed(p_digest,tenant,p->>'companyId',p->>'branchId')
     OR NOT EXISTS(SELECT FROM public.ventio_identity_audit a WHERE a.tenant_id=tenant AND a.subject_id=target.actor_id
       AND a.details->>'companyId'=p->>'companyId' AND a.details->>'branchId'=p->>'branchId')
     OR EXISTS(SELECT FROM public.ventio_identity_grants g WHERE g.tenant_id=tenant AND g.actor_id=target.actor_id
       AND (g.company_id,g.branch_id) IS DISTINCT FROM (p->>'companyId',p->>'branchId'))
     OR EXISTS(SELECT FROM public.ventio_identity_role_assignments a WHERE a.tenant_id=tenant AND a.actor_id=target.actor_id
       AND (a.company_id,a.branch_id) IS DISTINCT FROM (p->>'companyId',p->>'branchId')) THEN
    RAISE EXCEPTION 'Account management denied' USING ERRCODE='42501'; END IF;
  END IF;
  IF p->>'username' IS NULL OR p->>'username' !~ '^[A-Za-z0-9][A-Za-z0-9_.@-]{2,63}$'
   OR p->>'passwordHash' IS NULL OR p->>'passwordHash' !~ '^pbkdf2-sha256:600000:[A-Za-z0-9_-]{43}:[A-Za-z0-9_-]{43}$' THEN
   RAISE EXCEPTION 'Invalid login' USING ERRCODE='22023'; END IF;
  UPDATE public.ventio_identity_users SET username=p->>'username',password_hash=p->>'passwordHash',
   password_version=password_version+1,login_failures=0,login_locked_until=NULL WHERE tenant_id=tenant AND actor_id=target.actor_id;
 ELSIF operation='SET_ORGANIZATION_ACCESS' THEN
  IF NOT owner_account OR target.is_owner OR jsonb_typeof(p->'enabled') IS DISTINCT FROM 'boolean' THEN
   RAISE EXCEPTION 'Account management denied' USING ERRCODE='42501'; END IF;
  UPDATE public.ventio_identity_users SET organization_wide=(p->>'enabled')::boolean
   WHERE tenant_id=tenant AND actor_id=target.actor_id;
 ELSIF operation='REVOKE_SESSIONS' THEN
  IF target.is_owner OR NOT owner_account THEN
   RAISE EXCEPTION 'Account management denied' USING ERRCODE='42501'; END IF;
  UPDATE public.ventio_identity_users SET password_version=password_version+1
   WHERE tenant_id=tenant AND actor_id=target.actor_id;
 ELSE RAISE EXCEPTION 'Invalid account operation' USING ERRCODE='22023'; END IF;
 INSERT INTO public.ventio_identity_audit(tenant_id,operator_label,action,subject_id,details)
 VALUES(tenant,'account:'||left(actor,240),operation,target.actor_id,
   jsonb_build_object('companyId',p->>'companyId','branchId',p->>'branchId'));
 RETURN jsonb_build_object('changed',true);
END $fn$;

-- Only an elevated local Host pipe caller can reach this operation. It uses
-- recovery admission and a fixed helper, never a network recovery endpoint.
CREATE OR REPLACE FUNCTION ventio_security.local_owner_recover(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
DECLARE tenant text:=p->>'tenantId'; actor text; operation text:=p->>'mode';
 company text:=p->>'companyId'; branch text:=p->>'branchId';
BEGIN
 PERFORM pg_advisory_xact_lock(86744321);
 IF NOT ventio_security.recovery_guard() OR p->>'windowsAdminTag' IS NULL
  OR p->>'windowsAdminTag' !~ '^[0-9a-f]{16}$' OR p->>'windowsAdminSid' IS NULL
  OR p->>'windowsAdminSid' !~ '^S-1-[0-9]+(-[0-9]+)+$' OR tenant IS NULL OR length(tenant) NOT BETWEEN 1 AND 256
  OR p->>'username' IS NULL OR p->>'username' !~ '^[A-Za-z0-9][A-Za-z0-9_.@-]{2,63}$'
  OR p->>'passwordHash' IS NULL OR p->>'passwordHash' !~ '^pbkdf2-sha256:600000:[A-Za-z0-9_-]{43}:[A-Za-z0-9_-]{43}$' THEN
  RAISE EXCEPTION 'Local Owner operation denied' USING ERRCODE='42501'; END IF;
 SELECT actor_id INTO actor FROM public.ventio_identity_users WHERE tenant_id=tenant AND is_owner FOR UPDATE;
 IF operation='RECOVER' THEN
  IF actor IS NULL THEN RAISE EXCEPTION 'Owner migration required' USING ERRCODE='42501'; END IF;
 ELSIF operation='MIGRATE' THEN
  IF actor IS NOT NULL THEN RAISE EXCEPTION 'Organization already owned' USING ERRCODE='42501'; END IF;
  actor:=p->>'actorId';
  IF NOT EXISTS(SELECT FROM public.ventio_identity_users WHERE tenant_id=tenant AND actor_id=actor AND disabled_at IS NULL) THEN
   RAISE EXCEPTION 'Explicit existing active account required' USING ERRCODE='42501'; END IF;
  UPDATE public.ventio_identity_users SET is_owner=true WHERE tenant_id=tenant AND actor_id=actor;
 ELSIF operation='BOOTSTRAP' THEN
  IF actor IS NOT NULL OR NOT EXISTS(SELECT FROM public.ventio_wave2_organizations WHERE tenant_id=tenant)
   OR NOT EXISTS(SELECT FROM public.ventio_identity_branches WHERE tenant_id=tenant) THEN
   RAISE EXCEPTION 'Existing unowned organization required' USING ERRCODE='42501'; END IF;
  actor:='usr_'||encode(ventio_crypto.gen_random_bytes(16),'hex');
  INSERT INTO public.ventio_identity_users(tenant_id,actor_id,is_owner) VALUES(tenant,actor,true);
 ELSIF operation='INITIALIZE' THEN
  IF EXISTS(SELECT FROM public.ventio_identity_users WHERE tenant_id=tenant)
   OR EXISTS(SELECT FROM public.ventio_wave2_organizations WHERE tenant_id=tenant)
   OR company IS NULL OR branch IS NULL OR length(company) NOT BETWEEN 1 AND 256 OR length(branch) NOT BETWEEN 1 AND 256 THEN
   RAISE EXCEPTION 'Organization already exists or invalid scope' USING ERRCODE='42501'; END IF;
  actor:='usr_'||encode(ventio_crypto.gen_random_bytes(16),'hex');
  INSERT INTO public.ventio_identity_users(tenant_id,actor_id,is_owner) VALUES(tenant,actor,true);
  INSERT INTO public.ventio_identity_branches(tenant_id,company_id,branch_id) VALUES(tenant,company,branch);
  INSERT INTO public.ventio_wave2_organizations(tenant_id,display_name) VALUES(tenant,tenant) ON CONFLICT DO NOTHING;
  INSERT INTO public.ventio_wave2_companies(tenant_id,company_id,display_name) VALUES(tenant,company,company) ON CONFLICT DO NOTHING;
  INSERT INTO public.ventio_wave2_branches(tenant_id,company_id,branch_id,display_name) VALUES(tenant,company,branch,branch) ON CONFLICT DO NOTHING;
 ELSE RAISE EXCEPTION 'Invalid Owner operation' USING ERRCODE='22023'; END IF;
 UPDATE public.ventio_identity_users SET username=p->>'username',password_hash=p->>'passwordHash',
  password_version=password_version+1,login_failures=0,login_locked_until=NULL,disabled_at=NULL WHERE tenant_id=tenant AND actor_id=actor;
 -- Recovery invalidates previous device credentials; a new local handoff is
 -- enrolled through the existing identity tables, never a PostgreSQL login.
 UPDATE public.ventio_identity_credentials SET revoked_at=coalesce(revoked_at,clock_timestamp())
  WHERE tenant_id=tenant AND actor_id=actor;
 company:=coalesce(company,(SELECT company_id FROM public.ventio_identity_branches WHERE tenant_id=tenant ORDER BY company_id,branch_id LIMIT 1));
 branch:=coalesce(branch,(SELECT branch_id FROM public.ventio_identity_branches WHERE tenant_id=tenant AND company_id=company ORDER BY branch_id LIMIT 1));
 IF NOT EXISTS(SELECT FROM public.ventio_identity_branches WHERE tenant_id=tenant AND company_id=company AND branch_id=branch)
  OR p->>'tokenDigest' IS NULL OR p->>'tokenDigest' !~ '^[0-9a-f]{64}$'
  OR p->>'credentialId' IS NULL OR p->>'credentialId' !~ '^pair_[0-9a-f]{32}$' THEN
  RAISE EXCEPTION 'Invalid recovery handoff' USING ERRCODE='22023'; END IF;
 UPDATE public.ventio_identity_pairings SET revoked_at=clock_timestamp()
  WHERE tenant_id=tenant AND actor_id=actor AND redeemed_at IS NULL AND revoked_at IS NULL;
 INSERT INTO public.ventio_identity_pairings(pairing_id,pairing_digest,tenant_id,actor_id,company_id,branch_id,
  created_by_actor_id,allowed_permissions,expires_at)
 VALUES(p->>'credentialId',p->>'tokenDigest',tenant,actor,company,branch,actor,
  ARRAY['host.status.read','host.diagnostics.read','identity.users.manage','identity.devices.manage',
    'identity.pairing.manage','identity.roles.manage','extension.package.read','extension.package.submit','extension.package.review'],
  clock_timestamp()+interval '5 minutes');
 INSERT INTO public.ventio_identity_audit(tenant_id,operator_label,action,subject_id,details)
 VALUES(tenant,'local-owner-recovery','OWNER_'||operation,actor,
  jsonb_build_object('windowsAdminTag',p->>'windowsAdminTag','windowsAdminSid',p->>'windowsAdminSid','companyId',company,'branchId',branch));
 RETURN jsonb_build_object('actorId',actor,'tenantId',tenant,'companyId',company,'branchId',branch);
END $fn$;

REVOKE ALL ON FUNCTION ventio_security.account_credential_valid(text),
 ventio_security.protect_organization_owner(),ventio_security.account_login_material(text,text,text),
 ventio_security.account_login_issue(text,text,text,text,text,text,boolean),ventio_security.account_change(text,jsonb),
 ventio_security.local_owner_recover(jsonb) FROM PUBLIC,ventio_runtime,ventio_identity_admin,ventio_identity_api;
GRANT EXECUTE ON FUNCTION ventio_security.account_login_material(text,text,text),
 ventio_security.account_login_issue(text,text,text,text,text,text,boolean),ventio_security.account_change(text,jsonb),
 ventio_security.local_owner_recover(jsonb) TO ventio_identity_api;

CREATE OR REPLACE FUNCTION ventio_security.account_user_permissions(p_tenant text,p_actor text,p_company text,p_branch text)
RETURNS text[] LANGUAGE sql SECURITY DEFINER
SET search_path=pg_catalog,ventio_security,pg_temp AS $fn$
 SELECT coalesce(array_agg(DISTINCT permission ORDER BY permission),'{}'::text[]) FROM (
  SELECT g.permission FROM public.ventio_identity_grants g JOIN public.ventio_identity_users u USING(tenant_id,actor_id)
   WHERE g.tenant_id=p_tenant AND g.actor_id=p_actor AND u.disabled_at IS NULL
    AND (u.organization_wide OR (g.company_id=p_company AND g.branch_id=p_branch))
  UNION SELECT rp.permission FROM public.ventio_identity_role_assignments a
   JOIN public.ventio_identity_users u USING(tenant_id,actor_id)
   JOIN public.ventio_identity_role_permissions rp USING(tenant_id,role_id)
   WHERE a.tenant_id=p_tenant AND a.actor_id=p_actor AND u.disabled_at IS NULL
    AND (u.organization_wide OR (a.company_id=p_company AND a.branch_id=p_branch))
    AND rp.permission !~ '^(identity|host|system|security|recovery|authorization)\.'
    AND rp.permission NOT IN ('platform.organizations.manage','platform.configuration.manage','platform.customizations.manage','platform.operations.manage')
  UNION SELECT unnest(ARRAY['host.status.read','host.diagnostics.read','identity.users.manage','identity.devices.manage',
   'identity.pairing.manage','identity.roles.manage','extension.package.read','extension.package.submit','extension.package.review'])
   FROM public.ventio_identity_users WHERE tenant_id=p_tenant AND actor_id=p_actor AND is_owner
 ) effective
$fn$;
REVOKE ALL ON FUNCTION ventio_security.account_user_permissions(text,text,text,text) FROM PUBLIC,ventio_runtime,ventio_identity_admin,ventio_identity_api;
