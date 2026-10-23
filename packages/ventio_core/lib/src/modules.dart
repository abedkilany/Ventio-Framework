import 'contracts.dart';
import 'metadata.dart';

class ModuleRegistry {
  final String platformApiVersion;
  final Map<String, ModuleManifest> _modules = {};
  final Map<String, Capability> _capabilities = {};

  ModuleRegistry({this.platformApiVersion = '0.1.0'}) {
    semverParts(platformApiVersion);
  }

  void registerTrustedCapability(Capability capability) {
    if (_capabilities.containsKey(capability.id)) {
      throw ContractError('DUPLICATE_CAPABILITY', capability.id);
    }
    // Register capabilities only through trusted host bootstrap code.
    if (capability.executor != 'host' ||
        capability.executionKind != 'trusted_builtin' ||
        capability.transactionMode != 'required') {
      throw const ContractError('UNSUPPORTED_CAPABILITY',
          'Only transactional trusted host capabilities are supported');
    }
    _capabilities[capability.id] = capability;
  }

  void validateInstall(
      ModuleManifest module, List<DocTypeDefinition> docTypes) {
    if (_modules.containsKey(module.moduleId)) {
      throw ContractError('DUPLICATE_MODULE', module.moduleId);
    }
    if (compareSemver(platformApiVersion, module.minPlatformApi) < 0) {
      throw ContractError('INCOMPATIBLE_PLATFORM', module.minPlatformApi);
    }
    for (final dependency in module.dependencies) {
      if (!_modules.containsKey(dependency)) {
        throw ContractError('MISSING_DEPENDENCY', dependency);
      }
      if (dependency == module.moduleId) {
        throw const ContractError('INVALID_DEPENDENCY', 'Self-dependency');
      }
    }
    for (final capabilityId in module.requiredCapabilities) {
      if (!_capabilities.containsKey(capabilityId)) {
        throw ContractError('MISSING_CAPABILITY', capabilityId);
      }
    }
    for (final command in module.commands) {
      final capability = _capabilities[command.capabilityId];
      if (capability == null ||
          !capability.requiredPermissions.contains(command.permission)) {
        throw ContractError('INVALID_COMMAND_CAPABILITY', command.type);
      }
      if (_modules.values.any((existing) => existing.commands.any((previous) =>
          previous.type == command.type &&
          previous.version == command.version))) {
        throw ContractError('DUPLICATE_COMMAND', command.type);
      }
    }
    for (final type in module.offlineCommands) {
      final command = module.commands.firstWhere((item) => item.type == type);
      if (_capabilities[command.capabilityId]?.offlineMode != 'provisional') {
        throw ContractError('OFFLINE_NOT_ALLOWED', type);
      }
    }
    final expected = module.docTypes.toSet();
    final actual = docTypes.map((d) => d.name).toSet();
    if (expected.length != docTypes.length ||
        expected.difference(actual).isNotEmpty ||
        actual.difference(expected).isNotEmpty ||
        docTypes.any((type) => type.moduleId != module.moduleId)) {
      throw const ContractError(
          'INVALID_MODULE', 'DocTypes do not match module manifest');
    }
  }

  void install(ModuleManifest module, List<DocTypeDefinition> docTypes) {
    validateInstall(module, docTypes);
    _modules[module.moduleId] = module;
  }

  ModuleManifest? getModule(String id) => _modules[id];
  Capability? getCapability(String id) => _capabilities[id];

  ModuleManifest? moduleForCommand(String type, int version) {
    for (final module in _modules.values) {
      if (module.commands
          .any((cmd) => cmd.type == type && cmd.version == version)) {
        return module;
      }
    }
    return null;
  }

  CommandDefinition? getCommand(String moduleId, String type, int version) {
    final module = _modules[moduleId];
    if (module == null) return null;
    for (final command in module.commands) {
      if (command.type == type && command.version == version) return command;
    }
    return null;
  }

  List<String> get installedIds => List.unmodifiable(_modules.keys);
}
