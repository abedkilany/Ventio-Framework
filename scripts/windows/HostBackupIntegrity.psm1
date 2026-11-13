Set-StrictMode -Version Latest

# Shared by the existing trusted, elevated upgrade/restore workflows. It does
# not start services, invoke database tools, change ACLs or restore any data.
function Get-HostBackupIntegrity([string] $DataDirectory) {
  $root = [IO.Path]::GetFullPath($DataDirectory).TrimEnd('\')
  $ancestor = [IO.DirectoryInfo]::new($root)
  while ($null -ne $ancestor) {
    if (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'HOST_BACKUP_INTEGRITY_REPARSE_POINT' }
    $ancestor = $ancestor.Parent
  }
  $prefix = $root + '\'
  $stack = [Collections.Generic.Stack[string]]::new()
  $stack.Push($root)
  $files = [Collections.Generic.List[object]]::new()
  while ($stack.Count -gt 0) {
    $current = $stack.Pop()
    $directory = Get-Item -LiteralPath $current -Force -ErrorAction Stop
    if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'HOST_BACKUP_INTEGRITY_REPARSE_POINT' }
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($current)) {
      $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
      $full = [IO.Path]::GetFullPath($item.FullName)
      if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
          ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'HOST_BACKUP_INTEGRITY_PATH_INVALID' }
      if ($item.PSIsContainer) { $stack.Push($full); continue }
      if ($files.Count -ge 500000) { throw 'HOST_BACKUP_INTEGRITY_FILE_LIMIT' }
      $stream = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
      $algorithm = [Security.Cryptography.SHA256]::Create()
      try {
        $length = $stream.Length
        $hash = [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        if ($stream.Length -ne $length) { throw 'HOST_BACKUP_INTEGRITY_FILE_CHANGED' }
      } finally { $algorithm.Dispose(); $stream.Dispose() }
      $files.Add([pscustomobject]@{ path = $full.Substring($prefix.Length).Replace('\', '/'); bytes = $length; sha256 = $hash })
    }
  }
  return @($files | Sort-Object -Property path)
}

function Assert-HostBackupIntegrity([string] $DataDirectory, [object[]] $ExpectedFiles) {
  $expected = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($file in $ExpectedFiles) {
    $relative = [string]$file.path
    if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains('\') -or
        $relative.Split('/') -contains '..' -or $relative.Split('/') -contains '.' -or
        $relative.Split('/') -contains '' -or $relative.Contains(':') -or
        [string]$file.sha256 -notmatch '^[0-9a-f]{64}$' -or [long]$file.bytes -lt 0 -or
        $expected.ContainsKey($relative)) { throw 'HOST_BACKUP_INTEGRITY_MANIFEST_INVALID' }
    $expected.Add($relative, $file)
  }
  $actual = @(Get-HostBackupIntegrity $DataDirectory)
  if ($actual.Count -ne $expected.Count) { throw 'HOST_BACKUP_INTEGRITY_FILE_COUNT_MISMATCH' }
  foreach ($file in $actual) {
    if (-not $expected.ContainsKey($file.path) -or
        [long]$expected[$file.path].bytes -ne [long]$file.bytes -or
        [string]$expected[$file.path].sha256 -cne [string]$file.sha256) { throw 'HOST_BACKUP_INTEGRITY_CONTENT_MISMATCH' }
  }
}

Export-ModuleMember -Function Get-HostBackupIntegrity, Assert-HostBackupIntegrity
