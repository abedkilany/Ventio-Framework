import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ventio_core/ventio_core.dart';

import 'host_credentials.dart';
import 'transport_fixture.dart';

class HostScopeGrant {
  HostScopeGrant({
    required this.companyId,
    required this.branchId,
    required Iterable<String> permissions,
  }) : permissions = Set.unmodifiable(permissions);

  final String companyId;
  final String branchId;
  final Set<String> permissions;
}

class HostSessionIdentity {
  HostSessionIdentity({
    required this.tenantId,
    required this.actorId,
    required this.deviceId,
    required this.persistent,
    required this.roleAdministrationAvailable,
    required Iterable<HostScopeGrant> scopes,
  }) : scopes = List.unmodifiable(scopes);

  final String tenantId;
  final String actorId;
  final String deviceId;
  final bool persistent;
  final bool roleAdministrationAvailable;
  final List<HostScopeGrant> scopes;
}

class HostIdentityRole {
  HostIdentityRole({
    required this.roleId,
    required this.displayName,
    required Iterable<String> permissions,
    required Iterable<String> assignedActorIds,
  }) : permissions = Set.unmodifiable(permissions),
       assignedActorIds = List.unmodifiable(assignedActorIds);

  final String roleId;
  final String displayName;
  final Set<String> permissions;
  final List<String> assignedActorIds;
}

class HostIdentityRoleSnapshot {
  HostIdentityRoleSnapshot({
    required this.tenantId,
    required this.companyId,
    required this.branchId,
    required Iterable<HostIdentityRole> roles,
  }) : roles = List.unmodifiable(roles);

  final String tenantId;
  final String companyId;
  final String branchId;
  final List<HostIdentityRole> roles;
}

class HostExtensionRecord {
  HostExtensionRecord({
    required this.recordId,
    required this.revision,
    required this.updatedAtUtc,
    required Map<String, dynamic> values,
  }) : values = Map.unmodifiable(values);

  final String recordId;
  final int revision;
  final String updatedAtUtc;
  final Map<String, dynamic> values;
}

class HostExtensionRecordPage {
  HostExtensionRecordPage({
    required Iterable<HostExtensionRecord> records,
    required this.packageSha256,
    required this.hasMore,
    Iterable<String>? readableFields,
    Iterable<String>? writableFields,
    Iterable<String>? creatableFields,
  }) : records = List.unmodifiable(records),
       readableFields = readableFields == null
           ? null
           : Set.unmodifiable(readableFields),
       writableFields = writableFields == null
           ? null
           : Set.unmodifiable(writableFields),
       creatableFields = creatableFields == null
           ? null
           : Set.unmodifiable(creatableFields);

  final List<HostExtensionRecord> records;
  final String packageSha256;
  final bool hasMore;
  final Set<String>? readableFields;
  final Set<String>? writableFields;
  final Set<String>? creatableFields;
}

class HostApprovedPackageSummary {
  const HostApprovedPackageSummary({
    required this.moduleId,
    required this.version,
    required this.packageSha256,
    required this.displayName,
    required this.description,
  });

  final String moduleId;
  final String version;
  final String packageSha256;
  final String displayName;
  final String? description;
}

class HostApprovedPackagePage {
  HostApprovedPackagePage({
    required Iterable<HostApprovedPackageSummary> packages,
    required this.hasMore,
  }) : packages = List.unmodifiable(packages);

  final List<HostApprovedPackageSummary> packages;
  final bool hasMore;

  HostApprovedPackageSummary? get nextCursor =>
      packages.isEmpty ? null : packages.last;
}

typedef HostExtensionPackageClientFactory =
    HostExtensionPackageClient Function({
      required Uri endpoint,
      required HostCredentialVault credentials,
    });

enum HostPackageSubmissionStatus { submitted, alreadyApproved }

