$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:COMPUTERNAME -in @('BAHAA','TEST-01','TEST-02')){throw 'HOSTED_OBSERVER_HARNESS_ONLY'}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$out=Join-Path $repo 'test-results/recovery-admission';[void][IO.Directory]::CreateDirectory($out)
$progressPath=Join-Path $out 'observer-progress.json'
$info=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'))
$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
$info.Arguments='-NoLogo -NoProfile -NonInteractive -File "'+(Join-Path $PSScriptRoot 'test-recovery-lab-observer.ps1')+'"'
# Do not let PowerShell 7's inherited module path resolve PS7 assemblies inside
# Windows PowerShell 5.1. This changes only the child environment, never policy.
$info.EnvironmentVariables['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')
$process=[Diagnostics.Process]::Start($info)
$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
$watch=[Diagnostics.Stopwatch]::StartNew();$phaseWatch=[Diagnostics.Stopwatch]::StartNew();$stage='startup';$failed=$false
try {
  while(-not $process.WaitForExit(1000)){
    if(Test-Path $progressPath){
      try{$progress=Get-Content $progressPath -Raw|ConvertFrom-Json;if($progress.stage -cne $stage){$stage=$progress.stage;$phaseWatch.Restart();Write-Host ('OBSERVER-PHASE '+$stage)}}catch{Write-Host 'Progress update in flight'}
    }
    $limit=90;if($stage -like 'OBS16-*'){$limit=240}
    if($phaseWatch.Elapsed.TotalSeconds -gt $limit -or $watch.Elapsed.TotalSeconds -gt 480){$failed=$true;throw ('OBSERVER_FIXTURE_TIMEOUT_PHASE_'+$stage)}
  }
  if($process.ExitCode -ne 0){$failed=$true}
} catch {$failed=$true;throw} finally {
  if(-not $process.HasExited){$process.Kill($true);[void]$process.WaitForExit(10000)}
  # A stuck descendant must not make log collection unbounded. Hosted runner
  # orphan cleanup discards remaining fixture processes with the entire VM.
  foreach($entry in @(@{task=$stdout;name='observer-stdout.log'},@{task=$stderr;name='observer-stderr.log'})){
    if($entry.task.Wait(5000)){$text=$entry.task.GetAwaiter().GetResult();[IO.File]::WriteAllText((Join-Path $out $entry.name),$text,[Text.UTF8Encoding]::new($false));Write-Host $text}
  }
  @{sourceCommit=$env:GITHUB_SHA;runId=$env:GITHUB_RUN_ID;stage=$stage;status=$(if($failed){'FAILED'}else{'PASSED'});elapsedSeconds=$watch.Elapsed.TotalSeconds}|ConvertTo-Json|Set-Content (Join-Path $out 'observer-harness.json')
  $process.Dispose()
}
if($failed){throw 'Observer fixture process failed; see phase, case and bounded logs'}
