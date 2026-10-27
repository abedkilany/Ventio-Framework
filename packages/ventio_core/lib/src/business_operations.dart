import 'contracts.dart';

/// A declarative operation contract. It contains data only; execution is
/// restricted to the Host's built-in effect interpreter.
class BusinessOperationDefinition {
  const BusinessOperationDefinition({
    required this.id,
    required this.version,
    required this.permission,
    required this.inputs,
    required this.outputs,
    required this.effects,
  });

  static final _idPattern = RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$');
  static final _namePattern = RegExp(r'^[a-z][A-Za-z0-9_]{0,79}$');
  static final _permissionPattern =
      RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){2,}$');
  static const supportedTypes = {
    'text',
    'integer',
    'decimal',
    'boolean',
    'date',
    'reference',
  };
  static const supportedEffects = {
    'document.allocate_number',
    'document.transition',
    'record.increment',
    'record.increment_rows',
    'document.amend',
  };

  final String id;
  final int version;
  final String permission;
  final Map<String, OperationValueDefinition> inputs;
  final Map<String, OperationValueDefinition> outputs;
  final List<OperationEffectDefinition> effects;

  factory BusinessOperationDefinition.fromJson(Map<String, dynamic> json) {
    const allowed = {
      'id',
      'version',
      'permission',
      'inputs',
      'outputs',
      'effects',
    };
    if (json.keys.toSet().difference(allowed).isNotEmpty) {
      throw const ContractError(
        'INVALID_OPERATION',
        'Unknown business operation property.',
      );
    }
    final id = requireString(json, 'id');
    final version = requireInt(json, 'version', min: 1);
    if (version > 255) {
      throw const ContractError(
          'INVALID_OPERATION', 'Invalid operation version.');
    }
    final permission = requireString(json, 'permission');
    if (id.length > 128 || !_idPattern.hasMatch(id)) {
      throw const ContractError('INVALID_OPERATION', 'Invalid operation ID.');
    }
    if (!_permissionPattern.hasMatch(permission)) {
      throw const ContractError(
        'INVALID_OPERATION',
        'Operation permission must be a namespaced permission key.',
      );
    }
    Map<String, OperationValueDefinition> values(String key) {
      final raw = requireMap(json[key], key);
      if (raw.length > 32 ||
          raw.keys.any((name) => !_namePattern.hasMatch(name))) {
        throw ContractError('INVALID_OPERATION', 'Invalid $key contract.');
      }
      return Map.unmodifiable({
        for (final entry in raw.entries)
          entry.key: OperationValueDefinition.fromJson(
            requireMap(entry.value, '$key.${entry.key}'),
          ),
      });
    }

    final effects = requireList(json, 'effects')
        .map((effect) => OperationEffectDefinition.fromJson(
              requireMap(effect, 'effects[]'),
            ))
        .toList(growable: false);
    final inputs = values('inputs');
    final outputs = values('outputs');
    if (effects.where((item) => item.type == 'document.transition').length >
            1 ||
        effects
                .where((item) => item.type == 'document.allocate_number')
                .length >
            1) {
      throw const ContractError(
        'INVALID_OPERATION',
        'An operation may contain at most one transition and one number allocation.',
      );
    }
    final producedOutputs = <String>{
      for (final effect
          in effects.where((item) => item.type == 'document.allocate_number'))
        effect.output!,
      if (effects.any((item) => item.type == 'document.transition')) 'status',
      for (final effect
          in effects.where((item) => item.type == 'document.amend'))
        effect.output!,
    };
    final statusOutput = outputs['status'];
    if (outputs.keys.any((name) => !producedOutputs.contains(name)) ||
        (statusOutput != null &&
            (statusOutput.type != 'integer' || !statusOutput.required))) {
      throw const ContractError(
        'INVALID_OPERATION',
        'Operation outputs must bind to a declared Host effect result.',
      );
    }
    for (final effect
        in effects.where((item) => item.type == 'document.allocate_number')) {
      final output = outputs[effect.output];
      if (output == null || output.type != 'text' || !output.required) {
        throw const ContractError(
          'INVALID_OPERATION',
          'Number allocation outputs must bind to a required text output.',
        );
      }
    }
    for (final effect
        in effects.where((item) => item.type == 'document.amend')) {
      final output = outputs[effect.output];
      if (output == null || output.type != 'text' || !output.required) {
        throw const ContractError(
          'INVALID_OPERATION',
          'Amend effects must bind a required text record-ID output.',
        );
      }
      if (effects.length != 1) {
        throw const ContractError(
          'INVALID_OPERATION',
          'An amend operation cannot be combined with other effects.',
        );
      }
    }
    if (effects.any((item) => item.type == 'document.allocate_number') &&
        !effects.any((item) =>
            item.type == 'document.transition' && item.targetStatus == 1)) {
      throw const ContractError(
        'INVALID_OPERATION',
        'Official number allocation must be part of a submit transition.',
      );
    }
    for (final effect
        in effects.where((item) => item.type == 'record.increment')) {
      final target = inputs[effect.targetIdInput];
      final amount = inputs[effect.amountInput];
      if (target == null ||
          target.type != 'reference' ||
          !target.required ||
          amount == null ||
          !amount.required ||
          !{'integer', 'decimal'}.contains(amount.type)) {
        throw const ContractError(
          'INVALID_OPERATION',
          'Record increment effects must bind declared reference and numeric inputs.',
        );
      }
    }
    if (effects.isEmpty || effects.length > 8) {
      throw const ContractError(
        'INVALID_OPERATION',
        'An operation must declare between one and eight Host effects.',
      );
    }
    return BusinessOperationDefinition(
      id: id,
      version: version,
      permission: permission,
      inputs: inputs,
      outputs: outputs,
      effects: List.unmodifiable(effects),
    );
  }
}

