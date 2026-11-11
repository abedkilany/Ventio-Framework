CREATE INDEX ventio_identity_user_state_audit_scope_recent
  ON public.ventio_identity_audit (
    tenant_id,
    (details->>'companyId'),
    (details->>'branchId'),
    id DESC
  )
  WHERE action IN ('USER_DISABLED','USER_ENABLED');