/// Authenticated transport for package review and approved-package reads.
/// It never treats a submitted candidate as an approved installation.
class HostExtensionPackageClient {
  HostExtensionPackageClient({
    required Uri endpoint,
    required this.credentials,
    HttpClient Function()? clientFactory,
    this.timeout = const Duration(seconds: 15),
    this.maxResponseBytes = 4 * 1024 * 1024,
  }) : endpoint = HostCredentialVault.normalizeEndpoint(endpoint),
       _clientFactory = clientFactory ?? HttpClient.new {
    if (timeout <= Duration.zero || maxResponseBytes < 1) {
      throw ArgumentError('Host package transport limits must be positive.');
    }
  }

  final Uri endpoint;
  final HostCredentialVault credentials;
  final HttpClient Function() _clientFactory;
  final Duration timeout;
  final int maxResponseBytes;

  Future<HostSessionIdentity> session() async {
    final response = await _request('GET', '/api/v1/session');
    if (response.statusCode != HttpStatus.ok) {
      throw _responseError(response);
    }
    final raw = response.body['identity'];
    if (raw is! Map) {
      throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
    }
    final identity = Map<String, dynamic>.from(raw);
    if (identity.keys.toSet().difference(const {
          'tenantId',
          'actorId',
          'deviceId',
          'persistent',
          'roleAdministrationAvailable',
          'scopes',
        }).isNotEmpty ||
        identity.keys.length != 6 ||
        identity['persistent'] is! bool ||
        identity['roleAdministrationAvailable'] is! bool ||
        identity['scopes'] is! List) {
      throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
    }
    final scopes = (identity['scopes'] as List).map((rawScope) {
      if (rawScope is! Map) {
        throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
      }
      final scope = Map<String, dynamic>.from(rawScope);
      if (scope.keys.toSet().difference(const {
            'companyId',
            'branchId',
            'permissions',
          }).isNotEmpty ||
          scope.keys.length != 3 ||
          scope['permissions'] is! List ||
          (scope['permissions'] as List).any((value) => value is! String)) {
        throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
      }
      final permissions = (scope['permissions'] as List).cast<String>();
      if (permissions.toSet().length != permissions.length) {
        throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
      }
      return HostScopeGrant(
        companyId: _requiredIdentifier(scope['companyId']),
        branchId: _requiredIdentifier(scope['branchId']),
        permissions: permissions,
      );
    }).toList();
    return HostSessionIdentity(
      tenantId: _requiredIdentifier(identity['tenantId']),
      actorId: _requiredIdentifier(identity['actorId']),
      deviceId: _requiredIdentifier(identity['deviceId']),
      persistent: identity['persistent'] as bool,
      roleAdministrationAvailable:
          identity['roleAdministrationAvailable'] as bool,
      scopes: scopes,
    );
  }

  Future<HostPackageSubmissionStatus> submit({
    required ExtensionBundle bundle,
    required String companyId,
    required String branchId,
  }) async {
    final response = await _request('POST', '/api/v1/extensions/submit', {
      'companyId': companyId,
      'branchId': branchId,
      'package': bundle.toJson(),
    });
    final result = _packageResult(response);
    return switch (result['status']) {
      'SUBMITTED' => HostPackageSubmissionStatus.submitted,
      'APPROVED' => HostPackageSubmissionStatus.alreadyApproved,
      _ => throw _packageError(response, result),
    };
  }

  Future<ExtensionBundle> readApproved({
    required String moduleId,
    required String version,
    required String companyId,
    required String branchId,
    String? expectedPackageSha256,
  }) async {
    final response = await _request('POST', '/api/v1/extensions/read', {
      'companyId': companyId,
      'branchId': branchId,
      'moduleId': moduleId,
      'version': version,
    });
    final result = _packageResult(response);
    if (response.statusCode != HttpStatus.ok ||
        result['status'] != 'APPROVED') {
      throw _packageError(response, result);
    }
    final rawPackage = result['package'];
    if (rawPackage is! Map) {
      throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
    }
    final bundle = ExtensionBundle.fromJson(
      Map<String, dynamic>.from(rawPackage),
    );
    final canonical = canonicalJson(bundle.toJson());
    if (utf8.encode(canonical).length > ExtensionBundle.maxEncodedBytes ||
        bundle.moduleId != moduleId ||
        bundle.version != version ||
        result['packageSha256'] !=
            sha256.convert(utf8.encode(canonical)).toString() ||
        (expectedPackageSha256 != null &&
            result['packageSha256'] != expectedPackageSha256)) {
      throw const HostPackageTransportException(
        'HOST_PACKAGE_INTEGRITY_FAILED',
      );
    }
    return bundle;
  }

