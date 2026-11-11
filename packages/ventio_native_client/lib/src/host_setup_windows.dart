import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'extension_store.dart';
import 'host_credentials.dart';
import 'host_setup.dart';

class WindowsHostSetupPlatform implements HostSetupPlatform {
  static const _serviceNames = {'VentioPostgres', 'VentioHost'};
  static const _allowedPhases = {
    'PAYLOAD_VALIDATION',
    'POSTGRES_SERVICE_PROVISIONING',
    'DATABASE_INITIALIZATION',
    'MIGRATION_CREDENTIAL_PROTECTION',
    'HOST_SERVICE_REGISTRATION',
    'HOST_CONFIGURATION_PROTECTION',
    'HOST_LAN_CONFIGURATION',
    'HOST_SERVICE_STARTUP',
    'HOST_READINESS',
    'FIRST_ADMINISTRATOR_BOOTSTRAP',
    'BOOTSTRAP_CREDENTIAL_PROTECTION',
  };
  static const _hostEndpoint = 'http://127.0.0.1:8080/healthz';

  @override
  bool get supportsHostSetup => Platform.isWindows;

  @override
  Future<bool> currentProcessIsElevated() async {
    if (!Platform.isWindows) return false;
    return Isolate.run(_currentProcessIsElevated);
  }

  @override
  Future<String> currentUserSid() async {
    if (!Platform.isWindows) {
      throw const HostSetupException('HOST_SETUP_WINDOWS_ONLY');
    }
    return Isolate.run(_currentUserSid);
  }

  @override
  Future<HostSetupPendingOperation?> readPendingOperation() async {
    if (!Platform.isWindows) return null;
    return _readPendingOperation();
  }

  @override
  Future<void> savePendingOperation(HostSetupPendingOperation operation) async {
    if (!Platform.isWindows) {
      throw const HostSetupException('HOST_SETUP_WINDOWS_ONLY');
    }
    _writePendingOperation(operation);
  }

