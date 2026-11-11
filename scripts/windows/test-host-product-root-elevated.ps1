param([Parameter(Mandatory=$true)][string] $TestRoot,[switch] $Cleanup)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'HostProductDataRoot.psm1') -Force
$root=[IO.Path]::GetFullPath($TestRoot)
$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
if(-not [IO.Directory]::GetParent($root).FullName.Equals($parent,[StringComparison]::OrdinalIgnoreCase) -or
  [IO.Path]::GetFileName($root) -notmatch '^ventio-product-root-[a-f0-9]{32}$'){throw 'ISOLATED_ROOT_INVALID'}
if($Cleanup){
  if((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'ISOLATED_ROOT_REPARSE'}
  if(@(Get-ChildItem -LiteralPath $root -Force).Count -ne 0){throw 'ISOLATED_ROOT_NOT_EMPTY'}
  if((Get-Acl -LiteralPath $root).GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544'){throw 'ISOLATED_ROOT_OWNER_CHANGED'}
  [IO.Directory]::Delete($root,$false)
}else{Protect-HostProductDataRoot -TestRoot $root -TestMode}
