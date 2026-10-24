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
  static const commandVersion = 1;

  final CommandEnvelope envelope;
  final String moduleId;
  final String docType;
  final Map<String, dynamic> values;

  String get operation => envelope.type == createType ? 'create' : 'update';

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

  factory ExtensionRecordCommand.fromEnvelope(CommandEnvelope envelope) {
    final operation = switch (envelope.type) {
      createType => 'create',
      updateType => 'update',
      _ => throw const ContractError(
          'UNKNOWN_COMMAND',
          'Unsupported generic extension record command.',
        ),
    };
    final expectedRevision = envelope.expectedRevision;
    if ((operation == 'create' && expectedRevision != null) ||
        (operation == 'update' &&
            (expectedRevision == null || expectedRevision < 1))) {
      throw const ContractError(
        'INVALID_CONTRACT',
        'Create commands have no expected revision; updates require a positive revision.',
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
    if (moduleId.length > 128 || !_moduleIdPattern.hasMatch(moduleId)) {
      throw const ContractError('INVALID_MODULE_ID', 'Invalid extension ID.');
    }
    if (docType.length > 80 || !_docTypePattern.hasMatch(docType)) {
      throw const ContractError('INVALID_DOCTYPE', 'Invalid DocType name.');
    }
    return ExtensionRecordCommand._(
      envelope,
      moduleId,
      docType,
      requireMap(payload['values'], 'values'),
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
