import 'package:flutter/widgets.dart';
import 'package:ventio_core/ventio_core.dart';

/// Owns the single message resolver shared by first-party UI and dynamic
/// extension metadata. English remains the fallback for every locale.
class VentioLocalizationController extends ChangeNotifier
    implements LocalizationProvider {
  VentioLocalizationController({EnglishCatalog? catalog})
    : catalog = catalog ?? EnglishCatalog() {
    registerEnglishFallbacks(nativeEnglishMessages);
  }

  static const nativeEnglishMessages = <String, String>{
    'native.app.title': 'Ventio Extension Builder',
  };

  static final defaultInstance = VentioLocalizationController._fallback();

  VentioLocalizationController._fallback() : catalog = EnglishCatalog() {
    registerEnglishFallbacks(nativeEnglishMessages);
  }

  final EnglishCatalog catalog;
  Locale _locale = const Locale('en');
  TextDirection _textDirection = TextDirection.ltr;

  Locale get locale => _locale;
  TextDirection get textDirection => _textDirection;

  void registerEnglishFallbacks(Map<String, String> messages) {
    for (final entry in messages.entries) {
      catalog.registerFallback(entry.key, entry.value);
    }
  }

  /// Runtime locale switching is intentionally data-only. Production UI ships
  /// English only; pseudo locales are accepted for tests and RTL readiness.
  void setDisplayLocale(Locale locale, {TextDirection? direction}) {
    if (locale.languageCode != 'en' && locale.toLanguageTag() != 'ar-XB') {
      throw ArgumentError.value(locale, 'locale', 'Unsupported display locale');
    }
    _locale = locale;
    _textDirection =
        direction ??
        (locale.toLanguageTag() == 'ar-XB'
            ? TextDirection.rtl
            : TextDirection.ltr);
    notifyListeners();
  }

  void installTestCatalog(String locale, Map<String, dynamic> messages) {
    catalog.registerTranslationCatalog(locale, messages);
  }

  void removeCatalog(String locale) {
    catalog.removeTranslationCatalog(locale);
    if (_locale.toLanguageTag() == locale) {
      _locale = const Locale('en');
      _textDirection = TextDirection.ltr;
    }
    notifyListeners();
  }

  @override
  String text(
    String key, {
    Map<String, Object?> params = const {},
    String locale = 'en',
  }) => catalog.text(
    key,
    params: params,
    locale: locale == 'en' ? _locale.toLanguageTag() : locale,
  );

  String extensionMetadataText(String key, String englishFallback) {
    catalog.registerFallback(key, englishFallback);
    return catalog.text(key, locale: _locale.toLanguageTag());
  }
}

class VentioLocalizationScope
    extends InheritedNotifier<VentioLocalizationController> {
  const VentioLocalizationScope({
    required VentioLocalizationController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static VentioLocalizationController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<VentioLocalizationScope>();
    return scope?.notifier ?? VentioLocalizationController.defaultInstance;
  }
}

extension VentioLocalizedBuildContext on BuildContext {
  String ventioText(String key, {Map<String, Object?> params = const {}}) =>
      VentioLocalizationScope.of(this).text(key, params: params);

  String extensionMetadataText(String key, String englishFallback) =>
      VentioLocalizationScope.of(
        this,
      ).extensionMetadataText(key, englishFallback);
}
