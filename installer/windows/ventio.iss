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
Filename: "{app}\{#AppExeName}"; Description: "Launch Ventio"; WorkingDir: "{app}"; Flags: postinstall nowait skipifsilent runasoriginaluser

[Code]
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

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpSelectComponents) and
     (WizardSetupType(False) = 'host') and
     (not IsAdminInstallMode) then begin
    MsgBox('Host installation needs administrator mode to place service files under Program Files. Restart Setup and choose the all-users installation mode. Client installation can use per-user mode.', mbError, MB_OK);
    Result := False;
  end;
end;\n