import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;

import 'authentication.dart';
import 'private_files.dart';

/// A latest-state witness kept OUTSIDE the database and its backup/rollback domain.
/// Its directory and update authority are trusted operator infrastructure. A copy
/// stored/restored with PostgreSQL is not an independent recovery authority.
class RecoveryAuthority {
  final String path;
  final int? trustedOwnerUid;
  final int? readerGroupId;
  final String? trustedOwnerSid;
  final String? readerSid;
  final FutureOr<void> Function(String)? testBarrier;
  static final Map<String, Future<void>> _tails = {};
  RecoveryAuthority(
    this.path, {
    this.testBarrier,
    this.trustedOwnerUid,
    this.readerGroupId,
    this.trustedOwnerSid,
    this.readerSid,
  }) {
    if (trustedOwnerSid != null && readerSid == null) {
      throw ArgumentError(
        'Windows recovery authority needs both trusted owner and reader SIDs.',
      );
    }
    if (trustedOwnerSid != null &&
        (trustedOwnerUid != null || readerGroupId != null)) {
      throw ArgumentError('Linux IDs and Windows SIDs cannot be combined.');
    }
    if (readerSid != null && readerGroupId != null) {
      throw ArgumentError(
        'Linux reader groups and Windows reader SIDs cannot be combined.',
      );
    }
  }

  Future<String> _readFile() =>
      trustedOwnerUid != null ||
          readerGroupId != null ||
          trustedOwnerSid != null ||
          readerSid != null
      ? PrivateFiles.readAuthority(
          path,
          trustedOwnerUid: trustedOwnerUid,
          trustedOwnerSid: trustedOwnerSid,
          readerSid: readerSid,
        )
      : PrivateFiles.read(path);
  Future<void> _create(Map<String, dynamic> value) => readerGroupId != null
      ? PrivateFiles.createAuthority(path, value, readerGroupId!)
      : readerSid != null
      ? PrivateFiles.createAuthority(path, value, -1, readerSid: readerSid)
      : PrivateFiles.create(path, value);
  Future<void> _replace(Map<String, dynamic> value) => readerGroupId != null
      ? PrivateFiles.replaceAuthority(path, value, readerGroupId!)
      : readerSid != null
      ? PrivateFiles.replaceAuthority(path, value, -1, readerSid: readerSid)
      : PrivateFiles.replace(path, value);

