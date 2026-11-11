import 'contracts.dart';

/// Wire contract for record writes handled by Ventio's trusted generic engine.
/// Extension metadata chooses the DocType and declared permission; it never
/// supplies an executable command handler.
class ExtensionRecordCommand {
  ExtensionRecordCommand._(
      this.envelope, this.moduleId, this.docType, this.values);

  static final _moduleIdPattern =
      RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$');
  static final _docTypePattern = RegExp(r'^[A-Z][A-Za-z0-9_]*$');

  static const createType = 'extension.record.create';
  static const updateType = 'extension.record.update';
  static const deleteType = 'extension.record.delete';
  static const commandVersion = 1;

  final CommandEnvelope envelope;
  final String moduleId;
  final String docType;
  final Map<String, dynamic> values;

  String get operation => switch (envelope.type) {
        createType => 'create',
        updateType => 'update',
        deleteType => 'delete',
        _ => throw const ContractError(
            'UNKNOWN_COMMAND', 'Unknown record command.'),
      };

  factory ExtensionRecordCommand.create({
    required String commandId,
    required String tenantId,
    required String companyId,
    required String branchId,
    required String recordId,
    required String actorId,
    required String deviceId,
    required String moduleId,
    required String moduleVersion,
    required String docType,
    required int schemaVersion,
    required Map<String, dynamic> values,
    List<String> dependsOn = const [],
  }) =>
      _build(
        type: createType,
        commandId: commandId,
        tenantId: tenantId,
        companyId: companyId,
        branchId: branchId,
        recordId: recordId,
        actorId: actorId,
        deviceId: deviceId,
        moduleId: moduleId,
        moduleVersion: moduleVersion,
        docType: docType,
        schemaVersion: schemaVersion,
        values: values,
        dependsOn: dependsOn,
      );

  factory ExtensionRecordCommand.update({
    required String commandId,
    required String tenantId,
    required String companyId,
    required String branchId,
    required String recordId,
    required int expectedRevision,
    required String actorId,
    required String deviceId,
    required String moduleId,
    required String moduleVersion,
    required String docType,
    required int schemaVersion,
    required Map<String, dynamic> values,
    List<String> dependsOn = const [],
  }) =>
      _build(
        type: updateType,
        commandId: commandId,
        tenantId: tenantId,
        companyId: companyId,
        branchId: branchId,
        recordId: recordId,
        expectedRevision: expectedRevision,
        actorId: actorId,
        deviceId: deviceId,
        moduleId: moduleId,
        moduleVersion: moduleVersion,
        docType: docType,
        schemaVersion: schemaVersion,
        values: values,
        dependsOn: dependsOn,
      );

  factory ExtensionRecordCommand.delete({
    required String commandId,
    required String tenantId,
    required String companyId,
    required String branchId,
    required String recordId,
    required int expectedRevision,
    required String actorId,
    required String deviceId,
    required String moduleId,
    required String moduleVersion,
    required String docType,
    required int schemaVersion,
    List<String> dependsOn = const [],
  }) =>
      _build(
        type: deleteType,
        commandId: commandId,
        tenantId: tenantId,
        companyId: companyId,
        branchId: branchId,
        recordId: recordId,
        expectedRevision: expectedRevision,
        actorId: actorId,
        deviceId: deviceId,
        moduleId: moduleId,
        moduleVersion: moduleVersion,
        docType: docType,
        schemaVersion: schemaVersion,
        values: const {},
        dependsOn: dependsOn,
      );

  factory ExtensionRecordCommand.fromEnvelope(CommandEnvelope envelope) {
    if (envelope.typeVersion != commandVersion) {
      throw const ContractError(
        'UNSUPPORTED_VERSION',
        'Unsupported generic extension record command version.',
      );
    }
    final operation = switch (envelope.type) {
      createType => 'create',
      updateType => 'update',
      deleteType => 'delete',
      _ => throw const ContractError(
          'UNKNOWN_COMMAND',
          'Unsupported generic extension record command.',
        ),
    };
    final expectedRevision = envelope.expectedRevision;
    if ((operation == 'create' && expectedRevision != null) ||
        (operation != 'create' &&
            (expectedRevision == null || expectedRevision < 1))) {
      throw const ContractError(
        'INVALID_CONTRACT',
        'Create commands have no expected revision; updates and deletes require a positive revision.',
      );
    }
    final payload = envelope.payload;
    if (payload.keys.toSet().difference(const {
          'moduleId',
          'docType',
          'values',
        }).isNotEmpty ||
        payload.keys.length != 3) {
      throw const ContractError(
        'INVALID_CONTRACT',
        'Extension record commands require moduleId, docType and values only.',
      );
    }
    final moduleId = requireString(payload, 'moduleId');
    final docType = requireString(payload, 'docType');
    final values = requireMap(payload['values'], 'values');
    if (operation == 'delete' && values.isNotEmpty) {
      throw const ContractError(
        'INVALID_CONTRACT',
        'Delete commands cannot include business field values.',
      );
    }
    if (moduleId.length > 128 ||
        !ExtensionRecordCommand._moduleIdPattern.hasMatch(moduleId)) {
      throw const ContractError('INVALID_MODULE_ID', 'Invalid extension ID.');
    }
    if (docType.length > 80 ||
        !ExtensionRecordCommand._docTypePattern.hasMatch(docType)) {
      throw const ContractError('INVALID_DOCTYPE', 'Invalid DocType name.');
    }
    return ExtensionRecordCommand._(
      envelope,
      moduleId,
      docType,
      values,
    );
  }