  @override
  Future<void> clearPendingOperation() async {
    if (!Platform.isWindows) return;
    final file = _pendingOperationFile();
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.file) {
      await file.delete();
    }
  }

  @override
  Future<bool> requestAdministratorSetup(
    HostSetupPendingOperation operation,
  ) async {
    if (!Platform.isWindows) return false;
    return Isolate.run(() => _requestAdministratorSetup(operation));
  }

  @override
  Future<HostSetupOperationStatus> setupOperationStatus(
    String operationId,
  ) async {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(operationId)) {
      throw const HostSetupException('HOST_SETUP_OPERATION_INVALID');
    }
    final file = File('${_statusDirectory().path}\\$operationId.json');
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return const HostSetupOperationStatus(
        state: HostSetupOperationState.pending,
      );
    }
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const HostSetupException('HOST_SETUP_STATUS_UNAVAILABLE');
    }
    try {
      final content = await file.readAsString();
      if (content.length > 2048) throw const FormatException();
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException();
      }
      final statusDocument = HostSetupOperationStatus.normalizeJson(decoded);
      if (statusDocument.length != decoded.length ||
          statusDocument['formatVersion'] != 1 ||
          statusDocument['operationId'] != operationId ||
          statusDocument['state'] is! String) {
        throw const FormatException();
      }
      final state = switch (statusDocument['state']) {
        'running' => HostSetupOperationState.running,
        'complete' => HostSetupOperationState.complete,
        'failed' => HostSetupOperationState.failed,
        _ => throw const FormatException(),
      };
      final phase = statusDocument['phase'];
      final failureCode = statusDocument['failureCode'];
      final updatedAtText = statusDocument['updatedAtUtc'];
      final updatedAtUtc = updatedAtText is String
          ? DateTime.tryParse(updatedAtText)
          : null;
      if ((phase != null &&
              (phase is! String || !_allowedPhases.contains(phase))) ||
          (failureCode != null &&
              (failureCode is! String ||
                  !RegExp(r'^[A-Z0-9_]{1,96}$').hasMatch(failureCode))) ||
          updatedAtUtc == null) {
        throw const FormatException();
      }
      return HostSetupOperationStatus(
        state: state,
        phase: phase as String?,
        failureCode: failureCode as String?,
        updatedAtUtc: updatedAtUtc,
      );
    } on HostSetupException {
      rethrow;
    } on Object {
      throw const HostSetupException('HOST_SETUP_STATUS_UNAVAILABLE');
    }
  }

  @override
  Future<HostFirstAdministratorReply> readBootstrapResult(
    String operationId,
  ) async {
    if (!Platform.isWindows ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(operationId)) {
      throw const HostSetupException('HOST_SETUP_OPERATION_INVALID');
    }
    return Isolate.run(() => _readBootstrapResult(operationId));
  }

  @override
  Future<void> clearBootstrapResult(String operationId) async {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(operationId)) {
      throw const HostSetupException('HOST_SETUP_OPERATION_INVALID');
    }
    final file = File(
      '${_statusDirectory().path}\\$operationId.credential.dpapi',
    );
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.file) {
      await file.delete();
    }
  }

  @override
  Future<HostWindowsServiceState> serviceState(String serviceName) async {
    _validateServiceName(serviceName);
    if (!Platform.isWindows) return HostWindowsServiceState.notInstalled;
    return Isolate.run(() => _queryServiceState(serviceName));
  }

  @override
  Future<bool> waitForHostReadiness() async {
    final endpoint = Uri.parse(_hostEndpoint);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2)
      ..findProxy = (_) => 'DIRECT';
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    try {
      while (DateTime.now().isBefore(deadline)) {
        try {
          final request = await client
              .getUrl(endpoint)
              .timeout(const Duration(seconds: 2));
          final response = await request.close().timeout(
            const Duration(seconds: 2),
          );
          final body = await response
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 2));
          if (response.statusCode == HttpStatus.ok && body.length <= 1024) {
            final decoded = jsonDecode(body);
            if (decoded is Map &&
                decoded.length == 2 &&
                decoded['apiVersion'] == 1 &&
                decoded['status'] == 'alive') {
              return true;
            }
          }
        } on Object {
          // The service starts the API after the bootstrap transaction commits.
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static void _validateServiceName(String serviceName) {
    if (!_serviceNames.contains(serviceName)) {
      throw ArgumentError.value(serviceName, 'serviceName');
    }
  }

  static Directory _statusDirectory() {
    final programFiles = Platform.environment['ProgramFiles'];
    if (programFiles == null || programFiles.isEmpty) {
      throw const HostSetupException('HOST_SETUP_STATUS_UNAVAILABLE');
    }
    return Directory('$programFiles\\Ventio\\SetupStatus');
  }

  static File _pendingOperationFile() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) {
      throw const HostSetupException('HOST_SETUP_STATE_UNAVAILABLE');
    }
    return File('$localAppData\\VentioFramework\\host-setup-pending.json');
  }

  static Future<HostSetupPendingOperation?> _readPendingOperation() async {
    final file = _pendingOperationFile();
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw const HostSetupException('HOST_SETUP_STATE_UNAVAILABLE');
    }
    try {
      final source = await file.readAsString();
      if (source.length > 4096) throw const FormatException();
      final value = jsonDecode(source);
      if (value is! Map<String, dynamic> ||
          value.keys.toSet().difference({
            'formatVersion',
            'operationId',
            'requesterSid',
            'tenantId',
            'companyId',
            'branchId',
          }).isNotEmpty ||
          value['formatVersion'] != 1 ||
          value['operationId'] is! String ||
          value['requesterSid'] is! String ||
          value['tenantId'] is! String ||
          value['companyId'] is! String ||
          value['branchId'] is! String) {
        throw const FormatException();
      }
      return HostSetupPendingOperation(
        operationId: value['operationId'] as String,
        requesterSid: value['requesterSid'] as String,
        scope: HostSetupScope(
          tenantId: value['tenantId'] as String,
          companyId: value['companyId'] as String,
          branchId: value['branchId'] as String,
        ),
      );
    } on Object {
      throw const HostSetupException('HOST_SETUP_STATE_UNAVAILABLE');
    }
  }

  static Future<void> _writePendingOperation(
    HostSetupPendingOperation operation,
  ) async {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(operation.operationId) ||
        !RegExp(r'^S-1-\d+(?:-\d+)+$').hasMatch(operation.requesterSid)) {
      throw const HostSetupException('HOST_SETUP_OPERATION_INVALID');
    }
    final file = _pendingOperationFile();
    final directory = file.parent;
    await directory.create(recursive: true);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const HostSetupException('HOST_SETUP_STATE_ALREADY_EXISTS');
    }
    final temporary = File('${file.path}.tmp');
    if (await FileSystemEntity.type(temporary.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const HostSetupException('HOST_SETUP_STATE_UNAVAILABLE');
    }
    final contents = jsonEncode({
      'formatVersion': 1,
      'operationId': operation.operationId,
      'requesterSid': operation.requesterSid,
      'tenantId': operation.scope.tenantId,
      'companyId': operation.scope.companyId,
      'branchId': operation.scope.branchId,
    });
    try {
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(file.path);
    } on Object {
      if (await FileSystemEntity.type(temporary.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await temporary.delete();
      }
      throw const HostSetupException('HOST_SETUP_STATE_UNAVAILABLE');
    }
  }

  static bool _requestAdministratorSetup(HostSetupPendingOperation operation) {
    if (_currentUserSid() != operation.requesterSid) {
      throw const HostSetupException('HOST_SETUP_REQUESTER_IDENTITY_MISMATCH');
    }
    final programFiles = Platform.environment['ProgramFiles'];
    if (programFiles == null || programFiles.isEmpty) {
      throw const HostSetupException('HOST_SETUP_BROKER_UNAVAILABLE');
    }
    final executable = File(
      '$programFiles\\Ventio\\host-payload\\VentioSetupBroker.exe',
    );
    if (!executable.isAbsolute || !executable.existsSync()) {
      throw const HostSetupException('HOST_SETUP_BROKER_UNAVAILABLE');
    }
    if (![
      operation.scope.tenantId,
      operation.scope.companyId,
      operation.scope.branchId,
    ].every(
      (value) => RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$').hasMatch(value),
    )) {
      return false;
    }
    final commandLine = [
      '--setup-new-host',
      operation.operationId,
      operation.scope.tenantId,
      operation.scope.companyId,
      operation.scope.branchId,
      operation.requesterSid,
    ].join(' ');
    final arguments = commandLine.toNativeUtf16();
    final verb = 'runas'.toNativeUtf16();
    final file = executable.path.toNativeUtf16();
    final workingDirectory = executable.parent.path.toNativeUtf16();
    try {
      final result = ShellExecute(
        HWND(nullptr),
        PCWSTR(verb),
        PCWSTR(file),
        PCWSTR(arguments),
        PCWSTR(workingDirectory),
        SW_SHOWNORMAL,
      );
      if (result.address > 32) return true;
      if (result.address == 1223) return false;
      throw const HostSetupException('HOST_SETUP_BROKER_UNAVAILABLE');
    } finally {
      malloc.free(arguments);
      malloc.free(verb);
      malloc.free(file);
      malloc.free(workingDirectory);
    }
  }

  static HostWindowsServiceState _queryServiceState(String serviceName) {
    return using((arena) {
      final serviceNamePointer = serviceName.toNativeUtf16(allocator: arena);
      final manager = OpenSCManager(null, null, SC_MANAGER_CONNECT);
      if (!manager.value.isValid) return HostWindowsServiceState.unknown;
      try {
        final service = OpenService(
          manager.value,
          PCWSTR(serviceNamePointer),
          SERVICE_QUERY_STATUS,
        );
        if (!service.value.isValid) {
          return service.error.code == ERROR_SERVICE_DOES_NOT_EXIST.code
              ? HostWindowsServiceState.notInstalled
              : HostWindowsServiceState.unknown;
        }
        try {
          final status = arena<SERVICE_STATUS>();
          final result = QueryServiceStatus(service.value, status);
          if (!result.value) return HostWindowsServiceState.unknown;
          return _mapServiceState(status.ref.dwCurrentState);
        } finally {
          CloseServiceHandle(service.value);
        }
      } finally {
        CloseServiceHandle(manager.value);
      }
    });
  }

  static HostWindowsServiceState _mapServiceState(
    SERVICE_STATUS_CURRENT_STATE state,
  ) => switch (state) {
    SERVICE_RUNNING => HostWindowsServiceState.running,
    SERVICE_START_PENDING => HostWindowsServiceState.startPending,
    SERVICE_STOP_PENDING => HostWindowsServiceState.stopPending,
    SERVICE_STOPPED => HostWindowsServiceState.stopped,
    _ => HostWindowsServiceState.unknown,
  };

  static String _currentUserSid() {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final advapi = DynamicLibrary.open('advapi32.dll');
    final getCurrentProcess = kernel
        .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'GetCurrentProcess',
        );
    final openProcessToken = advapi
        .lookupFunction<
          Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>),
          int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
        >('OpenProcessToken');
    final getTokenInformation = advapi
        .lookupFunction<
          Int32 Function(
            Pointer<Void>,
            Uint32,
            Pointer<Void>,
            Uint32,
            Pointer<Uint32>,
          ),
          int Function(Pointer<Void>, int, Pointer<Void>, int, Pointer<Uint32>)
        >('GetTokenInformation');
    final convertSid = advapi
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Pointer<Utf16>>),
          int Function(Pointer<Void>, Pointer<Pointer<Utf16>>)
        >('ConvertSidToStringSidW');
    final closeHandle = kernel
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('CloseHandle');
    final localFree = kernel
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('LocalFree');
    final token = calloc<Pointer<Void>>();
    final buffer = calloc<Uint8>(4096);
    final requiredLength = calloc<Uint32>();
    final sidString = calloc<Pointer<Utf16>>();
    try {
      if (openProcessToken(getCurrentProcess(), 0x0008, token) == 0 ||
          token.value == nullptr) {
        throw const HostSetupException('HOST_SETUP_IDENTITY_UNAVAILABLE');
      }
      if (getTokenInformation(
            token.value,
            1,
            buffer.cast(),
            4096,
            requiredLength,
          ) ==
          0) {
        throw const HostSetupException('HOST_SETUP_IDENTITY_UNAVAILABLE');
      }
      final sid = buffer.cast<Pointer<Void>>().value;
      if (sid == nullptr ||
          convertSid(sid, sidString) == 0 ||
          sidString.value == nullptr) {
        throw const HostSetupException('HOST_SETUP_IDENTITY_UNAVAILABLE');
      }
      return sidString.value.toDartString();
    } on HostSetupException {
      rethrow;
    } on Object {
      throw const HostSetupException('HOST_SETUP_IDENTITY_UNAVAILABLE');
    } finally {
      if (sidString.value != nullptr) localFree(sidString.value.cast());
      if (token.value != nullptr) closeHandle(token.value);
      calloc.free(sidString);
      calloc.free(requiredLength);
      calloc.free(buffer);
      calloc.free(token);
    }
  }

  static bool _currentProcessIsElevated() {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final advapi = DynamicLibrary.open('advapi32.dll');
    final getCurrentProcess = kernel
        .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'GetCurrentProcess',
        );
    final openProcessToken = advapi
        .lookupFunction<
          Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>),
          int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
        >('OpenProcessToken');
    final getTokenInformation = advapi
        .lookupFunction<
          Int32 Function(
            Pointer<Void>,
            Uint32,
            Pointer<Void>,
            Uint32,
            Pointer<Uint32>,
          ),
          int Function(Pointer<Void>, int, Pointer<Void>, int, Pointer<Uint32>)
        >('GetTokenInformation');
    final closeHandle = kernel
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('CloseHandle');
    final token = calloc<Pointer<Void>>();
    final elevation = calloc<Uint32>();
    final requiredLength = calloc<Uint32>();
    try {
      if (openProcessToken(getCurrentProcess(), 0x0008, token) == 0 ||
          token.value == nullptr ||
          getTokenInformation(
                token.value,
                20,
                elevation.cast(),
                sizeOf<Uint32>(),
                requiredLength,
              ) ==
              0) {
        throw const HostSetupException('HOST_SETUP_IDENTITY_UNAVAILABLE');
      }
      return elevation.value != 0;
    } on HostSetupException {
      rethrow;
    } on Object {
      throw const HostSetupException('HOST_SETUP_IDENTITY_UNAVAILABLE');
    } finally {
      if (token.value != nullptr) closeHandle(token.value);
      calloc.free(requiredLength);
      calloc.free(elevation);
      calloc.free(token);
    }
  }

  static HostFirstAdministratorReply _readBootstrapResult(String operationId) {
    final path = File(
      '${_statusDirectory().path}\\$operationId.credential.dpapi',
    );
    if (FileSystemEntity.typeSync(path.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const HostSetupException('HOST_BOOTSTRAP_CREDENTIAL_UNAVAILABLE');
    }
    final encrypted = path.readAsBytesSync();
    if (encrypted.isEmpty || encrypted.length > 16384) {
      encrypted.fillRange(0, encrypted.length, 0);
      throw const HostSetupException('HOST_BOOTSTRAP_CREDENTIAL_UNAVAILABLE');
    }
    final entropyBytes = Uint8List.fromList(utf8.encode(operationId));
    final input = calloc<_DataBlob>();
    final entropy = calloc<_DataBlob>();
    final output = calloc<_DataBlob>();
    final description = calloc<Pointer<Utf16>>();
    final inputBytes = calloc<Uint8>(encrypted.length);
    final entropyBuffer = calloc<Uint8>(entropyBytes.length);
    final crypt32 = DynamicLibrary.open('crypt32.dll');
    final kernel = DynamicLibrary.open('kernel32.dll');
    final unprotect = crypt32
        .lookupFunction<
          Int32 Function(
            Pointer<_DataBlob>,
            Pointer<Pointer<Utf16>>,
            Pointer<_DataBlob>,
            Pointer<Void>,
            Pointer<Void>,
            Uint32,
            Pointer<_DataBlob>,
          ),
          int Function(
            Pointer<_DataBlob>,
            Pointer<Pointer<Utf16>>,
            Pointer<_DataBlob>,
            Pointer<Void>,
            Pointer<Void>,
            int,
            Pointer<_DataBlob>,
          )
        >('CryptUnprotectData');
    final localFree = kernel
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('LocalFree');
    try {
      inputBytes.asTypedList(encrypted.length).setAll(0, encrypted);
      entropyBuffer.asTypedList(entropyBytes.length).setAll(0, entropyBytes);
      input.ref.length = encrypted.length;
      input.ref.data = inputBytes;
      entropy.ref.length = entropyBytes.length;
      entropy.ref.data = entropyBuffer;
      if (unprotect(input, description, entropy, nullptr, nullptr, 1, output) ==
              0 ||
          output.ref.data == nullptr ||
          output.ref.length <= 0 ||
          output.ref.length > 8192) {
        throw const HostSetupException('HOST_BOOTSTRAP_CREDENTIAL_UNAVAILABLE');
      }
      final plaintext = Uint8List(output.ref.length);
      plaintext.setRange(
        0,
        plaintext.length,
        output.ref.data.asTypedList(output.ref.length),
      );
      try {
        final decoded = jsonDecode(utf8.decode(plaintext));
        if (decoded is! Map<String, dynamic> ||
            decoded.keys.toSet().difference({
              'formatVersion',
              'operationId',
              'requestId',
              'actorId',
              'token',
              'expiresAt',
            }).isNotEmpty ||
            decoded['formatVersion'] != 1 ||
            decoded['operationId'] != operationId ||
            decoded['requestId'] is! String ||
            decoded['actorId'] is! String ||
            decoded['token'] is! String ||
            decoded['expiresAt'] is! String) {
          throw const FormatException();
        }
        return HostFirstAdministratorReply(
          success: true,
          status: 'pending',
          requestId: decoded['requestId'] as String,
          actorId: decoded['actorId'] as String,
          token: decoded['token'] as String,
          expiresAt: decoded['expiresAt'] as String,
        );
      } finally {
        plaintext.fillRange(0, plaintext.length, 0);
      }
    } on HostSetupException {
      rethrow;
    } on Object {
      throw const HostSetupException('HOST_BOOTSTRAP_CREDENTIAL_UNAVAILABLE');
    } finally {
      if (output.ref.data != nullptr && output.ref.length > 0) {
        output.ref.data
            .asTypedList(output.ref.length)
            .fillRange(0, output.ref.length, 0);
      }
      if (output.ref.data != nullptr) localFree(output.ref.data.cast());
      if (description.value != nullptr) localFree(description.value.cast());
      encrypted.fillRange(0, encrypted.length, 0);
      entropyBytes.fillRange(0, entropyBytes.length, 0);
      calloc.free(entropyBuffer);
      calloc.free(inputBytes);
      calloc.free(description);
      calloc.free(output);
      calloc.free(entropy);
      calloc.free(input);
    }
  }
}

