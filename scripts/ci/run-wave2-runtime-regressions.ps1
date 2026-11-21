$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:COMPUTERNAME -in @('BAHAA','TEST-01','TEST-02')){throw 'Disposable hosted Windows regression only'}
if((Get-Service VentioHost,VentioPostgres -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $env:ProgramData 'Ventio'))){throw 'Fresh machine with no product data required'}
$out=Join-Path (Get-Location) 'test-results/wave2-runtime'
[void](New-Item -ItemType Directory -Path $out)
$rows=@()
$pgRoot=Split-Path -Parent $env:VENTIO_TEST_POSTGRES_BIN_DIR
$plans=@(
  @{id='NET-HOST-SERVICE';exe='dotnet';arguments=@('run','--project','installer/windows/host-service.tests/HostService.Tests.csproj','-c','Release')},
  @{id='NET-SETUP-BROKER';exe='dotnet';arguments=@('run','--project','installer/windows/setup-broker.tests/VentioSetupBroker.Tests.csproj','-c','Release')},
  @{id='PG-SINGLE-USER-RECOVERY';exe='powershell.exe';arguments=@('-NoLogo','-NoProfile','-NonInteractive','-File','scripts/windows/test-postgres-single-user-recovery.ps1','-PostgresRoot',$pgRoot)}
)
foreach($plan in $plans){
  $log=Join-Path $out ($plan.id+'.log')
  & $plan.exe @($plan.arguments) *> $log
  $code=$LASTEXITCODE
  Get-Content -LiteralPath $log
  $rows += [pscustomobject]@{id=$plan.id;exitCode=$code;status=$(if($code -eq 0){'PASSED'}else{'FAILED'});log=($plan.id+'.log')}
  [ordered]@{commit=$env:GITHUB_SHA;runId=$env:GITHUB_RUN_ID;sdk=(& dotnet --version);postgres=(& (Join-Path $env:VENTIO_TEST_POSTGRES_BIN_DIR 'postgres.exe') --version);cases=$rows;physicalMachinesTouched=$false} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $out 'runtime-results.json')
}
if(@($rows | Where-Object status -ne 'PASSED').Count){throw 'Targeted runtime regressions failed; see retained individual logs'}
