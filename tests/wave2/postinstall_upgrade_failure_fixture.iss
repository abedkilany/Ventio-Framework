#ifndef FixtureOutput
  #error FixtureOutput is required
#endif
#ifndef FixtureMode
  #error FixtureMode is required
#endif

[Setup]
AppId={{7F1633A2-98F5-458C-8E58-71E195220194}
AppName=Ventio Postinstall Exit Fixture
AppVersion=1
DefaultDirName={autopf}\Ventio-Postinstall-Exit-Fixture
CreateAppDir=no
Uninstallable=no
PrivilegesRequired=admin
OutputDir={#FixtureOutput}
OutputBaseFilename=postinstall-{#FixtureMode}

[Code]
var
  HostDatabaseUpgradeFailed: Boolean;

#include "..\..\installer\windows\postinstall-upgrade-failure.iss"

procedure CurStepChanged(CurrentStep: TSetupStep);
begin
  if (CurrentStep = ssPostInstall) and ('{#FixtureMode}' = 'fail') then
    ReportHostDatabaseUpgradeFailure();
end;
