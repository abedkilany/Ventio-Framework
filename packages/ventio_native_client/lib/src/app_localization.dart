import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:ventio_core/ventio_core.dart';

import 'native_english_messages.dart';

/// Owns the single message resolver shared by first-party UI and dynamic
/// extension metadata. English remains the fallback for every locale.
class VentioLocalizationController extends ChangeNotifier
    implements LocalizationProvider {
  VentioLocalizationController({EnglishCatalog? catalog})
    : catalog = catalog ?? EnglishCatalog() {
    registerEnglishFallbacks(ventioNativeEnglishMessages);
  }

  static final defaultInstance = VentioLocalizationController._fallback();

  VentioLocalizationController._fallback() : catalog = EnglishCatalog() {
    registerEnglishFallbacks(ventioNativeEnglishMessages);
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
    // Custom labels belong to a separately versioned overlay. Keep previous
    // renderings and immutable base-package catalog entries deterministic when
    // a customization owner changes a label during the same application run.
    if (key.startsWith('extension.') && key.contains('.custom.')) {
      key = '$key.v_${sha256.convert(utf8.encode(englishFallback))}';
    }
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

/// Catalog-backed drop-in text widgets. Keeping these constructors const lets
/// existing immutable widget trees stay const while their rendered message
/// resolves through the active provider at build time.
class VentioText extends StatelessWidget {
  const VentioText(
    this.keyName, {
    this.params = const {},
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    super.key,
  });

  final String keyName;
  final Map<String, Object?> params;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;

  @override
  Widget build(BuildContext context) => Text(
    context.ventioText(keyName, params: params),
    style: style,
    strutStyle: strutStyle,
    textAlign: textAlign,
    textDirection: textDirection,
    locale: locale,
    softWrap: softWrap,
    overflow: overflow,
    textScaler: textScaler,
    maxLines: maxLines,
    semanticsLabel: semanticsLabel,
    textWidthBasis: textWidthBasis,
    textHeightBehavior: textHeightBehavior,
    key: key,
  );
}
