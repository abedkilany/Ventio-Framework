param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Elevated disposable Windows test process required'}
$iscc=Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
$source='tests/wave2/postinstall_upgrade_failure_fixture.iss'
$output=[IO.Path]::GetFullPath($OutputDirectory)
[void](New-Item -ItemType Directory -Path $output -Force)
$cases=@()
foreach($mode in @('pass','fail')){
  & $iscc ('/DFixtureOutput='+$output) ('/DFixtureMode='+$mode) $source | Out-Null
  if($LASTEXITCODE){throw "Actual Inno postinstall fixture compile failed: $mode"}
  $exe=Join-Path $output ('postinstall-'+$mode+'.exe')
  $process=Start-Process -FilePath $exe -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' -PassThru -WindowStyle Hidden
  if(-not $process.WaitForExit(30000)){
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw "Silent Inno postinstall fixture hung: $mode"
  }
  $expected=if($mode -eq 'fail'){9}else{0}
  if($process.ExitCode -ne $expected){throw "Silent Inno postinstall exit mismatch: $mode / $($process.ExitCode)"}
  $cases+=@{mode=$mode;exitCode=$process.ExitCode;expectedExitCode=$expected;withinThirtySeconds=$true;sha256=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$report=[ordered]@{case='ACTUAL_INNO_SILENT_POSTINSTALL_EXIT';status='PASS';utc=[datetime]::UtcNow.ToString('o');sourceCommit=$env:GITHUB_SHA;runId=$env:GITHUB_RUN_ID;usesActualProductionPostinstallInclude=$true;hostServicesTouched=$false;cases=$cases}
$report|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $output 'postinstall-exit-results.json') -Encoding UTF8
$report|ConvertTo-Json -Depth 5
