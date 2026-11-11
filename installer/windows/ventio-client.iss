#ifndef AppVersion
  #error AppVersion must be supplied by build-client-installer.ps1
#endif
#ifndef BuildOutput
  #error BuildOutput must point at the Flutter Windows Release directory
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
DefaultDirName={localappdata}\Programs\Ventio
DefaultGroupName=Ventio
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#InstallerOutput}
OutputBaseFilename=Ventio-Client-Setup-{#AppVersion}
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

[Icons]
Name: "{autoprograms}\Ventio"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\Ventio"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch Ventio"; WorkingDir: "{app}"; Flags: postinstall nowait skipifsilent

; The installer intentionally handles only the Flutter client application.
; User data, SQLite files, credentials, backups, and Host services are outside
; {app} and are never removed by this package or its uninstaller.
