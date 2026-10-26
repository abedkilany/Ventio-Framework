[CmdletBinding()]
param(
    [switch]$Stage
)

$ErrorActionPreference = 'Stop'

$ndkVersion = '28.2.13676358'
$ndkRelativePath = "ndk\$ndkVersion"
$ndkRequiredFiles = @(
    'source.properties',
    'ndk-build.cmd',
    'build\cmake\android.toolchain.cmake',
    'toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe'
)
$networkServiceSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-20')
$writeRights = [Security.AccessControl.FileSystemRights]::WriteData -bor
    [Security.AccessControl.FileSystemRights]::AppendData -bor
    [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
    [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
    [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
    [Security.AccessControl.FileSystemRights]::Delete -bor
    [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
    [Security.AccessControl.FileSystemRights]::TakeOwnership
$robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'

function Assert-NdkPackage {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Pinned Android NDK package is missing: $Path"
    }
    $package = Get-Item -LiteralPath $Path -Force
    if ($package.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to use an NDK package that is a reparse point: $Path"
    }

    $propertiesPath = Join-Path $Path 'source.properties'
    if (-not (Test-Path -LiteralPath $propertiesPath -PathType Leaf) -or
        (Get-Content -LiteralPath $propertiesPath -Raw) -notmatch '(?m)^\s*Pkg\.Revision\s*=\s*28\.2\.13676358\s*$') {
        throw "Android NDK package revision must be ${ndkVersion}: $propertiesPath"
    }
    foreach ($relativeFile in $ndkRequiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $relativeFile) -PathType Leaf)) {
            throw "Android NDK $ndkVersion is missing required file: $relativeFile"
        }
    }
}

function Assert-StageRoot {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "The persistent Android SDK stage is missing: $Path"
    }
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) {
        throw "Android SDK stage must have a protected ACL: $Path"
    }
    $rules = foreach ($rule in $acl.Access) {
        [pscustomobject]@{
            Sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            Rights = $rule.FileSystemRights
            Type = $rule.AccessControlType
        }
    }
    $serviceReadOnly = @($rules | Where-Object {
        $_.Sid -eq $networkServiceSid.Value -and
        $_.Type -eq [Security.AccessControl.AccessControlType]::Allow -and
        ($_.Rights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [Security.AccessControl.FileSystemRights]::ReadAndExecute -and
        ($_.Rights -band $writeRights) -eq 0
    }).Count -gt 0
    $broadAccess = @($rules | Where-Object {
        $_.Type -eq [Security.AccessControl.AccessControlType]::Allow -and
        $_.Sid -in @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')
    })
    if (-not $serviceReadOnly -or $broadAccess.Count -gt 0) {
        throw "Android SDK stage is not restricted to read-only NETWORK SERVICE access: $Path"
    }
}

function Copy-NdkMirror {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $destinationParent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    if (Test-Path -LiteralPath $Destination) {
        $item = Get-Item -LiteralPath $Destination -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to mirror NDK into a reparse-point directory: $Destination"
        }
    }
    & $robocopy $Source $Destination /MIR /COPY:DAT /DCOPY:DAT /R:2 /W:1 /XJ /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "Could not mirror Android NDK $ndkVersion to $Destination (robocopy $LASTEXITCODE)."
    }
}

if ($Stage) {
    $sourceRoot = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    $sourceNdk = Join-Path $sourceRoot $ndkRelativePath
    $toolCacheRoot = 'C:\actions-runner\_work\_tool'
    $stageRoot = Join-Path $toolCacheRoot 'ventio-android-sdk-seed'
    $stagedNdk = Join-Path $stageRoot $ndkRelativePath

    Assert-NdkPackage -Path $sourceNdk
    Assert-StageRoot -Path $stageRoot
    if ((Test-Path -LiteralPath $stagedNdk -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $stagedNdk 'source.properties') -PathType Leaf) -and
        (Get-Content -LiteralPath (Join-Path $stagedNdk 'source.properties') -Raw) -match '(?m)^\s*Pkg\.Revision\s*=\s*28\.2\.13676358\s*$') {
        Assert-NdkPackage -Path $stagedNdk
        Write-Output "Verified Android NDK $ndkVersion is already staged: $stagedNdk"
        exit 0
    }

    Copy-NdkMirror -Source $sourceNdk -Destination $stagedNdk
    Assert-NdkPackage -Path $stagedNdk
    Assert-StageRoot -Path $stageRoot
    Write-Output "Staged verified Android NDK $ndkVersion with read-only runner access: $stagedNdk"
    exit 0
}

$toolCacheRoot = [IO.Path]::GetFullPath($env:RUNNER_TOOL_CACHE).TrimEnd('\')
$sdkRoot = [IO.Path]::GetFullPath($env:ANDROID_SDK_ROOT).TrimEnd('\')
$expectedSdkRoot = Join-Path $toolCacheRoot 'ventio-android-sdk-36'
if (-not [string]::Equals($sdkRoot, $expectedSdkRoot, [StringComparison]::OrdinalIgnoreCase) -or
    -not [string]::Equals($env:ANDROID_HOME, $expectedSdkRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Android NDK destination must remain inside the isolated SDK: $expectedSdkRoot"
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.User.Equals($networkServiceSid)) {
    throw "Expected the runner job to run as NETWORK SERVICE; received $($identity.Name)."
}

$stageRoot = Join-Path $toolCacheRoot 'ventio-android-sdk-seed'
$stagedNdk = Join-Path $stageRoot $ndkRelativePath
$sdkNdk = Join-Path $sdkRoot $ndkRelativePath
Assert-StageRoot -Path $stageRoot
Assert-NdkPackage -Path $stagedNdk

if ((Test-Path -LiteralPath $sdkNdk -PathType Container) -and
    (Test-Path -LiteralPath (Join-Path $sdkNdk 'source.properties') -PathType Leaf) -and
    (Get-Content -LiteralPath (Join-Path $sdkNdk 'source.properties') -Raw) -match '(?m)^\s*Pkg\.Revision\s*=\s*28\.2\.13676358\s*$') {
    Assert-NdkPackage -Path $sdkNdk
    Write-Output "Verified Android NDK $ndkVersion in the isolated SDK: $sdkNdk"
    exit 0
}

Copy-NdkMirror -Source $stagedNdk -Destination $sdkNdk
Assert-NdkPackage -Path $sdkNdk
Write-Output "Seeded Android NDK $ndkVersion into the isolated SDK: $sdkNdk"