/// Parameters for one supported, non-executable Core effect.
class OperationEffectDefinition {
  const OperationEffectDefinition({
    required this.type,
    this.field,
    this.targetDocType,
    this.targetIdInput,
    this.amountInput,
    this.targetStatus,
    this.output,
    this.rowsField,
    this.targetIdField,
    this.amountField,
    this.amountMultiplier,
    this.linkField,
  });

  final String type;
  final String? field;
  final String? targetDocType;
  final String? targetIdInput;
  final String? amountInput;
  final int? targetStatus;
  final String? output;
  final String? rowsField;
  final String? targetIdField;
  final String? amountField;
  final int? amountMultiplier;
  final String? linkField;

  factory OperationEffectDefinition.fromJson(Map<String, dynamic> json) {
    final type = requireString(json, 'type');
    final allowed = switch (type) {
      'document.allocate_number' => {'type', 'field', 'output'},
      'document.transition' => {'type', 'targetStatus'},
      'record.increment' => {
          'type',
          'targetDocType',
          'targetIdInput',
          'amountInput',
          'field',
        },
      'record.increment_rows' => {
          'type',
          'targetDocType',
          'rowsField',
          'targetIdField',
          'amountField',
          'field',
          'amountMultiplier',
        },
      'document.amend' => {'type', 'linkField', 'output'},
      _ => <String>{},
    };
    if (allowed.isEmpty || json.keys.toSet().difference(allowed).isNotEmpty) {
      throw const ContractError(
        'INVALID_OPERATION',
        'Unknown or unsupported Host effect declaration.',
      );
    }
    final field = optionalString(json, 'field');
    final targetDocType = optionalString(json, 'targetDocType');
    final targetIdInput = optionalString(json, 'targetIdInput');
    final amountInput = optionalString(json, 'amountInput');
    final status = json['targetStatus'];
    final output = optionalString(json, 'output');
    final rowsField = optionalString(json, 'rowsField');
    final targetIdField = optionalString(json, 'targetIdField');
    final amountField = optionalString(json, 'amountField');
    final amountMultiplier = json['amountMultiplier'];
    final linkField = optionalString(json, 'linkField');
    if (type == 'document.allocate_number' &&
        (field == null ||
            !_fieldName.hasMatch(field) ||
            output == null ||
            !_inputName.hasMatch(output))) {
      throw const ContractError(
        'INVALID_OPERATION',
        'Number allocation requires a field and declared output name.',
      );
    }
    if (type == 'document.transition' &&
        (status is! int || (status != 1 && status != 2))) {
      throw const ContractError(
        'INVALID_OPERATION',
        'Document transition status must be submitted (1) or cancelled (2).',
      );
    }
    if (type == 'record.increment' &&
        (targetDocType == null ||
            !_docTypeName.hasMatch(targetDocType) ||
            field == null ||
            !_fieldName.hasMatch(field) ||
            targetIdInput == null ||
            !_inputName.hasMatch(targetIdInput) ||
            amountInput == null ||
            !_inputName.hasMatch(amountInput))) {
      throw const ContractError(
        'INVALID_OPERATION',
        'Invalid numeric record increment target or input binding.',
      );
    }
    if (type == 'record.increment_rows' &&
        (targetDocType == null ||
            !_docTypeName.hasMatch(targetDocType) ||
            field == null ||
            !_fieldName.hasMatch(field) ||
            rowsField == null ||
            !_fieldName.hasMatch(rowsField) ||
            targetIdField == null ||
            !_fieldName.hasMatch(targetIdField) ||
            amountField == null ||
            !_fieldName.hasMatch(amountField) ||
            amountMultiplier is! int ||
            (amountMultiplier != 1 && amountMultiplier != -1))) {
      throw const ContractError(
        'INVALID_OPERATION',
        'Invalid child row increment target or field binding.',
      );
    }
    if (type == 'document.amend' &&
        (linkField == null ||
            !_fieldName.hasMatch(linkField) ||
            output == null ||
            !_inputName.hasMatch(output))) {
      throw const ContractError(
        'INVALID_OPERATION',
        'Amend effects require a self-reference field and output name.',
      );
    }
    return OperationEffectDefinition(
      type: type,
      field: field,
      targetDocType: targetDocType,
      targetIdInput: targetIdInput,
      amountInput: amountInput,
      targetStatus: status as int?,
      output: output,
      rowsField: rowsField,
      targetIdField: targetIdField,
      amountField: amountField,
      amountMultiplier: amountMultiplier as int?,
      linkField: linkField,
    );
  }
}

