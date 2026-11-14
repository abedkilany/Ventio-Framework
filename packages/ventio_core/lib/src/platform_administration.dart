import 'contracts.dart';
import 'customization.dart';

const organizationAdministrationPermission = 'platform.organizations.manage';
const hostOperationsManagePermission = 'platform.operations.manage';

/// The organization identity is the existing tenant identity. New companies
/// and branches never confer credential scopes, grants or memberships.
void validateOrganizationChange(Map<String, dynamic> change) {
  wave2Keys(change, const {
    'kind',
    'id',
    'parentId',
    'displayName',
    'archived',
    'expectedRevision',
    'requestId'
  });
  if (!const {'organization', 'company', 'branch'}.contains(change['kind']) ||
      requireString(change, 'id').length > 256 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(requireString(change, 'id')) ||
      requireString(change, 'displayName').length > 120 ||
      change['archived'] is! bool ||
      !RegExp(r'^[0-9a-f-]{36}$')
          .hasMatch(requireString(change, 'requestId'))) {
    throw const ContractError('INVALID_ORGANIZATION_CHANGE',
        'Invalid organization administration request.');
  }
  requireInt(change, 'expectedRevision');
  if (change['kind'] == 'branch') requireString(change, 'parentId');
  if (change['kind'] != 'branch' && change['parentId'] != null) {
    throw const ContractError('INVALID_ORGANIZATION_CHANGE',
        'Company/organization parents are fixed by tenant identity.');
  }
}

class BackupPolicy {
  BackupPolicy._(this.json);
  final Map<String, dynamic> json;
  factory BackupPolicy.fromJson(Map<String, dynamic> source) {
    wave2Keys(source, const {
      'contractVersion',
      'enabled',
      'utcTime',
      'retainDays',
      'retainCopies',
      'maximumAttempts',
      'retryMinutes'
    });
    if (source['contractVersion'] != 1 ||
        source['enabled'] is! bool ||
        !RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$')
            .hasMatch(requireString(source, 'utcTime')) ||
        requireInt(source, 'retainDays', min: 1) > 3650 ||
        requireInt(source, 'retainCopies', min: 2) > 1000 ||
        requireInt(source, 'maximumAttempts', min: 1) > 5 ||
        requireInt(source, 'retryMinutes', min: 5) > 1440) {
      throw const ContractError(
          'INVALID_BACKUP_POLICY', 'Invalid bounded backup policy.');
    }
    return BackupPolicy._(immutableJson(source) as Map<String, dynamic>);
  }
}

void validateOperationalSettings(Map<String, dynamic> body) {
  for (final key in ['maintenanceMode', 'jobsPaused']) {
    if (body.containsKey(key) && body[key] is! bool) {
      throw const ContractError(
          'INVALID_CONFIGURATION', 'Operational switches must be boolean.');
    }
  }
  for (final entry in {'defaultPageSize': 100, 'maxImportRows': 500}.entries) {
    if (body.containsKey(entry.key) &&
        requireInt(body, entry.key, min: 1) > entry.value) {
      throw const ContractError('INVALID_CONFIGURATION',
          'Operational bound exceeds the platform limit.');
    }
  }
}

void validateHostOperation(
    String id, String operation, Map<String, dynamic> body) {
  if (!RegExp(r'^[0-9a-f-]{36}$').hasMatch(id) ||
      !const {'APPLY_POLICY', 'BACKUP_NOW', 'RESTORE_PLAN', 'RESTORE'}
          .contains(operation)) {
    throw const ContractError(
        'INVALID_OPERATION', 'Unsupported Host operation.');
  }
  wave2Keys(
      body,
      operation == 'RESTORE'
          ? const {'backupName', 'planOperationId', 'planSha256'}
          : operation == 'RESTORE_PLAN'
              ? const {'backupName'}
              : const {});
  if (operation.startsWith('RESTORE') &&
      !RegExp(r'^ventio-postgresql-before-upgrade-[0-9]{8}T[0-9]{9}Z-[0-9a-f]{32}$')
          .hasMatch(requireString(body, 'backupName'))) {
    throw const ContractError('INVALID_OPERATION', 'Invalid backup identity.');
  }
  if (operation == 'RESTORE' &&
      (!RegExp(r'^[0-9a-f-]{36}$')
              .hasMatch(requireString(body, 'planOperationId')) ||
          !RegExp(r'^[0-9a-f]{64}$')
              .hasMatch(requireString(body, 'planSha256')))) {
    throw const ContractError(
        'INVALID_OPERATION', 'A current protected restore plan is required.');
  }
}
