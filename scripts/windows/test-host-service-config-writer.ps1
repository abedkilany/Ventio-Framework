$ErrorActionPreference = 'Stop'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$testDirectory = Join-Path $tempRoot ('ventio-config-writer-test-' + [guid]::NewGuid().ToString('N'))
$resolvedTestDirectory = [IO.Path]::GetFullPath($testDirectory)
if (-not $resolvedTestDirectory.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Config writer test output must remain under the Windows temporary directory.'
}

$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$runtimeCredential = [PSCredential]::new('runtime_fixture', (ConvertTo-SecureString 'fixture-only-secret-a' -AsPlainText -Force))
$identityCredential = [PSCredential]::new('identity_fixture', (ConvertTo-SecureString 'fixture-only-secret-b' -AsPlainText -Force))

function Remove-TestDirectory([string] $Path) {
  $resolved = [IO.Path]::GetFullPath($Path)
  if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
      (Split-Path -Leaf $resolved) -notmatch '^ventio-config-writer-test-[0-9a-f]{32}$') {
    throw 'Refusing to remove a path outside this temporary configuration test.'
  }
  if (-not (Test-Path -LiteralPath $resolved)) { return }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}

try {
  & (Join-Path $PSScriptRoot 'write-host-service-config.ps1') `
    -RuntimeCredential $runtimeCredential `
    -IdentityApiCredential $identityCredential `
    -OutputDirectory $resolvedTestDirectory `
    -TestMode `
    -TestServiceSid $sid
  if (-not $?) { throw 'Host service configuration writer failed.' }

  $configPath = Join-Path $resolvedTestDirectory 'service-config.dpapi'
  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw 'Protected Host service configuration was not created.'
  }
  $fileBytes = [IO.File]::ReadAllBytes($configPath)
  try {
    $fileText = [Text.Encoding]::UTF8.GetString($fileBytes)
    if ($fileText.Contains('fixture-only-secret-a') -or $fileText.Contains('fixture-only-secret-b')) {
      throw 'Plaintext credential material appeared in the protected configuration file.'
    }
  }
  finally { [Array]::Clear($fileBytes, 0, $fileBytes.Length) }

  & dotnet run --project (Join-Path $PSScriptRoot '..\..\installer\windows\host-service.tests\HostService.Tests.csproj') `
    -c Release --no-restore -- --validate-file $configPath
  if ($LASTEXITCODE -ne 0) { throw 'Host service rejected the configuration written by the DPAPI writer.' }
  Write-Output 'Host DPAPI config writer integration passed: encrypted file, protected ACL, no plaintext credential bytes, service validator accepted.'
}
finally {
  $runtimeCredential = $null
  $identityCredential = $null
  if (Test-Path -LiteralPath $resolvedTestDirectory) {
    Remove-TestDirectory $resolvedTestDirectory
  }
}
