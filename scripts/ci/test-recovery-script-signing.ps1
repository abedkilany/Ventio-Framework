$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:COMPUTERNAME -in @('BAHAA','TEST-01','TEST-02')){throw 'HOSTED_SIGNING_FIXTURE_ONLY'}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
Import-Module (Join-Path $repo 'scripts/windows/SignHostScripts.psm1') -Force
$root=Join-Path $env:RUNNER_TEMP ('recovery-signing-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$out=Join-Path $repo 'test-results/recovery-admission';[void][IO.Directory]::CreateDirectory($out)
$results=[Collections.Generic.List[object]]::new()
$before=@{};foreach($scope in @('LocalMachine','CurrentUser','Process')){$before[$scope]=[string](Get-ExecutionPolicy -Scope $scope)}
$tasks=[Collections.Generic.List[string]]::new()
function Write-Source([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
function Require([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
function Record([string]$Id,[scriptblock]$Body){try{& $Body;$results.Add(@{id=$Id;status='PASSED'});Write-Output "PASS $Id"}catch{$results.Add(@{id=$Id;status='FAILED';reason=$_.Exception.Message});Write-Output "FAIL $Id $($_.Exception.Message)"}}
function Invoke-Probe([string]$Path,[string]$Context,[string]$OutputPath){
  if($Context -eq 'operator'){
    $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'))
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.Arguments='-NoLogo -NoProfile -NonInteractive -File "'+$Path+'" -OutputPath "'+$OutputPath+'"'
    $process=[Diagnostics.Process]::Start($start)
    try{$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();if(-not $process.WaitForExit(60000)){$process.Kill();throw 'Operator probe timed out'};[void]$stdout.GetAwaiter().GetResult();[void]$stderr.GetAwaiter().GetResult();return $process.ExitCode}finally{$process.Dispose()}
  }
  $name='Ventio-CI-Signing-'+[guid]::NewGuid().ToString('N');$tasks.Add($name)
  $action=New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -Argument ('-NoLogo -NoProfile -NonInteractive -File "'+$Path+'" -OutputPath "'+$OutputPath+'"')
  $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -ErrorAction Stop|Out-Null
  Start-ScheduledTask -TaskName $name
  $watch=[Diagnostics.Stopwatch]::StartNew()
  while($watch.Elapsed.TotalSeconds -lt 60){$info=Get-ScheduledTaskInfo -TaskName $name;$task=Get-ScheduledTask -TaskName $name;if($info.LastRunTime.Year -gt 2020 -and $task.State -eq 'Ready'){return [long]$info.LastTaskResult};Start-Sleep -Milliseconds 200}
  throw 'SYSTEM probe timed out'
}
try {
  # These identities and trust additions exist only in this disposable hosted VM.
  $certificate=New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Ventio CI fixture ONLY - NOT RELEASE' -CertStoreLocation Cert:\CurrentUser\My -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256
  $other=New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Ventio CI unapproved publisher' -CertStoreLocation Cert:\CurrentUser\My -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256
  foreach($cert in @($certificate,$other)){
    $cer=Join-Path $root ($cert.Thumbprint+'.cer');Export-Certificate -Cert $cert -FilePath $cer|Out-Null
    Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\Root|Out-Null
    if($cert.Thumbprint -eq $certificate.Thumbprint){Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher|Out-Null}
  }
  $body=@'
param([Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
__MODULE__
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
@{sid=$identity.User.Value;policy=[string](Get-ExecutionPolicy);scopes=@(Get-ExecutionPolicy -List|ForEach-Object {@{scope=[string]$_.Scope;policy=[string]$_.ExecutionPolicy}});version=[string]$PSVersionTable.PSVersion;value='signed-probe-ran'}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $OutputPath
'@
  $variants=@('valid','unsigned','tampered','untrusted','module-valid','module-unsigned','module-tampered','module-untrusted')
  foreach($variant in $variants){
    $directory=Join-Path $root $variant;[void][IO.Directory]::CreateDirectory($directory)
    $moduleLine=''
    if($variant.StartsWith('module-')){
      $modulePath=Join-Path $directory 'probe.psm1';Write-Source $modulePath "function Get-FixtureValue {'fixture'};Export-ModuleMember -Function Get-FixtureValue"
      $moduleLine="Import-Module (Join-Path `$PSScriptRoot 'probe.psm1') -Force -ErrorAction Stop"
    }
    $path=Join-Path $directory 'probe.ps1';Write-Source $path ($body.Replace('__MODULE__',$moduleLine))
    if($variant -ne 'unsigned'){
      [void](Set-VentioStagedScriptSignatures -Root $directory -CertificateThumbprint $certificate.Thumbprint -FixtureCertificate)
      if($variant -eq 'untrusted'){[void](Set-AuthenticodeSignature $path -Certificate $other -HashAlgorithm SHA256)}
      if($variant -eq 'tampered'){[IO.File]::AppendAllText($path,"`n# changed after signing`n")}
      if($variant -eq 'module-unsigned'){Write-Source $modulePath "function Get-FixtureValue {'unsigned'}"}
      if($variant -eq 'module-tampered'){[IO.File]::AppendAllText($modulePath,"`n# changed module`n")}
      if($variant -eq 'module-untrusted'){[void](Set-AuthenticodeSignature $modulePath -Certificate $other -HashAlgorithm SHA256)}
    }
  }
  Record 'SIG01-release-needs-timestamp' {$blocked=$false;try{Set-VentioStagedScriptSignatures -Root (Join-Path $root 'valid') -CertificateThumbprint $certificate.Thumbprint|Out-Null}catch{$blocked=$true};Require $blocked 'Release signature accepted without timestamp'}
  Record 'SIG02-source-tree-refused' {$blocked=$false;try{Set-VentioStagedScriptSignatures -Root (Join-Path $repo 'scripts/windows') -CertificateThumbprint $certificate.Thumbprint -FixtureCertificate|Out-Null}catch{$blocked=$true};Require $blocked 'Checked-out source signing accepted'}
  # Normal policy, both contexts, no ExecutionPolicy argument on either child.
  Set-ExecutionPolicy AllSigned -Scope LocalMachine -Force
  Set-ExecutionPolicy Undefined -Scope CurrentUser -Force
  Set-ExecutionPolicy Undefined -Scope Process -Force
  foreach($context in @('operator','SYSTEM')){foreach($variant in $variants){
    Record ('SIG-'+$context+'-'+$variant) {
      $outputPath=Join-Path $root ($context+'-'+$variant+'.json');$path=Join-Path (Join-Path $root $variant) 'probe.ps1'
      $exit=Invoke-Probe $path $context $outputPath
      if($variant -in @('valid','module-valid')){
        Require ($exit -eq 0 -and (Test-Path $outputPath)) 'Valid signed probe failed'
        $proof=Get-Content $outputPath -Raw|ConvertFrom-Json
        Require ($proof.policy -eq 'AllSigned' -and $proof.value -eq 'signed-probe-ran') 'Effective policy/probe mismatch'
        if($context -eq 'SYSTEM'){Require ($proof.sid -ceq 'S-1-5-18') 'Probe was not SYSTEM'}else{Require ($proof.sid -cne 'S-1-5-18') 'Operator probe was SYSTEM'}
        Copy-Item -LiteralPath $outputPath -Destination (Join-Path $out ('signing-'+$context+'-'+$variant+'.json'))
      } else {Require ($exit -ne 0 -and -not (Test-Path $outputPath)) 'Unsigned/tampered/unapproved content ran'}
    }
  }}
} catch {
  $results.Add(@{id='SIG-FIXTURE-SETUP';status='FAILED';reason=$_.Exception.Message})
  throw
} finally {
  # Restore the hosted fixture's original policy even after a probe fails.
  foreach($scope in @('Process','CurrentUser','LocalMachine')){Set-ExecutionPolicy $before[$scope] -Scope $scope -Force}
  foreach($task in $tasks){Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue}
  [ordered]@{sourceCommit=$env:GITHUB_SHA;runId=$env:GITHUB_RUN_ID;fixtureOnly=$true;releasePublisherTrusted=$false;cases=@($results.ToArray());physicalVmTouched=$false}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $out 'script-signing.json')
}
if(@($results|Where-Object status -eq 'FAILED').Count){throw 'Script signing/operator/SYSTEM compatibility failures'}
