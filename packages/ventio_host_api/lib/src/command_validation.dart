import 'package:ventio_core/ventio_core.dart';

/// Shared admission shape for HTTP commands and durable Host job commands.
void validateHostCommandWireShape(Map<String, dynamic> json) {
  const allowed = {
    'protocolVersion',
    'commandId',
    'type',
    'typeVersion',
    'tenantId',
    'companyId',
    'branchId',
    'aggregateId',
    'expectedRevision',
    'dependsOn',
    'payload',
    'clientContext',
  };
  final context = requireMap(json['clientContext'], 'clientContext');
  if (json.keys.any((key) => !allowed.contains(key)) ||
      context.keys.any(
        (key) => !{
          'deviceId',
          'actorId',
          'moduleVersion',
          'docTypeVersion',
          'clientTimestamp',
        }.contains(key),
      ) ||
      !RegExp(r'^[a-z][a-z0-9_.]+$').hasMatch(requireString(json, 'type'))) {
    throw const ContractError('INVALID_COMMAND', 'Invalid command wire shape.');
  }
  if (context.containsKey('clientTimestamp') &&
      (context['clientTimestamp'] is! String ||
          !RegExp(
            r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$',
          ).hasMatch(context['clientTimestamp'] as String) ||
          DateTime.tryParse(context['clientTimestamp'] as String) == null)) {
    throw const ContractError('INVALID_COMMAND', 'Invalid command wire shape.');
  }
  for (final key in [
    'tenantId',
    'companyId',
    'branchId',
    'aggregateId',
    'type',
  ]) {
    if (requireString(json, key).length > 256)
      throw const ContractError(
        'INVALID_COMMAND',
        'Invalid command wire shape.',
      );
  }
  for (final key in ['actorId', 'deviceId']) {
    if (requireString(context, key).length > 256)
      throw const ContractError(
        'INVALID_COMMAND',
        'Invalid command wire shape.',
      );
  }
  if (json['dependsOn'] is List && (json['dependsOn'] as List).length > 128) {
    throw const ContractError('INVALID_COMMAND', 'Invalid command wire shape.');
  }
}
