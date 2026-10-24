import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/ventio_native_client.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) exit(64);
  sqfliteFfiInit();
  final envelope = CommandEnvelope.fromJson(
    jsonDecode(args[1]) as Map<String, dynamic>,
  );
  final queue = await LocalCommandQueue.open(
    factory: databaseFactoryFfi,
    path: args[0],
  );
  await queue.enqueue(envelope);
  await queue.recordAttempt(envelope.commandId);

  // Exit the process without closing the database or completing a response.
  exit(73);
}
