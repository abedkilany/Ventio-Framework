// A copied file inherits its directory ACL but is not DACL-protected. The
// maintenance broker deliberately requires an explicit protected private ACL.
function NativeDescriptorOwner(Descriptor: LongWord; var Owner: LongWord; var Defaulted: LongWord): Boolean;
  external 'GetSecurityDescriptorOwner@advapi32.dll stdcall';
function NativeDescriptorDacl(Descriptor: LongWord; var Present: LongWord; var Dacl: LongWord; var Defaulted: LongWord): Boolean;
  external 'GetSecurityDescriptorDacl@advapi32.dll stdcall';
function NativeSetNamedSecurity(Path: String; ObjectType: Cardinal; Information: Cardinal; Owner: LongWord; Group: LongWord; Dacl: LongWord; Sacl: LongWord): Cardinal;
  external 'SetNamedSecurityInfoW@advapi32.dll stdcall';

function ProtectNativeMaintenanceFile(const Path: String): Boolean;
var
  Descriptor, Owner, Dacl: LongWord;
  Defaulted, Present: LongWord;
begin
  Result := False;
  Descriptor := 0;
  if not NativeSecurityDescriptor('O:BAG:BAD:P(A;;FA;;;BA)(A;;FA;;;SY)', 1, Descriptor, 0) then exit;
  try
    if not NativeDescriptorOwner(Descriptor, Owner, Defaulted) then exit;
    if not NativeDescriptorDacl(Descriptor, Present, Dacl, Defaulted) then exit;
    if (Present = 0) or (Owner = 0) or (Dacl = 0) then exit;
    // SE_FILE_OBJECT; OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION |
    // PROTECTED_DACL_SECURITY_INFORMATION. Never merge inherited permissions.
    Result := NativeSetNamedSecurity(Path, 1, $80000005, Owner, 0, Dacl, 0) = 0;
  finally
    NativeLocalFree(Descriptor);
  end;
end;
