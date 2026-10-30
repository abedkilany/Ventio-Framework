#ifndef AppVersion
  #error AppVersion must be supplied by build-windows-installer.ps1
#endif
#ifndef BuildOutput
  #error BuildOutput must point at the Flutter Windows Release directory
#endif
#ifndef HostPayload
  #error HostPayload must point at the verified Host payload directory
#endif
#ifndef InstallerOutput
  #error InstallerOutput must point at the installer output directory
#endif

#define AppName "Ventio"
#define AppPublisher "Ventio Framework"
#define AppExeName "ventio_native_client.exe"

[Setup]
AppId={{62C74F3A-5420-4E2F-91A3-9178C4E4D8A1}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\Ventio
DefaultGroupName=Ventio
DisableProgramGroupPage=yes
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#InstallerOutput}
OutputBaseFilename=Ventio-Setup-{#AppVersion}
UninstallDisplayName=Ventio
CloseApplications=yes
RestartApplications=no
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
SetupLogging=no
Uninstallable=yes
UsePreviousAppDir=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Types]
Name: "client"; Description: "Client workstation"
Name: "host"; Description: "Host server"
Name: "custom"; Description: "Custom installation"; Flags: iscustom

[Components]
Name: "host"; Description: "Host infrastructure (PostgreSQL 16.15 and Ventio Host Engine)"; Types: host; Flags: fixed

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#BuildOutput}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#HostPayload}\*"; DestDir: "{app}\host-payload"; Components: host; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Ventio"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\Ventio"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Parameters: "--host-setup"; Description: "Set up Ventio Host"; WorkingDir: "{app}"; Components: host; Flags: postinstall nowait skipifsilent runasoriginaluser
Filename: "{app}\{#AppExeName}"; Description: "Launch Ventio"; WorkingDir: "{app}"; Check: not WizardIsComponentSelected('host'); Flags: postinstall nowait skipifsilent runasoriginaluser

[Code]
var
  RemoveVentioHostData: Boolean;

function InitializeSetup(): Boolean;
begin
  Result := True;
  if (Lowercase(ExpandConstant('{param:TYPE|}')) = 'host') and
     (not IsAdminInstallMode) then begin
    if WizardSilent then
      Log('HOST_INSTALL_REQUIRES_ADMIN_MODE')
    else
      MsgBox('Host installation needs administrator mode to place service files under Program Files. Restart Setup and choose the all-users installation mode.', mbError, MB_OK);
    Result := False;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
  StopScript: string;
  PowerShell: string;
  Parameters: string;
  HasHostService: Boolean;
  HasPostgresService: Boolean;
begin
  Result := '';
  if not WizardIsComponentSelected('host') then exit;
  HasHostService := RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\VentioHost');
  HasPostgresService := RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\VentioPostgres');
  if not HasHostService and not HasPostgresService then exit;
  StopScript := ExpandConstant('{app}\host-payload\setup\stop-host-services.ps1');
  if not FileExists(StopScript) then begin
    Result := 'An existing Host service was found, but this installation does not contain the reviewed service-stop helper. No upgrade was performed.';
    exit;
  end;
  PowerShell := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + StopScript + '"';
  if not Exec(PowerShell, Parameters, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then begin
    Result := 'Ventio could not safely stop its existing Host services. The installer stopped before replacing files.';
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  PowerShell: string;
  ScriptPath: string;
  Parameters: string;
begin
  if (CurStep = ssPostInstall) and WizardIsComponentSelected('host') then begin
    PowerShell := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
    ScriptPath := ExpandConstant('{app}\host-payload\setup\provision-host-installation.ps1');
    Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ScriptPath + '" -PayloadDirectory "' + ExpandConstant('{app}\host-payload') + '" -Apply';
    if not Exec(PowerShell, Parameters, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then begin
      MsgBox('Ventio Host provisioning did not complete. Any PostgreSQL data created by setup was preserved. Rerun the Host installer to resume or repair installation.', mbError, MB_OK);
      Abort();
    end;
  end;
end;

function InitializeUninstall(): Boolean;
var
  ResultCode: Integer;
  PowerShell: string;
  ScriptPath: string;
  Parameters: string;
begin
  Result := True;
  ScriptPath := ExpandConstant('{app}\host-payload\setup\remove-host-installation.ps1');
  if not FileExists(ScriptPath) then begin
    if RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\VentioHost') or
       RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\VentioPostgres') then begin
      MsgBox('Ventio Host services were found, but this installation does not contain the reviewed removal helper. The uninstaller stopped; services and data remain in place.', mbError, MB_OK);
      Result := False;
    end;
    exit;
  end;
  RemoveVentioHostData := False;
  if not UninstallSilent then begin
    RemoveVentioHostData := (MsgBox('Do you want to permanently delete the Ventio Host database, Recovery Authority data, diagnostics, backups, and protected migration credential? Choose No to retain this data after the services are removed.', mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES);
  end;
  PowerShell := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ScriptPath + '" -PayloadDirectory "' + ExpandConstant('{app}\host-payload') + '"';
  if RemoveVentioHostData then Parameters := Parameters + ' -RemoveData';
  if not Exec(PowerShell, Parameters, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then begin
    MsgBox('Ventio could not safely remove its Host services. The uninstaller stopped; Host files and data remain in place.', mbError, MB_OK);
    Result := False;
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  ExpectedHostDir: string;
  SelectedDir: string;
begin
  Result := True;
  if (CurPageID = wpSelectComponents) and (WizardSetupType(False) = 'host') then begin
    if not IsAdminInstallMode then begin
      MsgBox('Host installation needs administrator mode to place service files under Program Files. Restart Setup and choose the all-users installation mode. Client installation can use per-user mode.', mbError, MB_OK);
      Result := False;
    end else begin
      ExpectedHostDir := ExpandConstant('{autopf}\Ventio');
      SelectedDir := WizardDirValue;
      if (CompareText(SelectedDir, ExpectedHostDir) <> 0) and
         (CompareText(SelectedDir, ExpectedHostDir + '\') <> 0) then begin
        MsgBox('Host files must be installed in the protected Ventio folder under Program Files. Return to the folder page and restore the default Ventio location.', mbError, MB_OK);
        Result := False;
      end;
    end;
  end;
end;
