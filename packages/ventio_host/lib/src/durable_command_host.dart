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
      ExtensionRecordCommand command,
    )?
    resolveExtensionBundle,
  }) async {
    ExtensionRecordCommand? extensionCommand;
    if (command.type == ExtensionRecordCommand.createType ||
        command.type == ExtensionRecordCommand.updateType ||
        command.type == ExtensionRecordCommand.deleteType) {
      try {
        extensionCommand = ExtensionRecordCommand.fromEnvelope(command);
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
          late final Map<String, dynamic> recordValues;
          var valuesForStorage = <String, dynamic>{};
          int? updateBaseRevision;
          String? releaseFailureReasonCode;
          ExtensionBundle? authorizedBundle;
          if (extensionRequest != null) {
            final authorization = await resolveExtensionBundle?.call(
              tx,
              extensionRequest,
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
            if (bundle.moduleId != extensionRequest.moduleId ||
                bundle.version != command.moduleVersion) {
              return _failure(command, 'REJECTED', 'UPGRADE_REQUIRED');
            }
            releaseFailureReasonCode = authorization?.failureReasonCode;
            final matches = bundle.docTypes.where(
              (type) => type.name == extensionRequest.docType,
            );
            if (matches.length != 1) {
              return _failure(command, 'REJECTED', 'INVALID_EXTENSION');
            }
            docType = matches.single;
            moduleVersion = bundle.version;
            moduleId = bundle.moduleId;
            operation = extensionRequest.operation;
            recordValues = extensionRequest.values;
            if (docType.moduleId != bundle.moduleId ||
                docType.schemaVersion != command.docTypeVersion) {
              return _failure(command, 'REJECTED', 'UPGRADE_REQUIRED');
            }
            final permission = docType.permissions[operation];
            final readPermission = docType.permissions['read'];
            if (!docType.operations.contains(operation) ||
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
          if (extensionRequest == null && command.expectedRevision != null) {
            throw _RejectedCommand(
              _failure(
                command,
                'CONFLICT',
                'EXPECTED_REVISION_MUST_BE_NULL',
                currentRevision: 0,
              ),
            );
          }
          if (docType
              .validatePayload(recordValues, partial: operation != 'create')
              .isNotEmpty) {
            throw _RejectedCommand(
              _failure(command, 'REJECTED', 'INVALID_PAYLOAD'),
            );
          }
          valuesForStorage = Map<String, dynamic>.from(recordValues);
          if (operation == 'update' || operation == 'delete') {
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
          if (operation != 'delete') {
            valuesForStorage = docType.applyDefaults(valuesForStorage);
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
          } else if (operation == 'update') {
            final expectedRevision = command.expectedRevision!;
            final updated = await tx.execute(
              pg.Sql.named('''
            UPDATE ventio_records
            SET revision = revision + 1, record_data = CAST(@data AS jsonb),
                updated_at = clock_timestamp()
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
              },
            );
            if (updated.isEmpty) {
              throw _RejectedCommand(
                _failure(command, 'CONFLICT', 'REVISION_CONFLICT'),
              );
            }
            recordRevision = updated.single[0] as int;
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
            'type': extensionRequest == null
                ? '${docType.name}.created'
                : 'extension.record.changed',
            'aggregateId': command.aggregateId,
            'recordRevision': recordRevision,
            if (extensionRequest != null) ...{
              'moduleId': extensionRequest.moduleId,
              'docType': extensionRequest.docType,
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
            output: {'serverRecordId': command.aggregateId},
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
