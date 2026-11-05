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
#ifndef VCRedistPath
  #error VCRedistPath must point at the verified Microsoft x64 Visual C++ Redistributable
#endif
#ifndef VCRuntimeHelperPath
  #error VCRuntimeHelperPath must point at the runtime prerequisite helper
#endif
#ifndef VCRuntimeModulePath
  #error VCRuntimeModulePath must point at the runtime prerequisite module
#endif
#ifndef VCRuntimeMinimumVersion
  #error VCRuntimeMinimumVersion must be supplied by build-windows-installer.ps1
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
DisableDirPage=yes
DefaultGroupName=Ventio
DisableProgramGroupPage=yes
PrivilegesRequired=admin
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

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#BuildOutput}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#HostPayload}\*"; DestDir: "{app}\host-payload"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#VCRedistPath}"; DestDir: "{tmp}"; Flags: dontcopy
Source: "{#VCRuntimeHelperPath}"; DestDir: "{tmp}"; Flags: dontcopy
Source: "{#VCRuntimeModulePath}"; DestDir: "{tmp}"; Flags: dontcopy
Source: "{#HostPayload}\setup\stop-host-services.ps1"; Flags: dontcopy
Source: "{#HostPayload}\setup\HostMigrationCredential.psm1"; Flags: dontcopy

[Icons]
Name: "{autoprograms}\Ventio"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\Ventio"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch Ventio"; WorkingDir: "{app}"; Flags: postinstall nowait skipifsilent runasoriginaluser; Check: IsVentioRuntimeReady

[Code]
var
  RemoveVentioHostData: Boolean;
  HostRecoveryHelpersExtracted: Boolean;
  HostServicesStoppedForUpgrade: Boolean;
  ExistingHostServiceFound: Boolean;
  ExistingPostgresServiceFound: Boolean;
  VCRuntimeIsReady: Boolean;

function IsVentioRuntimeReady(): Boolean;
begin
  Result := VCRuntimeIsReady;
end;

function EnsureVCRuntime(): String;
var
  ResultCode: Integer;
  PowerShell: String;
  RuntimeInstaller: String;
  RuntimeHelper: String;
  RuntimeModule: String;
  Parameters: String;
