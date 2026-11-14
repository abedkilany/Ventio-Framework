import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'private_files.dart';
import 'recovery_authority.dart';
import 'role_administration.dart';

/// Private local transport, separate from HTTP and the SQLite command queue.
/// Contains no credentials, scripts, command lines or database paths. The
/// trusted elevated runner is the only consumer and cannot be uploaded.
class WindowsOperationsDelivery {
  WindowsOperationsDelivery({
    required this.pool,
    required this.admission,
    required this.directory,
    required this.reportFailure,
  });
  final pg.Pool<dynamic> pool;
  final RecoveryAuthority admission;
  final Directory directory;
  final void Function() reportFailure;
  Timer? _timer;
  Future<void>? _active;
  DateTime? _lastFailure;
  bool _closed = false;
  void start() {
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _tick());
  }

  void _tick() {
    if (_closed || _active != null) return;
    _active = _deliver()
        .catchError((Object _) {
          final now = DateTime.now();
          if (_lastFailure == null ||
              now.difference(_lastFailure!) > const Duration(minutes: 1)) {
            _lastFailure = now;
            reportFailure();
          }
        })
        .whenComplete(() => _active = null);
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    await _active;
  }

  Future<void> _deliver() async {
    final marker = File(
      '${directory.path}${Platform.pathSeparator}delivery.json',
    );
    if (!await marker.exists())
      await PrivateFiles.create(marker.path, {'formatVersion': 1});
    await PrivateFiles.verifyPrivateFile(marker.path);
    await pool.withConnection((connection) async {
      await verifyIdentityAdministrationConnection(connection);
      await connection.execute("SET statement_timeout='15s'");
      await connection.execute("SET lock_timeout='5s'");
      // Consume completed/running outcomes first, so schedules cannot outrun
      // the durable result of a prior physical backup.
      var count = 0;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File ||
            !RegExp(r'[0-9a-f-]{36}\.result\.json$').hasMatch(entity.path))
          continue;
        if (++count > 100) break;
        final result = requireMap(
          jsonDecode(await PrivateFiles.read(entity.path)),
          'result',
        );
        final id = requireString(result, 'operationId');
        final offer = requireString(result, 'offerId');
        if (!RegExp(r'^[0-9a-f-]{36}$').hasMatch(id) ||
            !RegExp(r'^[0-9a-f-]{36}$').hasMatch(offer) ||
            entity.uri.pathSegments.last != '$id.result.json')
          throw StateError('Invalid operation result identity');
        final acknowledged = await connection.runTx((tx) async {
          await admission.admit(tx);
          final rows = await tx.execute(
            pg.Sql.named(
              'SELECT ventio_security.wave2_operation_result(@id,@offer,CAST(@result AS jsonb))',
            ),
            parameters: {
              'id': id,
              'offer': offer,
              'result': canonicalJson(result),
            },
          );
          return rows.single[0] == true;
        });
        if (acknowledged && result['state'] != 'RUNNING') {
          // The admin-only runner journal retains the physical claim. SQL
          // retains the public audit outcome. Delete only this exact spool ID.
          for (final suffix in ['request', 'claimed', 'result']) {
            final file = File(
              '${directory.path}${Platform.pathSeparator}$id.$suffix.json',
            );
            if (await file.exists()) {
              await PrivateFiles.verifyPrivateFile(file.path);
              await file.delete();
            }
          }
        }
      }
      final offers = await connection.runTx((tx) async {
        await admission.admit(tx);
        final rows = await tx.execute(
          'SELECT ventio_security.wave2_operation_offers()::text',
        );
        return jsonDecode(rows.single[0] as String) as List;
      });
      for (final raw in offers) {
        final offer = requireMap(raw, 'offer');
        final id = requireString(offer, 'operationId');
        if (!RegExp(r'^[0-9a-f-]{36}$').hasMatch(id))
          throw StateError('Invalid operation identity');
        final file = File(
          '${directory.path}${Platform.pathSeparator}$id.request.json',
        );
        if (await File(
          '${directory.path}${Platform.pathSeparator}$id.claimed.json',
        ).exists())
          continue;
        if (await file.exists())
          await PrivateFiles.replace(file.path, offer);
        else
          await PrivateFiles.create(file.path, offer);
      }
      // Expired offers never remain executable indefinitely on a quiet Host.
      // A claimed file is retained until its outcome is reconciled.
      final currentIds = offers
          .map((raw) => requireString(requireMap(raw, 'offer'), 'operationId'))
          .toSet();
      var expired = 0;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File ||
            !RegExp(r'[0-9a-f-]{36}\.request\.json$').hasMatch(entity.path))
          continue;
        final offer = requireMap(
          jsonDecode(await PrivateFiles.read(entity.path)),
          'offer',
        );
        final id = requireString(offer, 'operationId');
        if (currentIds.contains(id) ||
            !RegExp(r'^[0-9a-f-]{36}$').hasMatch(id) ||
            entity.uri.pathSegments.last != '$id.request.json')
          continue;
        if (DateTime.parse(
              requireString(offer, 'validUntilUtc'),
            ).toUtc().isBefore(DateTime.now().toUtc()) &&
            !await File(
              '${directory.path}${Platform.pathSeparator}$id.claimed.json',
            ).exists()) {
          await entity.delete();
          if (++expired >= 100) break;
        }
      }
    });
  }
}
