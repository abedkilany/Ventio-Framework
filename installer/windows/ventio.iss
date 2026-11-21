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

#ifndef VCRuntimeSha256
  #error VCRuntimeSha256 must be supplied by the verified build
#endif

#define AppName "Ventio"
#define AppPublisher "Ventio Framework"
#define AppExeName "ventio_native_client.exe"
#define MaintenanceBrokerSha256 GetSHA256OfFile(HostPayload + "\VentioSetupBroker.exe")

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
Source: "{#HostPayload}\VentioSetupBroker.exe"; DestName: "VentioSetupMaintenance.exe"; Flags: dontcopy

[Icons]
Name: "{autoprograms}\Ventio"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\Ventio"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch Ventio"; WorkingDir: "{app}"; Flags: postinstall nowait skipifsilent runasoriginaluser; Check: IsVentioRuntimeReady

[Code]
var
  RemoveVentioHostData: Boolean;
  NativeMaintenanceHelper: String;
  NativeMaintenanceDirectory: String;
  HostFilesUpdateStarted: Boolean;
  HostServicesStoppedForUpgrade: Boolean;
  ExistingHostServiceFound: Boolean;
  ExistingPostgresServiceFound: Boolean;
  HostDatabaseUpgradeFailed: Boolean;
  VCRuntimeIsReady: Boolean;

#include "postinstall-upgrade-failure.iss"

function IsVentioRuntimeReady(): Boolean;
begin
  Result := VCRuntimeIsReady;
end;

function IsVCRuntimeSufficient(): Boolean;
var
  Installed: Cardinal;
  VersionText: String;
  InstalledVersion, MinimumVersion: Int64;
begin
  Result := False;
  if not RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Installed', Installed) then exit;
  if Installed <> 1 then exit;
  if not RegQueryStringValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Version', VersionText) then exit;
  VersionText := Trim(VersionText);
  if (Length(VersionText) > 0) and ((VersionText[1] = 'v') or (VersionText[1] = 'V')) then Delete(VersionText, 1, 1);
  if not StrToVersion(VersionText, InstalledVersion) then exit;
  if not StrToVersion('{#VCRuntimeMinimumVersion}', MinimumVersion) then exit;
  Result := ComparePackedVersion(InstalledVersion, MinimumVersion) >= 0;
end;

function EnsureVCRuntime(): String;
var
  ResultCode: Integer;
  RuntimeInstaller: String;