/// Starts the installed Setup Broker with UAC approval and exchanges a narrowly
/// scoped pairing request through a short-lived user-profile file. The operator
/// credential digest never enters process arguments or diagnostics; the one-time
/// pairing code returns only in a CurrentUser DPAPI-protected result file.
class WindowsTrustedPairingOperator {
  Future<WindowsTrustedPairingResult?> createPairing({
    required String operationId,
    required String tenantId,
    required String operatorActorId,
    required String targetActorId,
    required String companyId,
    required String branchId,
    required List<String> permissions,
    required String operatorCredentialDigest,
  }) async {
    if (!Platform.isWindows) {
      throw const HostSetupException('HOST_TRUSTED_PAIRING_WINDOWS_ONLY');
    }
    final request = <String, Object?>{
      'operationId': operationId,
      'tenantId': tenantId,
      'operatorActorId': operatorActorId,
      'targetActorId': targetActorId,
      'companyId': companyId,
      'branchId': branchId,
      'permissions': permissions,
      'operatorCredentialDigest': operatorCredentialDigest,
    };
    return Isolate.run(() => _createTrustedPairing(request));
  }

  static Future<WindowsTrustedPairingResult?> _createTrustedPairing(
    Map<String, Object?> request,
  ) async {
    final operationId = request['operationId'] as String;
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(operationId)) {
      throw const HostSetupException('HOST_TRUSTED_PAIRING_REQUEST_INVALID');
    }
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final programFiles = Platform.environment['ProgramFiles'];
    if (localAppData == null ||
        localAppData.isEmpty ||
        programFiles == null ||
        programFiles.isEmpty) {
      throw const HostSetupException('HOST_TRUSTED_PAIRING_BROKER_UNAVAILABLE');
    }
    final requesterSid = WindowsHostSetupPlatform._currentUserSid();
    final requestDirectory = Directory(
      '$localAppData\\VentioFramework\\TrustedOperator',
    );
    final requestFile = File(
      '${requestDirectory.path}\\$operationId.request.json',
    );
    final resultFile = File(
      '$programFiles\\Ventio\\SetupStatus\\$operationId.pairing.dpapi',
    );
    final broker = File(
      '$programFiles\\Ventio\\host-payload\\VentioSetupBroker.exe',
    );
    try {
      await requestDirectory.create(recursive: true);
      _assertOrdinaryPath(requestDirectory.path, allowMissingLeaf: false);
      if (await FileSystemEntity.type(requestFile.path, followLinks: false) !=
              FileSystemEntityType.notFound ||
          await FileSystemEntity.type(resultFile.path, followLinks: false) !=
              FileSystemEntityType.notFound ||
          await FileSystemEntity.type(broker.path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const HostSetupException(
          'HOST_TRUSTED_PAIRING_STATE_UNAVAILABLE',
        );
      }
      final document = jsonEncode({'formatVersion': 1, ...request});
      await requestFile.create(exclusive: true);
      final handle = await requestFile.open(mode: FileMode.write);
      try {
        await handle.writeString(document, encoding: utf8);
        await handle.flush();
      } finally {
        await handle.close();
      }

      final commandLine = [
        '--trusted-pairing',
        operationId,
        request['tenantId'] as String,
        request['companyId'] as String,
        request['branchId'] as String,
        requesterSid,
        requestFile.path,
      ].map(_quoteWindowsArgument).join(' ');
      final arguments = commandLine.toNativeUtf16();
      final verb = 'runas'.toNativeUtf16();
      final executable = broker.path.toNativeUtf16();
      final workingDirectory = broker.parent.path.toNativeUtf16();
      try {
        final launched = ShellExecute(
          HWND(nullptr),
          PCWSTR(verb),
          PCWSTR(executable),
          PCWSTR(arguments),
          PCWSTR(workingDirectory),
          SW_SHOWNORMAL,
        );
        if (launched.address == 1223) return null;
        if (launched.address <= 32) {
          throw const HostSetupException(
            'HOST_TRUSTED_PAIRING_BROKER_UNAVAILABLE',
          );
        }
      } finally {
        malloc.free(arguments);
        malloc.free(verb);
        malloc.free(executable);
        malloc.free(workingDirectory);
      }

      final deadline = DateTime.now().add(const Duration(seconds: 120));
      while (DateTime.now().isBefore(deadline)) {
        if (await FileSystemEntity.type(resultFile.path, followLinks: false) ==
            FileSystemEntityType.file) {
          return _readProtectedResult(resultFile, request);
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      throw const HostSetupException('HOST_TRUSTED_PAIRING_OUTCOME_UNKNOWN');
    } on HostSetupException {
      rethrow;
    } on Object {
      throw const HostSetupException('HOST_TRUSTED_PAIRING_FAILED');
    } finally {
      try {
        if (await FileSystemEntity.type(requestFile.path, followLinks: false) ==
            FileSystemEntityType.file) {
          await requestFile.delete();
        }
      } catch (_) {}
    }
  }

  static WindowsTrustedPairingResult _readProtectedResult(
    File file,
    Map<String, Object?> request,
  ) {
    _assertOrdinaryPath(file.path, allowMissingLeaf: false);
    final encrypted = file.readAsBytesSync();
    if (encrypted.isEmpty || encrypted.length > 16384) {
      encrypted.fillRange(0, encrypted.length, 0);
      throw const HostSetupException('HOST_TRUSTED_PAIRING_RESULT_INVALID');
    }
    final operationId = request['operationId'] as String;
    final entropyBytes = Uint8List.fromList(utf8.encode(operationId));
    final input = calloc<_DataBlob>();
    final entropy = calloc<_DataBlob>();
    final output = calloc<_DataBlob>();
    final description = calloc<Pointer<Utf16>>();
    final inputBytes = calloc<Uint8>(encrypted.length);
    final entropyBuffer = calloc<Uint8>(entropyBytes.length);
    final crypt32 = DynamicLibrary.open('crypt32.dll');
    final kernel = DynamicLibrary.open('kernel32.dll');
    final unprotect = crypt32
        .lookupFunction<
          Int32 Function(
            Pointer<_DataBlob>,
            Pointer<Pointer<Utf16>>,
            Pointer<_DataBlob>,
            Pointer<Void>,
            Pointer<Void>,
            Uint32,
            Pointer<_DataBlob>,
          ),
          int Function(
            Pointer<_DataBlob>,
            Pointer<Pointer<Utf16>>,
            Pointer<_DataBlob>,
            Pointer<Void>,
            Pointer<Void>,
            int,
            Pointer<_DataBlob>,
          )
        >('CryptUnprotectData');
    final localFree = kernel
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('LocalFree');
    try {
      inputBytes.asTypedList(encrypted.length).setAll(0, encrypted);
      entropyBuffer.asTypedList(entropyBytes.length).setAll(0, entropyBytes);
      input.ref.length = encrypted.length;
      input.ref.data = inputBytes;
      entropy.ref.length = entropyBytes.length;
      entropy.ref.data = entropyBuffer;
      if (unprotect(input, description, entropy, nullptr, nullptr, 1, output) ==
              0 ||
          output.ref.data == nullptr ||
          output.ref.length <= 0 ||
          output.ref.length > 8192) {
        throw const HostSetupException('HOST_TRUSTED_PAIRING_RESULT_INVALID');
      }
      final plaintext = Uint8List(output.ref.length);
      plaintext.setRange(
        0,
        plaintext.length,
        output.ref.data.asTypedList(output.ref.length),
      );
      try {
        final decoded = jsonDecode(utf8.decode(plaintext));
        if (decoded is! Map<String, dynamic> ||
            decoded.keys.toSet().difference({
              'formatVersion',
              'operationId',
              'status',
              'pairingId',
              'actorId',
              'companyId',
              'branchId',
              'permissions',
              'code',
              'expiresAtUtc',
              'failureCode',
            }).isNotEmpty ||
            decoded.length != 11 ||
            decoded['formatVersion'] != 1 ||
            decoded['operationId'] != operationId) {
          throw const HostSetupException('HOST_TRUSTED_PAIRING_RESULT_INVALID');
        }
        if (decoded['status'] == 'failed') {
          final failureCode = decoded['failureCode'];
          if (failureCode is! String ||
              !RegExp(
                r'^HOST_TRUSTED_PAIRING_[A-Z_]+$',
              ).hasMatch(failureCode)) {
            throw const HostSetupException(
              'HOST_TRUSTED_PAIRING_RESULT_INVALID',
            );
          }
          throw HostSetupException(failureCode);
        }
        final permissions = decoded['permissions'];
        final code = decoded['code'];
        final expiryText = decoded['expiresAtUtc'];
        final expiry = expiryText is String
            ? DateTime.tryParse(expiryText)
            : null;
        final requestedPermissions =
            (request['permissions'] as List).cast<String>()..sort();
        final returnedPermissions = permissions is List
            ? (permissions.cast<String>()..sort())
            : <String>[];
        if (decoded['status'] != 'created' ||
            decoded['pairingId'] != 'pair_$operationId' ||
            decoded['actorId'] != request['targetActorId'] ||
            decoded['companyId'] != request['companyId'] ||
            decoded['branchId'] != request['branchId'] ||
            code is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(code) ||
            expiry == null ||
            !expiry.isAfter(DateTime.now().toUtc()) ||
            expiry.isAfter(
              DateTime.now().toUtc().add(const Duration(minutes: 5)),
            ) ||
            returnedPermissions.length != requestedPermissions.length ||
            !returnedPermissions.asMap().entries.every(
              (entry) => entry.value == requestedPermissions[entry.key],
            )) {
          throw const HostSetupException('HOST_TRUSTED_PAIRING_RESULT_INVALID');
        }
        return WindowsTrustedPairingResult(
          pairingId: decoded['pairingId'] as String,
          actorId: decoded['actorId'] as String,
          companyId: decoded['companyId'] as String,
          branchId: decoded['branchId'] as String,
          permissions: List.unmodifiable(returnedPermissions),
          code: code,
          expiresAtUtc: expiry.toUtc(),
        );
      } finally {
        plaintext.fillRange(0, plaintext.length, 0);
      }
    } on HostSetupException {
      rethrow;
    } on Object {
      throw const HostSetupException('HOST_TRUSTED_PAIRING_RESULT_INVALID');
    } finally {
      encrypted.fillRange(0, encrypted.length, 0);
      entropyBytes.fillRange(0, entropyBytes.length, 0);
      if (description.value != nullptr) localFree(description.value.cast());
      if (output.ref.data != nullptr) {
        final outputBytes = output.ref.data.asTypedList(output.ref.length);
        outputBytes.fillRange(0, outputBytes.length, 0);
        localFree(output.ref.data.cast());
      }
      calloc.free(entropyBuffer);
      calloc.free(inputBytes);
      calloc.free(description);
      calloc.free(output);
      calloc.free(entropy);
      calloc.free(input);
      try {
        if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
            FileSystemEntityType.file) {
          file.deleteSync();
        }
      } catch (_) {}
    }
  }

  static void _assertOrdinaryPath(
    String path, {
    required bool allowMissingLeaf,
  }) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (!allowMissingLeaf &&
        type != FileSystemEntityType.file &&
        type != FileSystemEntityType.directory) {
      throw const HostSetupException('HOST_TRUSTED_PAIRING_STATE_UNAVAILABLE');
    }
    if (type == FileSystemEntityType.link) {
      throw const HostSetupException('HOST_TRUSTED_PAIRING_STATE_UNAVAILABLE');
    }
  }

