import 'dart:io';

import 'package:ventio_core/ventio_core.dart';

import 'host_readiness.dart';

class HostDiagnosticsResult {
  HostDiagnosticsResult({
    required this.correlationId,
    required Iterable<ManagementDiagnosticEvent> events,
  }) : events = List.unmodifiable(events);

  final String correlationId;
  final List<ManagementDiagnosticEvent> events;
}

/// Reads safe Host diagnostic events through a scoped, authenticated route.
/// The Host remains authoritative for every authorization decision.
class HostDiagnosticsClient {
  const HostDiagnosticsClient(this.transport);

  final HostReadinessClient transport;

  bool get canReadDiagnostics =>
      transport.canReadManagementPermission(hostDiagnosticsReadPermission);

  Future<HostDiagnosticsResult> recent({int limit = 50}) async {
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit');
    }
    final response = await transport.postManagement(
      path: HostManagementRoutes.diagnosticsRecent,
      permission: hostDiagnosticsReadPermission,
      payload: {
        'managementApiVersion': managementApiVersion,
        'companyId': transport.companyId,
        'branchId': transport.branchId,
        'limit': limit,
      },
    );
    final correlationId = _correlationId(response.body['correlationId']);
    if (response.statusCode != HttpStatus.ok) {
      final rawError = response.body['error'];
      final error = rawError is Map
          ? Map<String, dynamic>.from(rawError)
          : const <String, dynamic>{};
      final rawCode = error['code'];
      final code =
          rawCode is String &&
              RegExp(r'^[A-Z][A-Z0-9_]{0,79}$').hasMatch(rawCode)
          ? rawCode
          : 'HOST_HTTP_ERROR';
      throw HostReadinessException(
        code,
        statusCode: response.statusCode,
        correlationId: correlationId,
        retryable: error['retryable'] == true || response.statusCode >= 500,
      );
    }
    const expectedKeys = {
      'apiVersion',
      'managementApiVersion',
      'correlationId',
      'events',
    };
    final rawEvents = response.body['events'];
    if (response.body.length != expectedKeys.length ||
        response.body.keys.any((key) => !expectedKeys.contains(key)) ||
        rawEvents is! List ||
        rawEvents.length > limit) {
      throw HostReadinessException(
        'HOST_INVALID_RESPONSE',
        statusCode: response.statusCode,
        correlationId: correlationId,
      );
    }
    try {
      return HostDiagnosticsResult(
        correlationId: correlationId,
        events: rawEvents.map(ManagementDiagnosticEvent.fromJson),
      );
    } on FormatException {
      throw HostReadinessException(
        'HOST_INVALID_RESPONSE',
        statusCode: response.statusCode,
        correlationId: correlationId,
      );
    } on ArgumentError {
      throw HostReadinessException(
        'HOST_INVALID_RESPONSE',
        statusCode: response.statusCode,
        correlationId: correlationId,
      );
    }
  }
}

String _correlationId(Object? value) {
  if (value is String && RegExp(r'^cor_[a-f0-9]{32}$').hasMatch(value)) {
    return value;
  }
  throw const HostReadinessException('HOST_INVALID_RESPONSE');
}
