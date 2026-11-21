procedure ReportHostDatabaseUpgradeFailure();
begin
  HostDatabaseUpgradeFailed := True;
  Log('HOST_NATIVE_UPGRADE_FAILED_AFTER_APPLICATION_FILES_UPDATED');
  SuppressibleMsgBox('Ventio updated its application files, but the guarded native Host upgrade did not complete. Host remains stopped; database, Recovery Authority and backup/recovery records are preserved. Repair the reported upgrade state before starting Host.', mbError, MB_OK, IDOK);
end;

function GetCustomSetupExitCode(): Integer;
begin
  Result := 0;
  if HostDatabaseUpgradeFailed then Result := 9;
end;
