import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Launch only the installed, fixed operator script. The selected operation
/// contains no executable path, shell fragment or credential. UAC is a second,
/// machine-local authority boundary, independent of scoped Host permissions.
Future<bool> approveLocalHostOperation(
  String endpoint,
  String id, {
  String? restorePlanSha256,
}) async {
  final host = Uri.parse(endpoint).host;
  if (!Platform.isWindows ||
      !const {'127.0.0.1', 'localhost', '::1'}.contains(host) ||
      !RegExp(r'^[0-9a-f-]{36}$').hasMatch(id) ||
      (restorePlanSha256 != null &&
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(restorePlanSha256))) {
    throw StateError(
      'Local Windows Host profile required for elevated approval',
    );
  }
  return Isolate.run(() {
    final root = Platform.environment['ProgramFiles'];
    final system = Platform.environment['SystemRoot'];
    if (root == null || system == null) {
      throw StateError('Windows installation unavailable');
    }
    final script = File(
      '$root\\Ventio\\host-payload\\setup\\manage-host-operations.ps1',
    );
    final powershell = File(
      '$system\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
    );
    if (!script.existsSync() || !powershell.existsSync()) {
      throw StateError('Installed operations payload unavailable');
    }
    // Double quotes cannot enter trusted installation roots; IDs are hex only.
    if (script.path.contains('"') || powershell.path.contains('"')) {
      throw StateError('Invalid installed path');
    }
    final args =
        '-NoProfile -ExecutionPolicy Bypass -File "${script.path}" -OperationId $id${restorePlanSha256 == null ? '' : ' -ConfirmRestore -ExpectedPlanSha256 $restorePlanSha256'}'
            .toNativeUtf16();
    final exe = powershell.path.toNativeUtf16();
    final verb = 'runas'.toNativeUtf16();
    final cwd = script.parent.path.toNativeUtf16();
    try {
      final result = ShellExecute(
        HWND(nullptr),
        PCWSTR(verb),
        PCWSTR(exe),
        PCWSTR(args),
        PCWSTR(cwd),
        SW_SHOWNORMAL,
      );
      if (result.address == 1223) return false;
      if (result.address <= 32) {
        throw StateError('Elevated operation could not launch');
      }
      return true;
    } finally {
      malloc.free(args);
      malloc.free(exe);
      malloc.free(verb);
      malloc.free(cwd);
    }
  });
}
