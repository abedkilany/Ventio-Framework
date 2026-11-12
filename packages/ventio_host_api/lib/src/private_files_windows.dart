import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Windows ACL-backed counterpart to the Linux private-file helper.
/// Request data, including secrets, is sent over stdin rather than argv.
class WindowsPrivateFiles {
  static const _script = r'''
$ErrorActionPreference = 'Stop'
try {
  $utf8 = [System.Text.UTF8Encoding]::new($false)
  [Console]::InputEncoding = $utf8
  [Console]::OutputEncoding = $utf8
  $request = ConvertFrom-Json -InputObject ([Console]::In.ReadToEnd())
  $operation = [string]$request.operation
  $path = [System.IO.Path]::GetFullPath([string]$request.path)
  if ($path -notmatch '^[A-Za-z]:\\') { throw 'local absolute path required' }
  $drive = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($path))
  if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) { throw 'fixed local drive required' }
  $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $currentSid = $identity.User.Value
  $witness = $operation.StartsWith('witness-')
  $runtime = $operation -eq 'witness-read-runtime'
  $ownerWriter = $operation -eq 'witness-read-owner'
  $action = $operation.Replace('witness-', '').Replace('-runtime', '')
  if ($ownerWriter) { $action = 'read' }
  $ownerSid = if ($runtime -or $ownerWriter) { [string]$request.ownerSid } else { $currentSid }
  $readerSid = [string]$request.readerSid
  if ([string]::IsNullOrWhiteSpace($readerSid)) { $readerSid = $null }
  $isAuthorityLock = [System.IO.Path]::GetFileName($path).EndsWith(
    '.lock', [System.StringComparison]::Ordinal)
  $fileReaderSid = if ($action -eq 'lock' -or $isAuthorityLock) {
    $null
  } else {
    $readerSid
  }
  if ($runtime -and ($ownerSid -eq $currentSid -or $null -eq $readerSid)) {
    throw 'independent witness owner and reader required'
  }
  if ($ownerWriter -and $ownerSid -ne $currentSid) {
    throw 'trusted witness owner process required'
  }
  if ($witness -and $action -ne 'lock' -and $null -eq $readerSid) {
    throw 'explicit witness reader SID required'
  }
  if ($null -ne $readerSid) {
    $null = [System.Security.Principal.SecurityIdentifier]::new($readerSid)
  }

  function Resolve-Sid([string]$name) {
    if ($name -match '^S-1-') { return $name }
    return ([System.Security.Principal.NTAccount]::new($name)).Translate(
      [System.Security.Principal.SecurityIdentifier]).Value
  }
  function Assert-NoReparse([string]$candidate) {
    $item = Get-Item -LiteralPath $candidate -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw 'reparse point refused'
    }
  }
  function Assert-PathChain([string]$candidate) {
    $cursor = [System.IO.Path]::GetFullPath($candidate)
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
      Assert-NoReparse $cursor
      $parentPath = [System.IO.Path]::GetDirectoryName($cursor.TrimEnd('\'))
      if ([string]::IsNullOrWhiteSpace($parentPath) -or $parentPath -eq $cursor) { break }
      $cursor = $parentPath
    }
  }
  function Assert-SecureAncestors([string]$directoryPath, [string]$allowedOwner) {
    $trustedInstallerSid = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    $trustedSids = @($currentSid, $allowedOwner, 'S-1-5-18', 'S-1-5-32-544', $trustedInstallerSid)
    $destructiveMask = [int](
      [System.Security.AccessControl.FileSystemRights]::Delete -bor
      [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
      [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
      [System.Security.AccessControl.FileSystemRights]::TakeOwnership)
    $cursor = [System.IO.Directory]::GetParent($directoryPath)
    while ($null -ne $cursor) {
      Assert-NoReparse $cursor.FullName
      $acl = [System.IO.Directory]::GetAccessControl($cursor.FullName)
      $ancestorOwner = Resolve-Sid $acl.Owner
      if ($trustedSids -notcontains $ancestorOwner) {
        throw 'untrusted ancestor owner refused'
      }
      $rules = $acl.GetAccessRules($true, $false,
        [System.Security.Principal.SecurityIdentifier])
      foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
          continue
        }
        if (($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) {
          continue
        }
        if (([int]$rule.FileSystemRights -band $destructiveMask) -eq 0) { continue }
        if ($trustedSids -contains $rule.IdentityReference.Value) { continue }
        throw 'untrusted ancestor can delete or replace a protected path'
      }
      $cursor = $cursor.Parent
    }
  }
  function Assert-SecureAcl([string]$candidate, [string]$expectedOwner,
      [string]$allowedReader, [bool]$isDirectory) {
    $item = Get-Item -LiteralPath $candidate -Force
    if ($isDirectory -ne $item.PSIsContainer) { throw 'unexpected file type' }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw 'reparse point refused'
    }
    $acl = if ($isDirectory) {
      [System.IO.Directory]::GetAccessControl($candidate)
    } else {
      [System.IO.File]::GetAccessControl($candidate)
    }
    if (-not $acl.AreAccessRulesProtected -or (Resolve-Sid $acl.Owner) -ne $expectedOwner) {
      throw 'protected owner and ACL required'
    }
    $full = [int][System.Security.AccessControl.FileSystemRights]::FullControl
    $readerRights = if ($isDirectory) {
      [int]([System.Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
        [System.Security.AccessControl.FileSystemRights]::Synchronize)
    } else {
      [int]([System.Security.AccessControl.FileSystemRights]::Read -bor
        [System.Security.AccessControl.FileSystemRights]::Synchronize)
    }
    $systemSid = 'S-1-5-18'
    $administratorsSid = 'S-1-5-32-544'
    $rules = $acl.GetAccessRules($true, $false,
      [System.Security.Principal.SecurityIdentifier])
    foreach ($rule in $rules) {
      if ($rule.IsInherited -or
          $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
        throw 'unexpected ACL rule'
      }
      $sid = $rule.IdentityReference.Value
      $rights = [int]$rule.FileSystemRights
      if ($sid -eq $expectedOwner -or $sid -eq $systemSid -or $sid -eq $administratorsSid) {
        if ($rights -ne $full) { throw 'unexpected privileged ACL rights' }
      } elseif (-not [string]::IsNullOrWhiteSpace($allowedReader) -and $sid -eq $allowedReader) {
        if ($rights -ne $readerRights) { throw 'unexpected reader ACL rights' }
      } else {
        throw 'untrusted ACL principal refused'
      }
    }
    foreach ($requiredSid in @($expectedOwner, $systemSid, $administratorsSid)) {
      if (-not ($rules | Where-Object { $_.IdentityReference.Value -eq $requiredSid })) {
        throw 'required owner ACL entry missing'
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($allowedReader) -and $allowedReader -ne $expectedOwner -and
        $allowedReader -ne $systemSid -and $allowedReader -ne $administratorsSid -and
        -not ($rules | Where-Object { $_.IdentityReference.Value -eq $allowedReader })) {
      throw 'required reader ACL entry missing'
    }
  }
  function Set-SecureAcl([string]$candidate, [string]$owner,
      [string]$allowedReader, [bool]$isDirectory) {
    $acl = if ($isDirectory) {
      [System.Security.AccessControl.DirectorySecurity]::new()
    } else {
      [System.Security.AccessControl.FileSecurity]::new()
    }
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = if ($isDirectory) {
      [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else {
      [System.Security.AccessControl.InheritanceFlags]::None
    }
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($sidText in @($owner, 'S-1-5-18', 'S-1-5-32-544')) {
      $sid = [System.Security.Principal.SecurityIdentifier]::new($sidText)
      $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $sid, [System.Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance, $propagation, $allow)
      $acl.AddAccessRule($rule)
    }
    if (-not [string]::IsNullOrWhiteSpace($allowedReader) -and
        $allowedReader -ne $owner -and
        $allowedReader -ne 'S-1-5-18' -and
        $allowedReader -ne 'S-1-5-32-544') {
      $sid = [System.Security.Principal.SecurityIdentifier]::new($allowedReader)
      $rights = if ($isDirectory) {
        [System.Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
          [System.Security.AccessControl.FileSystemRights]::Synchronize
      } else {
        [System.Security.AccessControl.FileSystemRights]::Read -bor
          [System.Security.AccessControl.FileSystemRights]::Synchronize
      }
      $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $sid, $rights, $inheritance, $propagation, $allow))
    }
    if ($isDirectory) {
      [System.IO.Directory]::SetAccessControl($candidate, $acl)
    } else {
      [System.IO.File]::SetAccessControl($candidate, $acl)
    }
  }

  $parent = [System.IO.Path]::GetDirectoryName($path)
  if ([string]::IsNullOrWhiteSpace($parent)) { throw 'parent directory required' }
  Assert-PathChain $parent
  Assert-SecureAncestors $parent $ownerSid
  if ($runtime -and -not ($identity.Groups | Where-Object { $_.Value -eq $readerSid })) {
    throw 'Host process is not a member of the configured witness reader group'
  }
  Assert-SecureAcl $parent $ownerSid $readerSid $true

  if ($action -eq 'read' -or $action -eq 'verify') {
    Assert-PathChain $path
    Assert-SecureAcl $path $ownerSid $fileReaderSid $false
    $stream = [System.IO.FileStream]::new($path,
      [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::Read)
    try {
      if ($stream.Length -gt 1048576) { throw 'file too large' }
      if ($action -eq 'read') {
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
          $count = $stream.Read($bytes, $offset, $bytes.Length - $offset)
          if ($count -le 0) { throw 'truncated file' }
          $offset += $count
        }
        [Console]::Out.Write([Convert]::ToBase64String($bytes))
      }
    } finally {
      $stream.Dispose()
    }
  } else {
    $bytes = $utf8.GetBytes([string]$request.data)
    if ($bytes.Length -gt 1048576) { throw 'file too large' }
    if ($action -eq 'replace') {
      Assert-PathChain $path
      Assert-SecureAcl $path $ownerSid $fileReaderSid $false
      $writePath = [System.IO.Path]::Combine($parent, '.ventio-' + [Guid]::NewGuid().ToString('N'))
    } elseif ($action -eq 'create' -or $action -eq 'lock') {
      $writePath = $path
    } else {
      throw 'unsupported operation'
    }
    $stream = $null
    try {
      $stream = [System.IO.FileStream]::new($writePath,
        [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite, 4096,
        [System.IO.FileOptions]::WriteThrough)
      Set-SecureAcl $writePath $currentSid $fileReaderSid $false
      $stream.Write($bytes, 0, $bytes.Length)
      $stream.Flush($true)
      $stream.Dispose()
      $stream = $null
      if ($action -eq 'replace') {
        $backupPath = [System.IO.Path]::Combine($parent, '.ventio-backup-' + [Guid]::NewGuid().ToString('N'))
        [System.IO.File]::Replace($writePath, $path, $backupPath, $true)
        if ([System.IO.File]::Exists($backupPath)) {
          [System.IO.File]::Delete($backupPath)
        }
      }
      Assert-SecureAcl $path $ownerSid $fileReaderSid $false
    } catch {
      if ($null -ne $stream) { $stream.Dispose() }
      if ($action -eq 'replace' -and [System.IO.File]::Exists($writePath)) {
        [System.IO.File]::Delete($writePath)
      }
      throw
    }
  }
} catch {
  if ($env:VENTIO_PRIVATE_FILES_DIAGNOSTICS -eq '1') {
    $exceptionType = $_.Exception.GetType().Name
    $exceptionCode = [BitConverter]::ToUInt32(
      [BitConverter]::GetBytes([int]$_.Exception.HResult), 0)
    [Console]::Error.WriteLine(
      'VENTIO_PRIVATE_HELPER_FAILURE:{0}:0x{1:X8}' -f $exceptionType, $exceptionCode)
  }
  [Console]::Error.WriteLine('Protected Windows file operation failed')
  exit 2
}
''';

