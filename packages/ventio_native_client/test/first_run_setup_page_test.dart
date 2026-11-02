import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_native_client/src/first_run_setup_page.dart';

void main() {
  testWidgets('offers Host setup and existing Host connection choices', (
    tester,
  ) async {
    var hostSelected = false;
    var clientSelected = false;
    await tester.pumpWidget(
      MaterialApp(
        home: FirstRunSetupPage(
          onSetUpHost: () => hostSelected = true,
          onConnectClient: (_) => clientSelected = true,
        ),
      ),
    );

    expect(find.text('Set up this device as Host'), findsOneWidget);
    expect(
      find.text('Connect this device to an existing Host'),
      findsOneWidget,
    );
    expect(hostSelected, isFalse);
    expect(clientSelected, isFalse);

    await tester.tap(
      find.byKey(const ValueKey('native.ui.first_run_continue')),
    );
    await tester.pump();
    expect(hostSelected, isTrue);

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('native.ui.first_run_connect')));
    await tester.pump();
    expect(clientSelected, isTrue);
  });
}
