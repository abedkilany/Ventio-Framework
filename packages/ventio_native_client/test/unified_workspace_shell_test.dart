import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_native_client/src/unified_workspace_shell.dart';

class _MemoryPreferences implements VentioSidebarPreferences {
  final values = <String, bool>{};

  @override
  Future<bool> load(String scope) async => values[scope] ?? false;

  @override
  Future<void> save(String scope, bool pinned) async {
    values[scope] = pinned;
  }
}

Future<void> _openNavigation(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('workspace-open-navigation')));
  await tester.pumpAndSettle();
}

Widget _app({
  bool admin = true,
  VoidCallback? onSignOut,
  String? scope,
  VentioSidebarPreferences? preferences,
}) => MaterialApp(
  home: VentioWorkspaceShell(
    sidebarPreferenceScope: scope,
    sidebarPreferences: preferences ?? _MemoryPreferences(),
    connectionLabel: 'Last session verified',
    connectionIcon: Icons.cloud_done_outlined,
    onRefresh: () {},
    onSignOut: onSignOut,
    sections: [
      VentioWorkspaceSection(
        id: 'home',
        label: 'Home',
        icon: Icons.home_outlined,
        builder: (_) => const Text('Home content'),
      ),
      VentioWorkspaceSection(
        id: 'applications',
        label: 'Applications',
        icon: Icons.apps_outlined,
        builder: (_) => const Text('Application content'),
      ),
      if (admin)
        VentioWorkspaceSection(
          id: 'administration',
          label: 'Administration',
          icon: Icons.admin_panel_settings_outlined,
          builder: (_) => const Text('Admin content'),
        ),
    ],
  ),
);

