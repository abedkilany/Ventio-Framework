import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ventio_core/ventio_core.dart';

import 'src/app_localization.dart';
import 'src/app_database.dart';
import 'src/local_diagnostics.dart';
import 'src/performance_probe.dart';
import 'src/extension_store.dart';
import 'src/extension_studio_page.dart';
import 'src/client_pairing_page.dart';
import 'src/first_run_setup_page.dart';
import 'src/host_credentials.dart';
import 'src/host_setup.dart';
import 'src/host_setup_page.dart';
import 'src/local_command_queue.dart';
import 'host_credentials_flutter.dart';

Future<void> main(List<String> args) async {
  VentioPerformanceProbe.event('app.main.entered');
  WidgetsFlutterBinding.ensureInitialized();
  VentioPerformanceProbe.event('app.binding.ready');
  _installFlutterUiFailureHandling();
  final queueFuture = VentioPerformanceProbe.measure(
    'startup.command_queue.open',
    openDefaultCommandQueue,
  );
  final extensionStoreFuture = VentioPerformanceProbe.measure(
    'startup.extension_store.open',
    openDefaultExtensionStore,
  );
  final queue = await queueFuture;
  final extensionStore = await extensionStoreFuture;
  VentioPerformanceProbe.event('startup.databases.ready');
  runApp(
    VentioClientApp(
      queue: queue,
      extensionStore: extensionStore,
      credentialVault: HostCredentialVault(PlatformHostCredentialBackend()),
      forceHostSetup: args.contains('--host-setup'),
    ),
  );
}

void _installFlutterUiFailureHandling() {
  final previousHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    if (kDebugMode) {
      previousHandler?.call(details);
    }
    unawaited(_recordFlutterUiFailure(details.exception, details.stack));
  };
  ErrorWidget.builder = (_) => const _UiRenderFailureFallback();
}

Future<void> _recordFlutterUiFailure(Object error, StackTrace? stack) async {
  LocalDiagnosticsStore? store;
  try {
    store = await openDefaultLocalDiagnosticsStore();
    final type = error.runtimeType.toString().replaceAll(
      RegExp(r'[^A-Za-z0-9_.]'),
      '',
    );
    final safeType = type.isEmpty
        ? 'Unknown'
        : type.substring(0, type.length > 80 ? 80 : type.length);
    final sourceFrames = _safeUiSourceFrames(stack);
    final frameSummary = sourceFrames.isEmpty
        ? ''
        : ' App frames: ${sourceFrames.join(', ')}.';
    await store.record(
      LocalDiagnosticInput(
        code: 'UI_RENDER_FAILED',
        component: 'client.ui',
        category: ManagementDiagnosticCategory.apiExecution,
        severity: ManagementDiagnosticSeverity.error,
        retryable: true,
        messageKey: 'native.diagnostics.ui_render_failed',
        safeExplanation:
            'Ventio could not render a screen. '
            'Error type: $safeType.$frameSummary',
        recommendedAction:
            'Return to the workspace, open Local diagnostics, and share the sanitized export with its correlation reference.',
      ),
    );
  } catch (_) {
    // Diagnostics must never turn a UI failure into another app failure.
  } finally {
    try {
      await store?.close();
    } catch (_) {
      // A failed diagnostics close must not affect the workspace.
    }
  }
}

List<String> _safeUiSourceFrames(StackTrace? stack) {
  if (stack == null) return const [];
  final framePattern = RegExp(
    r'package:(ventio_native_client|ventio_core)/([A-Za-z0-9_./-]+\.dart):(\d+)(?::\d+)?',
  );
  final frames = <String>[];
  for (final line in stack.toString().split('\n')) {
    final match = framePattern.firstMatch(line);
    if (match == null) continue;
    final relativePath = match.group(2)!;
    if (relativePath.split('/').contains('..')) continue;
    final frame = '${match.group(1)}/$relativePath:${match.group(3)}';
    if (!frames.contains(frame)) frames.add(frame);
    if (frames.length == 3) break;
  }
  return List.unmodifiable(frames);
}

