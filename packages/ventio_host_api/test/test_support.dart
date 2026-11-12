import 'dart:convert';
import 'dart:io';

import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

Future<String> currentWindowsSid() async {
  final identity = await Process.run('whoami.exe', [
    '/user',
    '/fo',
    'csv',
    '/nh',
  ]);
  if (identity.exitCode != 0) {
    throw StateError('Cannot resolve current Windows SID');
  }
  final sid = (identity.stdout as String)
      .split(',')
      .last
      .trim()
      .replaceAll('"', '');
  if (!RegExp(r'^S-1-\d+(?:-\d+)+$').hasMatch(sid)) {
    throw StateError('Windows returned an invalid current SID');
  }
  return sid;
}

Future<void> setPrivateWindowsDirectoryAcl(
  Directory directory,
  String ownerSid, {
  String? readerSid,
}) async {
  const script = r'''
$ErrorActionPreference = 'Stop'
$path = $env:VENTIO_TEST_PRIVATE_ACL_PATH
$ownerSid = [System.Security.Principal.SecurityIdentifier]::new($env:VENTIO_TEST_PRIVATE_ACL_OWNER)
$acl = [System.Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
  [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
$allow = [System.Security.AccessControl.AccessControlType]::Allow
$propagation = [System.Security.AccessControl.PropagationFlags]::None
$acl.SetOwner($ownerSid)
foreach ($sidText in @($ownerSid.Value, 'S-1-5-18', 'S-1-5-32-544')) {
  $sid = [System.Security.Principal.SecurityIdentifier]::new($sidText)
  $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
    $sid, [System.Security.AccessControl.FileSystemRights]::FullControl,
    $inheritance, $propagation, $allow))
}
$readerSid = $env:VENTIO_TEST_PRIVATE_ACL_READER
if (-not [string]::IsNullOrWhiteSpace($readerSid) -and
    $readerSid -notin @($ownerSid.Value, 'S-1-5-18', 'S-1-5-32-544')) {
  $reader = [System.Security.Principal.SecurityIdentifier]::new($readerSid)
  $rights = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
    [System.Security.AccessControl.FileSystemRights]::Synchronize
  $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
    $reader, $rights, $inheritance, $propagation, $allow))
}
Set-Acl -LiteralPath $path -AclObject $acl
$verified = Get-Acl -LiteralPath $path
if (-not $verified.AreAccessRulesProtected -or
    $verified.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -ne $ownerSid.Value) {
  throw 'Private test directory owner or inheritance protection did not persist.'
}
''';
  final systemRoot = Platform.environment['SystemRoot'];
  if (systemRoot == null) {
    throw StateError('A Windows system directory is unavailable');
  }
  final powershell =
      '$systemRoot${Platform.pathSeparator}System32${Platform.pathSeparator}'
      'WindowsPowerShell${Platform.pathSeparator}v1.0${Platform.pathSeparator}'
      'powershell.exe';
  final result = await Process.run(
    powershell,
    [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ],
    environment: {
      'VENTIO_TEST_PRIVATE_ACL_PATH': directory.path,
      'VENTIO_TEST_PRIVATE_ACL_OWNER': ownerSid,
      'VENTIO_TEST_PRIVATE_ACL_READER': readerSid ?? '',
    },
  );
  if (result.exitCode != 0) {
    throw StateError('Cannot prepare protected Windows test storage');
  }
}

Future<Directory> createPrivateTestDirectory(String prefix) async {
  if (!Platform.isWindows) {
    final directory = await Directory.systemTemp.createTemp(prefix);
    if (Platform.isLinux) {
      final result = await Process.run('chmod', ['700', directory.path]);
      if (result.exitCode != 0) {
        throw StateError('Could not protect test storage.');
      }
    }
    return directory;
  }

  final userProfile = Platform.environment['USERPROFILE'];
  if (userProfile == null || !Directory(userProfile).existsSync()) {
    throw StateError('A Windows user profile directory is unavailable');
  }
  final directory = Directory(
    '$userProfile${Platform.pathSeparator}$prefix$pid-'
    '${DateTime.now().microsecondsSinceEpoch}',
  );
  await directory.create();
  try {
    await setPrivateWindowsDirectoryAcl(directory, await currentWindowsSid());
    return directory;
  } catch (_) {
    await directory.delete(recursive: true);
    rethrow;
  }
}

