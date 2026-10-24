import 'package:flutter/material.dart';

import 'src/app_database.dart';
import 'src/extension_store.dart';
import 'src/extension_studio_page.dart';
import 'src/local_command_queue.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final queue = await openDefaultCommandQueue();
  final extensionStore = await openDefaultExtensionStore();
  runApp(VentioClientApp(queue: queue, extensionStore: extensionStore));
}

class VentioClientApp extends StatelessWidget {
  const VentioClientApp({
    required this.queue,
    required this.extensionStore,
    super.key,
  });

  final LocalCommandQueue queue;
  final LocalExtensionStore extensionStore;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ventio Extension Builder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff1f6f68)),
        useMaterial3: true,
      ),
      home: ExtensionStudioPage(store: extensionStore, queue: queue),
    );
  }
}
