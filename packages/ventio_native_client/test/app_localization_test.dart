import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_native_client/src/app_localization.dart';

void main() {
  testWidgets('pseudo locale rebuilds UI and removal restores English', (
    tester,
  ) async {
    final controller = VentioLocalizationController()
      ..registerEnglishFallbacks({'native.sample.greeting': 'Hello {name}'});

    Widget app() => MaterialApp(
      home: VentioLocalizationScope(
        controller: controller,
        child: const VentioText(
          'native.sample.greeting',
          params: {'name': 'Ventio'},
        ),
      ),
    );

    await tester.pumpWidget(app());
    expect(find.text('Hello Ventio'), findsOneWidget);

    controller.installTestCatalog('en-XA', {
      'native.sample.greeting': '[Hëllö {name}]',
    });
    controller.setDisplayLocale(const Locale('en', 'XA'));
    await tester.pump();
    expect(find.text('[Hëllö Ventio]'), findsOneWidget);

    controller.removeCatalog('en-XA');
    await tester.pump();
    expect(find.text('Hello Ventio'), findsOneWidget);
    expect(
      tester.widget<Directionality>(find.byType(Directionality)).textDirection,
      TextDirection.ltr,
    );
  });

  testWidgets('test RTL locale changes layout direction only', (tester) async {
    final controller = VentioLocalizationController()
      ..registerEnglishFallbacks({'native.sample.title': 'Inventory'});
    await tester.pumpWidget(
      MaterialApp(
        home: VentioLocalizationScope(
          controller: controller,
          child: Builder(
            builder: (context) => Directionality(
              textDirection: controller.textDirection,
              child: Text(context.ventioText('native.sample.title')),
            ),
          ),
        ),
      ),
    );
    controller.setDisplayLocale(
      const Locale('ar', 'XB'),
      direction: TextDirection.rtl,
    );
    await tester.pump();
    expect(find.text('Inventory'), findsOneWidget);
    expect(
      tester
          .widget<Directionality>(find.byType(Directionality).last)
          .textDirection,
      TextDirection.rtl,
    );
  });
}