class _UiRenderFailureFallback extends StatelessWidget {
  const _UiRenderFailureFallback();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xfff4f8f7),
    child: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 40),
                  const SizedBox(height: 12),
                  const Text(
                    'Ventio could not display this screen.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Open Local diagnostics from the workspace and copy the sanitized export.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Return to workspace'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class VentioClientApp extends StatefulWidget {
  const VentioClientApp({
    required this.queue,
    required this.extensionStore,
    this.credentialVault,
    this.diagnosticEventSource,
    this.localizations,
    this.forceHostSetup = false,
    super.key,
  });

  final LocalCommandQueue queue;
  final LocalExtensionStore extensionStore;
  final HostCredentialVault? credentialVault;
  final DiagnosticEventSource? diagnosticEventSource;
  final VentioLocalizationController? localizations;
  final bool forceHostSetup;

  @override
  State<VentioClientApp> createState() => _VentioClientAppState();
}

class _VentioClientAppState extends State<VentioClientApp> {
  final NavigatorObserver _navigatorObserver = _ProbeNavigatorObserver();
  late final VentioLocalizationController _localizations =
      widget.localizations ?? VentioLocalizationController();
  late bool _showHostSetup = widget.forceHostSetup;
  bool _showFirstRun = false;
  bool _startupReady = false;

  @override
  void initState() {
    super.initState();
    _loadStartupState();
  }

  Future<void> _loadStartupState() async {
    VentioPerformanceProbe.event('startup.first_screen.load.begin');
    var showFirstRun = false;
    if (!widget.forceHostSetup) {
      try {
        showFirstRun = await widget.extensionStore.getHostProfile() == null;
      } on Object {
        showFirstRun = true;
      }
    }
    if (!mounted) return;
    setState(() {
      _showFirstRun = showFirstRun;
      _startupReady = true;
    });
    VentioPerformanceProbe.event('startup.first_screen.ready');
  }

  void _beginHostSetup() => setState(() {
    _showFirstRun = false;
    _showHostSetup = true;
  });

  void _finishHostSetup() => setState(() {
    _showHostSetup = false;
    _showFirstRun = false;
  });

  Future<void> _connectClient(BuildContext context) async {
    final vault = widget.credentialVault;
    if (vault == null) return;
    final enrolled = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) =>
            ClientPairingPage(store: widget.extensionStore, credentials: vault),
      ),
    );
    if (enrolled == true && mounted) {
      setState(() => _showFirstRun = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _localizations,
      builder: (context, child) => MaterialApp(
        navigatorObservers: [_navigatorObserver],
        title: _localizations.text('native.app.title'),
        locale: _localizations.locale,
        supportedLocales: const [
          Locale('en'),
          Locale('en', 'XA'),
          Locale('ar', 'XB'),
        ],
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff1f6f68)),
          useMaterial3: true,
        ),
        builder: (context, child) => VentioLocalizationScope(
          controller: _localizations,
          child: Directionality(
            textDirection: _localizations.textDirection,
            child: child!,
          ),
        ),
        home: !_startupReady
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : _showHostSetup && widget.credentialVault != null
            ? HostSetupPage(
                credentialStore: LocalHostSetupCredentialStore(
                  credentials: widget.credentialVault!,
                  store: widget.extensionStore,
                ),
                onComplete: _finishHostSetup,
              )
            : _showFirstRun
            ? FirstRunSetupPage(
                onSetUpHost: _beginHostSetup,
                onConnectClient: _connectClient,
              )
            : ExtensionStudioPage(
                store: widget.extensionStore,
                queue: widget.queue,
                credentialVault: widget.credentialVault,
                diagnosticEventSource: widget.diagnosticEventSource,
              ),
      ),
    );
  }
}

class _ProbeNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    unawaited(VentioPerformanceProbe.measureNavigation(route));
  }
}
