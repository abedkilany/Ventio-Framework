import 'dart:convert';
import 'contracts.dart';
import 'metadata.dart';
import 'modules.dart';
import 'permissions.dart';

/// A trusted Host bootstrap explicitly binds a declarative command to a
/// vetted capability and a specific operational DocType.
/// No downloaded manifest may register executable Dart handlers.
class TrustedCommandBinding {
  final String commandType;
  final int commandVersion;
  final String docTypeName;

  const TrustedCommandBinding(
      this.commandType, this.commandVersion, this.docTypeName);
}

/// Shared binding contract for the in-memory proof and durable SQL engine.
/// Each engine retains its own execution/transaction implementation.
DocTypeDefinition validateTrustedCreateBinding(ModuleRegistry modules,
    DocTypeRegistry docTypes, TrustedCommandBinding binding) {
  final module =
      modules.moduleForCommand(binding.commandType, binding.commandVersion);
  final docType = docTypes.get(binding.docTypeName);
  final declaration = module == null
      ? null
      : modules.getCommand(
          module.moduleId, binding.commandType, binding.commandVersion);
  final capability = declaration == null
      ? null
      : modules.getCapability(declaration.capabilityId);
  if (module == null ||
      docType == null ||
      declaration == null ||
      capability == null ||
      !module.docTypes.contains(docType.name) ||
      docType.moduleId != module.moduleId ||
      docType.kind != 'operational' ||
      capability.executor != 'host' ||
      capability.executionKind != 'trusted_builtin' ||
      capability.transactionMode != 'required' ||
      !capability.effects.toSet().containsAll({'records', 'audit', 'outbox'}) ||
      !capability.requiredPermissions.contains(declaration.permission) ||
      docType.permissions['create'] != declaration.permission ||
      docType.fields.any(
        (field) => field.type == 'decimal' && field.precision == null,
      )) {
    throw const ContractError('INVALID_BINDING',
        'Trusted binding requires an installed operational DocType and transactional create capability');
  }
  return docType;
}

class StoredRecord {
  final String id;
  final String tenantId;
  final String companyId;
  final String branchId;
  final String docType;
  final int revision;
  final Map<String, dynamic> _data;
  Map<String, dynamic> get data =>
      jsonDecode(jsonEncode(_data)) as Map<String, dynamic>;

  StoredRecord(
      {required this.id,
      required this.tenantId,
      required this.companyId,
      required this.branchId,
      required this.docType,
      required this.revision,
      required Map<String, dynamic> data})
      : _data = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
}

class _JournalEntry {
  final String fingerprint;
  final CommandReceipt receipt;
  final String companyId;
  final String branchId;
  const _JournalEntry(
      this.fingerprint, this.receipt, this.companyId, this.branchId);
}

/// One immutable state root permits a single-swap commit in this isolate.
/// Durability still requires a real database transaction in the future Host.
class _HostState {
  final Map<String, StoredRecord> records;
  final Map<String, _JournalEntry> journal;
  final List<Map<String, dynamic>> audit;
  final List<Map<String, dynamic>> outbox;
  final int cursor;

  const _HostState(
      {required this.records,
      required this.journal,
      required this.audit,
      required this.outbox,
      required this.cursor});

  factory _HostState.empty() => const _HostState(
      records: {}, journal: {}, audit: [], outbox: [], cursor: 0);
}

/// Single-process, in-memory Host prototype.
///
/// Security decisions are made from [Principal], created by a trusted Host,
/// not from client supplied claims. The in-memory journal is NOT durable and
/// is NOT evidence of database atomicity, horizontal scale, or crash recovery.
class InMemoryHost {
  final ModuleRegistry modules;
  final DocTypeRegistry docTypes;
  final Map<String, TrustedCommandBinding> _bindings = {};
  _HostState _state = _HostState.empty();

  InMemoryHost({required this.modules, required this.docTypes});

  static String _bindingKey(String type, int version) => '$type@$version';

  void registerTrustedCreateBinding(TrustedCommandBinding binding) {
    validateTrustedCreateBinding(modules, docTypes, binding);
    final key = _bindingKey(binding.commandType, binding.commandVersion);
    if (_bindings.containsKey(key))
      throw ContractError('DUPLICATE_BINDING', key);
    _bindings[key] = binding;
  }

