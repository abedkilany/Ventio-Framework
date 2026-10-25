$ErrorActionPreference = 'Stop'

$toolCacheRoot = [IO.Path]::GetFullPath($env:RUNNER_TOOL_CACHE).TrimEnd('\')
$sdkRoot = [IO.Path]::GetFullPath($env:ANDROID_SDK_ROOT).TrimEnd('\')
$expectedSdkRoot = Join-Path $toolCacheRoot 'ventio-android-sdk-36'
if (-not [string]::Equals($sdkRoot, $expectedSdkRoot, [StringComparison]::OrdinalIgnoreCase) -or
    -not [string]::Equals($env:ANDROID_HOME, $expectedSdkRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Android SDK path must be isolated under RUNNER_TOOL_CACHE: $expectedSdkRoot"
}

$networkServiceSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-20')
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.User.Equals($networkServiceSid)) {
    throw "Expected the runner job to run as NETWORK SERVICE; received $($identity.Name)."
}

$sdkAcl = Get-Acl -LiteralPath $sdkRoot
if (-not $sdkAcl.AreAccessRulesProtected) {
    throw "Android SDK directory must have a protected ACL: $sdkRoot"
}
$broadAccess = @($sdkAcl.Access | Where-Object {
    $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
    $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -in @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')
})
if ($broadAccess.Count -gt 0) {
    throw "Android SDK directory is accessible to a broad Windows principal: $sdkRoot"
}

$expectedPackageProperties = @{
    'cmdline-tools\latest\source.properties' = 'Pkg.Revision=20.0'
    'platform-tools\source.properties' = 'Pkg.Revision=37.0.0'
    'platforms\android-36\source.properties' = 'AndroidVersion.ApiLevel=36'
    'build-tools\36.0.0\source.properties' = 'Pkg.Revision=36.0.0'
}
foreach ($relativePath in $expectedPackageProperties.Keys) {
    $sourcePath = Join-Path $sdkRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf) -or
        (Get-Content -LiteralPath $sourcePath -Raw) -notmatch [regex]::Escape($expectedPackageProperties[$relativePath])) {
        throw "Android SDK package failed its version check: $relativePath"
    }
}

$requiredFiles = @(
    'cmdline-tools\latest\bin\sdkmanager.bat',
    'platform-tools\adb.exe',
    'platforms\android-36\android.jar',
    'build-tools\36.0.0\aapt2.exe',
    'build-tools\36.0.0\apksigner.bat',
    'build-tools\36.0.0\zipalign.exe',
    'licenses\android-sdk-license'
)
$missingFiles = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $sdkRoot $_) -PathType Leaf) })
if ($missingFiles.Count -gt 0) {
    throw "Android SDK is missing required files: $($missingFiles -join ', ')"
}

if (-not (Test-Path -LiteralPath $env:GITHUB_PATH -PathType Leaf)) {
    throw 'GitHub Actions did not provide GITHUB_PATH for the job.'
}
$sdkManagerBin = Join-Path $sdkRoot 'cmdline-tools\latest\bin'
$platformToolsBin = Join-Path $sdkRoot 'platform-tools'
$utf8WithoutBom = [Text.UTF8Encoding]::new($false)
[IO.File]::AppendAllText($env:GITHUB_PATH, $sdkManagerBin + [Environment]::NewLine, $utf8WithoutBom)
[IO.File]::AppendAllText($env:GITHUB_PATH, $platformToolsBin + [Environment]::NewLine, $utf8WithoutBom)

Write-Output "Verified Android SDK packages and licenses in isolated root: $sdkRoot"
Write-Output 'Added the verified Android SDK command-line tools and platform-tools to this job PATH.'
