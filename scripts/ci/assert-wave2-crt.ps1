$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted'){throw 'Hosted compiler verification required'}
$vswhere="${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs=(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Out-String).Trim()
if($LASTEXITCODE -ne 0 -or -not $vs){throw 'Cannot identify selected C++ toolchain'}
$toolset=(Get-Content -LiteralPath (Join-Path $vs 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
$pins=Get-Content tests/wave2/build-inputs.json -Raw | ConvertFrom-Json
if($toolset -cne $pins.msvc.toolset){throw 'Hosted MSVC version drifted from the reviewed build pin'}
$headerPath=Join-Path $vs "VC/Tools/MSVC/$toolset/include/crtversion.h"
$header=Get-Content -LiteralPath $headerPath -Raw
$versions=@{}
foreach($part in @('MAJOR','MINOR','BUILD','RBUILD')){
  $foundValue=[regex]::Match($header,"(?m)^\s*#define\s+_VC_CRT_${part}_VERSION\s+([0-9]+)\b")
  if(-not $foundValue.Success){throw "Cannot identify CRT $part from installed headers"}
  $versions[$part]=[int]$foundValue.Groups[1].Value
}
$required=[version]::new($versions.MAJOR,$versions.MINOR,$versions.BUILD,$versions.RBUILD)
$manifest=Get-Content installer/windows/prerequisites/vc-runtime-prerequisite.json -Raw | ConvertFrom-Json
$result=[ordered]@{toolset=$toolset;header=$headerPath;headerSha256=(Get-FileHash $headerPath -Algorithm SHA256).Hash.ToLowerInvariant();crtHeaderVersion=$required.ToString();minimumRuntime=$manifest.minimumRuntimeVersion;bundledRuntime=$manifest.packageVersion}
$result | ConvertTo-Json | Set-Content (Join-Path $env:RUNNER_TEMP 'wave2-crt-compatibility.json')
$result | ConvertTo-Json
if([version]$manifest.minimumRuntimeVersion -lt $required -or [version]$manifest.packageVersion -lt [version]$manifest.minimumRuntimeVersion){throw 'Pinned runtime/floor is older than the selected CRT; build must stop'}
