$ErrorActionPreference = 'Stop'

$toolCacheRoot = [IO.Path]::GetFullPath($env:RUNNER_TOOL_CACHE).TrimEnd('\')
$sdkRoot = [IO.Path]::GetFullPath($env:ANDROID_SDK_ROOT).TrimEnd('\')
$expectedSdkRoot = Join-Path $toolCacheRoot 'ventio-android-sdk-36'
if (-not [string]::Equals($sdkRoot, $expectedSdkRoot, [StringComparison]::OrdinalIgnoreCase) -or
    -not [string]::Equals($env:ANDROID_HOME, $expectedSdkRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Android SDK path must be isolated under RUNNER_TOOL_CACHE: $expectedSdkRoot"
}

$networkServiceSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-20')
$systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$administratorsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.User.Equals($networkServiceSid)) {
    throw "Expected the runner job to run as NETWORK SERVICE; received $($identity.Name)."
}

$inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
    [Security.AccessControl.InheritanceFlags]::ObjectInherit
$accessType = [Security.AccessControl.AccessControlType]::Allow
if (Test-Path -LiteralPath $sdkRoot) {
    $existingAcl = Get-Acl -LiteralPath $sdkRoot
    if (-not $existingAcl.AreAccessRulesProtected) {
        throw "Preserving Android SDK directory with inherited permissions for inspection: $sdkRoot"
    }

    $existingRules = @($existingAcl.Access | Where-Object { $_.AccessControlType -eq $accessType })
    $translatedRules = foreach ($rule in $existingRules) {
        [pscustomobject]@{
            Sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            Rights = $rule.FileSystemRights
        }
    }
    $serviceHasModify = @($translatedRules | Where-Object {
        $_.Sid -eq $networkServiceSid.Value -and
        ($_.Rights -band [Security.AccessControl.FileSystemRights]::Modify) -eq [Security.AccessControl.FileSystemRights]::Modify
    }).Count -gt 0
    $systemHasFullControl = @($translatedRules | Where-Object {
        $_.Sid -eq $systemSid.Value -and $_.Rights -band [Security.AccessControl.FileSystemRights]::FullControl
    }).Count -gt 0
    $administratorsHaveFullControl = @($translatedRules | Where-Object {
        $_.Sid -eq $administratorsSid.Value -and $_.Rights -band [Security.AccessControl.FileSystemRights]::FullControl
    }).Count -gt 0
    $unexpectedPrincipals = @($translatedRules | Where-Object { $_.Sid -in @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545') })
    if (-not $serviceHasModify -or -not $systemHasFullControl -or
        -not $administratorsHaveFullControl -or $unexpectedPrincipals.Count -gt 0) {
        throw "Preserving Android SDK directory with an unexpected ACL for inspection: $sdkRoot"
    }
    Write-Output "Using existing isolated Android SDK home: $sdkRoot"
    exit 0
}

$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner($networkServiceSid)
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    $networkServiceSid,
    [Security.AccessControl.FileSystemRights]::Modify,
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

[IO.Directory]::CreateDirectory($sdkRoot) | Out-Null
Set-Acl -LiteralPath $sdkRoot -AclObject $acl
Write-Output "Created isolated Android SDK home with a protected ACL: $sdkRoot"
