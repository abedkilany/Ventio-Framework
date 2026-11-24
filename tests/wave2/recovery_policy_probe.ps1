param([Parameter(Mandatory)][string]$OutputPath)
# Harmless signed companion-tool probe. Registering any SYSTEM task on the owner
# VM requires separate configuration approval; this file creates no task itself.
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -in @('BAHAA','TEST-01','TEST-02','VENTIO-TEST-01','VENTIO-TEST-02')){throw 'PRESERVED_COMPUTER_POLICY_PROBE_PROHIBITED'}
# OPTIONAL_FIXTURE_MODULE_IMPORT
$target=[IO.Path]::GetFullPath($OutputPath)
$parent=Get-Item -LiteralPath ([IO.Path]::GetDirectoryName($target))
while($parent){if($parent.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'POLICY_PROBE_REPARSE_PATH_REFUSED'};$parent=$parent.Parent}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$proof=@{sid=$identity.User.Value;policy=[string](Get-ExecutionPolicy);scopes=@(Get-ExecutionPolicy -List|ForEach-Object {@{scope=[string]$_.Scope;policy=[string]$_.ExecutionPolicy}});version=[string]$PSVersionTable.PSVersion;value='signed-probe-ran';machineName=$env:COMPUTERNAME;scriptSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant();utc=[DateTime]::UtcNow.ToString('o')}
$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($proof|ConvertTo-Json -Depth 6))
$stream=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
