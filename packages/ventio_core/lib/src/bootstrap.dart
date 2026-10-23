import 'dart:convert';
import 'dart:io';
import 'contracts.dart';
import 'host.dart';
import 'installation.dart';
import 'localization.dart';
import 'metadata.dart';
import 'modules.dart';

/// Fixture loader for the V1.2 proof only. This is not a module installation API.
Map<String, dynamic> loadJsonFile(String path) {
  return requireMap(jsonDecode(File(path).readAsStringSync()), path);
}

class MaintenancePrototype {
  final ModuleRegistry modules;
  final DocTypeRegistry docTypes;
  final InMemoryHost host;
  final EnglishCatalog english;

  const MaintenancePrototype(
      this.modules, this.docTypes, this.host, this.english);
}

MaintenancePrototype bootstrapMaintenancePrototype(String specRoot) {
  final modules = ModuleRegistry();
  final docTypes = DocTypeRegistry();
  final english = EnglishCatalog();
  english.registerCatalog(loadJsonFile('$specRoot/localization/en.core.json'));
  english
      .registerCatalog(loadJsonFile('$specRoot/localization/en.runtime.json'));
  modules.registerTrustedCapability(Capability.fromJson(
      loadJsonFile('$specRoot/examples/maintenance_capability.json')));
  DeclarativeModuleInstaller(
          modules: modules, docTypes: docTypes, english: english)
      .install(
    manifestJson: loadJsonFile('$specRoot/examples/maintenance_manifest.json'),
    docTypeJsons: [loadJsonFile('$specRoot/examples/maintenance_doctype.json')],
    englishCatalog:
        loadJsonFile('$specRoot/examples/localization/en.maintenance.json'),
  );
  final host = InMemoryHost(modules: modules, docTypes: docTypes);
  host.registerTrustedCreateBinding(const TrustedCommandBinding(
      'maintenance.create', 1, 'MaintenanceRequest'));
  return MaintenancePrototype(modules, docTypes, host, english);
}
