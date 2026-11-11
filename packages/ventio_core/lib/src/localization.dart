import 'contracts.dart';

/// The baseline requires English messages. No translation module is installed.
/// A future optional module may implement this contract to provide other locales.
abstract interface class LocalizationProvider {
  String text(String key,
      {Map<String, Object?> params = const {}, String locale = 'en'});
}

class EnglishCatalog implements LocalizationProvider {
  final Map<String, String> _messages = {};
  final Map<String, Map<String, String>> _translations = {};

  void validateCatalog(Map<String, dynamic> json) {
    // V1.2 catalogs are flat: {"module.item.label": "English label"}.
    final messages = json;
    final replacements = <String, String>{};
    for (final entry in messages.entries) {
      if (entry.value is! String) {
        throw ContractError('INVALID_CATALOG', '${entry.key} needs text');
      }
      _validateMessage(entry.key, entry.value as String);
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

  /// Registers English fallback text supplied by declarative extension
  /// metadata. Re-registering an identical fallback is harmless; a key with a
  /// different fallback is rejected to keep resolution deterministic.
  void registerFallback(String key, String englishText) {
    _validateMessage(key, englishText);
    final previous = _messages[key];
    if (previous != null && previous != englishText) {
      throw ContractError('DUPLICATE_MESSAGE_KEY', key);
    }
    _messages[key] = englishText;
  }

  /// Installs an in-memory optional catalog (for example, a test-only
  /// pseudo-localization pack). Keys must already exist in the English
  /// catalog, and interpolation placeholders must match exactly.
  void registerTranslationCatalog(String locale, Map<String, dynamic> json) {
    if (!RegExp(r'^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$').hasMatch(locale) ||
        locale == 'en') {
      throw ContractError('INVALID_LOCALE', locale);
    }
    final replacements = <String, String>{};
    for (final entry in json.entries) {
      if (entry.value is! String) {
        throw ContractError('INVALID_CATALOG', '${entry.key} needs text');
      }
      _validateMessage(entry.key, entry.value as String);
      final english = _messages[entry.key];
      if (english == null) {
        throw ContractError('UNKNOWN_TRANSLATION_KEY', entry.key);
      }
      if (!_placeholders(english)
              .containsAll(_placeholders(entry.value as String)) ||
          !_placeholders(entry.value as String)
              .containsAll(_placeholders(english))) {
        throw ContractError('INVALID_TRANSLATION_PLACEHOLDERS', entry.key);
      }
      replacements[entry.key] = entry.value as String;
    }
    _translations[locale] = Map.unmodifiable(replacements);
  }

  void removeTranslationCatalog(String locale) => _translations.remove(locale);

  Set<String> get messageKeys => Set.unmodifiable(_messages.keys);

  static Set<String> _placeholders(String value) =>
      RegExp(r'\{([a-zA-Z][a-zA-Z0-9_]*)\}')
          .allMatches(value)
          .map((match) => match.group(1)!)
          .toSet();

  void _validateMessage(String key, String value) {
    if (!RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){2,}$').hasMatch(key)) {
      throw ContractError('INVALID_MESSAGE_KEY', key);
    }
    if (value.trim().isEmpty) {
      throw ContractError('INVALID_CATALOG', '$key needs English text');
    }
  }

  bool hasKey(String key) => _messages.containsKey(key);

  @override
  String text(String key,
      {Map<String, Object?> params = const {}, String locale = 'en'}) {
    // The base framework always returns English. Unsupported locales are not
    // silently embedded in the platform: optional packs are an extension.
    var value = (locale == 'en' ? null : _translations[locale]?[key]) ??
        _messages[key] ??
        key;
    for (final entry in params.entries) {
      value = value.replaceAll('{${entry.key}}', '${entry.value}');
    }
    return value;
  }
}
