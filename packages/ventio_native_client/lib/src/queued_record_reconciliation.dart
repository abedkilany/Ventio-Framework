import 'package:ventio_core/ventio_core.dart';

import 'extension_store.dart';
import 'local_command_queue.dart';

/// Reconciles locally queued generic records and governed operations after a
/// restart or Host response. Amend recovery can rebuild its provisional copy
/// from the durable command and cancelled source before applying the receipt.
Future<void> reconcileQueuedRecords(
  LocalExtensionStore store,
  LocalCommandQueue queue,
) async {
  final entries = await queue.list(limit: 1000);
  for (final entry in entries.reversed) {
    if (!entry.projectToLocalRecords) continue;
    final envelope = entry.envelope;
    final isRecordCommand =
        envelope.type == ExtensionRecordCommand.createType ||
        envelope.type == ExtensionRecordCommand.updateType ||
        envelope.type == ExtensionRecordCommand.deleteType;
    final isBusinessOperation =
        envelope.type == ExtensionBusinessOperationCommand.commandType;
    if (!isRecordCommand && !isBusinessOperation) {
      continue;
    }
    final command = isRecordCommand
        ? ExtensionRecordCommand.fromEnvelope(envelope)
        : null;
    final operationCommand = isBusinessOperation
        ? ExtensionBusinessOperationCommand.fromEnvelope(envelope)
        : null;
    BusinessOperationDefinition? operationDefinition;
    if (operationCommand != null) {
      final localMetadata = await store.getDocType(
        operationCommand.moduleId,
        operationCommand.docType,
      );
      if (localMetadata == null) continue;
      final localDefinition = DocTypeDefinition.fromJson(localMetadata);
      if (localDefinition.schemaVersion != envelope.docTypeVersion ||
          localDefinition.moduleId != operationCommand.moduleId) {
        continue;
      }
      final matches = localDefinition.businessOperations.where(
        (item) =>
            item.id == operationCommand.operationId &&
            item.version == operationCommand.operationVersion,
      );
      if (matches.length != 1) continue;
      operationDefinition = matches.single;
    }
    final amendmentEffect = operationDefinition?.effects
        .where((effect) => effect.type == 'document.amend')
        .firstOrNull;
    if (amendmentEffect != null && operationCommand != null) {
      await store.createAmendmentDraft(
        moduleId: operationCommand.moduleId,
        docTypeName: operationCommand.docType,
        sourceRecordId: envelope.aggregateId,
        scope: RecordScope(
          organizationId: envelope.tenantId,
          companyId: envelope.companyId,
          branchId: envelope.branchId,
        ),
        expectedSourceRevision: operationCommand.envelope.expectedRevision!,
        commandId: envelope.commandId,
        linkField: amendmentEffect.linkField!,
      );
    }
    final scope = RecordScope(
      organizationId: envelope.tenantId,
      companyId: envelope.companyId,
      branchId: envelope.branchId,
    );
    final receipt = entry.hostReceipt;
    if (receipt != null && receipt.status != 'RETRY_LATER') {
      final operationOutputs = <String, dynamic>{};
      int? documentStatus;
      String? amendedRecordId;
      if (operationDefinition != null && receipt.status == 'ACCEPTED') {
        for (final effect in operationDefinition.effects) {
          if (effect.type == 'document.transition') {
            documentStatus = effect.targetStatus;
            final reportedStatus = receipt.output?['status'];
            if (reportedStatus != null && reportedStatus != documentStatus) {
              throw const FormatException(
                'Host operation status output does not match its declaration.',
              );
            }
          } else if (effect.type == 'document.allocate_number') {
            final officialNumber = receipt.output?[effect.output];
            if (officialNumber is! String) {
              throw const FormatException(
                'Host operation receipt omitted its allocated number.',
              );
            }
            operationOutputs[effect.field!] = officialNumber;
          } else if (effect.type == 'document.amend') {
            final reportedId = receipt.output?[effect.output];
            if (reportedId is! String || reportedId != envelope.commandId) {
              throw const FormatException(
                'Host amendment receipt does not match the provisional record ID.',
              );
            }
            amendedRecordId = reportedId;
          }
        }
      }
      await store.applyHostReceipt(
        recordId: envelope.aggregateId,
        scope: scope,
        commandId: envelope.commandId,
        receipt: receipt,
        operation: command?.operation ?? 'update',
        documentStatus: documentStatus,
        valueUpdates: operationOutputs,
      );
      if (amendmentEffect != null) {
        final amendmentReceipt = receipt.status == 'ACCEPTED'
            ? CommandReceipt(
                commandId: receipt.commandId,
                status: receipt.status,
                serverTimestamp: receipt.serverTimestamp,
                hostRevision: 1,
                scopeCursor: receipt.scopeCursor,
                output: receipt.output,
              )
            : receipt;
        await store.applyHostReceipt(
          recordId: amendedRecordId ?? envelope.commandId,
          scope: scope,
          commandId: envelope.commandId,
          receipt: amendmentReceipt,
          operation: 'amend',
          documentStatus: 0,
        );
      }
    } else if (entry.isPending) {
      try {
        await store.markRecordPending(
          recordId: envelope.aggregateId,
          scope: scope,
          commandId: envelope.commandId,
          operation: command?.operation ?? 'update',
        );
      } on ExtensionStoreException catch (error) {
        if (error.code != 'RECORD_SYNC_STATE_CHANGED') rethrow;
      }
    }
    // Validate the queue payload against the same trusted generic contract
    // before applying any record state derived from its receipt.
    if ((command?.moduleId ?? operationCommand?.moduleId) !=
        envelope.payload['moduleId']) {
      throw const FormatException('Queued extension record identity mismatch.');
    }
  }
}
