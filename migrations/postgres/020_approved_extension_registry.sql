CREATE INDEX ventio_extension_packages_approved_registry
  ON ventio_extension_packages (tenant_id, module_id, version)
  WHERE status = 'APPROVED';
