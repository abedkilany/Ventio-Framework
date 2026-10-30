import 'package:flutter/material.dart';

import 'src/app_localization.dart';
import 'src/app_database.dart';
import 'src/extension_store.dart';
import 'src/extension_studio_page.dart';
import 'src/host_credentials.dart';
import 'src/host_setup.dart';
import 'src/host_setup_page.dart';
import 'src/local_command_queue.dart';
import 'host_credentials_flutter.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final queue = await openDefaultCommandQueue();
  final extensionStore = await openDefaultExtensionStore();
  runApp(
    VentioClientApp(
      queue: queue,
      extensionStore: extensionStore,
      credentialVault: HostCredentialVault(PlatformHostCredentialBackend()),
      forceHostSetup: args.contains('--host-setup'),
    ),
  );
}

class VentioClientApp extends StatefulWidget {
  const VentioClientApp({
    required this.queue,
    required this.extensionStore,
    this.credentialVault,
    this.localizations,
    this.forceHostSetup = false,
    super.key,
  });

  final LocalCommandQueue queue;
  final LocalExtensionStore extensionStore;
  final HostCredentialVault? credentialVault;
  final VentioLocalizationController? localizations;
  final bool forceHostSetup;

  @override
  State<VentioClientApp> createState() => _VentioClientAppState();
}

class _VentioClientAppState extends State<VentioClientApp> {
  late final VentioLocalizationController _localizations =
      widget.localizations ?? VentioLocalizationController();
  late bool _showHostSetup = widget.forceHostSetup;

  void _finishHostSetup() => setState(() => _showHostSetup = false);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _localizations,
      builder: (context, child) => MaterialApp(
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
        home: _showHostSetup && widget.credentialVault != null
            ? HostSetupPage(
                credentialStore: LocalHostSetupCredentialStore(
                  credentials: widget.credentialVault!,
                  store: widget.extensionStore,
                ),
                onComplete: _finishHostSetup,
              )
            : ExtensionStudioPage(
                store: widget.extensionStore,
                queue: widget.queue,
                credentialVault: widget.credentialVault,
              ),
      ),
    );
  }
}
