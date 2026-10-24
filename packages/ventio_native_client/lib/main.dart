import 'package:flutter/material.dart';

import 'src/app_database.dart';
import 'src/local_command_queue.dart';
import 'src/maintenance_request_page.dart';
import 'src/transport_fixture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final queue = await openDefaultCommandQueue();
  runApp(VentioClientApp(queue: queue));
}

class VentioClientApp extends StatelessWidget {
  const VentioClientApp({required this.queue, super.key});

  final LocalCommandQueue queue;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ventio Native Client Proof',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff1f6f68)),
        useMaterial3: true,
      ),
      home: MaintenanceRequestPage(
        queue: queue,
        transport: const DeterministicTransportFixture(),
      ),
    );
  }
}