  CommandReceipt execute(
      CommandEnvelope command, Principal authenticatedPrincipal) {
    CommandReceipt failure(String status, String code, {int? revision}) =>
        CommandReceipt(
          commandId: command.commandId,
          status: status,
          reasonCode: code,
          messageKey: 'core.error.${_snakeCase(code)}',
          currentRevision: revision,
        );

    // Authenticate scope BEFORE responding from the idempotency journal; a
    // commandId must not become an information leak across security domains.
    if (!authenticatedPrincipal.withinScope(
        tenantId: command.tenantId,
        companyId: command.companyId,
        branchId: command.branchId,
        actorId: command.actorId,
        deviceId: command.deviceId)) {
      return failure('REJECTED', 'SCOPE_DENIED');
    }

    final module = modules.moduleForCommand(command.type, command.typeVersion);
    final binding = _bindings[_bindingKey(command.type, command.typeVersion)];
    if (module == null || binding == null)
      return failure('REJECTED', 'UNKNOWN_COMMAND');
    final declaration =
        modules.getCommand(module.moduleId, command.type, command.typeVersion)!;
    final capability = modules.getCapability(declaration.capabilityId);
    final docType = docTypes.get(binding.docTypeName)!;
    // Re-check authorization on every request, including idempotent retries.
    if (!authenticatedPrincipal.allowsInScope(
          declaration.permission,
          command.companyId,
          command.branchId,
        ) ||
        capability == null ||
        capability.requiredPermissions.any(
          (permission) => !authenticatedPrincipal.allowsInScope(
            permission,
            command.companyId,
            command.branchId,
          ),
        )) {
      return failure('REJECTED', 'PERMISSION_DENIED');
    }
    final journalKey = '${command.tenantId}\u0000${command.commandId}';
    final fingerprint = canonicalJson(command.original);
    final past = _state.journal[journalKey];
    if (past != null) {
      return past.fingerprint == fingerprint
          ? past.receipt
          : failure('REJECTED', 'COMMAND_ID_REUSED');
    }

    if (command.moduleVersion != module.version ||
        command.docTypeVersion != docType.schemaVersion) {
      return failure('REJECTED', 'UPGRADE_REQUIRED');
    }
    if (command.dependsOn.any((id) {
      final parent = _state.journal['${command.tenantId}\u0000$id'];
      return parent == null ||
          !parent.receipt.accepted ||
          parent.companyId != command.companyId ||
          parent.branchId != command.branchId;
    })) {
      return failure('RETRY_LATER', 'DEPENDENCY_PENDING');
    }
    if (command.expectedRevision != null) {
      return failure('CONFLICT', 'EXPECTED_REVISION_MUST_BE_NULL', revision: 0);
    }
    final valuesForStorage = Map<String, dynamic>.of(command.payload);
    for (final field in docType.fields) {
      final requiredPermission = field.writePermission;
      if (requiredPermission == null ||
          authenticatedPrincipal.allowsInScope(
            requiredPermission,
            command.companyId,
            command.branchId,
          ) ||
          !valuesForStorage.containsKey(field.name)) {
        continue;
      }
      if (valuesForStorage[field.name] != null) {
        return failure('REJECTED', 'PERMISSION_DENIED');
      }
      valuesForStorage.remove(field.name);
    }
    if (docType.fields.any(
      (field) =>
          field.readOnly &&
          field.calculation == null &&
          valuesForStorage.containsKey(field.name) &&
          valuesForStorage[field.name] != field.defaultValue,
    )) {
      return failure('REJECTED', 'READ_ONLY_FIELD');
    }
    late final Map<String, dynamic> normalizedValues;
    try {
      normalizedValues = docType.calculateValues(
        valuesForStorage,
        verifyCalculatedFields: valuesForStorage.keys.toSet(),
      );
    } on ContractError catch (error) {
      return failure('REJECTED', error.code);
    }
    final issues = docType.validatePayload(normalizedValues);
    if (issues.isNotEmpty) {
      return failure('REJECTED', 'INVALID_PAYLOAD');
    }
    for (final reference in docType.referencesIn(normalizedValues)) {
      final targetKey = '${command.tenantId}\u0000${command.companyId}\u0000'
          '${command.branchId}\u0000${module.moduleId}\u0000'
          '${reference.targetDocType}\u0000${reference.recordId}';
      if (!_state.records.containsKey(targetKey)) {
        return failure('REJECTED', 'INVALID_REFERENCE');
      }
    }

    final recordKey =
        '${command.tenantId}\u0000${command.companyId}\u0000${command.branchId}\u0000${module.moduleId}\u0000${docType.name}\u0000${command.aggregateId}';
    final existing = _state.records[recordKey];
    if (existing != null) {
      return failure('CONFLICT', 'RECORD_ALREADY_EXISTS',
          revision: existing.revision);
    }

    // Prepare all state changes before publishing one new state root.
    // This is isolate-local atomicity, NOT crash-safe database atomicity.
    final nextCursor = _state.cursor + 1;
    final record = StoredRecord(
        id: command.aggregateId,
        tenantId: command.tenantId,
        companyId: command.companyId,
        branchId: command.branchId,
        docType: docType.name,
        revision: 1,
        data: normalizedValues);
    final receipt = CommandReceipt(
        commandId: command.commandId,
        status: 'ACCEPTED',
        hostRevision: 1,
        scopeCursor: 'prototype-cursor-$nextCursor',
        output: {'serverRecordId': record.id});
    final audit = <String, dynamic>{
      'tenantId': command.tenantId,
      'companyId': command.companyId,
      'branchId': command.branchId,
      'actorId': command.actorId,
      'commandId': command.commandId,
      'type': command.type,
      'aggregateId': command.aggregateId,
      'cursor': nextCursor,
    };
    final event = <String, dynamic>{
      'tenantId': command.tenantId,
      'companyId': command.companyId,
      'branchId': command.branchId,
      'type': '${docType.name}.created',
      'aggregateId': command.aggregateId,
      'cursor': nextCursor,
    };
    _state = _HostState(
      records: Map.unmodifiable({..._state.records, recordKey: record}),
      audit: List.unmodifiable(
          [..._state.audit, Map<String, dynamic>.unmodifiable(audit)]),
      outbox: List.unmodifiable(
          [..._state.outbox, Map<String, dynamic>.unmodifiable(event)]),
      journal: Map.unmodifiable({
        ..._state.journal,
        journalKey: _JournalEntry(
            fingerprint, receipt, command.companyId, command.branchId)
      }),
      cursor: nextCursor,
    );
    return receipt;
  }