  Future<Map<String, dynamic>> _read() async {
    final data = jsonDecode(await _readFile()) as Map<String, dynamic>;
    if (data['authorityId'] is! String ||
        !OpaqueToken.isValid(data['authorityId'] as String) ||
        data['version'] != 1 ||
        data['pending'] != false ||
        data['fingerprint'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(data['fingerprint'] as String)) {
      throw StateError('Recovery admission is quarantined');
    }
    return data;
  }

  Future<void> admit(pg.TxSession tx) async {
    final state = await _read();
    await _admitState(tx, state);
  }

  Future<void> _admitState(pg.TxSession tx, Map<String, dynamic> state) async {
    await tx.execute(
      pg.Sql.named('SELECT ventio_security.admit_recovery(@proof,@authority)'),
      parameters: {
        'proof': state['fingerprint'],
        'authority': state['authorityId'],
      },
    );
  }

  static Future<String> snapshot(pg.Session session) async =>
      (await session.execute(
            'SELECT ventio_security.recovery_snapshot()',
          )).single[0]
          as String;

  Future<T> _exclusive<T>(Future<T> Function() body) async {
    final previous = _tails[path] ?? Future<void>.value();
    final release = Completer<void>();
    _tails[path] = release.future;
    await previous;
    RandomAccessFile? lock;
    try {
      if (trustedOwnerUid != null || trustedOwnerSid != null)
        throw StateError('Read-only Host cannot administer authority');
      final lockPath = '$path.lock';
      try {
        if (readerGroupId == null && readerSid == null) {
          await PrivateFiles.create(lockPath, {'lock': 1});
        } else {
          await PrivateFiles.createAuthority(
            lockPath,
            {'lock': 1},
            readerGroupId ?? -1,
            lock: true,
            readerSid: readerSid,
          );
        }
      } catch (createError, createStack) {
        try {
          if (readerGroupId == null && readerSid == null) {
            await PrivateFiles.read(lockPath);
          } else {
            await PrivateFiles.readAuthority(lockPath, readerSid: readerSid);
          }
        } catch (_) {
          Error.throwWithStackTrace(createError, createStack);
        }
      }
      // OS lock serializes independent administration processes; the queue above
      // also serializes separate authority objects in this Dart process.
      lock = await File(lockPath).open(mode: FileMode.append);
      await lock.lock(FileLock.blockingExclusive);
      return await body();
    } finally {
      if (lock != null) {
        await lock.unlock();
        await lock.close();
      }
      release.complete();
      if (identical(_tails[path], release.future)) _tails.remove(path);
    }
  }

  /// Missing or mismatched evidence is NEVER automatically adopted. The only
  /// bootstrap/recovery path irreversibly retires every credential/device and
  /// clears every grant before a new authority generation can become ready.
  Future<void> resetForReenrollment(pg.Connection db, String operatorLabel) =>
      _exclusive(() async {
        final authority = OpaqueToken.generate();
        final state = <String, dynamic>{
          'version': 1,
          'pending': true,
          'authorityId': authority,
        };
        if (await FileSystemEntity.type(path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          await _create(state);
        } else {
          await _replace(state);
        }
        await testBarrier?.call('before_database');
        final fingerprint = await db.runTx((tx) async {
          await tx.execute(
            pg.Sql.named('SELECT ventio_security.reset_recovery(@id,@label)'),
            parameters: {'id': authority, 'label': operatorLabel},
          );
          await testBarrier?.call('before_commit');
          return snapshot(tx);
        });
        await testBarrier?.call('after_commit');
        await _replace({
          ...state,
          'pending': false,
          'fingerprint': fingerprint,
        });
      });

  /// Mark external evidence pending and fsync BEFORE changing PostgreSQL. A
  /// crash/unknown commit/witness write failure leaves admission closed. There
  /// is no unsafe "repair witness from whichever DB was restored" fallback.
  Future<void> change(
    pg.Connection db,
    Future<void> Function(pg.TxSession) action, {
    bool requireAdmissionProof = false,
  }) => _exclusive(() async {
    final state = await _read();
    // Validate under the SAME exclusive DB lock as the mutation. Another
    // admin process using raw RPCs cannot slip a stale change in between.
    await _replace({...state, 'pending': true});
    await testBarrier?.call('before_database');
    var rejectedBeforeCommit = false;
    late String fingerprint;
    try {
      fingerprint = await db.runTx((tx) async {
        await tx.execute('SELECT pg_advisory_xact_lock(86744321)');
        if (await snapshot(tx) != state['fingerprint']) {
          throw StateError('Recovery evidence does not match database');
        }
        if (requireAdmissionProof) await _admitState(tx, state);
        try {
          await action(tx);
        } on pg.ServerException {
          rejectedBeforeCommit = true;
          rethrow;
        }
        await testBarrier?.call('before_commit');
        return snapshot(tx);
      });
    } catch (_) {
      if (rejectedBeforeCommit) {
        // No COMMIT was sent: restore ready evidence only when the exact
        // previously trusted state is still present after rollback.
        final unchanged = await db.runTx((tx) async {
          await tx.execute('SELECT pg_advisory_xact_lock(86744321)');
          return await snapshot(tx) == state['fingerprint'];
        });
        if (unchanged) await _replace(state);
      }
      rethrow;
    }
    await testBarrier?.call('after_commit');
    await _replace({...state, 'pending': false, 'fingerprint': fingerprint});
  });
}
