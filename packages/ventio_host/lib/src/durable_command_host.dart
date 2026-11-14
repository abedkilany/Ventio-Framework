import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';

class ExtensionBundleAuthorization {
  const ExtensionBundleAuthorization.approved(
    this.bundle, {
    this.failureReasonCode,
  });
  const ExtensionBundleAuthorization.denied(this.failureReasonCode)
    : bundle = null;

  final ExtensionBundle? bundle;
  final String? failureReasonCode;
}

/// Only explicitly registered, trusted operational-create handlers can run.
/// New executable handlers cannot be loaded from declarative manifests.
class DurableCommandHost {
  final pg.Connection connection;
  final ModuleRegistry modules;
  final DocTypeRegistry docTypes;
  final Map<String, String> _trustedCreates = {};

  /// A test-only fault hook. Never supply this in a production Host.
  final FutureOr<void> Function(String stage)? testFaultInjector;

  DurableCommandHost({
    required this.connection,
    required this.modules,
    required this.docTypes,
    this.testFaultInjector,
  });

  String _key(String type, int version) => '$type@$version';

  Future<bool> _hasInboundReference(
    pg.TxSession tx,
    CommandEnvelope command,
    String moduleId,
    DocTypeDefinition target, {
    required ExtensionBundle bundle,
  }) async {
    for (final source in bundle.docTypes.where(
      (item) => item.moduleId == moduleId,
    )) {
      for (final field in source.fields) {
        final candidates = <({FieldDefinition field, String? tableField})>[
          if (field.type == 'reference' && field.referenceTo == target.name)
            (field: field, tableField: null),
          if (field.childDocType case final child?)
            for (final childField in child.fields)
              if (childField.type == 'reference' &&
                  childField.referenceTo == target.name)
                (field: childField, tableField: field.name),
        ];
        for (final candidate in candidates) {
          final isChild = candidate.tableField != null;
          final rows = await tx.execute(
            pg.Sql.named('''
          SELECT 1 FROM ventio_records
          WHERE tenant_id=@tenant AND company_id=@company AND branch_id=@branch
            AND module_id=@module AND doc_type=@doctype
            AND (doc_type<>@target_doctype OR record_id<>@target_record)
            AND deleted_at IS NULL
            AND ${isChild ? "EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(record_data->@parent_field)='array' THEN record_data->@parent_field ELSE '[]'::jsonb END) AS child_rows(value) WHERE child_rows.value->>@field=@target_value)" : 'record_data->>@field=@target_value'}
          LIMIT 1
        '''),
            parameters: {
              'tenant': command.tenantId,
              'company': command.companyId,
              'branch': command.branchId,
              'module': moduleId,
              'doctype': source.name,
              'target_doctype': target.name,
              'target_record': command.aggregateId,
              'field': candidate.field.name,
              if (candidate.tableField != null)
                'parent_field': candidate.tableField,
              'target_value': command.aggregateId,
            },
          );
          if (rows.isNotEmpty) return true;
        }
      }
    }
    return false;
  }

  void registerTrustedCreateBinding(TrustedCommandBinding binding) {
    validateTrustedCreateBinding(modules, docTypes, binding);
    final key = _key(binding.commandType, binding.commandVersion);
    if (_trustedCreates.containsKey(key)) {
      throw ContractError('DUPLICATE_BINDING', key);
    }
    _trustedCreates[key] = binding.docTypeName;
  }

  Map<String, dynamic> _failure(
    CommandEnvelope command,
    String status,
    String reason, {
    int? currentRevision,
  }) => CommandReceipt(
    commandId: command.commandId,
    status: status,
    reasonCode: reason,
    messageKey: 'core.error.${reason.toLowerCase()}',
    currentRevision: currentRevision,
  ).toJson();

  String? _operationInputFailure(
    BusinessOperationDefinition definition,
    Map<String, dynamic> values,
  ) {
    if (values.keys.any((key) => !definition.inputs.containsKey(key))) {
      return 'INVALID_PAYLOAD';
    }
    for (final entry in definition.inputs.entries) {
      final spec = entry.value;
      if (!values.containsKey(entry.key)) {
        if (spec.required) return 'INVALID_PAYLOAD';
        continue;
      }
      final value = values[entry.key];
      if (value == null) {
        if (spec.required) return 'INVALID_PAYLOAD';
        continue;
      }
      final valid = switch (spec.type) {
        'text' =>
          value is String &&
              (spec.maxLength == null || value.length <= spec.maxLength!),
        'integer' => value is int,
        'decimal' => value is num && value.isFinite,
        'boolean' => value is bool,
        'date' => value is String && DateTime.tryParse(value) != null,
        'reference' =>
          value is String && value.isNotEmpty && value.length <= 128,
        _ => false,
      };
      if (!valid) return 'INVALID_PAYLOAD';
      if (spec.type == 'decimal' && spec.precision != null) {
        final decimal = value.toString().toLowerCase();
        final exponent = decimal.indexOf('e');
        final mantissa = exponent < 0
            ? decimal
            : decimal.substring(0, exponent);
        final mantissaScale = mantissa.contains('.')
            ? mantissa.length - mantissa.indexOf('.') - 1
            : 0;
        final exponentValue = exponent < 0
            ? 0
            : int.tryParse(decimal.substring(exponent + 1)) ?? 0;
        final scale = (mantissaScale - exponentValue).clamp(0, 1000);
        if (scale > spec.precision!) return 'INVALID_PAYLOAD';
      }
    }
    return null;
  }

  /// Runs the whole accepted effect, receipt, audit and outbox atomically.
  ///
  /// A fresh *authenticated Host principal* is mandatory for every call.
  /// Unaccepted replies are transient; only accepted commands are journaled.
  /// The caller must not report success if this future throws or the commit
  /// outcome is unknown. Instead retry the same command ID and payload.
  Future<Map<String, dynamic>> execute(
    CommandEnvelope command,
    Principal authenticatedPrincipal,
  ) => executeAuthorized(command, (_) async => authenticatedPrincipal);

