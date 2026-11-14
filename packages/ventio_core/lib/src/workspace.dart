import 'dart:convert';

import 'contracts.dart';
import 'customization.dart';
import 'platform_administration.dart';

const wave2ContractVersion = 1;
const wave2CustomizationManagePermission = 'platform.customizations.manage';
const wave2WorkspacePermission = 'platform.workspace.use';
const wave2JobsRunPermission = 'platform.jobs.run';
const wave2JobsManagePermission = 'platform.jobs.manage';
const wave2ConfigurationPermission = 'platform.configuration.manage';

/// Saved queries contain declarative values only; the existing Host query
/// gateway revalidates every field, filter and sort when the view is opened.
class SavedRecordView {
  SavedRecordView._(this.json);
  final Map<String, dynamic> json;
  factory SavedRecordView.fromJson(Map<String, dynamic> source) {
    wave2Keys(source, const {
      'contractVersion',
      'title',
      'moduleId',
      'moduleVersion',
      'docType',
      'search',
      'filters',
      'sortField',
      'descending',
      'columns',
    });
    if (source['contractVersion'] != wave2ContractVersion ||
        requireString(source, 'title').length > 120 ||
        !isValidModuleId(requireString(source, 'moduleId')) ||
        !RegExp(
          r'^[A-Z][A-Za-z0-9_]{0,79}$',
        ).hasMatch(requireString(source, 'docType')) ||
        requireString(source, 'search', nonEmpty: false).length > 256 ||
        source['descending'] is! bool) {
      throw const ContractError('INVALID_SAVED_VIEW', 'Invalid saved view.');
    }
    semverParts(requireString(source, 'moduleVersion'));
    final filters = requireMap(source['filters'], 'filters');
    if (filters.length > 10 ||
        filters.entries.any(
          (entry) =>
              !_fieldName.hasMatch(entry.key) ||
              entry.value is Map ||
              entry.value is List ||
              entry.value == null ||
              (entry.value is String && (entry.value as String).length > 256),
        )) {
      throw const ContractError('INVALID_SAVED_VIEW', 'Invalid saved filters.');
    }
    final sort = source['sortField'];
    final columns = strings(requireList(source, 'columns'), 'columns');
    if ((sort != null && (sort is! String || !_fieldName.hasMatch(sort))) ||
        columns.isEmpty ||
        columns.length > 20 ||
        columns.toSet().length != columns.length ||
        columns.any((name) => !_fieldName.hasMatch(name))) {
      throw const ContractError(
        'INVALID_SAVED_VIEW',
        'Invalid view columns or sort.',
      );
    }
    return SavedRecordView._(immutableJson(source) as Map<String, dynamic>);
  }
}

final _fieldName = RegExp(r'^[a-z][A-Za-z0-9_]{0,79}$');

/// Validates the bounded, non-executable settings exposed by Wave 2. These
/// settings never select a file path, SQL, URL, executable, credential or role.
void validateWave2Definition(String kind, Map<String, dynamic> body) {
  if (utf8.encode(canonicalJson(body)).length > 32768) {
    throw const ContractError(
      'DEFINITION_TOO_LARGE',
      'Definition exceeds 32 KiB.',
    );
  }
  switch (kind) {
    case 'customization':
      MetadataCustomization.fromJson(body);
    case 'saved_view':
      SavedRecordView.fromJson(body);
    case 'preferences':
      wave2Keys(body, const {
        'contractVersion',
        'density',
        'theme',
        'moduleOrder',
      });
      final order = strings(requireList(body, 'moduleOrder'), 'moduleOrder');
      if (body['contractVersion'] != 1 ||
          !const {'comfortable', 'compact'}.contains(body['density']) ||
          !const {'system', 'light', 'dark'}.contains(body['theme']) ||
          order.length > 64 ||
          order.toSet().length != order.length ||
          order.any((id) => !isValidModuleId(id))) {
        throw const ContractError(
          'INVALID_PREFERENCES',
          'Invalid interface preference.',
        );
      }
    case 'dashboard':
      wave2Keys(body, const {'contractVersion', 'title', 'cards'});
      final cards = requireList(body, 'cards');
      if (body['contractVersion'] != 1 ||
          requireString(body, 'title').length > 120 ||
          cards.length > 12) {
        throw const ContractError('INVALID_DASHBOARD', 'Invalid dashboard.');
      }
      for (final raw in cards) {
        final card = requireMap(raw, 'card');
        wave2Keys(card, const {
          'title',
          'moduleId',
          'moduleVersion',
          'docType',
          'reportId',
          'filters',
        });
        if (requireString(card, 'title').length > 120 ||
            !isValidModuleId(requireString(card, 'moduleId')) ||
            requireString(card, 'docType').length > 80 ||
            requireString(card, 'reportId').length > 128 ||
            requireMap(card['filters'], 'filters').length > 10) {
          throw const ContractError(
            'INVALID_DASHBOARD',
            'Invalid dashboard card.',
          );
        }
        semverParts(requireString(card, 'moduleVersion'));
      }
    case 'configuration':
      wave2Keys(body, const {
        'contractVersion',
        'displayName',
        'maintenanceNotice',
        'maintenanceMode',
        'jobsPaused',
        'defaultPageSize',
        'maxImportRows',
        'completedJobRetentionDays',
      });
      validateOperationalSettings(body);
      if (body['contractVersion'] != 1 ||
          requireString(body, 'displayName').length > 120 ||
          requireString(body, 'maintenanceNotice', nonEmpty: false).length >
              1000) {
        throw const ContractError(
          'INVALID_CONFIGURATION',
          'Invalid scoped configuration.',
        );
      }
    case 'backup_policy':
      BackupPolicy.fromJson(body);
    default:
      throw const ContractError(
        'UNSUPPORTED_DEFINITION',
        'Unsupported definition kind.',
      );
  }
}
