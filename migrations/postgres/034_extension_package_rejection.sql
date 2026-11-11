DO $migration$
BEGIN
ALTER TABLE ventio_extension_packages
  DROP CONSTRAINT ventio_extension_packages_status_check,
  DROP CONSTRAINT ventio_extension_packages_check2,
  ADD COLUMN rejected_by text,
  ADD COLUMN rejected_at timestamptz,
  ADD COLUMN rejection_reason text,
  ADD CONSTRAINT ventio_extension_packages_status_check
    CHECK (status IN ('SUBMITTED', 'APPROVED', 'REJECTED', 'REVOKED')),
  ADD CONSTRAINT ventio_extension_packages_lifecycle_check CHECK (
    (status = 'SUBMITTED' AND approved_by IS NULL AND approved_at IS NULL AND
      revoked_by IS NULL AND revoked_at IS NULL AND revoke_reason IS NULL AND
      rejected_by IS NULL AND rejected_at IS NULL AND rejection_reason IS NULL) OR
    (status = 'APPROVED' AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND
      revoked_by IS NULL AND revoked_at IS NULL AND revoke_reason IS NULL AND
      rejected_by IS NULL AND rejected_at IS NULL AND rejection_reason IS NULL) OR
    (status = 'REJECTED' AND approved_by IS NULL AND approved_at IS NULL AND
      revoked_by IS NULL AND revoked_at IS NULL AND revoke_reason IS NULL AND
      rejected_by IS NOT NULL AND rejected_at IS NOT NULL AND
      rejection_reason IS NOT NULL AND length(trim(rejection_reason)) BETWEEN 1 AND 500) OR
    (status = 'REVOKED' AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND
      revoked_by IS NOT NULL AND revoked_at IS NOT NULL AND revoke_reason IS NOT NULL AND
      rejected_by IS NULL AND rejected_at IS NULL AND rejection_reason IS NULL)
  );
ALTER TABLE ventio_extension_package_events
  DROP CONSTRAINT ventio_extension_package_events_event_type_check,
  ADD CONSTRAINT ventio_extension_package_events_event_type_check
    CHECK (event_type IN ('SUBMITTED', 'APPROVED', 'REJECTED', 'REVOKED'));
END $migration$;
