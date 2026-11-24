DO $migration$
BEGIN
  IF to_regnamespace('ventio_security') IS NOT NULL AND
      to_regclass('public.ventio_extension_packages') IS NOT NULL THEN
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
  END IF;
END
$migration$;
