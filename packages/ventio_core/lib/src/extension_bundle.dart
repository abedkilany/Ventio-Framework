import 'dart:convert';
import 'dart:collection';

import 'contracts.dart';
import 'metadata.dart';
import 'modules.dart';

/// A bounded, declarative extension package for the trusted generic engines.
/// It carries no executable commands, scripts, SQL or custom capabilities.
class ExtensionBundle {
  ExtensionBundle._({
    required this.manifest,
    required this.docTypes,
    required this.dependencyVersions,
    required this.englishCatalog,
    required this.manifestJson,
    required this.docTypeJson,
  });

  static const maxEncodedBytes = 1024 * 1024;
  static const maxDocTypes = 64;
  static const maxFieldsPerDocType = 100;

  final ModuleManifest manifest;
  final List<DocTypeDefinition> docTypes;
  final Map<String, String> dependencyVersions;
  final Map<String, String> englishCatalog;
  final Map<String, dynamic> manifestJson;
  final List<Map<String, dynamic>> docTypeJson;

  String get moduleId => manifest.moduleId;
  String get version => manifest.version;

  factory ExtensionBundle.fromJson(Map<String, dynamic> source) {
    _validateJsonTree(source);
    _checkKeys(
      source,
      const {'manifest', 'docTypes', 'dependencyVersions', 'englishCatalog'},
      'extension bundle',
    );
    if (utf8.encode(canonicalJson(source)).length > maxEncodedBytes) {
      throw const ContractError(
        'EXTENSION_TOO_LARGE',
        'An extension package cannot exceed 1 MiB.',
      );
    }

    final rawManifest = requireMap(source['manifest'], 'manifest');
    _checkKeys(
      rawManifest,
      const {
        'manifestVersion',
        'moduleId',
        'version',
        'minPlatformApi',
        'displayName',
        'displayNameKey',
        'description',
        'descriptionKey',
        'englishCatalog',
        'dependencies',
        'docTypes',
        'commands',
        'requiredCapabilities',
        'offline',
      },
      'manifest',
    );
    final manifest = ModuleManifest.fromJson(rawManifest);
    if (!_moduleId.hasMatch(manifest.moduleId) ||
        manifest.moduleId.length > 128 ||
        manifest.displayName.length > 120 ||
        manifest.dependencies.length > 32) {
      throw const ContractError('INVALID_MODULE_ID', 'Invalid extension ID.');
    }
    final description = rawManifest['description'];
    if (description != null &&
        (description is! String || description.length > 2000)) {
      throw const ContractError(
        'INVALID_EXTENSION_BUNDLE',
        'The extension description must be text up to 2,000 characters.',
      );
    }
    final messageNamespace = 'extension.${_moduleSlug(manifest.moduleId)}.';
    _requireNamespace(manifest.displayNameKey, messageNamespace);
    if (!RegExp(r'^localization/en\.[a-z0-9_]+\.json$')
        .hasMatch(manifest.englishCatalog)) {
      throw const ContractError(
        'INVALID_ENGLISH_CATALOG',
        'The English catalog must be a bounded relative package path.',
      );
    }
    if (rawManifest.containsKey('descriptionKey')) {
      _requireNamespace(
        requireString(rawManifest, 'descriptionKey'),
        messageNamespace,
      );
    }
    if (manifest.commands.isNotEmpty ||
        manifest.requiredCapabilities.isNotEmpty ||
        manifest.offlineEnabled ||
        manifest.offlineCommands.isNotEmpty) {
      throw const ContractError(
        'UNTRUSTED_EXECUTABLE_SURFACE',
        'Metadata packages cannot provide commands, capabilities or executable offline handlers.',
      );
    }
    final offline = requireMap(rawManifest['offline'], 'offline');
    _checkKeys(offline, const {'enabled', 'allowedCommands'}, 'offline');

    final rawDocTypes = requireList(source, 'docTypes');
    if (rawDocTypes.isEmpty || rawDocTypes.length > maxDocTypes) {
      throw const ContractError(
        'INVALID_EXTENSION_BUNDLE',
        'An extension must define between 1 and 64 DocTypes.',
      );
    }
    final docTypeJson = rawDocTypes.map((raw) {
      final json = requireMap(raw, 'docTypes[]');
      _checkKeys(
        json,
        const {
          'name',
          'moduleId',
          'schemaVersion',
          'kind',
          'label',
          'labelKey',
          'description',
          'descriptionKey',
          'operations',
          'permissions',
          'fields',
          'ui',
          'migrations',
        },
        'DocType',
      );
      if (json['name'] is! String ||
          !_docTypeName.hasMatch(json['name'] as String) ||
          (json['name'] as String).length > 80) {
        throw const ContractError('INVALID_DOCTYPE', 'Invalid DocType name.');
      }
      final ui = requireMap(json['ui'], 'ui');
      _checkKeys(
        ui,
        const {
          'listColumns',
          'formFields',
          'detailFields',
          'pageTitle',
          'pageTitleKey',
          'pageIcon',
          'pageOrder',
        },
        'ui',
      );
      final fields = requireList(json, 'fields');
      if (fields.length > maxFieldsPerDocType) {
        throw const ContractError(
          'TOO_MANY_FIELDS',
          'A DocType may contain at most 100 fields.',
        );
      }
      for (final rawField in fields) {
        final field = requireMap(rawField, 'fields[]');
        _checkKeys(
          field,
          const {
            'name',
            'type',
            'required',
            'label',
            'labelKey',
            'minLength',
            'maxLength',
            'minValue',
            'maxValue',
            'precision',
            'default',
            'readOnly',
            'enumValues',
            'enumLabels',
            'referenceTo',
            'description',
            'descriptionKey',
            'readPermission',
            'writePermission',
          },
          'field',
        );
        if (field['name'] is! String ||
            !_fieldName.hasMatch(field['name'] as String) ||
            (field['name'] as String).length > 80) {
          throw const ContractError('INVALID_FIELD', 'Invalid field name.');
        }
        if (field['enumLabels'] case final labels?) {
          final values = requireMap(labels, 'enumLabels');
          for (final entry in values.entries) {
            final option = requireMap(entry.value, 'enumLabels[]');
            _checkKeys(option, const {'label', 'labelKey'}, 'enum label');
          }
        }
      }
      return _freezeMap(json);
    }).toList(growable: false);
    final docTypes =
        docTypeJson.map(DocTypeDefinition.fromJson).toList(growable: false);
    final hasFieldPermissions = docTypes.any(
      (type) => type.fields.any(
        (field) =>
            field.readPermission != null || field.writePermission != null,
      ),
    );
    if (hasFieldPermissions &&
        compareSemver(
              manifest.minPlatformApi,
              fieldPermissionPlatformApiVersion,
            ) <
            0) {
      throw const ContractError(
        'INCOMPATIBLE_PLATFORM',
        'Field permission metadata requires a platform API that enforces it.',
      );
    }
    final migrationStepCount = docTypes.fold<int>(
      0,
      (count, type) =>
          count +
          type.migrations.fold<int>(
            0,
            (steps, migration) => steps + migration.steps.length,
          ),
    );
    if (migrationStepCount > 128) {
      throw const ContractError(
        'TOO_MANY_MIGRATION_STEPS',
        'An extension package may contain at most 128 data migration operations.',
      );
    }
    final names = docTypes.map((type) => type.name).toSet();
    if (names.length != docTypes.length ||
        names.length != manifest.docTypes.length ||
        !names.containsAll(manifest.docTypes) ||
        docTypes.any(
          (type) =>
              type.moduleId != manifest.moduleId || type.kind != 'operational',
        )) {
      throw const ContractError(
        'INVALID_EXTENSION_BUNDLE',
        'DocTypes must uniquely match the package manifest and remain operational.',
      );
    }

    final doctypeNames = docTypes.map((type) => type.name).toSet();
    for (final type in docTypes) {
      for (final field in type.fields) {
        if (field.type == 'reference' &&
            !doctypeNames.contains(field.referenceTo)) {
          throw ContractError(
            'UNKNOWN_RELATION_TARGET',
            '${field.name} refers outside this extension package.',
          );
        }
      }
      _requireNamespace(type.labelKey, messageNamespace);
      _requireNamespace(type.pageTitleKey, messageNamespace);
      if (type.permissions.values.any(
        (permission) => !permission.startsWith(messageNamespace),
      )) {
        throw ContractError(
          'PERMISSION_NAMESPACE',
          '${type.name} declares a permission outside its extension namespace.',
        );
      }
      if (type.fields.any(
        (field) => [field.readPermission, field.writePermission]
            .whereType<String>()
            .any((permission) => !permission.startsWith(messageNamespace)),
      )) {
        throw ContractError(
          'PERMISSION_NAMESPACE',
          '${type.name} declares a field permission outside its extension namespace.',
        );
      }
    }

    final rawVersions =
        requireMap(source['dependencyVersions'], 'dependencyVersions');
    if (rawVersions.values.any((value) => value is! String)) {
      throw const ContractError(
        'INVALID_DEPENDENCY',
        'Dependency versions must map extension IDs to minimum versions.',
      );
    }
    final dependencyVersions = <String, String>{};
    for (final entry in rawVersions.entries) {
      final id = entry.key;
      final minimum = entry.value as String;
      if (!_moduleId.hasMatch(id) ||
          id.length > 128 ||
          id == manifest.moduleId) {
        throw const ContractError(
            'INVALID_DEPENDENCY', 'Invalid dependency ID.');
      }
      semverParts(minimum);
      dependencyVersions[id] = minimum;
    }
    if (dependencyVersions.keys
            .toSet()
            .difference(manifest.dependencies.toSet())
            .isNotEmpty ||
        manifest.dependencies
            .toSet()
            .difference(dependencyVersions.keys.toSet())
            .isNotEmpty) {
      throw const ContractError(
        'INVALID_DEPENDENCY',
        'Every dependency needs one minimum compatible version.',
      );
    }

    final rawCatalog = requireMap(source['englishCatalog'], 'englishCatalog');
    final catalog = <String, String>{};
    for (final entry in rawCatalog.entries) {
      if (entry.value is! String ||
          !_messageKey.hasMatch(entry.key) ||
          !entry.key.startsWith(messageNamespace)) {
        throw const ContractError(
          'INVALID_ENGLISH_CATALOG',
          'English catalog entries must use namespaced keys and string labels.',
        );
      }
      catalog[entry.key] = entry.value as String;
    }
    final requiredLabels = <String>{manifest.displayNameKey};
    if (rawManifest.containsKey('descriptionKey')) {
      requiredLabels.add(requireString(rawManifest, 'descriptionKey'));
    }
    for (final raw in docTypeJson) {
      final type = DocTypeDefinition.fromJson(raw);
      requiredLabels.add(type.labelKey);
      requiredLabels.add(type.pageTitleKey);
      if (raw.containsKey('descriptionKey')) {
        final key = requireString(raw, 'descriptionKey');
        _requireNamespace(key, messageNamespace);
        requiredLabels.add(key);
      }
      for (final rawField in requireList(raw, 'fields')) {
        final fieldJson = requireMap(rawField, 'fields[]');
        final field = FieldDefinition.fromJson(fieldJson);
        _requireNamespace(field.labelKey, messageNamespace);
        requiredLabels.add(field.labelKey);
        if (fieldJson.containsKey('descriptionKey')) {
          final key = requireString(fieldJson, 'descriptionKey');
          _requireNamespace(key, messageNamespace);
          requiredLabels.add(key);
        }
        if (field.type == 'enum') {
          final labels = requireMap(fieldJson['enumLabels'], 'enumLabels');
          for (final rawLabel in labels.values) {
            final key = requireString(
              requireMap(rawLabel, 'enumLabels[]'),
              'labelKey',
            );
            _requireNamespace(key, messageNamespace);
            requiredLabels.add(key);
          }
        }
      }
    }
    if (requiredLabels.any((key) => !catalog.containsKey(key))) {
      throw const ContractError(
        'MISSING_ENGLISH_LABELS',
        'The English catalog must label the extension and every generated field.',
      );
    }

    return ExtensionBundle._(
      manifest: manifest,
      docTypes: List.unmodifiable(docTypes),
      dependencyVersions: Map.unmodifiable(dependencyVersions),
      englishCatalog: Map.unmodifiable(catalog),
      manifestJson: _freezeMap(rawManifest),
      docTypeJson: List.unmodifiable(docTypeJson),
    );
  }

