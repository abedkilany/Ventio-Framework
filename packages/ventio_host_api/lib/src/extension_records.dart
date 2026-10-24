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
    required String search,
    required Map<String, dynamic> filters,
    required String? filterField,
    required String filterContains,
    required String? sortField,
    required bool descending,
    required int offset,
    required int limit,
  });
}

/// Marker required when record query routes are reachable beyond loopback.
abstract interface class AuthoritativeExtensionRecordQueryGateway
    implements ExtensionRecordQueryGateway {}
