import 'contracts.dart';
import 'metadata.dart';
import 'modules.dart';
import 'localization.dart';

/// Installs validated declarative metadata into the single-isolate prototype.
/// Only capabilities previously approved by trusted Host code are accepted.
/// No external Dart source is loaded. This is not durable installation.
class DeclarativeModuleInstaller {
  final ModuleRegistry modules;
  final DocTypeRegistry docTypes;
  final EnglishCatalog english;

  const DeclarativeModuleInstaller({
    required this.modules,
    required this.docTypes,
    required this.english,
  });

  void install({
    required Map<String, dynamic> manifestJson,
    required List<Map<String, dynamic>> docTypeJsons,
    required Map<String, dynamic> englishCatalog,
  }) {
    final manifest = ModuleManifest.fromJson(manifestJson);
    final definitions = docTypeJsons.map(DocTypeDefinition.fromJson).toList();

    // All checks happen before any registry is mutated. Within this synchronous
    // single-isolate process the remaining writes cannot interleave.
    modules.validateInstall(manifest, definitions);
    docTypes.validateRegistrations(definitions);
    english.validateCatalog(englishCatalog);

    final requiredLabels = <String>{manifest.displayNameKey};
    void addDescription(Map<String, dynamic> raw) {
      if (raw.containsKey('descriptionKey')) {
        requiredLabels.add(requireString(raw, 'descriptionKey'));
      }
    }

    addDescription(manifestJson);
    for (final document in docTypeJsons) {
      requiredLabels.add(requireString(document, 'labelKey'));
      addDescription(document);
      for (final field in requireList(document, 'fields')) {
        final item = requireMap(field, 'fields[]');
        requiredLabels.add(requireString(item, 'labelKey'));
        addDescription(item);
        if (item.containsKey('enumLabels')) {
          final labels = requireMap(item['enumLabels'], 'enumLabels');
          for (final option in labels.values) {
            requiredLabels.add(
                requireString(requireMap(option, 'enumLabels[]'), 'labelKey'));
          }
        }
      }
    }
    final missing = requiredLabels
        .where(
            (key) => !english.hasKey(key) && !englishCatalog.containsKey(key))
        .toList();
    if (missing.isNotEmpty) {
      throw ContractError('MISSING_ENGLISH_LABELS', missing.join(', '));
    }

    modules.install(manifest, definitions);
    docTypes.registerAll(definitions);
    english.registerCatalog(englishCatalog);
  }
}
