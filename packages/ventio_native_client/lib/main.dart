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
import 'src/account_sign_in.dart';
import 'src/host_setup_windows.dart';
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
                  const VentioText(
                    'native.ui.render_failure_title',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const VentioText(
                    'native.ui.render_failure_details',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back),
                    label: const VentioText('native.ui.return_to_workspace'),
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
  final GlobalKey<NavigatorState> _accountNavigatorKey =
      GlobalKey<NavigatorState>();
  final NavigatorObserver _navigatorObserver = _ProbeNavigatorObserver();
  late final VentioLocalizationController _localizations =
      widget.localizations ?? VentioLocalizationController();
  late bool _showHostSetup = widget.forceHostSetup;
  bool _showFirstRun = false;
  bool _startupReady = false;

  @override
  void initState() {
    super.initState();
    accountSessionInvalidated.addListener(_signOut);
    _enrollmentChanges = widget.credentialVault?.authorizationInvalidations
        .listen((_) => _signOut());
    _loadStartupState();
  }

  Future<void> _loadStartupState() async {
    VentioPerformanceProbe.event('startup.first_screen.load.begin');
    var showFirstRun = false;
    if (!widget.forceHostSetup) {
      try {
        _accountProfile = await widget.extensionStore.getHostProfile();
        showFirstRun = _accountProfile == null;
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

  void _finishHostSetup() {
    setState(() {
      _showHostSetup = false;
      _showFirstRun = false;
    });
    _loadStartupState();
  }

  HostConnectionProfile? _accountProfile;
  StreamSubscription<void>? _enrollmentChanges;
  DateTime? _signedInUntil;
  Timer? _leaseTimer;
  DateTime? _lastLeaseClock;

  void _signedIn(DateTime expiry) {
    _leaseTimer?.cancel();
    _lastLeaseClock = DateTime.now().toUtc();
    setState(() => _signedInUntil = expiry);
    _leaseTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      final now = DateTime.now().toUtc();
      if (!now.isBefore(expiry) ||
          (_lastLeaseClock != null && now.isBefore(_lastLeaseClock!))) {
        _signOut();
        return;
      }
      _lastLeaseClock = now;
      final profile = _accountProfile;
      if (profile != null) {
        final endpoint = Uri.parse(profile.endpoint);
        final cache = await widget.credentialVault?.readOfflineAccount(
          endpoint,
        );
        if (cache != null) {
          cache['lastSeen'] = now.toIso8601String();
          await widget.credentialVault?.writeOfflineAccount(endpoint, cache);
        }
      }
    });
  }

  void _signOut() {
    _leaseTimer?.cancel();
    _navigatorObserver.navigator?.popUntil((route) => route.isFirst);
    if (mounted) setState(() => _signedInUntil = null);
  }

  @override
  void dispose() {
    _leaseTimer?.cancel();
    _enrollmentChanges?.cancel();
    accountSessionInvalidated.removeListener(_signOut);
    super.dispose();
  }

  Future<void> _connectClient(BuildContext context) async {
    final vault = widget.credentialVault;
    if (vault == null) return;
    final enrolled = await _accountNavigatorKey.currentState!.push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) =>
            ClientPairingPage(store: widget.extensionStore, credentials: vault),
      ),
    );
    if (enrolled == true && mounted) {
      setState(() {
        _showFirstRun = false;
        _signedInUntil = null;
      });
      await _loadStartupState();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _localizations,
      builder: (context, child) => MaterialApp(
        navigatorKey: _accountNavigatorKey,
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
                onOwnerSetup: () => launchOwnerRecovery(),
                onConnectClient: _connectClient,
              )
            : _accountProfile != null &&
                  widget.credentialVault != null &&
                  _signedInUntil == null
            ? AccountSignInPage(
                signIn: AccountSignIn(
                  credentials: widget.credentialVault!,
                  profile: _accountProfile!,
                ),
                onSignedIn: _signedIn,
                onEnroll: () => _connectClient(context),
              )
            : ExtensionStudioPage(
                store: widget.extensionStore,
                queue: widget.queue,
                onSignOut: _signOut,
                onAccountSettings: _accountProfile == null
                    ? null
                    : () => _accountNavigatorKey.currentState!.push(
                        MaterialPageRoute<void>(
                          builder: (_) => AccountLoginSettingsPage(
                            signIn: AccountSignIn(
                              credentials: widget.credentialVault!,
                              profile: _accountProfile!,
                            ),
                          ),
                        ),
                      ),
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
