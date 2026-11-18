$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows') { throw 'Fresh GitHub-hosted Windows runner required' }
$root = Join-Path $env:RUNNER_TEMP 'wave2-inputs'
if (Test-Path -LiteralPath $root) { throw 'Fresh input directory required; no acceptance cache is reused' }
[void](New-Item -ItemType Directory -Path $root)
$pins = Get-Content tests/wave2/build-inputs.json -Raw | ConvertFrom-Json
$records = @()
foreach ($name in @('dart','inno','pdfium')) {
  $pin = $pins.$name
  $extension = if ($name -eq 'dart') { '.zip' } elseif ($name -eq 'pdfium') { '.tgz' } else { '.exe' }
  $path = Join-Path $root ($name + $extension)
  Invoke-WebRequest -Uri $pin.url -OutFile $path
  $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($hash -cne $pin.sha256) { throw "Pinned upstream digest mismatch: $name" }
  $records += [pscustomobject]@{name=$name;url=$pin.url;sha256=$hash;bytes=(Get-Item -LiteralPath $path).Length}
}
$vc = Get-Content installer/windows/prerequisites/vc-runtime-prerequisite.json -Raw | ConvertFrom-Json
$vcPath = Join-Path $root 'vc_redist.x64.exe'
Invoke-WebRequest -Uri $vc.downloadUrl -OutFile $vcPath
./scripts/windows/test-vc-runtime-package.ps1 -RuntimeInstallerPath $vcPath
$records += [pscustomobject]@{name='vc-runtime';url=$vc.downloadUrl;sha256=(Get-FileHash $vcPath -Algorithm SHA256).Hash.ToLowerInvariant();bytes=(Get-Item $vcPath).Length}
$inno = Join-Path $root 'inno.exe'
$sig = Get-AuthenticodeSignature -LiteralPath $inno
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -ne 'Pyrsys B.V.') { throw 'Inno publisher verification failed' }
$proc = Start-Process -FilePath $inno -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' -Wait -PassThru -WindowStyle Hidden
if ($proc.ExitCode -ne 0) { throw 'Pinned Inno compiler staging failed' }
Expand-Archive -LiteralPath (Join-Path $root 'dart.zip') -DestinationPath (Join-Path $root 'host-sdk')
$dartBin = Join-Path $root 'host-sdk/dart-sdk/bin'
$dartBin | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append
"VENTIO_HOST_DART_BIN=$dartBin" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
$records | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'upstream-inputs.json')
$source = git rev-parse HEAD
if ($source -cne $env:GITHUB_SHA -or (git status --porcelain --untracked-files=no)) { throw 'Checkout is not the requested clean commit' }
[pscustomobject]@{commit=$source;tree=(git rev-parse 'HEAD^{tree}');runId=$env:GITHUB_RUN_ID;attempt=$env:GITHUB_RUN_ATTEMPT;runnerEnvironment=$env:RUNNER_ENVIRONMENT;machine=$env:COMPUTERNAME;imageOS=$env:ImageOS;imageVersion=$env:ImageVersion;utc=[datetime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'hosted-provenance.json')