begin
  Result := '';
  VCRuntimeIsReady := IsVCRuntimeSufficient();
  if VCRuntimeIsReady then exit;
  ExtractTemporaryFile('vc_redist.x64.exe');
  RuntimeInstaller := ExpandConstant('{tmp}\vc_redist.x64.exe');
  if (not FileExists(RuntimeInstaller)) or
     (CompareText(GetSHA256OfFile(RuntimeInstaller), '{#VCRuntimeSha256}') <> 0) then begin
    Result := 'The verified Microsoft Visual C++ x64 prerequisite is unavailable or failed its SHA-256 check. Setup stopped before changing Ventio files or services.';
    exit;
  end;
  if not Exec(RuntimeInstaller, '/install /quiet /norestart', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then begin
    Result := 'The Microsoft Visual C++ x64 prerequisite could not start. Setup stopped before changing Ventio files or services.';
    exit;
  end;
  if (ResultCode = 3010) or (ResultCode = 1641) then begin
    Result := 'The Microsoft Visual C++ x64 Runtime requires a Windows restart. Restart Windows, then run Ventio Setup again. No Ventio files or services were changed.';
    exit;
  end;
  VCRuntimeIsReady := ((ResultCode = 0) or (ResultCode = 1638)) and IsVCRuntimeSufficient();
  if not VCRuntimeIsReady then
    Result := 'The Microsoft Visual C++ x64 Runtime could not be verified after installation. Setup stopped before changing Ventio files or services.';
end;

function IsSafePreinstallFailureCode(const Code: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := (Pos('HOST_', Code) = 1) and (Length(Code) <= 112);
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

function IsSafePreinstallFailureStage(const Stage: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := (Length(Stage) > 0) and (Length(Stage) <= 112);
  if not Result then exit;
  for I := 1 to Length(Stage) do begin
    C := Stage[I];
    if not (((C >= 'A') and (C <= 'Z')) or
            ((C >= '0') and (C <= '9')) or (C = '_')) then begin
      Result := False;
      exit;
    end;
  end;
end;

type
  TNativeSecurityAttributes = record
    Length: Cardinal;
    Descriptor: LongWord;
    InheritHandle: Cardinal;
  end;

function NativeSecurityDescriptor(Sddl: String; Revision: Cardinal; var Descriptor: LongWord; Size: LongWord): Boolean;
  external 'ConvertStringSecurityDescriptorToSecurityDescriptorW@advapi32.dll stdcall';
function NativeCreateDirectory(Path: String; var Attributes: TNativeSecurityAttributes): Boolean;
  external 'CreateDirectoryW@kernel32.dll stdcall';
function NativeLocalFree(Memory: LongWord): LongWord;
  external 'LocalFree@kernel32.dll stdcall';
function NativeGetFileAttributes(Path: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';
function NativeGetTickCount(): Cardinal;
  external 'GetTickCount@kernel32.dll stdcall';

#include "maintenance-file-security.iss"

function EnsureNativeMaintenanceHelper(): Boolean;
var
  Descriptor: LongWord;
  Attributes: TNativeSecurityAttributes;
  Nonce: String;
begin
  Result := False;
  if NativeMaintenanceHelper <> '' then begin
    Result := FileExists(NativeMaintenanceHelper) and
      (CompareText(GetSHA256OfFile(NativeMaintenanceHelper), '{#MaintenanceBrokerSha256}') = 0);
    exit;
  end;
  // Atomic protected creation under the OS-owned Program Files root. Copy from
  // the extraction cache, then validate the protected destination before Exec.
  // No executable is launched from a user-writable temporary directory.
  if (NativeGetFileAttributes(ExpandConstant('{autopf}')) and $400) <> 0 then exit;
  Nonce := Copy(GetSHA256OfString(ExpandConstant('{tmp}') + IntToStr(NativeGetTickCount())), 1, 32);
  NativeMaintenanceDirectory := ExpandConstant('{autopf}\Ventio-Setup-') + Nonce;
  Descriptor := 0;
  if not NativeSecurityDescriptor('O:BAG:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)', 1, Descriptor, 0) then exit;
  try
    Attributes.Length := SizeOf(Attributes);
    Attributes.Descriptor := Descriptor;
    Attributes.InheritHandle := 0;
    if not NativeCreateDirectory(NativeMaintenanceDirectory, Attributes) then exit;
  finally
    NativeLocalFree(Descriptor);
  end;
  ExtractTemporaryFile('VentioSetupMaintenance.exe');
  NativeMaintenanceHelper := NativeMaintenanceDirectory + '\VentioSetupBroker.exe';
  if not FileCopy(ExpandConstant('{tmp}\VentioSetupMaintenance.exe'), NativeMaintenanceHelper, True) then exit;
  if not ProtectNativeMaintenanceFile(NativeMaintenanceHelper) then exit;
  Result := CompareText(GetSHA256OfFile(NativeMaintenanceHelper), '{#MaintenanceBrokerSha256}') = 0;
  if not Result then NativeMaintenanceHelper := '';
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := EnsureVCRuntime();
  if Result <> '' then exit;
  ExistingHostServiceFound := RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\VentioHost');
  ExistingPostgresServiceFound := RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\VentioPostgres');
  if not ExistingHostServiceFound and not ExistingPostgresServiceFound then exit;
  if not EnsureNativeMaintenanceHelper() then begin
    Result := 'Ventio pre-install failed safely. Failure code: HOST_PREINSTALL_NATIVE_HELPER_INTEGRITY_FAILED. No application files were replaced.';
    exit;
  end;
  if not Exec(NativeMaintenanceHelper, '--prepare-installer-upgrade', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then begin
    Result := 'Ventio pre-install failed safely. Failure code: HOST_PREINSTALL_NATIVE_MAINTENANCE_FAILED. Existing services and data require verified repair before retrying. No application files were replaced.';
    exit;
  end;
  HostServicesStoppedForUpgrade := True;
end;

procedure DeinitializeSetup();
var
  ResultCode: Integer;
  Operation: String;
begin
  if HostServicesStoppedForUpgrade and (NativeMaintenanceHelper <> '') then begin
    if not HostFilesUpdateStarted and not HostDatabaseUpgradeFailed then
      Operation := '--resume-installer-upgrade'
    else
      Operation := '--resume-installer-postgres';
    if not Exec(NativeMaintenanceHelper, Operation, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
      Log('HOST_NATIVE_RESUME_FAILED_DATA_AND_RECOVERY_RECORDS_PRESERVED');
  end;
  if NativeMaintenanceHelper <> '' then DeleteFile(NativeMaintenanceHelper);
  if NativeMaintenanceDirectory <> '' then RemoveDir(NativeMaintenanceDirectory);
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

function IsSafeHostDatabaseUpgradeFailureCode(const Code: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := (Pos('HOST_DATABASE_', Code) = 1) and (Length(Code) <= 140);
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

function IsSafeHostDatabaseUpgradeFailureStage(const Stage: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := (Pos('STAGE=', Stage) = 1) and (Length(Stage) > 6) and (Length(Stage) <= 104);
  if not Result then exit;
  for I := 7 to Length(Stage) do begin
    C := Stage[I];
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
begin
  if CurrentStep = ssInstall then HostFilesUpdateStarted := True;
  if (CurrentStep <> ssPostInstall) or not HostServicesStoppedForUpgrade then exit;
  if not Exec(NativeMaintenanceHelper, '--complete-installer-upgrade', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then begin
    ReportHostDatabaseUpgradeFailure();
    exit;
  end;
  HostServicesStoppedForUpgrade := False;
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
  if (not DirExists(ExpandConstant('{commonappdata}\Ventio'))) and
     (not RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\VentioHost')) and
     (not RegKeyExists(HKLM, 'SYSTEM\CurrentControlSet\Services\VentioPostgres')) then exit;
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
  Parameters := '-NoLogo -NoProfile -NonInteractive -File "' + ScriptPath + '" -PayloadDirectory "' + ExpandConstant('{app}\host-payload') + '"';
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
