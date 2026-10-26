param(
    [switch]$Stage,
    [string]$ArchivePath
)

$ErrorActionPreference = 'Stop'
$dartVersion = '3.13.7'
$archiveLength = 219893829L
$archiveMd5Base64 = 'CipfP/Z6jbPlljHMTmO9EQ=='
$archiveSha256 = '3b31d9f90b27861f29842d378f39f98ce9e60910042334f950ef5702f174fb81'
$toolCacheRoot = 'C:\actions-runner\_work\_tool'
if ($env:RUNNER_TOOL_CACHE -and
    -not [string]::Equals([IO.Path]::GetFullPath($env:RUNNER_TOOL_CACHE).TrimEnd('\'), $toolCacheRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Dart SDK must remain inside the dedicated runner tool cache: $toolCacheRoot"
}
$installRoot = Join-Path $toolCacheRoot 'ventio-dart-sdk-3.13.7-x64'
$dartRoot = Join-Path $installRoot 'dart-sdk'
$dartBin = Join-Path $dartRoot 'bin'
$dartExe = Join-Path $dartBin 'dart.exe'

function Get-RestrictedAclState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) {
        throw "Dart SDK directory must have a protected ACL: $Path"
    }
    $rules = foreach ($rule in $acl.Access) {
        [pscustomobject]@{
            Sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            Rights = $rule.FileSystemRights
            Type = $rule.AccessControlType
        }
    }
    $networkServiceSid = 'S-1-5-20'
    $writeRights = [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    $serviceCanRead = @($rules | Where-Object {
        $_.Sid -eq $networkServiceSid -and
        $_.Type -eq [Security.AccessControl.AccessControlType]::Allow -and
        ($_.Rights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [Security.AccessControl.FileSystemRights]::ReadAndExecute
    }).Count -gt 0
    $serviceCanWrite = @($rules | Where-Object {
        $_.Sid -eq $networkServiceSid -and
        $_.Type -eq [Security.AccessControl.AccessControlType]::Allow -and
        ($_.Rights -band $writeRights) -ne 0
    }).Count -gt 0
    $broadAccess = @($rules | Where-Object {
        $_.Sid -in @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')
    })
    if (-not $serviceCanRead -or $serviceCanWrite -or $broadAccess.Count -gt 0) {
        throw "Dart SDK must be readable but not writable by NETWORK SERVICE, with no broad ACLs: $Path"
    }
}

function Test-DartVersion {
    if (-not (Test-Path -LiteralPath $dartExe -PathType Leaf)) {
        throw "The pinned Dart SDK is not staged at $dartExe; run this script with -Stage first."
    }
    $versionOutput = (& $dartExe --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch "Dart SDK version: $([regex]::Escape($dartVersion))\b") {
        throw "Expected Dart $dartVersion at $dartExe; received: $versionOutput"
    }
    return $versionOutput
}

if ($Stage) {
    if (-not $ArchivePath) {
        throw 'Specify the verified Dart SDK archive with -ArchivePath.'
    }
    $ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "Dart SDK archive not found: $ArchivePath"
    }
    if (Test-Path -LiteralPath $installRoot) {
        $versionOutput = Test-DartVersion
        Get-RestrictedAclState -Path $installRoot
        Write-Output "Using existing protected Dart SDK: $versionOutput"
        exit 0
    }

    $archive = Get-Item -LiteralPath $ArchivePath
    if ($archive.Length -ne $archiveLength) {
        throw "Dart SDK archive length mismatch: expected $archiveLength, received $($archive.Length)."
    }
    $actualSha256 = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $archiveSha256) {
        throw "Dart SDK SHA-256 mismatch: expected $archiveSha256, received $actualSha256."
    }
    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        $archiveStream = [IO.File]::OpenRead($ArchivePath)
        try {
            $actualMd5Base64 = [Convert]::ToBase64String($md5.ComputeHash($archiveStream))
        } finally {
            $archiveStream.Dispose()
        }
    } finally {
        $md5.Dispose()
    }
    if ($actualMd5Base64 -ne $archiveMd5Base64) {
        throw "Dart SDK official archive checksum mismatch: expected $archiveMd5Base64, received $actualMd5Base64."
    }

    $currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $networkServiceSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-20')
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administratorsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
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

    [IO.Directory]::CreateDirectory($installRoot, $acl) | Out-Null
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $installRoot
    $versionOutput = Test-DartVersion
    Get-RestrictedAclState -Path $installRoot
    Write-Output "Staged and verified the official Dart SDK: $versionOutput"
    exit 0
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.User.Equals([Security.Principal.SecurityIdentifier]::new('S-1-5-20'))) {
    throw "Expected the runner job to run as NETWORK SERVICE; received $($identity.Name)."
}
Get-RestrictedAclState -Path $installRoot
$versionOutput = Test-DartVersion
if (-not (Test-Path -LiteralPath $env:GITHUB_PATH -PathType Leaf)) {
    throw 'GitHub Actions did not provide GITHUB_PATH for the job.'
}
$utf8WithoutBom = [Text.UTF8Encoding]::new($false)
[IO.File]::AppendAllText($env:GITHUB_PATH, $dartBin + [Environment]::NewLine, $utf8WithoutBom)
Write-Output "Verified the protected pinned Dart SDK: $versionOutput"
