$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows'){throw 'Disposable hosted Windows fixture required'}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$output=Join-Path $env:RUNNER_TEMP 'ventio-native-private-file-runtime'
& dotnet publish (Join-Path $repo 'installer\windows\host-service\VentioHostService.csproj') -c Release -o $output
if($LASTEXITCODE){throw 'Native private-file fixture compilation failed'}
$helper=Join-Path $output 'VentioHostService.exe'
if(-not (Test-Path -LiteralPath $helper -PathType Leaf)){throw 'Native private-file fixture runtime missing'}
$env:VENTIO_WINDOWS_PRIVATE_FILE_HELPER=$helper
'VENTIO_WINDOWS_PRIVATE_FILE_HELPER='+$helper | Out-File -LiteralPath $env:GITHUB_ENV -Encoding utf8 -Append
Write-Output 'Built actual native private-file runtime for disposable Dart tests; no services or policy were changed.'
