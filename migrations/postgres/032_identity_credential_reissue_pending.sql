CREATE UNIQUE INDEX ventio_identity_credential_reissue_one_pending_device
  ON ventio_identity_credential_reissues (tenant_id, device_id)
  WHERE state = 'PREPARED';