Future<bool> hasPrivateTestFilePermissions(String path) async {
  if (Platform.isLinux) {
    final result = await Process.run('stat', ['-c', '%a', path]);
    return result.exitCode == 0 && (result.stdout as String).trim() == '600';
  }
  if (!Platform.isWindows) {
    throw UnsupportedError(
      'Private test-file permission checks need Linux or Windows.',
    );
  }

  const script = r'''
$path = $env:VENTIO_TEST_PRIVATE_ACL_PATH
$item = if ([System.IO.Directory]::Exists($path)) {
  [System.IO.DirectoryInfo]::new($path)
} else {
  [System.IO.FileInfo]::new($path)
}
$acl = $item.GetAccessControl()
$currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
$expected = @($currentSid, 'S-1-5-18', 'S-1-5-32-544')
$rules = $acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])
if (-not $acl.AreAccessRulesProtected -or $ownerSid -ne $currentSid -or $rules.Count -ne 3) { exit 1 }
foreach ($rule in $rules) {
  if ($expected -notcontains $rule.IdentityReference.Value -or
      $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
      [int]$rule.FileSystemRights -ne [int][System.Security.AccessControl.FileSystemRights]::FullControl -or
      $rule.IsInherited) { exit 1 }
}
exit 0
''';
  final systemRoot = Platform.environment['SystemRoot'];
  if (systemRoot == null) {
    throw StateError('Windows system directory is unavailable');
  }
  final powershell =
      '$systemRoot${Platform.pathSeparator}System32${Platform.pathSeparator}'
      'WindowsPowerShell${Platform.pathSeparator}v1.0${Platform.pathSeparator}'
      'powershell.exe';
  final result = await Process.run(
    powershell,
    [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ],
    environment: {'VENTIO_TEST_PRIVATE_ACL_PATH': path},
  );
  return result.exitCode == 0;
}

Future<void> makeTestFileReadableByEveryone(String path) async {
  final result = Platform.isWindows
      ? await Process.run('icacls.exe', [path, '/grant', '*S-1-1-0:(R)'])
      : await Process.run('chmod', ['644', path]);
  if (result.exitCode != 0) {
    throw StateError(
      'Could not make the disposable test file readable by Everyone.',
    );
  }
}

bool hasForcedTerminationExitCode(int exitCode) => Platform.isWindows
    ? exitCode != 0
    : exitCode == -ProcessSignal.sigkill.signalNumber;

// Deterministic disposable test credentials. Never use outside this test suite.
final validToken = List.filled(43, 'a').join();
final deniedToken = List.filled(43, 'b').join();
final expiredToken = List.filled(43, 'c').join();
final revokedToken = List.filled(43, 'd').join();

Principal principal(String tenant, {bool permitted = true}) => Principal(
  actorId: 'user-001',
  deviceId: 'device-001',
  tenantId: tenant,
  companyIds: {'company-001'},
  branchIds: {'branch-001'},
  permissions: permitted ? {'maintenance.create'} : {},
);

DevelopmentTokenAuthenticator authenticator(String tenant) {
  DevelopmentCredential credential(
    String token, {
    bool permitted = true,
    bool expired = false,
  }) => DevelopmentCredential(
    tokenDigest: DevelopmentCredential.digest(token),
    principal: principal(tenant, permitted: permitted),
    expiresAt: DateTime.now().toUtc().add(Duration(hours: expired ? -1 : 1)),
  );
  return DevelopmentTokenAuthenticator([
    credential(validToken),
    credential(deniedToken, permitted: false),
    credential(expiredToken, expired: true),
    credential(revokedToken),
  ])..revokeDigest(DevelopmentCredential.digest(revokedToken));
}

Map<String, dynamic> command(String tenant, {int id = 1, String? record}) {
  final source = loadJsonFile(
    '../../spec/v1.2/examples/create_maintenance_command.json',
  );
  source['tenantId'] = tenant;
  source['companyId'] = 'company-001';
  source['branchId'] = 'branch-001';
  source['commandId'] =
      '10000000-0000-4000-8000-${id.toString().padLeft(12, '0')}';
  source['aggregateId'] = record ?? 'api-record-$id';
  source['clientContext']['actorId'] = 'user-001';
  source['clientContext']['deviceId'] = 'device-001';
  return source;
}

class Reply {
  final int status;
  final Map<String, dynamic> body;
  final HttpHeaders headers;
  Reply(this.status, this.body, this.headers);
}

Future<Reply> send(
  HostApi api, {
  String path = '/api/v1/commands',
  String method = 'POST',
  String? token,
  Object? body,
  String contentType = 'application/json',
  bool chunked = false,
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${api.port}$path'),
    );
    if (token != null) request.headers.set('Authorization', 'Bearer $token');
    headers.forEach(request.headers.set);
    request.headers.set('Content-Type', contentType);
    if (body != null) {
      final bytes = utf8.encode(body is String ? body : jsonEncode(body));
      if (!chunked) request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close().timeout(const Duration(seconds: 30));
    final text = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 30));
    return Reply(
      response.statusCode,
      jsonDecode(text) as Map<String, dynamic>,
      response.headers,
    );
  } finally {
    client.close(force: true);
  }
}

int assertions = 0;
void check(bool condition, String label) {
  if (!condition) throw StateError('FAIL: $label');
  assertions++;
  stdout.writeln('PASS: $label');
}