  static ExtensionRecordCommand _build({
    required String type,
    required String commandId,
    required String tenantId,
    required String companyId,
    required String branchId,
    required String recordId,
    int? expectedRevision,
    required String actorId,
    required String deviceId,
    required String moduleId,
    required String moduleVersion,
    required String docType,
    required int schemaVersion,
    required Map<String, dynamic> values,
    required List<String> dependsOn,
  }) {
    final envelope = CommandEnvelope.fromJson({
      'protocolVersion': 0,
      'commandId': commandId,
      'type': type,
      'typeVersion': commandVersion,
      'tenantId': tenantId,
      'companyId': companyId,
      'branchId': branchId,
      'aggregateId': recordId,
      'expectedRevision': expectedRevision,
      'dependsOn': dependsOn,
      'payload': {'moduleId': moduleId, 'docType': docType, 'values': values},
      'clientContext': {
        'deviceId': deviceId,
        'actorId': actorId,
        'moduleVersion': moduleVersion,
        'docTypeVersion': schemaVersion,
      },
    });
    return ExtensionRecordCommand.fromEnvelope(envelope);
  }
}

/// Wire command for a package-declared business operation. The payload carries
/// only bounded data; the Host resolves the approved declaration and runs its
/// Core-owned effect implementation.
class ExtensionBusinessOperationCommand {
  const ExtensionBusinessOperationCommand._(this.envelope, this.moduleId,
      this.docType, this.operationId, this.operationVersion, this.inputs);

  static const commandType = 'extension.operation.execute';
  static const commandVersion = 1;

  final CommandEnvelope envelope;
  final String moduleId;
  final String docType;
  final String operationId;
  final int operationVersion;
  final Map<String, dynamic> inputs;

  factory ExtensionBusinessOperationCommand.execute({
    required String commandId,
    required String tenantId,
    required String companyId,
    required String branchId,
    required String recordId,
    required int expectedRevision,
    required String actorId,
    required String deviceId,
    required String moduleId,
    required String moduleVersion,
    required String docType,
    required int schemaVersion,
    required String operationId,
    required int operationVersion,
    required Map<String, dynamic> inputs,
    List<String> dependsOn = const [],
  }) {
    final envelope = CommandEnvelope.fromJson({
      'protocolVersion': 0,
      'commandId': commandId,
      'type': commandType,
      'typeVersion': commandVersion,
      'tenantId': tenantId,
      'companyId': companyId,
      'branchId': branchId,
      'aggregateId': recordId,
      'expectedRevision': expectedRevision,
      'dependsOn': dependsOn,
      'payload': {
        'moduleId': moduleId,
        'docType': docType,
        'operationId': operationId,
        'operationVersion': operationVersion,
        'inputs': inputs,
      },
      'clientContext': {
        'deviceId': deviceId,
        'actorId': actorId,
        'moduleVersion': moduleVersion,
        'docTypeVersion': schemaVersion,
      },
    });
    return ExtensionBusinessOperationCommand.fromEnvelope(envelope);
  }

  factory ExtensionBusinessOperationCommand.fromEnvelope(
      CommandEnvelope envelope) {
    if (envelope.type != commandType ||
        envelope.typeVersion != commandVersion ||
        envelope.expectedRevision == null ||
        envelope.expectedRevision! < 1) {
      throw const ContractError(
          'INVALID_COMMAND', 'Invalid business operation command.');
    }
    final payload = envelope.payload;
    if (payload.keys.toSet().difference(const {
          'moduleId',
          'docType',
          'operationId',
          'operationVersion',
          'inputs',
        }).isNotEmpty ||
        payload.length != 5) {
      throw const ContractError(
          'INVALID_CONTRACT', 'Invalid business operation command payload.');
    }
    final moduleId = requireString(payload, 'moduleId');
    final docType = requireString(payload, 'docType');
    final operationId = requireString(payload, 'operationId');
    final operationVersion = requireInt(payload, 'operationVersion', min: 1);
    final inputs = requireMap(payload['inputs'], 'inputs');
    if (moduleId.length > 128 ||
        !ExtensionRecordCommand._moduleIdPattern.hasMatch(moduleId)) {
      throw const ContractError('INVALID_MODULE_ID', 'Invalid extension ID.');
    }
    if (docType.length > 80 ||
        !ExtensionRecordCommand._docTypePattern.hasMatch(docType)) {
      throw const ContractError('INVALID_DOCTYPE', 'Invalid DocType name.');
    }
    if (operationId.length > 128 ||
        !RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$').hasMatch(operationId) ||
        operationVersion > 255 ||
        inputs.length > 32 ||
        inputs.entries.any((entry) =>
            !RegExp(r'^[a-z][A-Za-z0-9_]{0,79}$').hasMatch(entry.key) ||
            entry.value is Map ||
            entry.value is List ||
            (entry.value is num && !(entry.value as num).isFinite))) {
      throw const ContractError(
          'INVALID_CONTRACT', 'Invalid business operation inputs.');
    }
    return ExtensionBusinessOperationCommand._(
      envelope,
      moduleId,
      docType,
      operationId,
      operationVersion,
      Map.unmodifiable(inputs),
    );
  }
}
