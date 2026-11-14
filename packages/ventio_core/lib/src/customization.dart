import 'dart:convert';

import 'contracts.dart';
import 'extension_bundle.dart';
import 'metadata.dart';

/// A separately owned overlay. Approved package bytes are never rewritten.
/// Version 1 permits optional scalar fields and presentation overrides only.
class MetadataCustomization {
  MetadataCustomization._(this.json);

  final Map<String, dynamic> json;
  static const apiVersion = 1;
  String get moduleId => json['moduleId'] as String;
  String get moduleVersion => json['moduleVersion'] as String;
  String get docType => json['docType'] as String;
  String get baseSha256 => json['baseSha256'] as String;

  factory MetadataCustomization.fromJson(Map<String, dynamic> source) {
    wave2Keys(source, const {
      'contractVersion',
      'moduleId',
      'moduleVersion',
      'docType',
      'baseSha256',
      'fields',
      'properties',
      'ui',
    });
    if (source['contractVersion'] != apiVersion ||
        utf8.encode(canonicalJson(source)).length > 32768 ||
        !isValidModuleId(requireString(source, 'moduleId')) ||
        !RegExp(
          r'^[A-Z][A-Za-z0-9_]{0,79}$',
        ).hasMatch(requireString(source, 'docType')) ||
        !RegExp(
          r'^[0-9a-f]{64}$',
        ).hasMatch(requireString(source, 'baseSha256'))) {
      throw const ContractError(
        'INVALID_CUSTOMIZATION',
        'Invalid overlay identity.',
      );
    }
    semverParts(requireString(source, 'moduleVersion'));
    final customNamespace =
        'extension.${requireString(source, 'moduleId').replaceAll(RegExp(r'[^a-z0-9]+'), '_')}.custom.';
    final fields = requireList(source, 'fields');
    if (fields.length > 20) {
      throw const ContractError(
        'INVALID_CUSTOMIZATION',
        'At most 20 custom fields are allowed.',
      );
    }
    final names = <String>{};
    for (final raw in fields) {
      final field = requireMap(raw, 'fields[]');
      wave2Keys(field, const {
        'name',
        'type',
        'required',
        'label',
        'labelKey',
        'maxLength',
        'precision',
        'readPermission',
        'writePermission',
      });
      final definition = FieldDefinition.fromJson(field);
      if (!RegExp(r'^custom_[A-Za-z0-9_]{1,73}$').hasMatch(definition.name) ||
          !names.add(definition.name) ||
          definition.required ||
          !definition.labelKey.startsWith(customNamespace) ||
          !const {
            'text',
            'long_text',
            'integer',
            'decimal',
            'boolean',
            'date',
            'datetime',
          }.contains(definition.type) ||
          definition.readPermission == null ||
          definition.writePermission == null) {
        throw const ContractError(
          'INVALID_CUSTOMIZATION',
          'Custom fields must be optional scalar fields with explicit permissions.',
        );
      }
    }
    final properties = requireMap(source['properties'], 'properties');
    wave2Keys(properties, const {'label', 'labelKey'});
    if (properties.isNotEmpty) {
      if (properties.length != 2 ||
          requireString(properties, 'label').length > 120) {
        throw const ContractError(
          'INVALID_CUSTOMIZATION',
          'Labels require a fallback and message key.',
        );
      }
      requireString(properties, 'labelKey');
      if (!requireString(properties, 'labelKey').startsWith(customNamespace)) {
        throw const ContractError(
          'INVALID_CUSTOMIZATION',
          'Custom labels require a separate customization namespace.',
        );
      }
    }
    final ui = requireMap(source['ui'], 'ui');
    wave2Keys(ui, const {
      'listColumns',
      'formFields',
      'detailFields',
      'pageTitle',
      'pageTitleKey',
      'pageIcon',
      'pageOrder',
    });
    if (ui.containsKey('pageTitle') != ui.containsKey('pageTitleKey') ||
        (ui.containsKey('pageTitleKey') &&
            !requireString(ui, 'pageTitleKey').startsWith(customNamespace))) {
      throw const ContractError(
        'INVALID_CUSTOMIZATION',
        'Custom page titles require a separate namespaced label key.',
      );
    }
    for (final key in ['listColumns', 'formFields', 'detailFields']) {
      if (!ui.containsKey(key)) continue;
      final fields = strings(requireList(ui, key), key);
      if (fields.isEmpty ||
          fields.length > 100 ||
          fields.toSet().length != fields.length) {
        throw const ContractError(
          'INVALID_CUSTOMIZATION',
          'Layouts require unique, bounded field lists.',
        );
      }
    }
    // Deep-copy before freezing: caller-owned Maps cannot change a validated overlay.
    return MetadataCustomization._(_freeze(source) as Map<String, dynamic>);
  }