  Map<String, dynamic> toJson() => {
        'manifest': manifestJson,
        'docTypes': docTypeJson,
        'dependencyVersions': dependencyVersions,
        'englishCatalog': englishCatalog,
      };
}

final RegExp _moduleId = RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$');
final RegExp _messageKey = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){2,}$');
final RegExp _docTypeName = RegExp(r'^[A-Z][A-Za-z0-9_]*$');
final RegExp _fieldName = RegExp(r'^[a-z][A-Za-z0-9_]*$');

String _moduleSlug(String moduleId) =>
    moduleId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

void _checkKeys(Map<String, dynamic> value, Set<String> allowed, String path) {
  final unknown = value.keys.toSet().difference(allowed);
  if (unknown.isNotEmpty) {
    throw ContractError(
      'UNSUPPORTED_METADATA',
      '$path contains unsupported keys: ${unknown.join(', ')}',
    );
  }
}

void _validateJsonTree(Object? root) {
  final stack = <(Object?, int)>[(root, 1)];
  final containers = HashSet<Object>.identity();
  var visited = 0;
  while (stack.isNotEmpty) {
    final (value, depth) = stack.removeLast();
    visited++;
    if (visited > 100000 || depth > 32) {
      throw const ContractError(
        'INVALID_EXTENSION_BUNDLE',
        'Extension metadata exceeds the supported structural limits.',
      );
    }
    if (value is Map) {
      if (!containers.add(value) || value.keys.any((key) => key is! String)) {
        throw const ContractError(
          'INVALID_EXTENSION_BUNDLE',
          'Extension metadata must be a finite JSON object tree.',
        );
      }
      for (final item in value.values) {
        stack.add((item, depth + 1));
      }
    } else if (value is List) {
      if (!containers.add(value)) {
        throw const ContractError(
          'INVALID_EXTENSION_BUNDLE',
          'Extension metadata must be a finite JSON object tree.',
        );
      }
      for (final item in value) {
        stack.add((item, depth + 1));
      }
    } else if (value != null &&
        value is! String &&
        value is! bool &&
        !(value is num && value.isFinite)) {
      throw const ContractError(
        'INVALID_EXTENSION_BUNDLE',
        'Extension metadata contains a non-JSON value.',
      );
    }
  }
}

Map<String, dynamic> _freezeMap(Map<String, dynamic> value) =>
    immutableJson(value) as Map<String, dynamic>;

void _requireNamespace(String key, String namespace) {
  if (!_messageKey.hasMatch(key) || !key.startsWith(namespace)) {
    throw const ContractError(
      'MESSAGE_NAMESPACE',
      'Extension messages must stay inside their own namespace.',
    );
  }
}
