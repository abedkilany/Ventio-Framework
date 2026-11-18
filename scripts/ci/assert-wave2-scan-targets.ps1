param([Parameter(Mandatory)][string[]]$Paths, [Parameter(Mandatory)][string]$EvidencePath)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted'){throw 'Hosted verification only'}
$mp=Join-Path $env:ProgramData 'Microsoft/Windows Defender/Platform/CurrentVersion/MpCmdRun.exe'
$signature=Get-AuthenticodeSignature -LiteralPath $mp
if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike '*Microsoft*'){throw 'Defender CLI signature not verified'}
$checks=@()
$complete=$false
try {
  # Normal API changes may take time to reach the engine. Observe only; never
  # suppress an excluded result, restart protection or change another policy.
  for($attempt=0;$attempt -lt 13;$attempt++){
    $clear=$true
    foreach($targetPath in $Paths){
      if(-not(Test-Path -LiteralPath $targetPath)){throw 'Scan target missing'}
      $output=& $mp -CheckExclusion -Path $targetPath 2>&1 | Out-String
      $code=$LASTEXITCODE
      $checks += [pscustomobject]@{attempt=$attempt;utc=[datetime]::UtcNow.ToString('o');path=$targetPath;exitCode=$code;output=$output.Trim()}
      if($code -ne 1){$clear=$false}
    }
    if($clear){$complete=$true;break}
    if($attempt -lt 12){Start-Sleep -Seconds 5}
  }
} finally {
  [ordered]@{allTargetsEffectivelyNotExcluded=$complete;checks=$checks} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $EvidencePath
}
if(-not $complete){throw 'Effective Defender exclusion checks remain blocked after bounded observation; no bypass attempted'}
