import 'authentication.dart';

/// Bounded, metadata-validated read of records belonging to an approved
/// extension DocType. Implementations re-check identity and permissions.
abstract interface class ExtensionRecordQueryGateway {
  Future<Map<String, dynamic>> query({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String moduleId,
    required String version,
    required String docType,
    String? recordId,
    required String search,
    required Map<String, dynamic> filters,
    required String? filterField,
    required String filterContains,
    required String? sortField,
    required bool descending,
    String? cursor,
    required int offset,
    required int limit,
  });
}

/// Marker required when record query routes are reachable beyond loopback.
abstract interface class AuthoritativeExtensionRecordQueryGateway
    implements ExtensionRecordQueryGateway {}

/// Executes a saved, approved report without accepting caller-selected query
/// structure. Implementations enforce current identity, scope, and field ACLs.
abstract interface class ExtensionReportQueryGateway {
  Future<Map<String, dynamic>> queryReport({
    required AuthenticatedSession session,
    required String companyId,
    required String branchId,
    required String moduleId,
    required String version,
    required String docType,
    required String reportId,
    required Map<String, dynamic> filters,
  });
}

abstract interface class AuthoritativeExtensionReportQueryGateway
    implements ExtensionReportQueryGateway {}