  Future<HostApprovedPackagePage> listApproved({
    required String companyId,
    required String branchId,
    int limit = 50,
    String? afterModuleId,
    String? afterVersion,
  }) async {
    if (limit < 1 ||
        limit > 50 ||
        (afterModuleId == null) != (afterVersion == null)) {
      throw const HostPackageTransportException('INVALID_PACKAGE_PAGE');
    }
    if (afterModuleId != null) {
      if (!_validModuleId(afterModuleId)) {
        throw const HostPackageTransportException('INVALID_PACKAGE_PAGE');
      }
      try {
        semverParts(afterVersion!);
      } on ContractError {
        throw const HostPackageTransportException('INVALID_PACKAGE_PAGE');
      }
    }
    final body = <String, Object?>{
      'companyId': companyId,
      'branchId': branchId,
      'limit': limit,
    };
    if (afterModuleId != null) {
      body['afterModuleId'] = afterModuleId;
      body['afterVersion'] = afterVersion;
    }
    final response = await _request(
      'POST',
      '/api/v1/extensions/approved',
      body,
    );
    final result = _packageResult(response);
    if (response.statusCode != HttpStatus.ok ||
        result['status'] != 'APPROVED') {
      throw _packageError(response, result);
    }
    final rawPackages = result['packages'];
    final hasMore = result['hasMore'];
    if (result.keys.toSet().difference(const {
          'status',
          'packages',
          'hasMore',
        }).isNotEmpty ||
        result.length != 3 ||
        rawPackages is! List ||
        hasMore is! bool ||
        rawPackages.length > limit ||
        (hasMore && rawPackages.isEmpty)) {
      throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
    }
    final packages = rawPackages
        .map((rawPackage) {
          if (rawPackage is! Map) {
            throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
          }
          final item = Map<String, dynamic>.from(rawPackage);
          if (item.keys.toSet().difference(const {
                'moduleId',
                'version',
                'packageSha256',
                'displayName',
                'description',
              }).isNotEmpty ||
              item.length != 5) {
            throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
          }
          final moduleId = item['moduleId'];
          final version = item['version'];
          final digest = item['packageSha256'];
          final displayName = item['displayName'];
          final description = item['description'];
          if (moduleId is! String ||
              !_validModuleId(moduleId) ||
              version is! String ||
              !_validVersion(version) ||
              digest is! String ||
              !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
              displayName is! String ||
              displayName.trim().isEmpty ||
              displayName.length > 120 ||
              (description != null &&
                  (description is! String || description.length > 2000))) {
            throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
          }
          return HostApprovedPackageSummary(
            moduleId: moduleId,
            version: version,
            packageSha256: digest,
            displayName: displayName,
            description: description as String?,
          );
        })
        .toList(growable: false);
    final seen = <String>{};
    for (final package in packages) {
      if (!seen.add('${package.moduleId}\u0000${package.version}')) {
        throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
      }
    }
    return HostApprovedPackagePage(packages: packages, hasMore: hasMore);
  }