  static Future<String> run(
    String operation,
    String path,
    String data, {
    String? ownerSid,
    String? readerSid,
  }) async {
    final scriptBytes = <int>[];
    for (final unit in _script.codeUnits) {
      scriptBytes
        ..add(unit & 0xff)
        ..add(unit >> 8);
    }
    final encodedScript = base64Encode(scriptBytes);
    final systemRoot = Platform.environment['SystemRoot'];
    if (systemRoot == null || !Directory(systemRoot).isAbsolute) {
      throw StateError('Windows system directory is unavailable');
    }
    final powershell = File(
      Directory(systemRoot).absolute.path +
          Platform.pathSeparator +
          'System32' +
          Platform.pathSeparator +
          'WindowsPowerShell' +
          Platform.pathSeparator +
          'v1.0' +
          Platform.pathSeparator +
          'powershell.exe',
    );
    if (await FileSystemEntity.type(powershell.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('Windows private-file runtime is unavailable');
    }
    Process? process;
    Future<List<int>>? stdout;
    Future<String>? stderr;
    var phase = 'start';
    try {
      process = await Process.start(powershell.path, [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-EncodedCommand',
        encodedScript,
      ]);
      stdout = process.stdout.fold<List<int>>(<int>[], (bytes, chunk) {
        if (bytes.length + chunk.length > 2 * 1024 * 1024) {
          throw const FormatException('Protected file output too large');
        }
        bytes.addAll(chunk);
        return bytes;
      });
      stderr = process.stderr.transform(utf8.decoder).join();
      phase = 'send_request';
      process.stdin.write(
        jsonEncode({
          'operation': operation,
          'path': path,
          'ownerSid': ownerSid,
          'readerSid': readerSid,
          'data': data,
        }),
      );
      phase = 'close_request';
      await process.stdin.close().timeout(const Duration(seconds: 10));
      phase = 'wait_for_helper';
      final code = await process.exitCode.timeout(const Duration(seconds: 10));
      phase = 'collect_output';
      final helperStderr = await stderr;
      final result = utf8.decode(await stdout);
      if (code != 0) {
        phase = 'helper_rejected';
        if (Platform.environment['VENTIO_PRIVATE_FILES_DIAGNOSTICS'] == '1') {
          final diagnostic = RegExp(
            r'VENTIO_PRIVATE_HELPER_FAILURE:([A-Za-z]+):(0x[0-9A-Fa-f]{8})',
          ).firstMatch(helperStderr);
          if (diagnostic != null) {
            print(
              'Windows private-file helper: ${diagnostic[1]} ${diagnostic[2]}',
            );
          }
        }
        throw StateError('Protected file operation failed');
      }
      if (operation == 'read' || operation.startsWith('witness-read')) {
        return utf8.decode(base64Decode(result.trim()));
      }
      return result;
    } catch (_) {
      final child = process;
      if (child != null) {
        child.kill();
        try {
          await child.exitCode.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          // Do not delay reporting a private-file helper failure indefinitely.
        }
      }
      try {
        await stderr!;
        await stdout!;
      } catch (_) {
        // Drain failures are deliberately excluded from public error text.
      }
      throw StateError('Protected file operation failed ($operation, $phase)');
    }
  }
}