void main() {
  testWidgets('desktop auto-hide, pin, permission removal and sign out', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var signedOut = false;
    await tester.pumpWidget(_app(onSignOut: () => signedOut = true));
    expect(find.text('Home content'), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-nav-home')), findsNothing);
    await _openNavigation(tester);
    await tester.tap(find.byKey(const ValueKey('workspace-nav-applications')));
    await tester.pumpAndSettle();
    expect(find.text('Application content'), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-nav-home')), findsNothing);
    await _openNavigation(tester);
    await tester.tap(find.byKey(const ValueKey('workspace-pin-sidebar')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Unpin sidebar (auto-hide)'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('workspace-nav-administration')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Admin content'), findsOneWidget);
    await tester.pumpWidget(
      _app(admin: false, onSignOut: () => signedOut = true),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('workspace-nav-administration')),
      findsNothing,
    );
    expect(find.text('Home content'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workspace-account-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(signedOut, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow window navigates using drawer without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_app(admin: false));
    await tester.tap(find.byKey(const ValueKey('workspace-open-navigation')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-nav-applications')));
    await tester.pumpAndSettle();
    expect(find.text('Application content'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('workspace-nav-administration')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'detail stays in shell and section switching asks before leaving',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          home: VentioWorkspaceShell(
            navigatorKey: navigator,
            connectionLabel: 'Online · last check',
            connectionIcon: Icons.cloud_done_outlined,
            onRefresh: () {},
            sections: [
              VentioWorkspaceSection(
                id: 'home',
                label: 'Home',
                icon: Icons.home_outlined,
                builder: (_) => const Text('Home root'),
              ),
              VentioWorkspaceSection(
                id: 'applications',
                label: 'Applications',
                icon: Icons.apps_outlined,
                builder: (_) => const Text('Applications root'),
              ),
            ],
          ),
        ),
      );
      navigator.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('Record detail')),
            body: const Text('Detail content'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Detail content'), findsOneWidget);
      await _openNavigation(tester);
      expect(find.byKey(const ValueKey('workspace-nav-home')), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('workspace-nav-applications')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Leave current page?'), findsOneWidget);
      await tester.tap(find.text('Stay'));
      await tester.pumpAndSettle();
      expect(find.text('Detail content'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('workspace-nav-applications')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave page'));
      await tester.pumpAndSettle();
      expect(find.text('Applications root'), findsOneWidget);
      expect(find.text('Detail content'), findsNothing);
      expect(navigator.currentState!.canPop(), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('removing an administration section closes its nested page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final navigator = GlobalKey<NavigatorState>();
    Widget app(bool allowed) => MaterialApp(
      home: VentioWorkspaceShell(
        navigatorKey: navigator,
        connectionLabel: 'Online · last check',
        connectionIcon: Icons.cloud_done_outlined,
        authorizationRevision: allowed ? 'allowed' : 'denied',
        onRefresh: () {},
        sections: [
          VentioWorkspaceSection(
            id: 'home',
            label: 'Home',
            icon: Icons.home_outlined,
            builder: (_) => const Text('Home root'),
          ),
          if (allowed)
            VentioWorkspaceSection(
              id: 'administration',
              label: 'Administration',
              icon: Icons.admin_panel_settings_outlined,
              builder: (_) => const Text('Administration root'),
            ),
        ],
      ),
    );
    await tester.pumpWidget(app(true));
    await _openNavigation(tester);
    await tester.tap(
      find.byKey(const ValueKey('workspace-nav-administration')),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Protected detail')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Protected detail'), findsOneWidget);
    await tester.pumpWidget(app(false));
    await tester.pumpAndSettle();
    expect(find.text('Protected detail'), findsNothing);
    expect(find.text('Home root'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'groups collapse, shortcuts open within shell and resize preserves route',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            home: VentioWorkspaceShell(
              navigatorKey: navigator,
              connectionLabel: 'Online · last check',
              connectionIcon: Icons.cloud_done_outlined,
              onRefresh: () {},
              sections: [
                VentioWorkspaceSection(
                  id: 'home',
                  label: 'Home',
                  icon: Icons.home_outlined,
                  builder: (_) => const Text('Home root'),
                ),
                VentioWorkspaceSection(
                  id: 'administration',
                  label: 'Administration',
                  icon: Icons.admin_panel_settings_outlined,
                  builder: (_) => const Text('Administration root'),
                ),
                VentioWorkspaceSection(
                  id: 'users',
                  label: 'Users',
                  icon: Icons.people_outline,
                  parentId: 'administration',
                  builder: (_) => const SizedBox.shrink(),
                  onOpen: () {
                    navigator.currentState!.push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            const Scaffold(body: Text('User detail')),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
        await _openNavigation(tester);
        expect(find.byKey(const ValueKey('workspace-nav-users')), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('workspace-group-administration')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('workspace-nav-users')));
        await tester.pumpAndSettle();
        expect(find.text('User detail'), findsOneWidget);
        tester.view.physicalSize = const Size(600, 800);
        await tester.pumpAndSettle();
        expect(find.text('User detail'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('workspace-open-navigation')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'hover reveals overlay without resizing content and hides on exit',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_app());
      final main = find.byKey(const ValueKey('ventio-workspace-main'));
      final initial = tester.getSize(main);
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(600, 400));
      try {
        await mouse.moveTo(const Offset(3, 160));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('workspace-nav-home')),
          findsOneWidget,
        );
        expect(tester.getSize(main), initial);
        final pageHeader = find.byKey(const ValueKey('workspace-page-header'));
        final sidebarHeader = find.byKey(
          const ValueKey('workspace-sidebar-header'),
        );
        expect(
          tester.getTopLeft(pageHeader).dy,
          tester.getTopLeft(sidebarHeader).dy,
        );
        expect(
          tester.getSize(pageHeader).height,
          tester.getSize(sidebarHeader).height,
        );
        await mouse.moveTo(const Offset(100, 160));
        await tester.pump();
        await mouse.moveTo(const Offset(600, 400));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('workspace-nav-home')), findsNothing);
        expect(tester.getSize(main), initial);
      } finally {
        await mouse.removePointer();
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pin preference is scoped and restored; keyboard opens and closes overlay',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final preferences = _MemoryPreferences();
      Widget app(String scope) => _app(scope: scope, preferences: preferences);
      await tester.pumpWidget(app('one'));
      await tester.pumpAndSettle();
      await _openNavigation(tester);
      await tester.tap(find.byKey(const ValueKey('workspace-pin-sidebar')));
      await tester.pumpAndSettle();
      expect(preferences.values['one'], isTrue);
      expect(
        find.byKey(const ValueKey('workspace-open-navigation')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(app('one'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Unpin sidebar (auto-hide)'), findsOneWidget);
      await tester.pumpWidget(app('two'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('workspace-nav-home')), findsNothing);
      await tester.pumpWidget(app('one'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Unpin sidebar (auto-hide)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('workspace-pin-sidebar')));
      await tester.pumpAndSettle();
      expect(preferences.values['one'], isFalse);
      expect(find.byKey(const ValueKey('workspace-nav-home')), findsNothing);
      // Focus the menu, then exercise the same shortcut available to desktop users.
      final menu = tester.widget<IconButton>(
        find.byKey(const ValueKey('workspace-open-navigation')),
      );
      menu.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('workspace-nav-home')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('workspace-nav-home')), findsNothing);
      await tester.pumpWidget(app('two'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('workspace-nav-home')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