  /// Persistent adapters resolve current identity and exact-scope permissions
  /// here, under this transaction, before journal access even on retries.
  /// The provider is trusted server code and must hold authorization locks
  /// through commit. A null result denies access without reading receipts.
  Future<Map<String, dynamic>> executeAuthorized(
    CommandEnvelope command,
    Future<Principal?> Function(pg.TxSession tx) resolvePrincipal, {
    Future<ExtensionBundleAuthorization> Function(
      pg.TxSession tx,
      CommandEnvelope command,
    )?
    resolveExtensionBundle,
    Future<String?> Function(pg.TxSession tx, Principal principal)?
    admissionGuard,
  }) async {
    ExtensionRecordCommand? extensionCommand;
    ExtensionBusinessOperationCommand? businessOperationCommand;
    if (command.type == ExtensionRecordCommand.createType ||
        command.type == ExtensionRecordCommand.updateType ||
        command.type == ExtensionRecordCommand.deleteType) {
      try {
        extensionCommand = ExtensionRecordCommand.fromEnvelope(command);
      } on ContractError {
        return _failure(command, 'REJECTED', 'INVALID_COMMAND');
      }
    } else if (command.type == ExtensionBusinessOperationCommand.commandType) {
      try {
        businessOperationCommand =
            ExtensionBusinessOperationCommand.fromEnvelope(command);
      } on ContractError {
        return _failure(command, 'REJECTED', 'INVALID_COMMAND');
      }
    }
    // Both payload and client context are covered by the idempotency digest.
    final fingerprint = sha256
        .convert(utf8.encode(canonicalJson(command.original)))
        .toString();

    try {
      final result = await connection.runTx(
        (tx) async {
          final extensionRequest = extensionCommand;
          final operationRequest = businessOperationCommand;
          final isBusinessOperation = operationRequest != null;
          final authenticatedPrincipal = await resolvePrincipal(tx);
          if (authenticatedPrincipal == null) {
            return _failure(command, 'REJECTED', 'AUTHENTICATION_REQUIRED');
          }
          if (!authenticatedPrincipal.withinScope(
            tenantId: command.tenantId,
            companyId: command.companyId,
            branchId: command.branchId,
            actorId: command.actorId,
            deviceId: command.deviceId,
          )) {
            return _failure(command, 'REJECTED', 'SCOPE_DENIED');
          }
          late final DocTypeDefinition docType;
          late final String moduleVersion;
          late final String moduleId;
          late final String operation;
          late Map<String, dynamic> recordValues;
          BusinessOperationDefinition? businessOperation;
          var valuesForStorage = <String, dynamic>{};
          int? updateBaseRevision;
          int? currentDocumentStatus;
          int? nextDocumentStatus;
          final operationOutputs = <String, dynamic>{};
          String? releaseFailureReasonCode;
          ExtensionBundle? authorizedBundle;
          if (extensionRequest != null || operationRequest != null) {
            final authorization = await resolveExtensionBundle?.call(
              tx,
              command,
            );
            final bundle = authorization?.bundle;
            if (bundle == null) {
              return _failure(
                command,
                'REJECTED',
                authorization?.failureReasonCode ?? 'EXTENSION_NOT_APPROVED',
              );
            }
            authorizedBundle = bundle;
            final requestedModule =
                extensionRequest?.moduleId ?? operationRequest!.moduleId;
            final requestedDocType =
                extensionRequest?.docType ?? operationRequest!.docType;
            if (bundle.moduleId != requestedModule ||
                bundle.version != command.moduleVersion) {
              return _failure(command, 'REJECTED', 'UPGRADE_REQUIRED');
            }
            releaseFailureReasonCode = authorization?.failureReasonCode;
            final matches = bundle.docTypes.where(
              (type) => type.name == requestedDocType,
            );
            if (matches.length != 1) {
              return _failure(command, 'REJECTED', 'INVALID_EXTENSION');
            }
            docType = matches.single;
            moduleVersion = bundle.version;
            moduleId = bundle.moduleId;
            if (extensionRequest != null) {
              operation = extensionRequest.operation;
              recordValues = extensionRequest.values;
            } else {
              final operationMatches = docType.businessOperations.where(
                (item) =>
                    item.id == operationRequest!.operationId &&
                    item.version == operationRequest.operationVersion,
              );
              if (operationMatches.length != 1) {
                return _failure(command, 'REJECTED', 'INVALID_EXTENSION');
              }
              businessOperation = operationMatches.single;
              final inputFailure = _operationInputFailure(
                businessOperation,
                operationRequest!.inputs,
              );
              if (inputFailure != null) {
                return _failure(command, 'REJECTED', inputFailure);
              }
              operation =
                  '${businessOperation.id}@${businessOperation.version}';
              recordValues = const {};
            }
            if (docType.moduleId != bundle.moduleId ||
                docType.schemaVersion != command.docTypeVersion) {
              return _failure(command, 'REJECTED', 'UPGRADE_REQUIRED');
            }
            final permission =
                businessOperation?.permission ?? docType.permissions[operation];
            final readPermission = docType.permissions['read'];
            if ((businessOperation == null &&
                    !docType.operations.contains(operation)) ||
                permission == null ||
                !authenticatedPrincipal.allowsInScope(
                  permission,
                  command.companyId,
                  command.branchId,
                ) ||
                (operation != 'create' &&
                    (readPermission == null ||
                        !authenticatedPrincipal.allowsInScope(
                          readPermission,
                          command.companyId,
                          command.branchId,
                        )))) {
              return _failure(command, 'REJECTED', 'PERMISSION_DENIED');
            }
          } else {
            final module = modules.moduleForCommand(
              command.type,
              command.typeVersion,
            );
            final bindingName =
                _trustedCreates[_key(command.type, command.typeVersion)];
            if (module == null || bindingName == null) {
              return _failure(command, 'REJECTED', 'UNKNOWN_COMMAND');
            }
            final declaration = modules.getCommand(
              module.moduleId,
              command.type,
              command.typeVersion,
            );
            final capability = declaration == null
                ? null
                : modules.getCapability(declaration.capabilityId);
            final boundDocType = docTypes.get(bindingName);
            if (declaration == null ||
                capability == null ||
                boundDocType == null ||
                !authenticatedPrincipal.allowsInScope(
                  declaration.permission,
                  command.companyId,
                  command.branchId,
                ) ||
                capability.requiredPermissions.any(
                  (permission) => !authenticatedPrincipal.allowsInScope(
                    permission,
                    command.companyId,
                    command.branchId,
                  ),
                )) {
              return _failure(command, 'REJECTED', 'PERMISSION_DENIED');
            }
            docType = boundDocType;
            moduleVersion = module.version;
            moduleId = module.moduleId;
            operation = 'create';
            recordValues = command.payload;
          }
          // Reservation is uncommitted until ALL effects commit. PostgreSQL's
          // unique-key arbitration makes concurrent identical retries wait.
          final reservation = await tx.execute(
            pg.Sql.named('''
          INSERT INTO ventio_command_journal
            (tenant_id, command_id, company_id, branch_id, actor_id,
             device_id, fingerprint, receipt)
          VALUES (@tenant, @command, @company, @branch, @actor,
                  @device, @fingerprint, '{}'::jsonb)
          ON CONFLICT (tenant_id, command_id) DO NOTHING
          RETURNING command_id
        '''),
            parameters: {
              'tenant': command.tenantId,
              'command': command.commandId,
              'company': command.companyId,
              'branch': command.branchId,
              'actor': command.actorId,
              'device': command.deviceId,
              'fingerprint': fingerprint,
            },
          );
          await testFaultInjector?.call('after_reservation');
          if (reservation.isEmpty) {
            final prior = await tx.execute(
              pg.Sql.named('''
            SELECT fingerprint, receipt::text AS stored_receipt,
                   company_id, branch_id, actor_id, device_id
            FROM ventio_command_journal
            WHERE tenant_id = @tenant AND command_id = @command
          '''),
              parameters: {
                'tenant': command.tenantId,
                'command': command.commandId,
              },
            );
            if (prior.isEmpty) {
              // RLS may intentionally hide a conflicting command in another
              // branch/company. Refuse reuse without exposing its receipt.
              return _failure(command, 'REJECTED', 'COMMAND_ID_REUSED');
            }
            final saved = prior.single.toColumnMap();
            if (saved['fingerprint'] != fingerprint ||
                saved['company_id'] != command.companyId ||
                saved['branch_id'] != command.branchId ||
                saved['actor_id'] != command.actorId ||
                saved['device_id'] != command.deviceId) {
              return _failure(command, 'REJECTED', 'COMMAND_ID_REUSED');
            }
            return jsonDecode(saved['stored_receipt'] as String)
                as Map<String, dynamic>;
          }

          // Return a saved accepted receipt for an identical retry even after
          // a package upgrade. A fresh command from a superseded release must
          // not proceed to its effects.
          final admissionFailure = await admissionGuard?.call(
            tx,
            authenticatedPrincipal,
          );
          if (admissionFailure != null) {
            throw _RejectedCommand(
              _failure(command, 'RETRY_LATER', admissionFailure),
            );
          }
          if (releaseFailureReasonCode != null) {
            throw _RejectedCommand(
              _failure(command, 'REJECTED', releaseFailureReasonCode),
            );
          }

          // Serialize accepted commits within this exact tenant/company/branch
          // scope. PostgreSQL sequences are allocated before commit and can be
          // observed out of order, so they cannot safely serve as sync cursors.
          // The cursor index makes the latest committed scope cursor an indexed
          // lookup instead of rescanning every JSON receipt. The transaction
          // advisory lock is released only at commit/rollback.
          final scopeKey = jsonEncode([
            command.tenantId,
            command.companyId,
            command.branchId,
          ]);
          await tx.execute(
            pg.Sql.named('''
          SELECT pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended(@scope_key, 0))
        '''),
            parameters: {'scope_key': scopeKey},
          );

          // Evaluate all mutable state under this same transaction. Throw to
          // roll back the journal reservation on every unsuccessful command.
          if (command.moduleVersion != moduleVersion ||
              command.docTypeVersion != docType.schemaVersion) {
            throw _RejectedCommand(
              _failure(command, 'REJECTED', 'UPGRADE_REQUIRED'),
            );
          }
          for (final dependency in command.dependsOn) {
            final rows = await tx.execute(
              pg.Sql.named('''
            SELECT receipt::text AS stored_receipt
            FROM ventio_command_journal
            WHERE tenant_id = @tenant AND company_id = @company
              AND branch_id = @branch AND command_id = @dependency
          '''),
              parameters: {
                'tenant': command.tenantId,
                'company': command.companyId,
                'branch': command.branchId,
                'dependency': dependency,
              },
            );
            if (rows.isEmpty ||
                (jsonDecode(
                          rows.single.toColumnMap()['stored_receipt'] as String,
                        )
                        as Map<String, dynamic>)['status'] !=
                    'ACCEPTED') {
              throw _RejectedCommand(
                _failure(command, 'RETRY_LATER', 'DEPENDENCY_PENDING'),
              );
            }
          }
          if (extensionRequest == null &&
              !isBusinessOperation &&
              command.expectedRevision != null) {
            throw _RejectedCommand(
              _failure(
                command,
                'CONFLICT',
                'EXPECTED_REVISION_MUST_BE_NULL',
                currentRevision: 0,
              ),
            );
          }
          try {
            recordValues = docType.calculateValues(
              recordValues,
              verifyCalculatedFields: recordValues.keys.toSet(),
            );
          } on ContractError catch (error) {
            throw _RejectedCommand(_failure(command, 'REJECTED', error.code));
          }
          if (docType
              .validatePayload(recordValues, partial: operation != 'create')
              .isNotEmpty) {
            throw _RejectedCommand(
              _failure(command, 'REJECTED', 'INVALID_PAYLOAD'),
            );
          }
          valuesForStorage = Map<String, dynamic>.from(recordValues);
          if (operation == 'update' ||
              operation == 'delete' ||
              isBusinessOperation) {
            final expectedRevision = command.expectedRevision!;
            if (expectedRevision >= 2147483647) {
              throw _RejectedCommand(
                _failure(
                  command,
                  'CONFLICT',
                  'REVISION_LIMIT',
                  currentRevision: expectedRevision,
                ),
              );
            }
            final currentRows = await tx.execute(
              pg.Sql.named('''
              -- The exact-scope advisory transaction lock above serializes
              -- Host writes. Avoid FOR UPDATE here: the RLS UPDATE policy
              -- binds rows to expected_revision, which would hide stale rows
              -- before we can return their current revision to the client.
              SELECT revision, record_data::text AS record_json,
                     document_status, deleted_at
            FROM ventio_records
            WHERE tenant_id = @tenant AND company_id = @company
              AND branch_id = @branch AND module_id = @module
              AND doc_type = @doctype AND record_id = @record
              AND deleted_at IS NULL
          '''),
              parameters: {
                'tenant': command.tenantId,
                'company': command.companyId,
                'branch': command.branchId,
                'module': moduleId,
                'doctype': docType.name,
                'record': command.aggregateId,
              },
            );
            if (currentRows.isEmpty) {
              throw _RejectedCommand(
                _failure(command, 'CONFLICT', 'RECORD_NOT_FOUND'),
              );
            }
            final current = currentRows.single.toColumnMap();
            updateBaseRevision = current['revision'] as int;
            currentDocumentStatus = current['document_status'] as int;
            if (updateBaseRevision != expectedRevision) {
              throw _RejectedCommand(
                _failure(
                  command,
                  'CONFLICT',
                  'REVISION_CONFLICT',
                  currentRevision: updateBaseRevision,
                ),
              );
            }
            if (operation == 'update' && currentDocumentStatus != 0) {
              throw _RejectedCommand(
                _failure(command, 'REJECTED', 'DOCUMENT_NOT_DRAFT'),
              );
            }
            if (operation == 'delete') {
              if ((current['document_status'] as int) != 0) {
                throw _RejectedCommand(
                  _failure(command, 'REJECTED', 'DOCUMENT_NOT_DRAFT'),
                );
              }
              if (await _hasInboundReference(
                tx,
                command,
                moduleId,
                docType,
                bundle: authorizedBundle!,
              )) {
                throw _RejectedCommand(
                  _failure(command, 'REJECTED', 'RECORD_IN_USE'),
                );
              }
              valuesForStorage = <String, dynamic>{};
            }
            final rawCurrentValues = jsonDecode(
              current['record_json'] as String,
            );
            if (rawCurrentValues is! Map) {
              throw const FormatException('Stored record JSON is invalid.');
            }
            valuesForStorage = Map<String, dynamic>.from(rawCurrentValues);
            final fieldsByName = {
              for (final field in docType.fields) field.name: field,
            };
            for (final entry
                in operation == 'delete'
                    ? const <MapEntry<String, dynamic>>[]
                    : recordValues.entries) {
              final field = fieldsByName[entry.key]!;
              if (field.readOnly &&
                  field.calculation == null &&
                  canonicalJson(valuesForStorage[field.name]) !=
                      canonicalJson(entry.value)) {
                throw _RejectedCommand(
                  _failure(command, 'REJECTED', 'READ_ONLY_FIELD'),
                );
              }
              final requiredPermission = field.writePermission;
              if (requiredPermission != null &&
                  !authenticatedPrincipal.allowsInScope(
                    requiredPermission,
                    command.companyId,
                    command.branchId,
                  )) {
                final currentValue = valuesForStorage[field.name];
                if (canonicalJson(currentValue) != canonicalJson(entry.value)) {
                  throw _RejectedCommand(
                    _failure(command, 'REJECTED', 'PERMISSION_DENIED'),
                  );
                }
                continue;
              }
              valuesForStorage[entry.key] = entry.value;
            }
          } else {
            final fieldsByName = {
              for (final field in docType.fields) field.name: field,
            };
            for (final entry in recordValues.entries) {
              final field = fieldsByName[entry.key]!;
              if (field.readOnly &&
                  field.calculation == null &&
                  canonicalJson(field.defaultValue) !=
                      canonicalJson(entry.value)) {
                throw _RejectedCommand(
                  _failure(command, 'REJECTED', 'READ_ONLY_FIELD'),
                );
              }
              final requiredPermission = field.writePermission;
              if (requiredPermission != null &&
                  !authenticatedPrincipal.allowsInScope(
                    requiredPermission,
                    command.companyId,
                    command.branchId,
                  )) {
                if (entry.value != null) {
                  throw _RejectedCommand(
                    _failure(command, 'REJECTED', 'PERMISSION_DENIED'),
                  );
                }
                valuesForStorage.remove(entry.key);
              }
            }
          }
          if (businessOperation != null) {
            final amendments = businessOperation.effects
                .where((effect) => effect.type == 'document.amend')
                .toList(growable: false);
            final transitions = businessOperation.effects
                .where((effect) => effect.type == 'document.transition')
                .toList(growable: false);
            if (transitions.length > 1) {
              throw _RejectedCommand(
                _failure(command, 'REJECTED', 'INVALID_EXTENSION'),
              );
            }
            final transition = transitions.isEmpty ? null : transitions.single;
            if (amendments.length > 1 ||
                (amendments.isNotEmpty && transition != null)) {
              throw _RejectedCommand(
                _failure(command, 'REJECTED', 'INVALID_EXTENSION'),
              );
            }
            if (amendments.isNotEmpty && currentDocumentStatus != 2) {
              throw _RejectedCommand(
                _failure(command, 'REJECTED', 'INVALID_DOCUMENT_TRANSITION'),
              );
            }
            if (amendments.isEmpty &&
                transition == null &&
                currentDocumentStatus != 0) {
              throw _RejectedCommand(
                _failure(command, 'REJECTED', 'DOCUMENT_NOT_DRAFT'),
              );
            }
            if (transition != null) {
              final validTransition =
                  (transition.targetStatus == 1 &&
                      currentDocumentStatus == 0) ||
                  (transition.targetStatus == 2 && currentDocumentStatus == 1);
              if (!validTransition) {
                throw _RejectedCommand(
                  _failure(command, 'REJECTED', 'INVALID_DOCUMENT_TRANSITION'),
                );
              }
              nextDocumentStatus = transition.targetStatus;
              if (businessOperation.outputs.containsKey('status')) {
                operationOutputs['status'] = nextDocumentStatus;
              }
            }
            for (final effect in businessOperation.effects) {
              if (effect.type == 'document.amend') {
                final createPermission = docType.permissions['create'];
                final linkField = docType.fields.singleWhere(
                  (field) => field.name == effect.linkField,
                );
                if (!docType.operations.contains('create') ||
                    createPermission == null ||
                    !authenticatedPrincipal.allowsInScope(
                      createPermission,
                      command.companyId,
                      command.branchId,
                    ) ||
                    (linkField.writePermission != null &&
                        !authenticatedPrincipal.allowsInScope(
                          linkField.writePermission!,
                          command.companyId,
                          command.branchId,
                        ))) {
                  throw _RejectedCommand(
                    _failure(command, 'REJECTED', 'PERMISSION_DENIED'),
                  );
                }
                final existingAmendments = await tx.execute(
                  pg.Sql.named('''
                    SELECT 1 FROM public.ventio_records
                    WHERE tenant_id=@tenant AND company_id=@company
                      AND branch_id=@branch AND module_id=@module
                      AND doc_type=@doctype AND deleted_at IS NULL
                      AND document_status<>2
                      AND record_data->>@link_field=@source
                    LIMIT 1
                  '''),
                  parameters: {
                    'tenant': command.tenantId,
                    'company': command.companyId,
                    'branch': command.branchId,
                    'module': moduleId,
                    'doctype': docType.name,
                    'link_field': effect.linkField,
                    'source': command.aggregateId,
                  },
                );
                if (existingAmendments.isNotEmpty) {
                  throw _RejectedCommand(
                    _failure(command, 'REJECTED', 'AMENDMENT_ALREADY_ACTIVE'),
                  );
                }
                final amendmentValues = Map<String, dynamic>.from(
                  valuesForStorage,
                );
                final namingField = docType.namingSeries?.field;
                if (namingField != null) amendmentValues.remove(namingField);
                amendmentValues[effect.linkField!] = command.aggregateId;
                final normalizedAmendment = docType.applyDefaults(
                  amendmentValues,
                );
                if (docType.validatePayload(normalizedAmendment).isNotEmpty) {
                  throw _RejectedCommand(
                    _failure(command, 'REJECTED', 'INVALID_PAYLOAD'),
                  );
                }
                for (final reference in docType.referencesIn(
                  normalizedAmendment,
                )) {
                  final foundReference = await tx.execute(
                    pg.Sql.named('''
                      SELECT 1 FROM public.ventio_records
                      WHERE tenant_id=@tenant AND company_id=@company
                        AND branch_id=@branch AND module_id=@module
                        AND doc_type=@doctype AND record_id=@record
                        AND deleted_at IS NULL
                      LIMIT 1
                    '''),
                    parameters: {
                      'tenant': command.tenantId,
                      'company': command.companyId,
                      'branch': command.branchId,
                      'module': moduleId,
                      'doctype': reference.targetDocType,
                      'record': reference.recordId,
                    },
                  );
                  if (foundReference.isEmpty) {
                    throw _RejectedCommand(
                      _failure(command, 'REJECTED', 'INVALID_REFERENCE'),
                    );
                  }
                }
                final createdAmendment = await tx.execute(
                  pg.Sql.named('''
                    INSERT INTO public.ventio_records
                      (tenant_id,company_id,branch_id,module_id,doc_type,
                       record_id,revision,record_data,document_status)
                    VALUES (@tenant,@company,@branch,@module,@doctype,
                            @record,1,CAST(@data AS jsonb),0)
                    ON CONFLICT
                      (tenant_id,company_id,branch_id,module_id,doc_type,record_id)
                    DO NOTHING
                    RETURNING record_id
                  '''),
                  parameters: {
                    'tenant': command.tenantId,
                    'company': command.companyId,
                    'branch': command.branchId,
                    'module': moduleId,
                    'doctype': docType.name,
                    'record': command.commandId,
                    'data': jsonEncode(normalizedAmendment),
                  },
                );
                if (createdAmendment.isEmpty) {
                  throw _RejectedCommand(
                    _failure(command, 'CONFLICT', 'RECORD_ALREADY_EXISTS'),
                  );
                }
                operationOutputs[effect.output!] = command.commandId;
                await testFaultInjector?.call('after_business_effect');
              } else if (effect.type == 'document.allocate_number') {
                final naming = docType.namingSeries;
                if (naming == null || naming.field != effect.field) {
                  throw _RejectedCommand(
                    _failure(command, 'REJECTED', 'INVALID_EXTENSION'),
                  );
                }
                final allocated = await tx.execute(
                  pg.Sql.named('''
                    INSERT INTO public.ventio_document_number_series
                      (tenant_id,company_id,branch_id,module_id,doc_type,series_id,
                       prefix,padding,next_number)
                    VALUES (@tenant,@company,@branch,@module,@doctype,@series,
                            @prefix,@padding,2)
                    ON CONFLICT
                      (tenant_id,company_id,branch_id,module_id,doc_type,series_id)
                    DO UPDATE SET next_number=public.ventio_document_number_series.next_number+1
                    WHERE public.ventio_document_number_series.prefix=EXCLUDED.prefix
                      AND public.ventio_document_number_series.padding=EXCLUDED.padding
                    RETURNING next_number-1
                  '''),
                  parameters: {
                    'tenant': command.tenantId,
                    'company': command.companyId,
                    'branch': command.branchId,
                    'module': moduleId,
                    'doctype': docType.name,
                    'series': naming.seriesId,
                    'prefix': naming.prefix,
                    'padding': naming.padding,
                  },
                );
                if (allocated.length != 1 || allocated.single[0] is! int) {
                  throw _RejectedCommand(
                    _failure(command, 'REJECTED', 'NUMBER_SERIES_CHANGED'),
                  );
                }
                final officialNumber = naming.formatNumber(
                  allocated.single[0] as int,
                );
                valuesForStorage[effect.field!] = officialNumber;
                operationOutputs[effect.output!] = officialNumber;
              } else if (effect.type == 'record.increment') {
                final targetDefinition = authorizedBundle!.docTypes.singleWhere(
                  (definition) => definition.name == effect.targetDocType,
                );
                final targetField = targetDefinition.fields.singleWhere(
                  (field) => field.name == effect.field,
                );
                final targetId = operationRequest!.inputs[effect.targetIdInput];
                final amount = operationRequest.inputs[effect.amountInput];
                final updatePermission = targetDefinition.permissions['update'];
                final readPermission = targetDefinition.permissions['read'];
                final fieldPermissions = [
                  targetField.readPermission,
                  targetField.writePermission,
                ].whereType<String>();
                if (targetId is! String ||
                    !targetDefinition.operations.contains('read') ||
                    !targetDefinition.operations.contains('update') ||
                    updatePermission == null ||
                    readPermission == null ||
                    !authenticatedPrincipal.allowsInScope(
                      updatePermission,
                      command.companyId,
                      command.branchId,
                    ) ||
                    !authenticatedPrincipal.allowsInScope(
                      readPermission,
                      command.companyId,
                      command.branchId,
                    ) ||
                    fieldPermissions.any(
                      (permission) => !authenticatedPrincipal.allowsInScope(
                        permission,
                        command.companyId,
                        command.branchId,
                      ),
                    ) ||
                    amount is! num ||
                    !amount.isFinite) {
                  throw _RejectedCommand(
                    _failure(command, 'REJECTED', 'PERMISSION_DENIED'),
                  );
                }
                final targetRows = await tx.execute(
                  pg.Sql.named('''
                    SELECT revision, record_data::text AS record_json
                    FROM public.ventio_records
                    WHERE tenant_id=@tenant AND company_id=@company AND branch_id=@branch
                      AND module_id=@module AND doc_type=@doctype AND record_id=@record
                      AND deleted_at IS NULL AND document_status=0
                  '''),
                  parameters: {
                    'tenant': command.tenantId,
                    'company': command.companyId,
                    'branch': command.branchId,
                    'module': moduleId,
                    'doctype': targetDefinition.name,
                    'record': targetId,
                  },
                );
                if (targetRows.isEmpty) {
                  throw _RejectedCommand(
                    _failure(command, 'REJECTED', 'INVALID_REFERENCE'),
                  );
                }
                final target = targetRows.single.toColumnMap();
                final targetData = jsonDecode(target['record_json'] as String);
                if (targetData is! Map || targetData[effect.field] is! num) {
                  throw _RejectedCommand(
                    _failure(command, 'REJECTED', 'INVALID_PAYLOAD'),
                  );
                }
                final updatedTarget = await tx.execute(
                  pg.Sql.named('''
                    UPDATE public.ventio_records
                    SET revision=revision+1,
                        record_data=jsonb_set(record_data,ARRAY[@field],
                          to_jsonb((record_data->>@field)::numeric + @amount::numeric),true),
                        updated_at=clock_timestamp()
                    WHERE tenant_id=@tenant AND company_id=@company AND branch_id=@branch
                      AND module_id=@module AND doc_type=@doctype AND record_id=@record
                      AND revision=@revision AND deleted_at IS NULL AND document_status=0
                    RETURNING revision, record_data::text AS record_json
                  '''),
                  parameters: {
                    'field': effect.field,
                    'amount': amount.toString(),
                    'tenant': command.tenantId,
                    'company': command.companyId,
                    'branch': command.branchId,
                    'module': moduleId,
                    'doctype': targetDefinition.name,
                    'record': targetId,
                    'revision': target['revision'],
                  },
                );
                if (updatedTarget.isEmpty) {
                  throw _RejectedCommand(
                    _failure(command, 'CONFLICT', 'REVISION_CONFLICT'),
                  );
                }
                final newTarget =
                    jsonDecode(
                          updatedTarget.single.toColumnMap()['record_json']
                              as String,
                        )
                        as Map<String, dynamic>;
                if (targetField.validate(newTarget[targetField.name]) != null) {
                  throw _RejectedCommand(
                    _failure(command, 'REJECTED', 'INVALID_PAYLOAD'),
                  );
                }
                await testFaultInjector?.call('after_business_effect');
              } else if (effect.type == 'record.increment_rows') {
                final targetDefinition = authorizedBundle!.docTypes.singleWhere(
                  (definition) => definition.name == effect.targetDocType,
                );
                final targetField = targetDefinition.fields.singleWhere(
                  (field) => field.name == effect.field,
                );
                final tableField = docType.fields.singleWhere(
                  (field) => field.name == effect.rowsField,
                );
                if (tableField.childDocType == null) {
                  throw _RejectedCommand(
                    _failure(command, 'REJECTED', 'INVALID_EXTENSION'),
                  );
                }
                final updatePermission = targetDefinition.permissions['update'];
                final readPermission = targetDefinition.permissions['read'];
                final targetPermissions = [
                  updatePermission,
                  readPermission,
                  targetField.readPermission,
                  targetField.writePermission,
                ].whereType<String>();
                if (targetDefinition.operations.contains('read') != true ||
                    targetDefinition.operations.contains('update') != true ||
                    updatePermission == null ||
                    readPermission == null ||
                    targetPermissions.any(
                      (permission) => !authenticatedPrincipal.allowsInScope(
                        permission,
                        command.companyId,
                        command.branchId,
                      ),
                    )) {
                  throw _RejectedCommand(
                    _failure(command, 'REJECTED', 'PERMISSION_DENIED'),
                  );
                }
                final rawRows = valuesForStorage[effect.rowsField];
                if (rawRows is! List || rawRows.length > 500) {
                  throw _RejectedCommand(
                    _failure(command, 'REJECTED', 'INVALID_PAYLOAD'),
                  );
                }
                final precision = targetField.type == 'decimal'
                    ? targetField.precision!
                    : 0;
                final totals = <String, BigInt>{};
                for (final rawRow in rawRows) {
                  if (rawRow is! Map) {
                    throw _RejectedCommand(
                      _failure(command, 'REJECTED', 'INVALID_PAYLOAD'),
                    );
                  }
                  final targetId = rawRow[effect.targetIdField];
                  final amount = rawRow[effect.amountField];
                  if (targetId is! String ||
                      amount is! num ||
                      !amount.isFinite) {
                    throw _RejectedCommand(
                      _failure(command, 'REJECTED', 'INVALID_PAYLOAD'),
                    );
                  }
                  final scaledAmount = _decimalToScaledInteger(
                    amount,
                    precision,
                  );
                  totals[targetId] =
                      (totals[targetId] ?? BigInt.zero) +
                      scaledAmount * BigInt.from(effect.amountMultiplier!);
                }
                for (final entry in totals.entries) {
                  // The RLS policy consumes this transaction-local target binding
                  // only after the Host has read it from the saved parent rows.
                  await tx.execute(
                    pg.Sql.named(
                      "SELECT set_config('ventio.effect_target_id', @target, true)",
                    ),
                    parameters: {'target': entry.key},
                  );
                  final targetRows = await tx.execute(
                    pg.Sql.named('''
                      SELECT revision, record_data::text AS record_json
                      FROM public.ventio_records
                      WHERE tenant_id=@tenant AND company_id=@company AND branch_id=@branch
                        AND module_id=@module AND doc_type=@doctype AND record_id=@record
                        AND deleted_at IS NULL AND document_status=0
                    '''),
                    parameters: {
                      'tenant': command.tenantId,
                      'company': command.companyId,
                      'branch': command.branchId,
                      'module': moduleId,
                      'doctype': targetDefinition.name,
                      'record': entry.key,
                    },
                  );
                  if (targetRows.isEmpty) {
                    throw _RejectedCommand(
                      _failure(command, 'REJECTED', 'INVALID_REFERENCE'),
                    );
                  }
                  final target = targetRows.single.toColumnMap();
                  final targetData = jsonDecode(
                    target['record_json'] as String,
                  );
                  if (targetData is! Map || targetData[effect.field] is! num) {
                    throw _RejectedCommand(
                      _failure(command, 'REJECTED', 'INVALID_PAYLOAD'),
                    );
                  }
                  final updated = await tx.execute(
                    pg.Sql.named('''
                      UPDATE public.ventio_records
                      SET revision=revision+1,
                          record_data=jsonb_set(record_data,ARRAY[@field],
                            to_jsonb((record_data->>@field)::numeric + @amount::numeric),true),
                          updated_at=clock_timestamp()
                      WHERE tenant_id=@tenant AND company_id=@company AND branch_id=@branch
                        AND module_id=@module AND doc_type=@doctype AND record_id=@record
                        AND revision=@revision AND deleted_at IS NULL AND document_status=0
                      RETURNING revision, record_data::text AS record_json
                    '''),
                    parameters: {
                      'field': effect.field,
                      'amount': _scaledIntegerToDecimal(entry.value, precision),
                      'tenant': command.tenantId,
                      'company': command.companyId,
                      'branch': command.branchId,
                      'module': moduleId,
                      'doctype': targetDefinition.name,
                      'record': entry.key,
                      'revision': target['revision'],
                    },
                  );
                  if (updated.isEmpty) {
                    throw _RejectedCommand(
                      _failure(command, 'CONFLICT', 'REVISION_CONFLICT'),
                    );
                  }
                  final newTarget =
                      jsonDecode(
                            updated.single.toColumnMap()['record_json']
                                as String,
                          )
                          as Map<String, dynamic>;
                  if (targetField.validate(newTarget[targetField.name]) !=
                      null) {
                    throw _RejectedCommand(
                      _failure(command, 'REJECTED', 'INVALID_PAYLOAD'),
                    );
                  }
                  await testFaultInjector?.call('after_business_effect');
                }
                await tx.execute(
                  pg.Sql.named(
                    "SELECT set_config('ventio.effect_target_id', '', true)",
                  ),
                );
              }
            }
            for (final output in businessOperation.outputs.entries) {
              if (output.value.required &&
                  !operationOutputs.containsKey(output.key)) {
                throw _RejectedCommand(
                  _failure(command, 'REJECTED', 'INVALID_PAYLOAD'),
                );
              }
            }
          }
          if (operation != 'delete') {
            try {
              valuesForStorage = docType.calculateValues(
                valuesForStorage,
                verifyCalculatedFields: recordValues.keys.toSet(),
              );
            } on ContractError catch (error) {
              throw _RejectedCommand(_failure(command, 'REJECTED', error.code));
            }
          }
          if (operation != 'delete' &&
              docType.validatePayload(valuesForStorage).isNotEmpty) {
            throw _RejectedCommand(
              _failure(command, 'REJECTED', 'INVALID_PAYLOAD'),
            );
          }
          for (final reference
              in operation == 'delete'
                  ? const <DocTypeReferenceValue>[]
                  : docType.referencesIn(valuesForStorage)) {
            final rows = await tx.execute(
              pg.Sql.named('''
            SELECT record_id FROM ventio_records
            WHERE tenant_id = @tenant AND company_id = @company
              AND branch_id = @branch AND module_id = @module
              AND doc_type = @doctype
              AND record_id = @record
              AND deleted_at IS NULL
          '''),
              parameters: {
                'tenant': command.tenantId,
                'company': command.companyId,
                'branch': command.branchId,
                'module': moduleId,
                'doctype': reference.targetDocType,
                'record': reference.recordId,
              },
            );
            if (rows.isEmpty) {
              throw _RejectedCommand(
                _failure(command, 'REJECTED', 'INVALID_REFERENCE'),
              );
            }
          }
          final cursorRows = await tx.execute(
            pg.Sql.named('''
          SELECT (coalesce(max(scope_cursor), 0) + 1)::text AS next_cursor
          FROM ventio_command_journal
          WHERE tenant_id = @tenant AND company_id = @company
            AND branch_id = @branch AND scope_cursor IS NOT NULL
        '''),
            parameters: {
              'tenant': command.tenantId,
              'company': command.companyId,
              'branch': command.branchId,
            },
          );
          final cursorValue = cursorRows.single[0] as String;
          final scopeCursor = 'scope-v1-$cursorValue';
          var recordRevision = 1;
          if (operation == 'delete') {
            final deleted = await tx.execute(
              pg.Sql.named('''
            UPDATE ventio_records
            SET revision = revision + 1, deleted_at = clock_timestamp(),
                updated_at = clock_timestamp()
            WHERE tenant_id = @tenant AND company_id = @company
              AND branch_id = @branch AND module_id = @module
              AND doc_type = @doctype AND record_id = @record
              AND revision = @expected AND deleted_at IS NULL
            RETURNING revision
          '''),
              parameters: {
                'tenant': command.tenantId,
                'company': command.companyId,
                'branch': command.branchId,
                'module': moduleId,
                'doctype': docType.name,
                'record': command.aggregateId,
                'expected': command.expectedRevision,
              },
            );
            if (deleted.isEmpty) {
              throw _RejectedCommand(
                _failure(command, 'CONFLICT', 'REVISION_CONFLICT'),
              );
            }
            recordRevision = deleted.single[0] as int;
          } else if (operation == 'update' || isBusinessOperation) {
            final expectedRevision = command.expectedRevision!;
            final isAmendment =
                businessOperation?.effects.any(
                  (effect) => effect.type == 'document.amend',
                ) ??
                false;
            if (isAmendment) {
              // Amend creates a new draft while leaving the cancelled source
              // and its revision untouched.
              recordRevision = updateBaseRevision!;
            } else {
              final updated = await tx.execute(
                pg.Sql.named('''
            UPDATE ventio_records
            SET revision = revision + 1, record_data = CAST(@data AS jsonb),
                updated_at = clock_timestamp(),
                document_status = coalesce(@document_status, document_status)
            WHERE tenant_id = @tenant AND company_id = @company
              AND branch_id = @branch AND module_id = @module
              AND doc_type = @doctype
              AND record_id = @record AND revision = @expected
            RETURNING revision
          '''),
                parameters: {
                  'tenant': command.tenantId,
                  'company': command.companyId,
                  'branch': command.branchId,
                  'module': moduleId,
                  'doctype': docType.name,
                  'record': command.aggregateId,
                  'expected': expectedRevision,
                  'data': jsonEncode(valuesForStorage),
                  'document_status': nextDocumentStatus,
                },
              );
              if (updated.isEmpty) {
                throw _RejectedCommand(
                  _failure(command, 'CONFLICT', 'REVISION_CONFLICT'),
                );
              }
              recordRevision = updated.single[0] as int;
            }
          } else {
            final record = await tx.execute(
              pg.Sql.named('''
          INSERT INTO ventio_records
            (tenant_id, company_id, branch_id, module_id, doc_type,
             record_id, revision, record_data)
          VALUES (@tenant, @company, @branch, @module, @doctype, @record, 1,
                  CAST(@data AS jsonb))
          ON CONFLICT (tenant_id, company_id, branch_id, module_id, doc_type, record_id)
          DO NOTHING RETURNING record_id
        '''),
              parameters: {
                'tenant': command.tenantId,
                'company': command.companyId,
                'branch': command.branchId,
                'module': moduleId,
                'doctype': docType.name,
                'record': command.aggregateId,
                'data': jsonEncode(valuesForStorage),
              },
            );
            if (record.isEmpty) {
              final previous = await tx.execute(
                pg.Sql.named('''
            SELECT revision FROM ventio_records WHERE tenant_id=@tenant
              AND company_id=@company AND branch_id=@branch
              AND module_id=@module AND doc_type=@doctype AND record_id=@record
          '''),
                parameters: {
                  'tenant': command.tenantId,
                  'company': command.companyId,
                  'branch': command.branchId,
                  'module': moduleId,
                  'doctype': docType.name,
                  'record': command.aggregateId,
                },
              );
              throw _RejectedCommand(
                _failure(
                  command,
                  'CONFLICT',
                  'RECORD_ALREADY_EXISTS',
                  currentRevision: previous.isEmpty
                      ? null
                      : previous.single[0] as int,
                ),
              );
            }
          }
          await testFaultInjector?.call('after_record');
          final audit = <String, dynamic>{
            'tenantId': command.tenantId,
            'companyId': command.companyId,
            'branchId': command.branchId,
            'actorId': command.actorId,
            'deviceId': command.deviceId,
            'commandId': command.commandId,
            'type': command.type,
            'aggregateId': command.aggregateId,
          };
          await tx.execute(
            pg.Sql.named('''
          INSERT INTO ventio_audit_entries
            (tenant_id, company_id, branch_id, actor_id,
             command_id, event_type, details)
          VALUES (@tenant, @company, @branch, @actor, @command,
                  @type, CAST(@details AS jsonb))
        '''),
            parameters: {
              'tenant': command.tenantId,
              'company': command.companyId,
              'branch': command.branchId,
              'actor': command.actorId,
              'command': command.commandId,
              'type': command.type,
              'details': jsonEncode(audit),
            },
          );
          await testFaultInjector?.call('after_audit');
          final event = <String, dynamic>{
            'tenantId': command.tenantId,
            'companyId': command.companyId,
            'branchId': command.branchId,
            'commandId': command.commandId,
            'type': extensionRequest == null && !isBusinessOperation
                ? '${docType.name}.created'
                : 'extension.record.changed',
            'aggregateId': command.aggregateId,
            'recordRevision': recordRevision,
            if (extensionRequest != null || isBusinessOperation) ...{
              'moduleId': extensionRequest?.moduleId ?? moduleId,
              'docType': extensionRequest?.docType ?? docType.name,
              'operation': operation,
            },
          };
          await tx.execute(
            pg.Sql.named('''
          INSERT INTO ventio_outbox
            (tenant_id, company_id, branch_id, command_id, event_type, payload)
          VALUES (@tenant, @company, @branch, @command,
                  @type, CAST(@payload AS jsonb))
        '''),
            parameters: {
              'tenant': command.tenantId,
              'company': command.companyId,
              'branch': command.branchId,
              'command': command.commandId,
              'type': event['type'],
              'payload': jsonEncode(event),
            },
          );
          await testFaultInjector?.call('after_outbox');
          final receipt = CommandReceipt(
            commandId: command.commandId,
            status: 'ACCEPTED',
            hostRevision: recordRevision,
            scopeCursor: scopeCursor,
            output: {
              'serverRecordId': command.aggregateId,
              if (isBusinessOperation) ...operationOutputs,
            },
          ).toJson();
          await tx.execute(
            pg.Sql.named('''
          UPDATE ventio_command_journal
          SET scope_cursor = @cursor, receipt = CAST(@receipt AS jsonb)
          WHERE tenant_id = @tenant AND command_id = @command
        '''),
            parameters: {
              'receipt': jsonEncode(receipt),
              'cursor': int.parse(cursorValue),
              'tenant': command.tenantId,
              'command': command.commandId,
            },
          );
          await testFaultInjector?.call('before_commit');
          return receipt;
        },
        settings: pg.TransactionSettings(
          isolationLevel: pg.IsolationLevel.readCommitted,
        ),
      );
      // This point is reached only after the driver has acknowledged COMMIT.
      await testFaultInjector?.call('after_commit');
      return result;
    } on _RejectedCommand catch (error) {
      return error.receipt;
    }
  }
}

class _RejectedCommand implements Exception {
  final Map<String, dynamic> receipt;
  const _RejectedCommand(this.receipt);
}

BigInt _decimalToScaledInteger(num value, int precision) {
  return ExactDecimal.toScaledInteger(value, precision);
}

String _scaledIntegerToDecimal(BigInt value, int precision) {
  if (precision == 0) return value.toString();
  final scale = BigInt.from(10).pow(precision);
  final negative = value.isNegative;
  final absolute = value.abs();
  final whole = absolute ~/ scale;
  final fraction = (absolute % scale).toString().padLeft(precision, '0');
  final trimmed = fraction.replaceFirst(RegExp(r'0+$'), '');
  return '${negative ? '-' : ''}$whole${trimmed.isEmpty ? '' : '.$trimmed'}';
}