  Future<HostIdentityRoleSnapshot> listRoles({
    required String companyId,
    required String branchId,
  }) async {
    final response = await _request('POST', '/api/v1/identity/roles/list', {
      'companyId': companyId,
      'branchId': branchId,
    });
    final raw = response.body['identityRoles'];
    if (response.statusCode != HttpStatus.ok || raw is! Map) {
      throw _responseError(response);
    }
    final result = Map<String, dynamic>.from(raw);
    if (result.keys.toSet().difference(const {
          'tenantId',
          'companyId',
          'branchId',
          'roles',
        }).isNotEmpty ||
        result.keys.length != 4 ||
        result['roles'] is! List) {
      throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
    }
    final roles = (result['roles'] as List)
        .map((rawRole) {
          if (rawRole is! Map) {
            throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
          }
          final role = Map<String, dynamic>.from(rawRole);
          if (role.keys.toSet().difference(const {
                'roleId',
                'displayName',
                'permissions',
                'assignedActorIds',
              }).isNotEmpty ||
              role.keys.length != 4 ||
              role['permissions'] is! List ||
              role['assignedActorIds'] is! List ||
              (role['permissions'] as List).any((value) => value is! String) ||
              (role['assignedActorIds'] as List).any(
                (value) => value is! String,
              )) {
            throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
          }
          final permissions = (role['permissions'] as List).cast<String>();
          final actorIds = (role['assignedActorIds'] as List).cast<String>();
          if (permissions.toSet().length != permissions.length ||
              actorIds.toSet().length != actorIds.length ||
              role['displayName'] is! String ||
              (role['displayName'] as String).trim().isEmpty ||
              (role['displayName'] as String).length > 120 ||
              !RegExp(
                r'^[a-z][a-z0-9_.-]{0,127}$',
              ).hasMatch(_requiredIdentifier(role['roleId'])) ||
              permissions.any(
                (permission) =>
                    permission.length > 256 ||
                    !RegExp(r'^[a-z][a-z0-9_.]+$').hasMatch(permission),
              ) ||
              actorIds.any(
                (actorId) => actorId.trim().isEmpty || actorId.length > 256,
              )) {
            throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
          }
          return HostIdentityRole(
            roleId: role['roleId'] as String,
            displayName: role['displayName'] as String,
            permissions: permissions,
            assignedActorIds: actorIds,
          );
        })
        .toList(growable: false);
    final tenantId = _requiredIdentifier(result['tenantId']);
    final responseCompanyId = _requiredIdentifier(result['companyId']);
    final responseBranchId = _requiredIdentifier(result['branchId']);
    if (responseCompanyId != companyId || responseBranchId != branchId) {
      throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
    }
    return HostIdentityRoleSnapshot(
      tenantId: tenantId,
      companyId: responseCompanyId,
      branchId: responseBranchId,
      roles: roles,
    );
  }

  Future<void> createRole({
    required String companyId,
    required String branchId,
    required String roleId,
    required String displayName,
  }) => _changeRole('create', companyId, branchId, {
    'roleId': roleId,
    'displayName': displayName,
  });

  Future<void> renameRole({
    required String companyId,
    required String branchId,
    required String roleId,
    required String displayName,
  }) => _changeRole('rename', companyId, branchId, {
    'roleId': roleId,
    'displayName': displayName,
  });

  Future<void> deleteRole({
    required String companyId,
    required String branchId,
    required String roleId,
  }) => _changeRole('delete', companyId, branchId, {'roleId': roleId});

  Future<void> grantRolePermission({
    required String companyId,
    required String branchId,
    required String roleId,
    required String permission,
  }) => _changeRole('grant-permission', companyId, branchId, {
    'roleId': roleId,
    'permission': permission,
  });

  Future<void> revokeRolePermission({
    required String companyId,
    required String branchId,
    required String roleId,
    required String permission,
  }) => _changeRole('revoke-permission', companyId, branchId, {
    'roleId': roleId,
    'permission': permission,
  });

  Future<void> assignRole({
    required String companyId,
    required String branchId,
    required String roleId,
    required String actorId,
  }) => _changeRole('assign', companyId, branchId, {
    'roleId': roleId,
    'actorId': actorId,
  });

  Future<void> unassignRole({
    required String companyId,
    required String branchId,
    required String roleId,
    required String actorId,
  }) => _changeRole('unassign', companyId, branchId, {
    'roleId': roleId,
    'actorId': actorId,
  });

  Future<void> _changeRole(
    String action,
    String companyId,
    String branchId,
    Map<String, Object?> fields,
  ) async {
    final response = await _request('POST', '/api/v1/identity/roles/$action', {
      'companyId': companyId,
      'branchId': branchId,
      ...fields,
    });
    final rawResult = response.body['identityRoleResult'];
    if (response.statusCode != HttpStatus.ok ||
        rawResult is! Map ||
        rawResult['status'] != 'APPLIED') {
      throw _responseError(response);
    }
  }