  static String _quoteWindowsArgument(String value) {
    final result = StringBuffer('"');
    var slashes = 0;
    for (final character in value.split('')) {
      if (character == r'\') {
        slashes++;
        continue;
      }
      if (character == '"') {
        result.write(List<String>.filled(slashes * 2 + 1, r'\').join());
        result.write('"');
      } else {
        result.write(List<String>.filled(slashes, r'\').join());
        result.write(character);
      }
      slashes = 0;
    }
    result.write(List<String>.filled(slashes * 2, r'\').join());
    result.write('"');
    return result.toString();
  }
}

class WindowsTrustedPairingResult {
  const WindowsTrustedPairingResult({
    required this.pairingId,
    required this.actorId,
    required this.companyId,
    required this.branchId,
    required this.permissions,
    required this.code,
    required this.expiresAtUtc,
  });

  final String pairingId;
  final String actorId;
  final String companyId;
  final String branchId;
  final List<String> permissions;
  final String code;
  final DateTime expiresAtUtc;
}

/// Requests a same-device credential ceiling transition through the installed
/// Host service and Setup Broker. No bearer credential is returned to Flutter.
class WindowsTrustedCredentialReissueOperator {
  Future<WindowsTrustedCredentialReissueResult?> request({
    required String operationId,
    required String tenantId,
    required String operatorActorId,
    required String targetActorId,
    required String companyId,
    required String branchId,
    required String deviceId,
    required String sourceCredentialId,
    required List<String> permissions,
    required List<String> approvedRemovals,
    required String operatorCredentialDigest,
  }) async {
    if (!Platform.isWindows) {
      throw const HostSetupException('HOST_TRUSTED_REISSUE_WINDOWS_ONLY');
    }
    final request = <String, Object?>{
      'operationId': operationId,
      'tenantId': tenantId,
      'operatorActorId': operatorActorId,
      'targetActorId': targetActorId,
      'companyId': companyId,
      'branchId': branchId,
      'deviceId': deviceId,
      'sourceCredentialId': sourceCredentialId,
      'permissions': permissions.toList()..sort(),
      'approvedRemovals': approvedRemovals.toList()..sort(),
      'operatorCredentialDigest': operatorCredentialDigest,
    };
    return Isolate.run(() => _requestCredentialReissue(request));
  }

  static Future<WindowsTrustedCredentialReissueResult?>
  _requestCredentialReissue(Map<String, Object?> request) async {
    final operationId = request['operationId'] as String;
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final programFiles = Platform.environment['ProgramFiles'];
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(operationId) ||
        localAppData == null ||
        localAppData.isEmpty ||
        programFiles == null ||
        programFiles.isEmpty) {
      throw const HostSetupException('HOST_TRUSTED_REISSUE_REQUEST_INVALID');
    }
    final requesterSid = WindowsHostSetupPlatform._currentUserSid();
    final requestDirectory = Directory(
      '$localAppData\\VentioFramework\\TrustedOperator',
    );
    final requestFile = File(
      '${requestDirectory.path}\\$operationId.request.json',
    );
    final resultFile = File(
      '$programFiles\\Ventio\\SetupStatus\\$operationId.reissue.dpapi',
    );
    final broker = File(
      '$programFiles\\Ventio\\host-payload\\VentioSetupBroker.exe',
    );
    try {
      await requestDirectory.create(recursive: true);
      _assertTrustedReissuePath(requestDirectory.path, allowMissingLeaf: false);
      final requestType = await FileSystemEntity.type(
        requestFile.path,
        followLinks: false,
      );
      if (requestType == FileSystemEntityType.link ||
          requestType == FileSystemEntityType.directory) {
        throw const HostSetupException(
          'HOST_TRUSTED_REISSUE_STATE_UNAVAILABLE',
        );
      }
      if (requestType == FileSystemEntityType.file) await requestFile.delete();
      final resultType = await FileSystemEntity.type(
        resultFile.path,
        followLinks: false,
      );
      if (resultType == FileSystemEntityType.link ||
          resultType == FileSystemEntityType.directory ||
          await FileSystemEntity.type(broker.path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const HostSetupException(
          'HOST_TRUSTED_REISSUE_STATE_UNAVAILABLE',
        );
      }
      if (resultType == FileSystemEntityType.file) await resultFile.delete();
      final document = jsonEncode({'formatVersion': 1, ...request});
      await requestFile.create(exclusive: true);
      final handle = await requestFile.open(mode: FileMode.write);
      try {
        await handle.writeString(document, encoding: utf8);
        await handle.flush();
      } finally {
        await handle.close();
      }
      final commandLine = [
        '--trusted-credential-reissue',
        operationId,
        request['tenantId'] as String,
        request['companyId'] as String,
        request['branchId'] as String,
        requesterSid,
        requestFile.path,
      ].map(_quoteTrustedReissueArgument).join(' ');
      final arguments = commandLine.toNativeUtf16();
      final verb = 'runas'.toNativeUtf16();
      final executable = broker.path.toNativeUtf16();
      final workingDirectory = broker.parent.path.toNativeUtf16();
      try {
        final launched = ShellExecute(
          HWND(nullptr),
          PCWSTR(verb),
          PCWSTR(executable),
          PCWSTR(arguments),
          PCWSTR(workingDirectory),
          SW_SHOWNORMAL,
        );
        if (launched.address == 1223) return null;
        if (launched.address <= 32) {
          throw const HostSetupException(
            'HOST_TRUSTED_REISSUE_BROKER_UNAVAILABLE',
          );
        }
      } finally {
        malloc.free(arguments);
        malloc.free(verb);
        malloc.free(executable);
        malloc.free(workingDirectory);
      }
      final deadline = DateTime.now().add(const Duration(seconds: 120));
      while (DateTime.now().isBefore(deadline)) {
        if (await FileSystemEntity.type(resultFile.path, followLinks: false) ==
            FileSystemEntityType.file) {
          return _readProtectedReissueResult(resultFile, request);
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      throw const HostSetupException('HOST_TRUSTED_REISSUE_OUTCOME_UNKNOWN');
    } on HostSetupException {
      rethrow;
    } on Object {
      throw const HostSetupException('HOST_TRUSTED_REISSUE_FAILED');
    } finally {
      try {
        if (await FileSystemEntity.type(requestFile.path, followLinks: false) ==
            FileSystemEntityType.file) {
          await requestFile.delete();
        }
      } catch (_) {}
    }
  }

  static WindowsTrustedCredentialReissueResult _readProtectedReissueResult(
    File file,
    Map<String, Object?> request,
  ) {
    _assertTrustedReissuePath(file.path, allowMissingLeaf: false);
    final encrypted = file.readAsBytesSync();
    final operationId = request['operationId'] as String;
    final entropyBytes = Uint8List.fromList(utf8.encode(operationId));
    final input = calloc<_DataBlob>();
    final entropy = calloc<_DataBlob>();
    final output = calloc<_DataBlob>();
    final description = calloc<Pointer<Utf16>>();
    final inputBytes = calloc<Uint8>(encrypted.length);
    final entropyBuffer = calloc<Uint8>(entropyBytes.length);
    final crypt32 = DynamicLibrary.open('crypt32.dll');
    final kernel = DynamicLibrary.open('kernel32.dll');
    final unprotect = crypt32
        .lookupFunction<
          Int32 Function(
            Pointer<_DataBlob>,
            Pointer<Pointer<Utf16>>,
            Pointer<_DataBlob>,
            Pointer<Void>,
            Pointer<Void>,
            Uint32,
            Pointer<_DataBlob>,
          ),
          int Function(
            Pointer<_DataBlob>,
            Pointer<Pointer<Utf16>>,
            Pointer<_DataBlob>,
            Pointer<Void>,
            Pointer<Void>,
            int,
            Pointer<_DataBlob>,
          )
        >('CryptUnprotectData');
    final localFree = kernel
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('LocalFree');
    try {
      if (encrypted.isEmpty || encrypted.length > 65536) {
        throw const HostSetupException('HOST_TRUSTED_REISSUE_RESULT_INVALID');
      }
      inputBytes.asTypedList(encrypted.length).setAll(0, encrypted);
      entropyBuffer.asTypedList(entropyBytes.length).setAll(0, entropyBytes);
      input.ref
        ..length = encrypted.length
        ..data = inputBytes;
      entropy.ref
        ..length = entropyBytes.length
        ..data = entropyBuffer;
      if (unprotect(input, description, entropy, nullptr, nullptr, 1, output) ==
              0 ||
          output.ref.data == nullptr ||
          output.ref.length <= 0 ||
          output.ref.length > 32768) {
        throw const HostSetupException('HOST_TRUSTED_REISSUE_RESULT_INVALID');
      }
      final clear = Uint8List(output.ref.length);
      clear.setRange(
        0,
        clear.length,
        output.ref.data.asTypedList(clear.length),
      );
      try {
        final decoded = jsonDecode(utf8.decode(clear));
        if (decoded is! Map<String, dynamic> ||
            decoded.length != 5 ||
            !decoded.keys.toSet().containsAll(const {
              'formatVersion',
              'operationId',
              'status',
              'reissue',
              'failureCode',
            }) ||
            decoded['formatVersion'] != 1 ||
            decoded['operationId'] != operationId) {
          throw const HostSetupException('HOST_TRUSTED_REISSUE_RESULT_INVALID');
        }
        if (decoded['status'] == 'failed') {
          final failure = decoded['failureCode'];
          if (failure is! String ||
              !RegExp(r'^HOST_TRUSTED_REISSUE_[A-Z_]+$').hasMatch(failure)) {
            throw const HostSetupException(
              'HOST_TRUSTED_REISSUE_RESULT_INVALID',
            );
          }
          throw HostSetupException(failure);
        }
        final raw = decoded['reissue'];
        if (decoded['status'] != 'completed' || raw is! Map) {
          throw const HostSetupException('HOST_TRUSTED_REISSUE_RESULT_INVALID');
        }
        final result = Map<String, dynamic>.from(raw);
        const expected = {
          'operationId',
          'state',
          'tenantId',
          'actorId',
          'deviceId',
          'companyId',
          'branchId',
          'credentialId',
          'permissions',
          'expiresAtUtc',
        };
        final expiryValue = result['expiresAtUtc'];
        final expiry = expiryValue is String
            ? DateTime.tryParse(expiryValue)
            : null;
        final resultPermissions = result['permissions'];
        final requested = (request['permissions'] as List).cast<String>()
          ..sort();
        final returned = resultPermissions is List
            ? (resultPermissions.cast<String>()..sort())
            : <String>[];
        if (result.length != expected.length ||
            result.keys.any((key) => !expected.contains(key)) ||
            result['operationId'] != 'reissue_$operationId' ||
            !const {
              'PREPARED',
              'FINALIZED',
              'EXPIRED',
              'REJECTED',
            }.contains(result['state']) ||
            result['tenantId'] != request['tenantId'] ||
            result['actorId'] != request['targetActorId'] ||
            result['deviceId'] != request['deviceId'] ||
            result['companyId'] != request['companyId'] ||
            result['branchId'] != request['branchId'] ||
            result['credentialId'] is! String ||
            !RegExp(
              r'^cred_[0-9a-f]{32}$',
            ).hasMatch(result['credentialId'] as String) ||
            expiry == null ||
            !expiry.isUtc ||
            (result['state'] == 'PREPARED' &&
                !expiry.isAfter(DateTime.now().toUtc())) ||
            expiry.isAfter(
              DateTime.now().toUtc().add(const Duration(minutes: 16)),
            ) ||
            returned.length != requested.length ||
            !returned.asMap().entries.every(
              (entry) => entry.value == requested[entry.key],
            )) {
          throw const HostSetupException('HOST_TRUSTED_REISSUE_RESULT_INVALID');
        }
        return WindowsTrustedCredentialReissueResult(
          operationId: result['operationId'] as String,
          state: result['state'] as String,
          tenantId: result['tenantId'] as String,
          actorId: result['actorId'] as String,
          deviceId: result['deviceId'] as String,
          companyId: result['companyId'] as String,
          branchId: result['branchId'] as String,
          credentialId: result['credentialId'] as String,
          permissions: List.unmodifiable(returned),
          expiresAtUtc: expiry,
        );
      } finally {
        clear.fillRange(0, clear.length, 0);
      }
    } on HostSetupException {
      rethrow;
    } on Object {
      throw const HostSetupException('HOST_TRUSTED_REISSUE_RESULT_INVALID');
    } finally {
      encrypted.fillRange(0, encrypted.length, 0);
      entropyBytes.fillRange(0, entropyBytes.length, 0);
      if (description.value != nullptr) {
        localFree(description.value.cast<Void>());
      }
      if (output.ref.data != nullptr) {
        output.ref.data
            .asTypedList(output.ref.length)
            .fillRange(0, output.ref.length, 0);
        localFree(output.ref.data.cast<Void>());
      }
      inputBytes
          .asTypedList(encrypted.length)
          .fillRange(0, encrypted.length, 0);
      entropyBuffer
          .asTypedList(entropyBytes.length)
          .fillRange(0, entropyBytes.length, 0);
      calloc.free(entropyBuffer);
      calloc.free(inputBytes);
      calloc.free(description);
      calloc.free(output);
      calloc.free(entropy);
      calloc.free(input);
    }
  }
}

class WindowsTrustedCredentialReissueResult {
  const WindowsTrustedCredentialReissueResult({
    required this.operationId,
    required this.state,
    required this.tenantId,
    required this.actorId,
    required this.deviceId,
    required this.companyId,
    required this.branchId,
    required this.credentialId,
    required this.permissions,
    required this.expiresAtUtc,
  });

  final String operationId;
  final String state;
  final String tenantId;
  final String actorId;
  final String deviceId;
  final String companyId;
  final String branchId;
  final String credentialId;
  final List<String> permissions;
  final DateTime expiresAtUtc;
}

void _assertTrustedReissuePath(String path, {required bool allowMissingLeaf}) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (!allowMissingLeaf &&
      type != FileSystemEntityType.file &&
      type != FileSystemEntityType.directory) {
    throw const HostSetupException('HOST_TRUSTED_REISSUE_STATE_UNAVAILABLE');
  }
  if (type == FileSystemEntityType.link) {
    throw const HostSetupException('HOST_TRUSTED_REISSUE_STATE_UNAVAILABLE');
  }
}

String _quoteTrustedReissueArgument(String value) {
  final slash = String.fromCharCode(92);
  final result = StringBuffer('"');
  var slashes = 0;
  for (final character in value.split('')) {
    if (character == slash) {
      slashes++;
      continue;
    }
    if (character == '"') {
      result.write(List<String>.filled(slashes * 2 + 1, slash).join());
      result.write('"');
    } else {
      result.write(List<String>.filled(slashes, slash).join());
      result.write(character);
    }
    slashes = 0;
  }
  result.write(List<String>.filled(slashes * 2, slash).join());
  result.write('"');
  return result.toString();
}

final class _DataBlob extends Struct {
  @Uint32()
  external int length;

  external Pointer<Uint8> data;
}

HostSetupPlatform createHostSetupPlatform() => WindowsHostSetupPlatform();

HostSetupCredentialStore createHostSetupCredentialStore({
  required HostCredentialVault credentials,
  required LocalExtensionStore store,
}) => LocalHostSetupCredentialStore(credentials: credentials, store: store);
