[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$CandidateZip,
  [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedZipSha256,
  [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedCommit,
  [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedPayloadManifestSha256,
  [Parameter(Mandatory)][string]$AdmissionRecord,
  [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedAdmissionSha256,
  [switch]$CreateFixtureMarker
)
# Preparation/intake only. No installer, service change, SQL mutation, test case,
# credential-store read, witness write, AV/policy change or existing file overwrite.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Require([bool]$Condition,[string]$Code){if(-not $Condition){throw $Code}}
Require ($env:COMPUTERNAME -cmatch '^VENTIO-W2-VM[0-9]{2}$') 'Separately provisioned disposable VM required; never rename a lab machine to satisfy admission'
Require ($env:COMPUTERNAME -notin @('TEST-01','TEST-02','VENTIO-TEST-01','VENTIO-TEST-02','BAHAA')) 'Preserved machines prohibited'
Require (([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Normal administrator elevation required'
Require ($env:VENTIO_WAVE2_PREPARED_TESTS -ceq 'yes') 'Explicit disposable fixture opt-in required'
Import-Module (Join-Path $PSScriptRoot '..\..\scripts\windows\RecoveryLabAdmission.psm1') -Force
$admission=Assert-CurrentRecoveryLabAdmission -Path $AdmissionRecord -ExpectedSha256 $ExpectedAdmissionSha256
Require ((Get-FileHash -LiteralPath $CandidateZip -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $ExpectedZipSha256) 'Candidate ZIP differs from independently approved digest'
$status=Get-MpComputerStatus
$prefs=Get-MpPreference
Require ($status.AMServiceEnabled -and $status.AntivirusEnabled -and $status.RealTimeProtectionEnabled -and -not $status.DefenderSignaturesOutOfDate -and $status.AMRunningMode -eq 'Normal') 'Current enabled Defender required'
Require (-not ($prefs.ExclusionPath -or $prefs.ExclusionExtension -or $prefs.ExclusionProcess -or $prefs.DisableArchiveScanning)) 'Review existing scan exclusions/archive settings before fixture admission; this script changes none'
Require (@(Get-MpThreat | Where-Object IsActive).Count -eq 0) 'Active threat blocks fixture admission'
Require (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -and -not (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) 'Pending restart blocks fixture admission'
$payload=Join-Path $env:ProgramFiles 'Ventio\host-payload'
$dataRoot=[Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$liveData=Join-Path $dataRoot 'Ventio\PostgreSQL\data'
$witness=Join-Path $dataRoot 'Ventio\Host\recovery.witness'
$markerDirectory=Join-Path $dataRoot 'Ventio-W2-Disposable'
$markerPath=Join-Path $markerDirectory 'fixture.json'
$manifestPath=Join-Path $markerDirectory 'installed-fixture.json'
Require (-not (Test-Path -LiteralPath $markerDirectory)) 'Refusing to replace an existing fixture marker or evidence'
$manifestFile=Join-Path $payload 'payload-manifest.json'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive=[IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $CandidateZip).Path)
try {
  $entry=$archive.GetEntry('SHA256SUMS.txt');Require ($null -ne $entry -and $entry.Length -lt 1048576) 'Bounded complete member manifest required'
  $reader=[IO.StreamReader]::new($entry.Open())
  try {$lines=$reader.ReadToEnd().Split([char]10)} finally {$reader.Dispose()}
  $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($line in $lines){
    if(-not $line.Trim()){continue}
    Require ($line -cmatch '^([0-9a-f]{64})  (.+?)\r?$') 'Invalid package checksum entry'
    $digest=$Matches[1];$name=$Matches[2]
    if(-not $name.StartsWith('HostPayload/',[StringComparison]::Ordinal)){continue}
    $relative=$name.Substring(12)
    Require (-not [IO.Path]::IsPathRooted($relative) -and $relative -notmatch '(^|[\\/])\.\.([\\/]|$)|:' -and $names.Add($relative)) 'Unsafe or duplicate Host member'
    $installed=[IO.Path]::GetFullPath((Join-Path $payload $relative))
    Require ($installed.StartsWith([IO.Path]::GetFullPath($payload).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) 'Host member escapes installed root'
    Require ((Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $digest) 'Installed Host member differs from approved complete package'
  }
  Require ($names.Count -gt 0 -and @(Get-ChildItem -LiteralPath $payload -Recurse -File).Count -eq $names.Count) 'Installed Host member set differs from package'
} finally {$archive.Dispose()}
Require ((Get-FileHash -LiteralPath $manifestFile -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $ExpectedPayloadManifestSha256) 'Installed payload manifest differs from reviewed package'
$payloadManifest=Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
Require ($payloadManifest.sourceCommit -ceq $ExpectedCommit -and $payloadManifest.sourceHasTrackedChanges -eq $false -and $payloadManifest.credentialsIncluded -eq $false -and $payloadManifest.databaseIncluded -eq $false) 'Reviewed clean source and stateless payload required'
foreach($entry in $payloadManifest.verifiedFiles){
  $file=[IO.Path]::GetFullPath((Join-Path $payload ([string]$entry.path)))
  Require ($file.StartsWith([IO.Path]::GetFullPath($payload).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) 'Payload entry escapes root'
  Require ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $entry.sha256) 'Installed payload differs from approved inventory'
  if([IO.Path]::GetExtension($file) -in @('.ps1','.psm1','.psd1','.ps1xml')){
    $signature=Get-AuthenticodeSignature -LiteralPath $file
    Require ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Thumbprint -ceq $admission.publisherThumbprint) 'Installed script publisher differs from approved identity'
  }
}
foreach($name in @('VentioHost','VentioPostgres')){
  $service=Get-CimInstance Win32_Service -Filter "Name='$name'"
  Require ($service -and $service.State -ceq 'Running' -and $service.StartName -ceq "NT SERVICE\$name") 'Real supported service identities and running services required'
  $expected=if($name -ceq 'VentioHost'){Join-Path $payload 'VentioHostService.exe'}else{Join-Path $payload 'postgresql\bin\pg_ctl.exe'}
  Require ($service.PathName.StartsWith('"'+$expected+'"',[StringComparison]::OrdinalIgnoreCase)) 'Service executable path differs from installed candidate'
}
Require ((Get-Content -LiteralPath (Join-Path $liveData 'PG_VERSION') -Raw).Trim() -ceq '16') 'Disposable PostgreSQL 16 cluster required'
Require (Test-Path -LiteralPath $witness -PathType Leaf) 'Existing independently bootstrapped recovery witness required'
$serviceSid=[Security.Principal.NTAccount]::new('NT SERVICE','VentioHost').Translate([Security.Principal.SecurityIdentifier]).Value
$witnessAcl=Get-Acl -LiteralPath $witness
Require ($witnessAcl.AreAccessRulesProtected -and $witnessAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ceq $serviceSid) 'Witness owner/protection mismatch; never adopt or rewrite it here'
Require (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'Ventio\Backups')) -or @(Get-ChildItem -LiteralPath (Join-Path $dataRoot 'Ventio\Backups') -Directory).Count -eq 0) 'Fresh backup root required; do not delete existing backups'
Require (-not [string]::IsNullOrWhiteSpace($env:VENTIO_W2_TOKEN)) 'Provide the supported disposable operator token through environment'
Require (-not [string]::IsNullOrWhiteSpace($env:VENTIO_W2_OBSERVER_DSN)) 'Provide separately provisioned disposable observer access; no protected credential is extracted'
$observer=[uri]$env:VENTIO_W2_OBSERVER_DSN
Require ($observer.Scheme -ceq 'postgresql' -and $observer.Host -ceq '127.0.0.1' -and $observer.Port -eq 54329 -and $observer.AbsolutePath -ceq '/ventio_host') 'Observer must target the exact disposable loopback cluster'
$session=Invoke-RestMethod -Uri 'http://127.0.0.1:8080/api/v1/session' -Headers @{Authorization='Bearer '+$env:VENTIO_W2_TOKEN}
$identity=$session.identity
Require ($identity.tenantId -ceq 'w2-physical-disposable' -and $identity.actorId -cmatch '^[A-Za-z0-9_.-]{1,128}$' -and $identity.deviceId -cmatch '^[A-Za-z0-9_.-]{1,128}$') 'Dedicated fixture operator identity required'
$scope=@($identity.scopes | Where-Object {$_.companyId -ceq 'w2-company' -and $_.branchId -ceq 'w2-branch'})
Require ($scope.Count -eq 1 -and 'platform.operations.manage' -in $scope[0].permissions) 'Current exact-scope operations grant required'
if(-not $CreateFixtureMarker){Write-Output 'FIXTURE_PREREQUISITES_VERIFIED_MARKER_NOT_CREATED';return}
$cursor=$markerDirectory
while($cursor){if(Test-Path -LiteralPath $cursor){Require (-not ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Reparse ancestor refused'};$parent=[IO.Directory]::GetParent($cursor);if($null -eq $parent){break};$cursor=$parent.FullName}
[void][IO.Directory]::CreateDirectory($markerDirectory)
$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
Set-Acl -LiteralPath $markerDirectory -AclObject $acl
$fixture=[ordered]@{fixtureOnly=$true;fixtureNonce=[guid]::NewGuid().ToString('N');machineName=$env:COMPUTERNAME;machineGuid=(Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid;sourceCommit=$ExpectedCommit;candidateZipSha256=$ExpectedZipSha256;payloadManifestSha256=$ExpectedPayloadManifestSha256;tenantId=$identity.tenantId;companyId='w2-company';branchId='w2-branch';actorId=$identity.actorId;deviceId=$identity.deviceId;recoveryWitnessPath=$witness}
$fixture.smbiosUuid=(Get-CimInstance Win32_ComputerSystemProduct).UUID
$fixture.admissionRecordSha256=$ExpectedAdmissionSha256
[IO.File]::WriteAllBytes((Join-Path $markerDirectory 'admission.json'),[IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $AdmissionRecord).Path))
foreach($file in @($markerPath,$manifestPath)){
  [IO.File]::WriteAllText($file,($fixture|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
  $fileAcl=[Security.AccessControl.FileSecurity]::new();$fileAcl.SetAccessRuleProtection($true,$false);$fileAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
  foreach($sid in @('S-1-5-18','S-1-5-32-544')){$fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow'))}
  Set-Acl -LiteralPath $file -AclObject $fileAcl
}
Write-Output 'DISPOSABLE_INSTALLED_FIXTURE_PREPARED_NO_TEST_EXECUTED'
