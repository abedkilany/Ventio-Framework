$ErrorActionPreference='Stop'
$records=@()
foreach($path in @('C:\','C:\ProgramData','C:\ProgramData\Ventio','C:\ProgramData\Ventio\Host','C:\ProgramData\Ventio\Host\recovery.witness','C:\ProgramData\Ventio\Host\recovery.witness.lock')) {
  if(Test-Path -LiteralPath $path) {
    $acl=Get-Acl -LiteralPath $path
    $records+=@{path=$path;owner=$acl.Owner;protected=$acl.AreAccessRulesProtected;rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Select-Object IdentityReference,FileSystemRights,AccessControlType,IsInherited,PropagationFlags)}
  } else {$records+=@{path=$path;missing=$true}}
}
[IO.File]::WriteAllText('C:\Program Files\Ventio\SetupStatus\maintenance-witness-acl-20261031.json',($records | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
