$ErrorActionPreference = 'Stop'

$toolCacheRoot = [IO.Path]::GetFullPath($env:RUNNER_TOOL_CACHE).TrimEnd('\')
$sdkRoot = [IO.Path]::GetFullPath($env:ANDROID_SDK_ROOT).TrimEnd('\')
$expectedSdkRoot = Join-Path $toolCacheRoot 'ventio-android-sdk-36'
if (-not [string]::Equals($sdkRoot, $expectedSdkRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Android SDK path must remain inside RUNNER_TOOL_CACHE: $expectedSdkRoot"
}

$requiredFiles = @(
    'platform-tools\adb.exe',
    'platforms\android-36\android.jar',
    'build-tools\36.0.0\aapt2.exe',
    'cmdline-tools\latest\bin\sdkmanager.bat',
    'licenses\android-sdk-license'
)
if (@($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $sdkRoot $_) -PathType Leaf) }).Count -eq 0) {
    Write-Output "All required packages are already present in the isolated Android SDK: $sdkRoot"
    exit 0
}

$stageRoot = Join-Path ([IO.Path]::GetFullPath($toolCacheRoot).TrimEnd('\')) 'ventio-android-sdk-seed'
if (-not (Test-Path -LiteralPath $stageRoot -PathType Container)) {
    throw "Required isolated Android SDK packages are missing and no verified seed is available: $stageRoot"
}

$networkServiceSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-20')
$stageAcl = Get-Acl -LiteralPath $stageRoot
if (-not $stageAcl.AreAccessRulesProtected) {
    throw "Refusing to read Android SDK seed with inherited permissions: $stageRoot"
}
$stageRules = foreach ($rule in $stageAcl.Access) {
    [pscustomobject]@{
        Sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        Rights = $rule.FileSystemRights
    }
}
$networkServiceCanRead = @($stageRules | Where-Object {
    $_.Sid -eq $networkServiceSid.Value -and
    ($_.Rights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [Security.AccessControl.FileSystemRights]::ReadAndExecute
}).Count -gt 0
$writeRights = [Security.AccessControl.FileSystemRights]::WriteData -bor
    [Security.AccessControl.FileSystemRights]::AppendData -bor
    [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
    [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
    [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
    [Security.AccessControl.FileSystemRights]::Delete -bor
    [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
    [Security.AccessControl.FileSystemRights]::TakeOwnership
$networkServiceCanWrite = @($stageRules | Where-Object {
    $_.Sid -eq $networkServiceSid.Value -and
    ($_.Rights -band $writeRights) -ne 0
}).Count -gt 0
$broadAccess = @($stageRules | Where-Object { $_.Sid -in @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545') })
if (-not $networkServiceCanRead -or $networkServiceCanWrite -or $broadAccess.Count -gt 0) {
    throw "Refusing to read an Android SDK seed without a narrow read-only ACL: $stageRoot"
}

$sourceProperties = @{
    'cmdline-tools\latest\source.properties' = 'Pkg.Revision=20.0'
    'platforms\android-36\source.properties' = 'AndroidVersion.ApiLevel=36'
    'build-tools\36.0.0\source.properties' = 'Pkg.Revision=36.0.0'
}
foreach ($relativePath in $sourceProperties.Keys) {
    $sourcePath = Join-Path $stageRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf) -or
        (Get-Content -LiteralPath $sourcePath -Raw) -notmatch [regex]::Escape($sourceProperties[$relativePath])) {
        throw "Staged Android SDK package failed its version check: $relativePath"
    }
}

$robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
foreach ($relativePath in @('platform-tools', 'platforms\android-36', 'build-tools\36.0.0', 'cmdline-tools\latest', 'licenses')) {
    $sourcePath = Join-Path $stageRoot $relativePath
    $destinationPath = Join-Path $sdkRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "Staged Android SDK package directory is missing: $sourcePath"
    }
    & $robocopy $sourcePath $destinationPath /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Could not seed Android SDK package $relativePath (robocopy $LASTEXITCODE)." }
}

$missingFiles = @($requiredFiles | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $sdkRoot $_) -PathType Leaf)
})
if ($missingFiles.Count -gt 0) {
    throw "Android SDK seeding is incomplete: $($missingFiles -join ', ')"
}
Write-Output "Seeded only the verified API 36, Build Tools 36.0.0, platform-tools, command-line tools, and license files into $sdkRoot."
