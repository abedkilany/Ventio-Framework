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
