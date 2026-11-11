-- Device role is descriptive infrastructure metadata. Existing rows remain
-- unclassified because their original role cannot be safely inferred.
ALTER TABLE ventio_identity_devices
  ADD COLUMN device_role text CHECK (device_role IN ('HOST','CLIENT'));
