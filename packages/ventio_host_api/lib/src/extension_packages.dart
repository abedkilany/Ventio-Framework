import 'package:ventio_core/ventio_core.dart';

import 'authentication.dart';

/// Authenticated Host operations for declarative package handoff.
/// Implementations must re-check permissions in the database transaction;
/// the Principal snapshot is only a fast deny boundary.
abstract interface class ExtensionPackageGateway {
  Future<Map<String, dynamic>> submit({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required ExtensionBundle bundle,
  });

  Future<Map<String, dynamic>> readApproved({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String moduleId,
    required String version,
  });

  Future<Map<String, dynamic>> listApproved({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required int limit,
    String? afterModuleId,
    String? afterVersion,
  });
}

/// Marker required when package routes are reachable beyond loopback.
abstract interface class AuthoritativeExtensionPackageGateway
    implements ExtensionPackageGateway {}

/// Optional, read-only diagnostic used after an authenticated package request
/// fails the current-session permission projection. Implementations may return
/// only a stable safe reason code for this credential and exact branch.
abstract interface class ExtensionPermissionDenialDiagnosticGateway {
  Future<String> permissionDenialCode({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String permission,
  });
}