  /// Rebase is explicit: callers must pin a new package digest and review the
  /// merged result. Destructive custom-field changes are refused on every save.
  ExtensionBundle merge(
    ExtensionBundle base, {
    MetadataCustomization? previous,
  }) {
    if (base.moduleId != moduleId || base.version != moduleVersion) {
      throw const ContractError(
        'CUSTOMIZATION_BASE_CHANGED',
        'The overlay targets another package release.',
      );
    }
    final source =
        jsonDecode(canonicalJson(base.toJson())) as Map<String, dynamic>;
    final definitions = requireList(source, 'docTypes');
    final matches = definitions
        .cast<Map<String, dynamic>>()
        .where((item) => item['name'] == docType)
        .toList();
    if (matches.length != 1) {
      throw const ContractError(
        'INVALID_CUSTOMIZATION',
        'The target DocType is unavailable.',
      );
    }
    final target = matches.single;
    final fields = requireList(target, 'fields');
    final baseFields = List<dynamic>.of(fields);
    final catalog = requireMap(source['englishCatalog'], 'englishCatalog');
    final names =
        fields.map((item) => requireMap(item, 'field')['name']).toSet();
    final permissions = requireMap(target['permissions'], 'permissions');
    final customFields = requireList(json, 'fields');
    if (permissions['read'] == null || permissions['update'] == null) {
      throw const ContractError(
        'INVALID_CUSTOMIZATION',
        'Custom fields require read and update operations.',
      );
    }
    for (final raw in customFields) {
      final field = requireMap(raw, 'field');
      if (!names.add(field['name']) ||
          field['readPermission'] != permissions['read'] ||
          field['writePermission'] != permissions['update']) {
        throw const ContractError(
          'INVALID_CUSTOMIZATION',
          'Custom fields must inherit DocType permissions and have unique names.',
        );
      }
      fields.add(field);
      catalog[field['labelKey'] as String] = field['label'];
    }
    if (previous != null) {
      for (final old in requireList(previous.json, 'fields')) {
        final oldField = requireMap(old, 'field');
        final next = customFields
            .map((raw) => requireMap(raw, 'field'))
            .where((item) => item['name'] == oldField['name'])
            .toList();
        const presentation = {'label', 'labelKey'};
        Map<String, dynamic> structural(Map<String, dynamic> value) => {
              for (final entry in value.entries)
                if (!presentation.contains(entry.key)) entry.key: entry.value,
            };
        if (next.length != 1 ||
            canonicalJson(structural(next.single)) !=
                canonicalJson(structural(oldField))) {
          throw const ContractError(
            'CUSTOMIZATION_MIGRATION_REQUIRED',
            'Removing or changing stored custom fields requires an explicit future migration.',
          );
        }
      }
    }
    final properties = requireMap(json['properties'], 'properties');
    target.addAll(properties);
    if (properties.isNotEmpty)
      catalog[properties['labelKey'] as String] = properties['label'];
    final ui = Map<String, dynamic>.from(
      target['ui'] as Map? ??
          {
            'listColumns': baseFields
                .take(4)
                .map((field) => (field as Map)['name'])
                .toList(),
            'formFields':
                baseFields.map((field) => (field as Map)['name']).toList(),
            'detailFields':
                baseFields.map((field) => (field as Map)['name']).toList(),
          },
    );
    ui.addAll(requireMap(json['ui'], 'ui'));
    target['ui'] = ui;
    if (ui['pageTitleKey'] is String && ui['pageTitle'] is String) {
      catalog[ui['pageTitleKey'] as String] = ui['pageTitle'];
    }
    source['englishCatalog'] = catalog;
    // Full existing package validation is retained, including namespace,
    // layout, field, report and platform-version compatibility checks.
    return ExtensionBundle.fromJson(source);
  }
}

void wave2Keys(Map<String, dynamic> json, Set<String> allowed) {
  if (json.keys.any((key) => !allowed.contains(key))) {
    throw const ContractError(
      'INVALID_WAVE2_CONTRACT',
      'Unsupported declarative property.',
    );
  }
}

Object? _freeze(Object? value) => switch (value) {
      Map() => Map<String, dynamic>.unmodifiable({
          for (final entry in value.entries)
            entry.key as String: _freeze(entry.value),
        }),
      List() => List<dynamic>.unmodifiable(value.map(_freeze)),
      _ => value,
    };
