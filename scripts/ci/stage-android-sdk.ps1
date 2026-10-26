$ErrorActionPreference = 'Stop'

$sourceRoot = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$toolCacheRoot = 'C:\actions-runner\_work\_tool'
$stageRoot = Join-Path $toolCacheRoot 'ventio-android-sdk-seed'
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "The verified Android SDK source is unavailable: $sourceRoot"
}
if (-not (Test-Path -LiteralPath $toolCacheRoot -PathType Container)) {
    throw "The Actions runner tool cache is unavailable: $toolCacheRoot"
}

$expectedPackageProperties = @{
    'cmdline-tools\latest\source.properties' = 'Pkg.Revision=20.0'
    'platform-tools\source.properties' = 'Pkg.Revision=37.0.0'
    'platforms\android-36\source.properties' = 'AndroidVersion.ApiLevel=36'
    'build-tools\36.0.0\source.properties' = 'Pkg.Revision=36.0.0'
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
foreach ($relativePath in $expectedPackageProperties.Keys) {
    $sourcePath = Join-Path $sourceRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf) -or
        (Get-Content -LiteralPath $sourcePath -Raw) -notmatch [regex]::Escape($expectedPackageProperties[$relativePath])) {
        throw "Android SDK source package failed its version check: $relativePath"
    }
}
foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $relativePath) -PathType Leaf)) {
        throw "Android SDK source is missing a required file: $relativePath"
    }
}

$networkServiceSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-20')
$systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$administratorsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
    [Security.AccessControl.InheritanceFlags]::ObjectInherit
$accessType = [Security.AccessControl.AccessControlType]::Allow
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner($currentUserSid)
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    $currentUserSid,
    [Security.AccessControl.FileSystemRights]::FullControl,
    $inheritance,
    [Security.AccessControl.PropagationFlags]::None,
    $accessType
))
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    $networkServiceSid,
    [Security.AccessControl.FileSystemRights]::ReadAndExecute,
    $inheritance,
    [Security.AccessControl.PropagationFlags]::None,
    $accessType
))
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    $systemSid,
    [Security.AccessControl.FileSystemRights]::FullControl,
    $inheritance,
    [Security.AccessControl.PropagationFlags]::None,
    $accessType
))
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    $administratorsSid,
    [Security.AccessControl.FileSystemRights]::FullControl,
    $inheritance,
    [Security.AccessControl.PropagationFlags]::None,
    $accessType
))

$robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
if (Test-Path -LiteralPath $stageRoot) {
    $existingAcl = Get-Acl -LiteralPath $stageRoot
    if (-not $existingAcl.AreAccessRulesProtected) {
        throw "Preserving existing Android SDK staging directory with inherited permissions: $stageRoot"
    }
    $existingRules = foreach ($rule in $existingAcl.Access) {
        [pscustomobject]@{
            Sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            Rights = $rule.FileSystemRights
        }
    }
    $writeRights = [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    $serviceCanRead = @($existingRules | Where-Object {
        $_.Sid -eq $networkServiceSid.Value -and
        ($_.Rights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [Security.AccessControl.FileSystemRights]::ReadAndExecute
    }).Count -gt 0
    $serviceCanWrite = @($existingRules | Where-Object {
        $_.Sid -eq $networkServiceSid.Value -and ($_.Rights -band $writeRights) -ne 0
    }).Count -gt 0
    $broadAccess = @($existingRules | Where-Object { $_.Sid -in @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545') })
    if (-not $serviceCanRead -or $serviceCanWrite -or $broadAccess.Count -gt 0) {
        throw "Preserving existing Android SDK staging directory with unexpected permissions: $stageRoot"
    }
    foreach ($relativePath in $expectedPackageProperties.Keys) {
        $stagedPath = Join-Path $stageRoot $relativePath
        if (-not (Test-Path -LiteralPath $stagedPath -PathType Leaf) -or
            (Get-Content -LiteralPath $stagedPath -Raw) -notmatch [regex]::Escape($expectedPackageProperties[$relativePath])) {
            throw "Preserving existing Android SDK staging directory with an invalid package: $relativePath"
        }
    }
    $missingFiles = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $stageRoot $_) -PathType Leaf) })
    if ($missingFiles.Count -gt 0) {
        throw "Preserving existing incomplete Android SDK staging directory: $($missingFiles -join ', ')"
    }
    Write-Output "Verified existing persistent Android SDK staging directory: $stageRoot"
    exit 0
}
[IO.Directory]::CreateDirectory($stageRoot, $acl) | Out-Null

foreach ($relativePath in @('platform-tools', 'platforms\android-36', 'build-tools\36.0.0', 'cmdline-tools\latest', 'licenses')) {
    $sourcePath = Join-Path $sourceRoot $relativePath
    $destinationPath = Join-Path $stageRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "Android SDK source package directory is missing: $sourcePath"
    }
    & $robocopy $sourcePath $destinationPath /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Could not stage Android SDK package $relativePath (robocopy $LASTEXITCODE)." }
}

$stagedFilesMissing = @($requiredFiles | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $stageRoot $_) -PathType Leaf)
})
if ($stagedFilesMissing.Count -gt 0) {
    throw "Android SDK staging is incomplete: $($stagedFilesMissing -join ', ')"
}
foreach ($relativePath in $expectedPackageProperties.Keys) {
    $stagedPath = Join-Path $stageRoot $relativePath
    if ((Get-Content -LiteralPath $stagedPath -Raw) -notmatch [regex]::Escape($expectedPackageProperties[$relativePath])) {
        throw "Staged Android SDK package failed its version check: $relativePath"
    }
}
$stagedAcl = Get-Acl -LiteralPath $stageRoot
if (-not $stagedAcl.AreAccessRulesProtected) {
    throw "Android SDK staging directory must have a protected ACL: $stageRoot"
}
$stagedRules = foreach ($rule in $stagedAcl.Access) {
    [pscustomobject]@{
        Sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        Rights = $rule.FileSystemRights
    }
}
$writeRights = [Security.AccessControl.FileSystemRights]::WriteData -bor
    [Security.AccessControl.FileSystemRights]::AppendData -bor
    [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
    [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
    [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
    [Security.AccessControl.FileSystemRights]::Delete -bor
    [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
    [Security.AccessControl.FileSystemRights]::TakeOwnership
$serviceCanRead = @($stagedRules | Where-Object {
    $_.Sid -eq $networkServiceSid.Value -and
    ($_.Rights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [Security.AccessControl.FileSystemRights]::ReadAndExecute
}).Count -gt 0
$serviceCanWrite = @($stagedRules | Where-Object {
    $_.Sid -eq $networkServiceSid.Value -and
    ($_.Rights -band $writeRights) -ne 0
}).Count -gt 0
$broadAccess = @($stagedRules | Where-Object { $_.Sid -in @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545') })
if (-not $serviceCanRead -or $serviceCanWrite -or $broadAccess.Count -gt 0) {
    throw "Android SDK staging permissions are not restricted to the intended principals: $stageRoot"
}
Write-Output "Staged verified Android SDK packages in a persistent, protected directory: $stageRoot"
