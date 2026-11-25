import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_native_client/src/first_run_setup_page.dart';

void main() {
  for (final role in ['host', 'client']) {
    testWidgets('Select $role and continue', (tester) async {
      var hostCalls = 0;
      var clientCalls = 0;

      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;

      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: FirstRunSetupPage(
            onSetUpHost: () => hostCalls++,
            onConnectClient: (_) => clientCalls++,
          ),
        ),
      );

      await tester.pumpAndSettle();

      final continueButton = find.byKey(
        const ValueKey('native.ui.first_run_continue'),
      );

      expect(find.text('Set Device Role'), findsOneWidget);
      expect(find.text('Host'), findsOneWidget);
      expect(find.text('Client'), findsOneWidget);

      expect(tester.widget<FilledButton>(continueButton).onPressed, isNull);

      await tester.tap(find.byKey(ValueKey('role-$role')));
      await tester.pumpAndSettle();

      expect(hostCalls, 0);
      expect(clientCalls, 0);

      await tester.ensureVisible(continueButton);
      await tester.tap(continueButton);
      await tester.pumpAndSettle();

      expect(hostCalls, role == 'host' ? 1 : 0);
      expect(clientCalls, role == 'client' ? 1 : 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Owner recovery remains available', (tester) async {
    var recoveryCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: FirstRunSetupPage(
          onSetUpHost: () {},
          onConnectClient: (_) {},
          onOwnerSetup: () => recoveryCalls++,
        ),
      ),
    );

    await tester.pumpAndSettle();
    final recoveryButton = find.byType(TextButton);

    await tester.ensureVisible(recoveryButton);
    await tester.tap(recoveryButton);
    await tester.pumpAndSettle();

    expect(recoveryCalls, 1);
    expect(tester.takeException(), isNull);
  });
}