  Future<HostExtensionRecordPage> queryRecords({
    required String companyId,
    required String branchId,
    required String moduleId,
    required String version,
    required String docType,
    String? recordId,
    String search = '',
    Map<String, dynamic> filters = const {},
    String? filterField,
    String filterContains = '',
    String? sortField,
    bool descending = false,
    int offset = 0,
    int limit = 50,
  }) async {
    if (search.length > 256 ||
        (recordId != null && (recordId.isEmpty || recordId.length > 128)) ||
        filterContains.length > 256 ||
        (filterField == null && filterContains.isNotEmpty) ||
        filters.length > 10 ||
        offset < 0 ||
        offset > 1000000 ||
        limit < 1 ||
        limit > 50 ||
        (recordId != null &&
            (search.isNotEmpty ||
                filters.isNotEmpty ||
                filterField != null ||
                filterContains.isNotEmpty ||
                offset != 0 ||
                limit != 1))) {
      throw const HostPackageTransportException('INVALID_RECORD_QUERY');
    }
    final query = <String, Object?>{
      'companyId': companyId,
      'branchId': branchId,
      'moduleId': moduleId,
      'version': version,
      'docType': docType,
      'search': search,
      'filters': filters,
      'filterField': filterField,
      'filterContains': filterContains,
      'sortField': sortField,
      'descending': descending,
      'offset': offset,
      'limit': limit,
    };
    if (recordId != null) query['recordId'] = recordId;
    final response = await _request(
      'POST',
      '/api/v1/extensions/records/query',
      query,
    );
    final rawResult = response.body['recordResult'];
    if (rawResult is! Map) {
      throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
    }
    final result = Map<String, dynamic>.from(rawResult);
    if (response.statusCode != HttpStatus.ok || result['status'] != 'RECORDS') {
      final reason = result['reasonCode'];
      final code =
          reason is String && RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(reason)
          ? reason
          : 'HOST_RECORD_QUERY_FAILED';
      throw HostPackageTransportException(
        code,
        statusCode: response.statusCode,
      );
    }
    final rawRecords = result['records'];
    final packageSha256 = result['packageSha256'];
    if (rawRecords is! List ||
        result['hasMore'] is! bool ||
        packageSha256 is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(packageSha256)) {
      throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
    }
    Set<String>? parseFieldSet(String key) {
      if (!result.containsKey(key)) return null;
      final raw = result[key];
      if (raw is! List ||
          raw.any(
            (value) =>
                value is! String ||
                !RegExp(r'^[a-z][A-Za-z0-9_]*$').hasMatch(value),
          )) {
        throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
      }
      final values = raw.cast<String>();
      if (values.toSet().length != values.length) {
        throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
      }
      return values.toSet();
    }

    final readableFields = parseFieldSet('readableFields');
    final writableFields = parseFieldSet('writableFields');
    final creatableFields = parseFieldSet('creatableFields');
    final records = rawRecords
        .map((rawRecord) {
          if (rawRecord is! Map) {
            throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
          }
          final row = Map<String, dynamic>.from(rawRecord);
          if (row.keys.toSet().difference(const {
                'recordId',
                'revision',
                'updatedAtUtc',
                'values',
              }).isNotEmpty ||
              row.length != 4 ||
              row['recordId'] is! String ||
              row['revision'] is! int ||
              row['revision'] < 1 ||
              row['updatedAtUtc'] is! String ||
              row['values'] is! Map) {
            throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
          }
          return HostExtensionRecord(
            recordId: row['recordId'] as String,
            revision: row['revision'] as int,
            updatedAtUtc: row['updatedAtUtc'] as String,
            values: Map<String, dynamic>.from(row['values'] as Map),
          );
        })
        .toList(growable: false);
    return HostExtensionRecordPage(
      records: records,
      packageSha256: packageSha256,
      hasMore: result['hasMore'] as bool,
      readableFields: readableFields,
      writableFields: writableFields,
      creatableFields: creatableFields,
    );
  }

