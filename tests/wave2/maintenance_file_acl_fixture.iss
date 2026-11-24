#ifndef FixtureOutput
  #error FixtureOutput is required
#endif
#ifndef FixtureId
  #error FixtureId is required
#endif
[Setup]
AppName=Ventio maintenance ACL regression
AppVersion=1.0
DefaultDirName={autopf}\Ventio-Acl-Regression-{#FixtureId}
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CreateAppDir=no
Uninstallable=no
OutputDir={#FixtureOutput}
OutputBaseFilename=maintenance-acl-fixture
DisableWelcomePage=yes
DisableDirPage=yes
DisableProgramGroupPage=yes
[Code]
type
  TNativeSecurityAttributes = record
    Length: Cardinal;
    Descriptor: LongWord;
    InheritHandle: Cardinal;
  end;
function NativeSecurityDescriptor(Sddl: String; Revision: Cardinal; var Descriptor: LongWord; Size: LongWord): Boolean;
  external 'ConvertStringSecurityDescriptorToSecurityDescriptorW@advapi32.dll stdcall';
function NativeLocalFree(Memory: LongWord): LongWord;
  external 'LocalFree@kernel32.dll stdcall';
function NativeCreateDirectory(Path: String; var Attributes: TNativeSecurityAttributes): Boolean;
  external 'CreateDirectoryW@kernel32.dll stdcall';
#include "..\..\installer\windows\maintenance-file-security.iss"

function InitializeSetup(): Boolean;
var
  Root, Original, Copied: String;
  Descriptor: LongWord;
  Attributes: TNativeSecurityAttributes;
begin
  Result := False;
  Root := ExpandConstant('{autopf}\Ventio-Acl-Regression-{#FixtureId}');
  if DirExists(Root) then RaiseException('Fresh fixture required');
  Descriptor := 0;
  if not NativeSecurityDescriptor('O:BAG:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)', 1, Descriptor, 0) then RaiseException('Private descriptor failed');
  try
    Attributes.Length := SizeOf(Attributes);
    Attributes.Descriptor := Descriptor;
    Attributes.InheritHandle := 0;
    if not NativeCreateDirectory(Root, Attributes) then RaiseException('Private directory failed');
  finally
    NativeLocalFree(Descriptor);
  end;
  Original := Root + '\inherited.txt';
  Copied := Root + '\protected.txt';
  if not SaveStringToFile(Original, 'Harmless Ventio installation ACL fixture', False) then RaiseException('Fixture write failed');
  if not FileCopy(Original, Copied, True) then RaiseException('Fixture copy failed');
  if not ProtectNativeMaintenanceFile(Copied) then RaiseException('Private file protection failed');
  if ProtectNativeMaintenanceFile(Root + '\missing.txt') then RaiseException('Missing file protection accepted');
  if not SaveStringToFile(Root + '\completed.txt', 'PRIVATE_FILE_PROTECTED_AND_MISSING_FILE_REJECTED', False) then RaiseException('Completion evidence failed');
  Result := True;
end;