  StoredRecord? readRecord(
      String docType, String aggregateId, Principal principal,
      {required String companyId, required String branchId}) {
    if (!principal.hasScope(companyId, branchId)) return null;
    final type = docTypes.get(docType);
    if (type == null ||
        !principal.allowsInScope(
          type.permissions['read'] ?? '',
          companyId,
          branchId,
        )) return null;
    final record = _state.records[
        '${principal.tenantId}\u0000$companyId\u0000$branchId\u0000${type.moduleId}\u0000$docType\u0000$aggregateId'];
    if (record == null ||
        record.companyId != companyId ||
        record.branchId != branchId) return null;
    final readableFields = type.fields
        .where(
          (field) =>
              field.readPermission == null ||
              principal.allowsInScope(
                field.readPermission!,
                companyId,
                branchId,
              ),
        )
        .map((field) => field.name)
        .toSet();
    final visibleValues = record.data
      ..removeWhere((fieldName, _) => !readableFields.contains(fieldName));
    return StoredRecord(
      id: record.id,
      tenantId: record.tenantId,
      companyId: record.companyId,
      branchId: record.branchId,
      docType: record.docType,
      revision: record.revision,
      data: visibleValues,
    );
  }

  int get recordCount => _state.records.length;
  int get auditCount => _state.audit.length;
  int get outboxCount => _state.outbox.length;
  int get acceptedCommandCount => _state.journal.length;
  int get cursor => _state.cursor;

  List<Map<String, dynamic>> get outbox => List.unmodifiable(_state.outbox);

  static String _snakeCase(String value) => value.toLowerCase();
}