/// Bounded scalar data contract used for operation inputs and outputs.
class OperationValueDefinition {
  const OperationValueDefinition({
    required this.type,
    required this.required,
    this.maxLength,
    this.precision,
    this.referenceTo,
  });

  final String type;
  final bool required;
  final int? maxLength;
  final int? precision;
  final String? referenceTo;

  factory OperationValueDefinition.fromJson(Map<String, dynamic> json) {
    const allowed = {
      'type',
      'required',
      'maxLength',
      'precision',
      'referenceTo',
    };
    if (json.keys.toSet().difference(allowed).isNotEmpty) {
      throw const ContractError(
        'INVALID_OPERATION',
        'Unknown operation value contract property.',
      );
    }
    final type = requireString(json, 'type');
    if (!BusinessOperationDefinition.supportedTypes.contains(type)) {
      throw const ContractError(
        'INVALID_OPERATION',
        'Unsupported operation value type.',
      );
    }
    final maxLength = json['maxLength'];
    final precision = json['precision'];
    final referenceTo = optionalString(json, 'referenceTo');
    if (maxLength != null &&
        (type != 'text' ||
            maxLength is! int ||
            maxLength < 1 ||
            maxLength > 4096)) {
      throw const ContractError('INVALID_OPERATION', 'Invalid text bound.');
    }
    if (precision != null &&
        (type != 'decimal' ||
            precision is! int ||
            precision < 0 ||
            precision > 9)) {
      throw const ContractError(
          'INVALID_OPERATION', 'Invalid decimal precision.');
    }
    if ((type == 'reference') != (referenceTo != null) ||
        (referenceTo != null && !_docTypeName.hasMatch(referenceTo))) {
      throw const ContractError(
        'INVALID_OPERATION',
        'Reference operation inputs must declare one valid target DocType.',
      );
    }
    return OperationValueDefinition(
      type: type,
      required: requireBool(json, 'required'),
      maxLength: maxLength as int?,
      precision: precision as int?,
      referenceTo: referenceTo,
    );
  }
}

final _fieldName = RegExp(r'^[a-z][A-Za-z0-9_]{0,79}$');
final _inputName = RegExp(r'^[a-z][A-Za-z0-9_]{0,79}$');
final _docTypeName = RegExp(r'^[A-Z][A-Za-z0-9_]{0,79}$');
