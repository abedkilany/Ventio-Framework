/// Version-zero wire contract readers matching the V1.2 JSON examples.
///
/// Validation is intentionally strict for the subset executed by this prototype.
/// Full JSON Schema validation remains a separate build-time responsibility.
import 'dart:convert';

class ContractError implements Exception {
  final String code;
  final String details;
  const ContractError(this.code, this.details);

  @override
  String toString() => '$code: $details';
}

Map<String, dynamic> requireMap(Object? value, String path) {
  if (value is! Map)
    throw ContractError('INVALID_CONTRACT', '$path must be an object');
  if (value.keys.any((key) => key is! String)) {
    throw ContractError('INVALID_CONTRACT', '$path must have string keys');
  }
  return Map<String, dynamic>.from(value);
}

String requireString(Map<String, dynamic> value, String name,
    {bool nonEmpty = true}) {
  final raw = value[name];
  if (raw is! String || (nonEmpty && raw.trim().isEmpty)) {
    throw ContractError('INVALID_CONTRACT', '$name must be a nonempty string');
  }
  return raw;
}

int requireInt(Map<String, dynamic> value, String name, {int min = 0}) {
  final raw = value[name];
  if (raw is! int || raw < min) {
    throw ContractError('INVALID_CONTRACT', '$name must be an integer >= $min');
  }
  return raw;
}

bool requireBool(Map<String, dynamic> value, String name) {
  final raw = value[name];
  if (raw is! bool)
    throw ContractError('INVALID_CONTRACT', '$name must be boolean');
  return raw;
}

List<dynamic> requireList(Map<String, dynamic> value, String name) {
  final raw = value[name];
  if (raw is! List)
    throw ContractError('INVALID_CONTRACT', '$name must be an array');
  return raw;
}

String? optionalString(Map<String, dynamic> value, String name) {
  final raw = value[name];
  if (raw == null) return null;
  if (raw is! String)
    throw ContractError('INVALID_CONTRACT', '$name must be a string');
  return raw;
}

List<String> strings(List<dynamic> raw, String path) {
  final result = <String>[];
  for (final entry in raw) {
    if (entry is! String || entry.isEmpty) {
      throw ContractError(
          'INVALID_CONTRACT', '$path must contain nonempty strings');
    }
    result.add(entry);
  }
  if (result.toSet().length != result.length) {
    throw ContractError('INVALID_CONTRACT', '$path contains duplicate entries');
  }
  return List.unmodifiable(result);
}