begin
  Result := '';
  VCRuntimeIsReady := False;
  ExtractTemporaryFile('vc_redist.x64.exe');
  ExtractTemporaryFile('ensure-vc-runtime-prerequisite.ps1');
  ExtractTemporaryFile('vc-runtime-prerequisite.psm1');

  RuntimeInstaller := ExpandConstant('{tmp}\vc_redist.x64.exe');
  RuntimeHelper := ExpandConstant('{tmp}\ensure-vc-runtime-prerequisite.ps1');
  RuntimeModule := ExpandConstant('{tmp}\vc-runtime-prerequisite.psm1');
  if (not FileExists(RuntimeInstaller)) or
     (not FileExists(RuntimeHelper)) or
     (not FileExists(RuntimeModule)) then begin
    Result := 'Ventio requires the Microsoft Visual C++ x64 Runtime, but its verified offline prerequisite could not be extracted. No Ventio application files or Host services were changed.';
    exit;
  end;

  PowerShell := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + RuntimeHelper + '" -RuntimeInstallerPath "' + RuntimeInstaller + '" -MinimumVersion "{#VCRuntimeMinimumVersion}"';
  if not Exec(PowerShell, Parameters, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then begin
    Result := 'Ventio could not start its Microsoft Visual C++ Runtime prerequisite check. No Ventio application files or Host services were changed.';
    exit;
  end;

  if ResultCode = 0 then begin
    VCRuntimeIsReady := True;
    exit;
  end;
  if (ResultCode = 3010) or (ResultCode = 1641) then begin
    Result := 'The Microsoft Visual C++ x64 Runtime was updated and requires a Windows restart. Restart Windows, then run Ventio Setup again. No Ventio application files or Host services were changed.';
    exit;
  end;

  Result := 'Ventio could not install or verify the Microsoft Visual C++ x64 Runtime. Setup stopped before replacing application files or stopping Host services. No database or Host data was changed.';
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
  Result := EnsureVCRuntime();
  if Result <> '' then exit;
  HasHostService := RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\VentioHost');
  HasPostgresService := RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\VentioPostgres');
  ExistingHostServiceFound := HasHostService;
  ExistingPostgresServiceFound := HasPostgresService;
  if not HasHostService and not HasPostgresService then exit;
  ExtractTemporaryFile('stop-host-services.ps1');
  ExtractTemporaryFile('HostMigrationCredential.psm1');
  HostRecoveryHelpersExtracted := True;
  StopScript := ExpandConstant('{tmp}\stop-host-services.ps1');
  if not FileExists(StopScript) then begin
    Result := 'An existing Host service was found, but this installation does not contain the reviewed service-stop helper. No upgrade was performed.';
    exit;
  end;
  PowerShell := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + StopScript + '" -PayloadDirectory "' + ExpandConstant('{app}\host-payload') + '" -AllowPostgresOnlyRecovery';
  if not Exec(PowerShell, Parameters, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then begin
    Result := 'Ventio could not safely stop its existing Host services. The installer stopped before replacing files.';
  end else begin
    HostServicesStoppedForUpgrade := True;
  end;
end;
procedure DeinitializeSetup();
var
  ResultCode: Integer;
  PowerShell: string;
  ResumeScript: string;
  Parameters: string;
begin
  if not HostServicesStoppedForUpgrade then exit;
  try
    if not HostRecoveryHelpersExtracted then begin
      ExtractTemporaryFile('stop-host-services.ps1');
      ExtractTemporaryFile('HostMigrationCredential.psm1');
      HostRecoveryHelpersExtracted := True;
    end;
    PowerShell := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
    ResumeScript := ExpandConstant('{tmp}\stop-host-services.ps1');
    if ExistingHostServiceFound and ExistingPostgresServiceFound then
      Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ResumeScript + '" -ResumeServices'
    else
      Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ResumeScript + '" -ResumePostgresOnly';
    if not Exec(PowerShell, Parameters, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then begin
      Log('HOST_POSTGRES_RESUME_AFTER_FAILED_INSTALL_DID_NOT_COMPLETE');
    end;
  except
    Log('HOST_POSTGRES_RESUME_HELPER_UNAVAILABLE');
  end;
end;

function IsSafeHostLanFailureCode(const Code: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := (Pos('HOST_LAN_', Code) = 1) and (Length(Code) <= 105);
  if not Result then exit;
  for I := 1 to Length(Code) do begin
    C := Code[I];
    if not (((C >= 'A') and (C <= 'Z')) or
            ((C >= '0') and (C <= '9')) or (C = '_')) then begin
      Result := False;
      exit;
    end;
  end;
end;

procedure CurStepChanged(CurrentStep: TSetupStep);
var
  ResultCode: Integer;
  PowerShell: string;
  ScriptPath: string;
  Parameters: string;
  FailureCodePath: string;
  FailureCode: string;
  FailureCodeLines: TArrayOfString;
begin
  if (CurrentStep <> ssPostInstall) or not HostServicesStoppedForUpgrade then exit;
  PowerShell := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  FailureCodePath := ExpandConstant('{tmp}\ventio-host-lan-failure.txt');
  DeleteFile(FailureCodePath);
  if ExistingHostServiceFound and ExistingPostgresServiceFound then begin
    ScriptPath := ExpandConstant('{app}\host-payload\setup\enable-host-lan-listener.ps1');
    if not FileExists(ScriptPath) then begin
      MsgBox('Ventio was updated, but the LAN HTTPS setup helper is missing. The existing Host will be restarted in local-only mode.', mbError, MB_OK);
      exit;
    end;
    Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ScriptPath + '" -PayloadDirectory "' + ExpandConstant('{app}\host-payload') + '" -RestartServices -FailureCodePath "' + FailureCodePath + '"';
  end else begin
    ScriptPath := ExpandConstant('{app}\host-payload\setup\stop-host-services.ps1');
    Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ScriptPath + '" -PayloadDirectory "' + ExpandConstant('{app}\host-payload') + '" -ResumePostgresOnly';
  end;
  if Exec(PowerShell, Parameters, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0) then begin
    HostServicesStoppedForUpgrade := False;
    DeleteFile(FailureCodePath);
  end else begin
    FailureCode := '';
    if ExistingHostServiceFound and ExistingPostgresServiceFound and FileExists(FailureCodePath) then begin
      if LoadStringsFromFile(FailureCodePath, FailureCodeLines) and
         (GetArrayLength(FailureCodeLines) > 0) then
        FailureCode := FailureCodeLines[0];
    end;
    DeleteFile(FailureCodePath);
    FailureCode := Trim(FailureCode);
    if IsSafeHostLanFailureCode(FailureCode) then
      MsgBox('Ventio updated its application files, but could not complete Host network setup or service restart. The Host will remain local-only if recovery succeeds. Check that Windows Firewall is enabled and this PC is connected to a Private or authenticated Domain network allowed by local security policy, then retry the update. Public networks are not enabled for Host access. No database reset was performed. Error code: ' + FailureCode + '.', mbError, MB_OK)
    else
      MsgBox('Ventio updated its application files, but could not complete Host network setup or service restart. The Host will remain local-only if recovery succeeds. Check that Windows Firewall is enabled and this PC is connected to a Private or authenticated Domain network allowed by local security policy, then retry the update. Public networks are not enabled for Host access. No database reset was performed.', mbError, MB_OK);
  end;
end;

function ConfirmHostDataRemoval(var DeleteData: Boolean): Boolean; forward;

function IsSafeRemovalFailureCode(const Code: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := (Pos('HOST_', Code) = 1) or (Pos('POSTGRES_', Code) = 1);
  if (not Result) or (Length(Code) > 104) then begin
    Result := False;
    exit;
  end;
  for I := 1 to Length(Code) do begin
    C := Code[I];
    if not (((C >= 'A') and (C <= 'Z')) or
            ((C >= '0') and (C <= '9')) or (C = '_')) then begin
      Result := False;
      exit;
    end;
  end;
end;

function InitializeUninstall(): Boolean;
var
  ResultCode: Integer;
  PowerShell: string;
  ScriptPath: string;
  Parameters: string;
  FailureCodePath: string;
  FailureCode: string;
  FailureCodeLines: TArrayOfString;
begin
  Result := True;
  ScriptPath := ExpandConstant('{app}\host-payload\setup\remove-host-installation.ps1');
  if not FileExists(ScriptPath) then begin
    if DirExists(ExpandConstant('{commonappdata}\Ventio')) or
       RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\VentioHost') or
       RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\VentioPostgres') then begin
      MsgBox('Ventio Host data or services were found, but this installation does not contain the reviewed removal helper. The uninstaller stopped; services and data remain in place.', mbError, MB_OK);
      Result := False;
    end;
    exit;
  end;
  RemoveVentioHostData := False;
  if not UninstallSilent and
     (DirExists(ExpandConstant('{commonappdata}\Ventio')) or
      RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\VentioHost') or
      RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\VentioPostgres')) then begin
    if not ConfirmHostDataRemoval(RemoveVentioHostData) then begin
      Result := False;
      exit;
    end;
  end;
  PowerShell := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  FailureCodePath := ExpandConstant('{tmp}\ventio-host-removal-failure.txt');
  DeleteFile(FailureCodePath);
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ScriptPath + '" -PayloadDirectory "' + ExpandConstant('{app}\host-payload') + '"';
  if RemoveVentioHostData then Parameters := Parameters + ' -RemoveData';
  Parameters := Parameters + ' -FailureCodePath "' + FailureCodePath + '"';
  if not Exec(PowerShell, Parameters, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then begin
    FailureCode := '';
    if FileExists(FailureCodePath) then begin
      if LoadStringsFromFile(FailureCodePath, FailureCodeLines) and
         (GetArrayLength(FailureCodeLines) > 0) then
        FailureCode := FailureCodeLines[0];
    end;
    DeleteFile(FailureCodePath);
    FailureCode := Trim(FailureCode);
    if IsSafeRemovalFailureCode(FailureCode) then
      MsgBox('Ventio could not safely complete Host removal. Uninstallation stopped; any Host data that was not removed remains on this device. Error code: ' + FailureCode + '. Retry the uninstall or contact an administrator.', mbError, MB_OK)
    else
      MsgBox('Ventio could not safely complete Host removal. Uninstallation stopped; any Host data that was not removed remains on this device. Retry the uninstall or contact an administrator.', mbError, MB_OK);
    Result := False;
  end else begin
    DeleteFile(FailureCodePath);
  end;
end;

function ConfirmHostDataRemoval(var DeleteData: Boolean): Boolean;
var
  Form: TSetupForm;
  Description: TNewStaticText;
  DeleteCheckBox: TNewCheckBox;
  UninstallButton: TNewButton;
  CancelButton: TNewButton;
  ButtonWidth: Integer;
  ButtonTop: Integer;
begin
  Result := False;
  DeleteData := False;
  Form := CreateCustomForm(520, 224, False, False);
  try
    Form.Caption := 'Uninstall Ventio';
    Form.BorderStyle := bsDialog;
    Form.BorderIcons := [biSystemMenu];
    Form.Position := poScreenCenter;

    Description := TNewStaticText.Create(Form);
    Description.Parent := Form;
    Description.SetBounds(ScaleX(16), ScaleY(16), Form.ClientWidth - ScaleX(32), ScaleY(78));
    Description.AutoSize := False;
    Description.WordWrap := True;
    Description.Caption := 'Ventio application files will be uninstalled and any Host services will be removed. The Host database, configuration, recovery evidence, diagnostics, backups, and other data under ProgramData\Ventio will stay on this device unless you select the option below. Deleting this data cannot be undone.';

    DeleteCheckBox := TNewCheckBox.Create(Form);
    DeleteCheckBox.Parent := Form;
    DeleteCheckBox.SetBounds(ScaleX(16), ScaleY(108), Form.ClientWidth - ScaleX(32), ScaleY(28));
    DeleteCheckBox.Caption := 'Permanently delete all Ventio Host data and backups';
    DeleteCheckBox.Checked := False;

    ButtonWidth := Form.CalculateButtonWidth(['Uninstall', 'Cancel']);
    ButtonTop := Form.ClientHeight - ScaleY(40);

    UninstallButton := TNewButton.Create(Form);
    UninstallButton.Parent := Form;
    UninstallButton.Caption := 'Uninstall';
    UninstallButton.SetBounds(Form.ClientWidth - ScaleX(16) - ButtonWidth * 2 - ScaleX(8), ButtonTop, ButtonWidth, ScaleY(26));
    UninstallButton.ModalResult := mrOk;

    CancelButton := TNewButton.Create(Form);
    CancelButton.Parent := Form;
    CancelButton.Caption := 'Cancel';
    CancelButton.SetBounds(Form.ClientWidth - ScaleX(16) - ButtonWidth, ButtonTop, ButtonWidth, ScaleY(26));
    CancelButton.ModalResult := mrCancel;
    CancelButton.Cancel := True;
    CancelButton.Default := True;
    Form.ActiveControl := CancelButton;

    if Form.ShowModal = mrOk then begin
      Result := True;
      DeleteData := DeleteCheckBox.Checked;
    end;
  finally
    Form.Free;
  end;
end;
