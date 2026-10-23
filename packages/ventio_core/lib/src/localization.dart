import 'contracts.dart';

/// The baseline requires English messages. No translation module is installed.
/// A future optional module may implement this contract to provide other locales.
abstract interface class LocalizationProvider {
  String text(String key,
      {Map<String, Object?> params = const {}, String locale = 'en'});
}

class EnglishCatalog implements LocalizationProvider {
  final Map<String, String> _messages = {};

  void validateCatalog(Map<String, dynamic> json) {
    // V1.2 catalogs are flat: {"module.item.label": "English label"}.
    final messages = json;
    final replacements = <String, String>{};
    for (final entry in messages.entries) {
      if (!RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){2,}$')
          .hasMatch(entry.key)) {
        throw ContractError('INVALID_MESSAGE_KEY', entry.key);
      }
      if (entry.value is! String || (entry.value as String).trim().isEmpty) {
        throw ContractError(
            'INVALID_CATALOG', '${entry.key} needs English text');
      }
      if (_messages.containsKey(entry.key) ||
          replacements.containsKey(entry.key)) {
        throw ContractError('DUPLICATE_MESSAGE_KEY', entry.key);
      }
      replacements[entry.key] = entry.value as String;
    }
  }

  void registerCatalog(Map<String, dynamic> json) {
    validateCatalog(json);
    _messages.addAll(json.cast<String, String>());
  }

  bool hasKey(String key) => _messages.containsKey(key);

  @override
  String text(String key,
      {Map<String, Object?> params = const {}, String locale = 'en'}) {
    // The base framework always returns English. Unsupported locales are not
    // silently embedded in the platform: optional packs are an extension.
    var value = _messages[key] ?? key;
    for (final entry in params.entries) {
      value = value.replaceAll('{${entry.key}}', '${entry.value}');
    }
    return value;
  }
}
