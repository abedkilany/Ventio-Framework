$ErrorActionPreference = 'Stop'

function New-HostProductDataRootAcl {
  param([string[]] $ServiceSids = @())
  $acl = [Security.AccessControl.DirectorySecurity]::new()
  $acl.SetAccessRuleProtection($true, $false)
  $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
  foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
      [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'Allow'))
  }
  foreach ($sid in ($ServiceSids | Select-Object -Unique)) {
    if ($sid -notmatch '^S-1-5-80-\d+-\d+-\d+-\d+-\d+$') { throw 'HOST_PRODUCT_ROOT_SERVICE_SID_INVALID' }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
      [Security.Principal.SecurityIdentifier]::new($sid), 'ReadAndExecute', 'Allow'))
  }
  return $acl
}

function Protect-HostProductDataRoot {
  param([string] $TestRoot, [switch] $TestMode)
  $programData = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData))
  $root = Join-Path $programData 'Ventio'
  if ($TestMode) {
    $testParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($TestRoot)
    if (-not ([IO.Directory]::GetParent($root).FullName.Equals($testParent,[StringComparison]::OrdinalIgnoreCase)) -or
        [IO.Path]::GetFileName($root) -notmatch '^ventio-product-root-[0-9a-f]{32}$') { throw 'HOST_PRODUCT_ROOT_TEST_PATH_INVALID' }
  } elseif ($TestRoot) { throw 'HOST_PRODUCT_ROOT_PATH_OVERRIDE_DENIED' }
  $cursor = $root
  while ($cursor) {
    if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw 'HOST_PRODUCT_ROOT_REPARSE_POINT'
    }
    $parent = [IO.Directory]::GetParent($cursor)
    if ($null -eq $parent) { break }
    $cursor = $parent.FullName
  }
  $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'HOST_PRODUCT_ROOT_ELEVATION_REQUIRED' }
  $serviceSids = @()
  foreach ($name in @('VentioHost','VentioPostgres')) {
    try { $serviceSids += [Security.Principal.NTAccount]::new('NT SERVICE',$name).Translate([Security.Principal.SecurityIdentifier]).Value }
    catch [Security.Principal.IdentityNotMappedException] { }
  }
  [void][IO.Directory]::CreateDirectory($root)
  Set-Acl -LiteralPath $root -AclObject (New-HostProductDataRootAcl -ServiceSids $serviceSids)
  $actual = Get-Acl -LiteralPath $root
  if (-not $actual.AreAccessRulesProtected -or $actual.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544') {
    throw 'HOST_PRODUCT_ROOT_PROTECTION_FAILED'
  }
}

Export-ModuleMember -Function New-HostProductDataRootAcl,Protect-HostProductDataRoot
