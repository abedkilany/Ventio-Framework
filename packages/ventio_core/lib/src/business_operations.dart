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
  };

  final String id;
  final int version;
  final String permission;
  final Map<String, OperationValueDefinition> inputs;
  final Map<String, OperationValueDefinition> outputs;
  final List<String> effects;

  factory BusinessOperationDefinition.fromJson(Map<String, dynamic> json) {
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

    final effects = strings(requireList(json, 'effects'), 'effects');
    if (effects.isEmpty ||
        effects.length > 8 ||
        effects.toSet().length != effects.length ||
        effects.any((effect) => !supportedEffects.contains(effect))) {
      throw const ContractError(
        'INVALID_OPERATION',
        'Operation effects must be unique supported Host effects (at most 8).',
      );
    }
    return BusinessOperationDefinition(
      id: id,
      version: version,
      permission: permission,
      inputs: values('inputs'),
      outputs: values('outputs'),
      effects: List.unmodifiable(effects),
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
  });

  final String type;
  final bool required;
  final int? maxLength;
  final int? precision;

  factory OperationValueDefinition.fromJson(Map<String, dynamic> json) {
    const allowed = {'type', 'required', 'maxLength', 'precision'};
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
    return OperationValueDefinition(
      type: type,
      required: requireBool(json, 'required'),
      maxLength: maxLength as int?,
      precision: precision as int?,
    );
  }
}
