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
  static const _pipeName = r'\\.\pipe\Ventio.Host.FirstAdmin.v1';
  static const _serviceNames = {'VentioPostgres', 'VentioHost'};
  static const _hostEndpoint = 'http://127.0.0.1:8080/healthz';

  @override
  bool get supportsHostSetup => Platform.isWindows;

  @override
  Future<bool> isAdministrator() async {
    if (!Platform.isWindows) return false;
    return Isolate.run(_isAdministrator);
  }

  @override
  Future<bool> requestAdministratorSetup() async {
    if (!Platform.isWindows) return false;
    return Isolate.run(_requestAdministratorSetup);
  }

  @override
  Future<HostWindowsServiceState> serviceState(String serviceName) async {
    _validateServiceName(serviceName);
    if (!Platform.isWindows) return HostWindowsServiceState.notInstalled;
    return Isolate.run(() => _queryServiceState(serviceName));
  }

  @override
  Future<void> startService(String serviceName) async {
    _validateServiceName(serviceName);
    if (!Platform.isWindows) {
      throw const HostSetupException('HOST_SETUP_WINDOWS_ONLY');
    }
    await Isolate.run(() => _startService(serviceName));
  }

  @override
  Future<HostFirstAdministratorReply> bootstrapFirstAdministrator(
    HostSetupScope scope,
  ) async {
    if (!Platform.isWindows) {
      throw const HostSetupException('HOST_SETUP_WINDOWS_ONLY');
    }
    final request = jsonEncode({
      'operation': 'bootstrap',
      'tenantId': scope.tenantId,
      'companyId': scope.companyId,
      'branchId': scope.branchId,
    });
    final response = await Isolate.run(() => _exchangeWithBroker(request));
    return _parseReply(response);
  }

  @override
  Future<void> acknowledgeFirstAdministrator(String requestId) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(requestId)) {
      throw const HostSetupException(
        'HOST_FIRST_ADMINISTRATOR_RESPONSE_INVALID',
      );
    }
    final request = jsonEncode({
      'operation': 'acknowledge',
      'requestId': requestId,
    });
    final response = _parseReply(
      await Isolate.run(() => _exchangeWithBroker(request)),
    );
    if (!response.success ||
        response.status != 'acknowledged' ||
        response.requestId != requestId ||
        response.token != null) {
      throw const HostSetupException('HOST_BOOTSTRAP_ACKNOWLEDGEMENT_FAILED');
    }
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

  static bool _isAdministrator() {
    final shell = DynamicLibrary.open('shell32.dll');
    final isUserAnAdmin = shell
        .lookupFunction<Int32 Function(), int Function()>('IsUserAnAdmin');
    return isUserAnAdmin() != 0;
  }

  static bool _requestAdministratorSetup() {
    final executable = Platform.resolvedExecutable;
    if (!File(executable).isAbsolute || !File(executable).existsSync()) {
      return false;
    }
    final arguments = '--host-setup'.toNativeUtf16();
    final operation = 'runas'.toNativeUtf16();
    final file = executable.toNativeUtf16();
    final workingDirectory = File(executable).parent.path.toNativeUtf16();
    try {
      final result = ShellExecute(
        HWND(nullptr),
        PCWSTR(operation),
        PCWSTR(file),
        PCWSTR(arguments),
        PCWSTR(workingDirectory),
        SW_SHOWNORMAL,
      );
      return result.address > 32;
    } finally {
      malloc.free(arguments);
      malloc.free(operation);
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

  static void _startService(String serviceName) {
    using((arena) {
      final manager = OpenSCManager(null, null, SC_MANAGER_CONNECT);
      if (!manager.value.isValid) {
        throw const HostSetupException('HOST_SERVICE_CONTROL_UNAVAILABLE');
      }
      try {
        final name = serviceName.toNativeUtf16(allocator: arena);
        final service = OpenService(
          manager.value,
          PCWSTR(name),
          SERVICE_QUERY_STATUS | SERVICE_START,
        );
        if (!service.value.isValid) {
          throw HostSetupException(
            service.error.code == ERROR_SERVICE_DOES_NOT_EXIST.code
                ? 'HOST_SERVICE_NOT_INSTALLED'
                : 'HOST_SERVICE_CONTROL_UNAVAILABLE',
          );
        }
        try {
          final status = arena<SERVICE_STATUS>();
          final current = QueryServiceStatus(service.value, status);
          if (!current.value) {
            throw const HostSetupException('HOST_SERVICE_STATUS_UNAVAILABLE');
          }
          if (status.ref.dwCurrentState != SERVICE_RUNNING) {
            final started = StartService(service.value, 0, nullptr);
            if (!started.value &&
                started.error.code != ERROR_SERVICE_ALREADY_RUNNING.code) {
              throw const HostSetupException('HOST_SERVICE_START_FAILED');
            }
          }

          final deadline = DateTime.now().add(const Duration(seconds: 180));
          while (DateTime.now().isBefore(deadline)) {
            final queried = QueryServiceStatus(service.value, status);
            if (!queried.value) {
              throw const HostSetupException('HOST_SERVICE_STATUS_UNAVAILABLE');
            }
            if (status.ref.dwCurrentState == SERVICE_RUNNING) return;
            if (status.ref.dwCurrentState == SERVICE_STOPPED) {
              throw const HostSetupException('HOST_SERVICE_START_FAILED');
            }
            Sleep(250);
          }
          throw const HostSetupException('HOST_SERVICE_START_TIMEOUT');
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

  static String _exchangeWithBroker(String request) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final waitNamedPipe = kernel
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, int)
        >('WaitNamedPipeW');
    final pipePath = _pipeName.toNativeUtf16();
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    HANDLE? pipe;
    try {
      while (DateTime.now().isBefore(deadline)) {
        final ready = waitNamedPipe(pipePath, 1000);
        if (ready != 0) {
          final opened = CreateFile(
            PCWSTR(pipePath),
            0x80000000 | 0x40000000,
            FILE_SHARE_NONE,
            nullptr,
            OPEN_EXISTING,
            FILE_FLAGS_AND_ATTRIBUTES(0),
            null,
          );
          if (opened.value.isValid) {
            pipe = opened.value;
            break;
          }
        }
        Sleep(100);
      }
      if (pipe == null) {
        throw const HostSetupException('HOST_BOOTSTRAP_BROKER_UNAVAILABLE');
      }

      final mode = calloc<Uint32>()..value = 1;
      try {
        if (!SetNamedPipeHandleState(pipe, mode, nullptr, nullptr).value) {
          throw const HostSetupException('HOST_BOOTSTRAP_BROKER_UNAVAILABLE');
        }
      } finally {
        calloc.free(mode);
      }

      final requestBytes = Uint8List.fromList([...utf8.encode(request), 0x0a]);
      final writtenCount = calloc<Uint32>();
      final requestBuffer = calloc<Uint8>(requestBytes.length);
      try {
        requestBuffer.asTypedList(requestBytes.length).setAll(0, requestBytes);
        final wrote = WriteFile(
          pipe,
          requestBuffer,
          requestBytes.length,
          writtenCount,
          nullptr,
        );
        if (!wrote.value || writtenCount.value != requestBytes.length) {
          throw const HostSetupException('HOST_BOOTSTRAP_REQUEST_FAILED');
        }
      } finally {
        requestBytes.fillRange(0, requestBytes.length, 0);
        calloc.free(requestBuffer);
        calloc.free(writtenCount);
      }

      final response = BytesBuilder(copy: false);
      final responseBuffer = calloc<Uint8>();
      final readCount = calloc<Uint32>();
      final responseDeadline = DateTime.now().add(const Duration(seconds: 70));
      try {
        while (response.length < 8192 &&
            DateTime.now().isBefore(responseDeadline)) {
          final read = ReadFile(pipe, responseBuffer, 1, readCount, nullptr);
          if (read.value && readCount.value == 1) {
            final byte = responseBuffer.value;
            if (byte == 0x0a) return utf8.decode(response.takeBytes());
            response.addByte(byte);
            continue;
          }
          if (!read.value && read.error.code == ERROR_NO_DATA.code) {
            Sleep(20);
            continue;
          }
          throw const HostSetupException('HOST_BOOTSTRAP_RESPONSE_FAILED');
        }
        throw const HostSetupException('HOST_BOOTSTRAP_RESPONSE_TIMEOUT');
      } finally {
        final remainder = response.takeBytes();
        remainder.fillRange(0, remainder.length, 0);
        calloc.free(responseBuffer);
        calloc.free(readCount);
      }
    } finally {
      if (pipe != null) CloseHandle(pipe);
      malloc.free(pipePath);
    }
  }

  static HostFirstAdministratorReply _parseReply(String response) {
    try {
      final decoded = jsonDecode(response);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException();
      }
      const allowed = {
        'success',
        'status',
        'requestId',
        'actorId',
        'token',
        'expiresAt',
      };
      if (decoded.keys.any((key) => !allowed.contains(key)) ||
          decoded['success'] is! bool ||
          decoded['status'] is! String) {
        throw const FormatException();
      }
      String? optionalString(String key) {
        final value = decoded[key];
        if (value == null) return null;
        if (value is! String) throw const FormatException();
        return value;
      }

      return HostFirstAdministratorReply(
        success: decoded['success'] as bool,
        status: decoded['status'] as String,
        requestId: optionalString('requestId'),
        actorId: optionalString('actorId'),
        token: optionalString('token'),
        expiresAt: optionalString('expiresAt'),
      );
    } on HostSetupException {
      rethrow;
    } on Object {
      throw const HostSetupException('HOST_BOOTSTRAP_RESPONSE_INVALID');
    }
  }
}

HostSetupPlatform createHostSetupPlatform() => WindowsHostSetupPlatform();

HostSetupCredentialStore createHostSetupCredentialStore({
  required HostCredentialVault credentials,
  required LocalExtensionStore store,
}) => LocalHostSetupCredentialStore(credentials: credentials, store: store);