final RegExp _semverPattern =
    RegExp(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$');

List<int> semverParts(String version) {
  if (!_semverPattern.hasMatch(version)) {
    throw ContractError(
        'INVALID_VERSION', '$version is not a supported version');
  }
  return version.split('.').map(int.parse).toList();
}

int compareSemver(String a, String b) {
  final aa = semverParts(a);
  final bb = semverParts(b);
  for (var i = 0; i < 3; i++) {
    if (aa[i] != bb[i]) return aa[i].compareTo(bb[i]);
  }
  return 0;
}

/// Deterministic equality for JSON objects regardless of map insertion order.
String canonicalJson(Object? value) {
  if (value is Map) {
    final map = requireMap(value, 'canonicalJson');
    final keys = map.keys.toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${canonicalJson(map[k])}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map(canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}

/// Detached, recursively immutable JSON for command fingerprints and receipts.
/// Top-level Map.unmodifiable alone leaves nested maps/lists mutable.
Object? immutableJson(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable(requireMap(value, 'json')
        .map((key, item) => MapEntry(key, immutableJson(item))));
  }
  if (value is List)
    return List<dynamic>.unmodifiable(value.map(immutableJson));
  if (value == null ||
      value is String ||
      value is bool ||
      (value is num && value.isFinite)) return value;
  throw const ContractError('INVALID_CONTRACT', 'Value is not finite JSON');
}

class CommandDefinition {
  final String type;
  final int version;
  final String capabilityId;
  final String permission;
  const CommandDefinition(
      this.type, this.version, this.capabilityId, this.permission);

  factory CommandDefinition.fromJson(Map<String, dynamic> json) {
    return CommandDefinition(
        requireString(json, 'type'),
        requireInt(json, 'version', min: 1),
        requireString(json, 'capabilityId'),
        requireString(json, 'permission'));
  }
}

class ModuleManifest {
  final String moduleId;
  final String version;
  final String minPlatformApi;
  final String displayName;
  final String displayNameKey;
  final String englishCatalog;
  final List<String> dependencies;
  final List<String> docTypes;
  final List<CommandDefinition> commands;
  final List<String> requiredCapabilities;
  final bool offlineEnabled;
  final List<String> offlineCommands;

  const ModuleManifest(
      {required this.moduleId,
      required this.version,
      required this.minPlatformApi,
      required this.displayName,
      required this.displayNameKey,
      required this.englishCatalog,
      required this.dependencies,
      required this.docTypes,
      required this.commands,
      required this.requiredCapabilities,
      required this.offlineEnabled,
      required this.offlineCommands});

  factory ModuleManifest.fromJson(Map<String, dynamic> json) {
    if (requireInt(json, 'manifestVersion') != 0) {
      throw const ContractError(
          'UNSUPPORTED_VERSION', 'Only manifestVersion 0 is supported');
    }
    final version = requireString(json, 'version');
    final minApi = requireString(json, 'minPlatformApi');
    semverParts(version);
    semverParts(minApi);
    final offline = requireMap(json['offline'], 'offline');
    final commands = requireList(json, 'commands')
        .map((item) =>
            CommandDefinition.fromJson(requireMap(item, 'commands[]')))
        .toList(growable: false);
    final types = commands
        .map((command) => '${command.type}@${command.version}')
        .toList();
    if (types.toSet().length != types.length) {
      throw const ContractError(
          'INVALID_CONTRACT', 'Duplicate command registration');
    }
    final required = strings(
        requireList(json, 'requiredCapabilities'), 'requiredCapabilities');
    for (final command in commands) {
      if (!required.contains(command.capabilityId)) {
        throw ContractError('MISSING_CAPABILITY',
            '${command.type} references undeclared capability');
      }
    }
    final allowed = strings(
        requireList(offline, 'allowedCommands'), 'offline.allowedCommands');
    if (!requireBool(offline, 'enabled') && allowed.isNotEmpty) {
      throw const ContractError('INVALID_CONTRACT',
          'Offline commands declared while offline disabled');
    }
    for (final command in allowed) {
      if (!commands.any((item) => item.type == command)) {
        throw ContractError(
            'INVALID_CONTRACT', 'Offline command $command is not declared');
      }
    }
    return ModuleManifest(
      moduleId: requireString(json, 'moduleId'),
      version: version,
      minPlatformApi: minApi,
      displayName: requireString(json, 'displayName'),
      displayNameKey: requireString(json, 'displayNameKey'),
      englishCatalog: requireString(json, 'englishCatalog'),
      dependencies: strings(
          json['dependencies'] == null ? [] : requireList(json, 'dependencies'),
          'dependencies'),
      docTypes: strings(requireList(json, 'docTypes'), 'docTypes'),
      commands: List.unmodifiable(commands),
      requiredCapabilities: required,
      offlineEnabled: requireBool(offline, 'enabled'),
      offlineCommands: allowed,
    );
  }
}

class Capability {
  final String id;
  final String provider;
  final String executor;
  final String executionKind;
  final String transactionMode;
  final String offlineMode;
  final List<String> requiredPermissions;
  final List<String> effects;

  const Capability(
      {required this.id,
      required this.provider,
      required this.executor,
      required this.executionKind,
      required this.transactionMode,
      required this.offlineMode,
      required this.requiredPermissions,
      required this.effects});

  factory Capability.fromJson(Map<String, dynamic> json) {
    final executor = requireString(json, 'executor');
    final executionKind = requireString(json, 'executionKind');
    final transactionMode = requireString(json, 'transactionMode');
    final offlineMode = requireString(json, 'offlineMode');
    if (!['host', 'local_preview', 'both'].contains(executor) ||
        !['trusted_builtin', 'trusted_deployed_module', 'bounded_rules']
            .contains(executionKind) ||
        !['required', 'read_only', 'none'].contains(transactionMode) ||
        !['not_allowed', 'provisional', 'local_only'].contains(offlineMode)) {
      throw const ContractError(
          'INVALID_CAPABILITY', 'Unsupported capability properties');
    }
    if (requireBool(json, 'deterministic') != true) {
      throw const ContractError('INVALID_CAPABILITY',
          'Prototype only supports deterministic capabilities');
    }
    // Validate references even when the prototype does not execute their schemas yet.
    requireString(json, 'inputSchemaRef');
    requireString(json, 'outputSchemaRef');
    final permissions = strings(
        requireList(json, 'requiredPermissions'), 'requiredPermissions');
    if (permissions.isEmpty)
      throw const ContractError(
          'INVALID_CAPABILITY', 'Permission list must not be empty');
    final effects = strings(requireList(json, 'effects'), 'effects');
    if (effects.any((effect) => ![
          'records',
          'inventory',
          'ledger',
          'outbox',
          'audit'
        ].contains(effect))) {
      throw const ContractError('INVALID_CAPABILITY', 'Unsupported effect');
    }
    return Capability(
      id: requireString(json, 'id'),
      provider: requireString(json, 'provider'),
      executor: executor,
      executionKind: executionKind,
      transactionMode: transactionMode,
      offlineMode: offlineMode,
      requiredPermissions: permissions,
      effects: effects,
    );
  }
}

final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$');

class CommandEnvelope {
  final String commandId;
  final String type;
  final int typeVersion;
  final String tenantId;
  final String companyId;
  final String branchId;
  final String aggregateId;
  final int? expectedRevision;
  final List<String> dependsOn;
  final Map<String, dynamic> payload;
  final String deviceId;
  final String actorId;
  final String moduleVersion;
  final int docTypeVersion;
  final Map<String, dynamic> original;

  const CommandEnvelope._(
      {required this.commandId,
      required this.type,
      required this.typeVersion,
      required this.tenantId,
      required this.companyId,
      required this.branchId,
      required this.aggregateId,
      required this.expectedRevision,
      required this.dependsOn,
      required this.payload,
      required this.deviceId,
      required this.actorId,
      required this.moduleVersion,
      required this.docTypeVersion,
      required this.original});

  factory CommandEnvelope.fromJson(Map<String, dynamic> json) {
    if (requireInt(json, 'protocolVersion') != 0) {
      throw const ContractError(
          'UNSUPPORTED_VERSION', 'Only protocolVersion 0 is supported');
    }
    final commandId = requireString(json, 'commandId');
    if (!_uuid.hasMatch(commandId))
      throw const ContractError(
          'INVALID_COMMAND_ID', 'commandId must be a UUID');
    final ctx = requireMap(json['clientContext'], 'clientContext');
    final moduleVersion = requireString(ctx, 'moduleVersion');
    semverParts(moduleVersion);
    final dependent = strings(
        json['dependsOn'] == null ? [] : requireList(json, 'dependsOn'),
        'dependsOn');
    for (final id in dependent) {
      if (!_uuid.hasMatch(id))
        throw const ContractError(
            'INVALID_CONTRACT', 'dependsOn must contain UUIDs');
    }
    final rawRev = json['expectedRevision'];
    if (rawRev != null && (rawRev is! int || rawRev < 0)) {
      throw const ContractError('INVALID_CONTRACT',
          'expectedRevision must be null or a nonnegative integer');
    }
    return CommandEnvelope._(
      commandId: commandId,
      type: requireString(json, 'type'),
      typeVersion: requireInt(json, 'typeVersion', min: 1),
      tenantId: requireString(json, 'tenantId'),
      companyId: requireString(json, 'companyId'),
      branchId: requireString(json, 'branchId'),
      aggregateId: requireString(json, 'aggregateId'),
      expectedRevision: rawRev as int?,
      dependsOn: dependent,
      payload: immutableJson(requireMap(json['payload'], 'payload'))
          as Map<String, dynamic>,
      deviceId: requireString(ctx, 'deviceId'),
      actorId: requireString(ctx, 'actorId'),
      moduleVersion: moduleVersion,
      docTypeVersion: requireInt(ctx, 'docTypeVersion', min: 1),
      original: immutableJson(json) as Map<String, dynamic>,
    );
  }
}

class CommandReceipt {
  final String commandId;
  final String serverTimestamp;
  final String status;
  final String? reasonCode;
  final String? messageKey;
  final int? hostRevision;
  final String? scopeCursor;
  final int? currentRevision;
  final Map<String, dynamic>? output;

  CommandReceipt(
      {required this.commandId,
      required this.status,
      this.reasonCode,
      this.messageKey,
      this.hostRevision,
      this.scopeCursor,
      this.currentRevision,
      Map<String, dynamic>? output})
      : output = output == null
            ? null
            : immutableJson(output) as Map<String, dynamic>,
        serverTimestamp = DateTime.now().toUtc().toIso8601String();

  bool get accepted => status == 'ACCEPTED';

  Map<String, dynamic> toJson() => {
        'protocolVersion': 0,
        'commandId': commandId,
        'status': status,
        'serverTimestamp': serverTimestamp,
        'retryable': status == 'RETRY_LATER',
        if (hostRevision != null) 'hostRevision': hostRevision,
        if (scopeCursor != null) 'scopeCursor': scopeCursor,
        if (reasonCode != null) 'reasonCode': reasonCode,
        if (messageKey != null) 'messageKey': messageKey,
        if (currentRevision != null) 'currentRevision': currentRevision,
        if (output != null) 'output': output,
      };
}