  Future<_HostResponse> _request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    final token = await credentials.read(endpoint);
    if (token == null) {
      throw const HostPackageTransportException('HOST_CREDENTIAL_MISSING');
    }
    final watch = Stopwatch()..start();
    final client = _clientFactory()..connectionTimeout = timeout;
    try {
      final uri = endpoint.replace(path: path);
      final request = await client
          .openUrl(method, uri)
          .timeout(_remaining(watch));
      request
        ..followRedirects = false
        ..maxRedirects = 0;
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/json')
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(canonicalJson(body));
      }
      final response = await request.close().timeout(_remaining(watch));
      if (response.headers.contentType?.mimeType.toLowerCase() !=
          'application/json') {
        throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
      }
      if (response.contentLength > maxResponseBytes) {
        throw const HostPackageTransportException('HOST_RESPONSE_TOO_LARGE');
      }
      final bytes = await response
          .fold<List<int>>(<int>[], (buffer, chunk) {
            if (buffer.length + chunk.length > maxResponseBytes) {
              throw const HostPackageTransportException(
                'HOST_RESPONSE_TOO_LARGE',
              );
            }
            buffer.addAll(chunk);
            return buffer;
          })
          .timeout(_remaining(watch));
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
      }
      final envelope = Map<String, dynamic>.from(decoded);
      if (envelope['apiVersion'] != hostApiVersion) {
        throw const HostPackageTransportException('HOST_API_VERSION_MISMATCH');
      }
      return _HostResponse(response.statusCode, envelope);
    } on HostPackageTransportException {
      rethrow;
    } on TimeoutException {
      throw const HostPackageTransportException(
        'HOST_REQUEST_TIMEOUT',
        retryable: true,
      );
    } on SocketException {
      throw const HostPackageTransportException(
        'HOST_UNREACHABLE',
        retryable: true,
      );
    } on TlsException {
      throw const HostPackageTransportException('HOST_TLS_VALIDATION_FAILED');
    } on HttpException {
      throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
    } on FormatException {
      throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
    } finally {
      client.close(force: true);
    }
  }

  Duration _remaining(Stopwatch watch) {
    final remaining = timeout - watch.elapsed;
    if (remaining <= Duration.zero) {
      throw const HostPackageTransportException(
        'HOST_REQUEST_TIMEOUT',
        retryable: true,
      );
    }
    return remaining;
  }
}

class _HostResponse {
  const _HostResponse(this.statusCode, this.body);

  final int statusCode;
  final Map<String, dynamic> body;
}

Map<String, dynamic> _packageResult(_HostResponse response) {
  final raw = response.body['packageResult'];
  if (raw is Map) return Map<String, dynamic>.from(raw);
  throw _responseError(response);
}

HostPackageTransportException _packageError(
  _HostResponse response,
  Map<String, dynamic> result,
) {
  final reason = result['reasonCode'];
  if (reason is String && RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(reason)) {
    return HostPackageTransportException(
      reason,
      statusCode: response.statusCode,
      retryable: response.statusCode >= 500,
    );
  }
  return _responseError(response);
}

HostPackageTransportException _responseError(_HostResponse response) {
  final raw = response.body['error'];
  final error = raw is Map ? Map<String, dynamic>.from(raw) : const {};
  final code = error['code'];
  final retryable = error['retryable'];
  return HostPackageTransportException(
    code is String && RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(code)
        ? code
        : 'HOST_HTTP_ERROR',
    statusCode: response.statusCode,
    retryable: retryable == true || response.statusCode >= 500,
  );
}

String _requiredIdentifier(Object? value) {
  if (value is! String || value.trim().isEmpty || value.length > 256) {
    throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
  }
  return value;
}

bool _validModuleId(String value) =>
    value.length <= 128 &&
    RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$').hasMatch(value);

bool _validVersion(String value) {
  try {
    semverParts(value);
    return true;
  } on ContractError {
    return false;
  }
}

class HostPackageTransportException implements Exception {
  const HostPackageTransportException(
    this.code, {
    this.statusCode,
    this.retryable = false,
  });

  final String code;
  final int? statusCode;
  final bool retryable;

  @override
  String toString() =>
      'Host package transport error: $code${statusCode == null ? '' : ' ($statusCode)'}';
}
