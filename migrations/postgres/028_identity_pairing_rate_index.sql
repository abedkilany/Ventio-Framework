CREATE INDEX ventio_identity_pairings_creator_window
  ON ventio_identity_pairings
    (tenant_id, created_by_actor_id, company_id, branch_id, created_at DESC)
