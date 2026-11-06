import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;

import 'authentication.dart';
import 'private_files.dart';

/// Bounded, non-sensitive timings for one recovery-admitted mutation.
/// Durations may be included in protected diagnostics; witness contents and
/// database fingerprints are deliberately absent.
class RecoveryMutationTimings {
  int authorityLockAcquisitionMs = 0;
  int authorityQueueWaitMs = 0;
  int authorityLockFileSetupMs = 0;
  int authorityOsLockWaitMs = 0;
  int witnessReadMs = 0;
  int witnessPendingWriteMs = 0;
  int databaseAdvisoryLockMs = 0;
  int databaseFingerprintBeforeMs = 0;
  int databaseMutationMs = 0;
  int databaseFingerprintAfterMs = 0;
  int databaseTransactionMs = 0;
  int witnessFinalizeMs = 0;

  /// Residual transaction time not attributed to the measured queries. The
  /// PostgreSQL driver does not expose a separate COMMIT round-trip timer.
  int get databaseTransactionResidualMs {
    final measured =
        databaseAdvisoryLockMs +
        databaseFingerprintBeforeMs +
        databaseMutationMs +
        databaseFingerprintAfterMs;
    return (databaseTransactionMs - measured).clamp(0, 1 << 31);
  }

  String toSafeSummary() =>
      'authority_lock_acquisition=${authorityLockAcquisitionMs}ms, '
      'authority_queue_wait=${authorityQueueWaitMs}ms, '
      'authority_lockfile_setup=${authorityLockFileSetupMs}ms, '
      'authority_os_lock_wait=${authorityOsLockWaitMs}ms, '
      'witness_read=${witnessReadMs}ms, '
      'witness_pending_write=${witnessPendingWriteMs}ms, '
      'db_lock=${databaseAdvisoryLockMs}ms, '
      'db_fingerprint_before=${databaseFingerprintBeforeMs}ms, '
      'db_mutation=${databaseMutationMs}ms, '
      'db_fingerprint_after=${databaseFingerprintAfterMs}ms, '
      'db_transaction_residual=${databaseTransactionResidualMs}ms, '
      'witness_finalize=${witnessFinalizeMs}ms';
}

/// PostgreSQL may have committed, but the caller could not confirm the result
/// or finalize the independent witness. Recovery admission remains fail-closed.
class RecoveryMutationOutcomeUnknown implements Exception {
  const RecoveryMutationOutcomeUnknown(this.timings);

  final RecoveryMutationTimings timings;
}

/// Recovery admission failed before the mutation commit was attempted.
class RecoveryAdmissionUnavailable implements Exception {
  const RecoveryAdmissionUnavailable();
}

/// The bounded Recovery Authority serialization window was exhausted.
class RecoveryAuthorityBusy implements Exception {
  const RecoveryAuthorityBusy();
}

/// A latest-state witness kept OUTSIDE the database and its backup/rollback domain.
/// Its directory and update authority are trusted operator infrastructure. A copy
/// stored/restored with PostgreSQL is not an independent recovery authority.
class RecoveryAuthority {
  final String path;
  final int? trustedOwnerUid;
  final int? readerGroupId;
  final String? trustedOwnerSid;
  final String? readerSid;
  final bool allowHostMutations;
  final FutureOr<void> Function(String)? testBarrier;
  static final Map<String, Future<void>> _tails = {};
  RecoveryAuthority(
    this.path, {
    this.testBarrier,
    this.trustedOwnerUid,
    this.readerGroupId,
    this.trustedOwnerSid,
    this.readerSid,
    this.allowHostMutations = false,
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
    if (allowHostMutations &&
        trustedOwnerUid == null &&
        trustedOwnerSid == null) {
      throw ArgumentError(
        'Host witness writes require a pinned recovery-authority owner.',
      );
    }
  }

  Future<String> _readFile() {
    if (allowHostMutations) {
      return PrivateFiles.readAuthorityAsOwner(
        path,
        trustedOwnerUid: trustedOwnerUid,
        readerGroupId: readerGroupId,
        trustedOwnerSid: trustedOwnerSid,
        readerSid: readerSid,
      );
    }
    return trustedOwnerUid != null ||
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
  }

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

  Future<Map<String, dynamic>> _readStoredState() async {
    final data = jsonDecode(await _readFile()) as Map<String, dynamic>;
    if (data['authorityId'] is! String ||
        !OpaqueToken.isValid(data['authorityId'] as String) ||
        data['version'] != 1 ||
        data['pending'] is! bool ||
        (data['fingerprint'] != null &&
            (data['fingerprint'] is! String ||
                !RegExp(
                  r'^[0-9a-f]{64}$',
                ).hasMatch(data['fingerprint'] as String)))) {
      throw StateError('Recovery admission is quarantined');
    }
    final upgrade = data['schemaUpgrade'];
    if (upgrade != null &&
        (upgrade is! Map<String, dynamic> ||
            upgrade.length != 6 ||
            upgrade['operationId'] is! String ||
            !RegExp(
              r'^upgrade_[0-9a-f]{32}$',
            ).hasMatch(upgrade['operationId'] as String) ||
            upgrade['preparedTransactionId'] is! String ||
            upgrade['preparedTransactionId'] !=
                _schemaUpgradeTransactionId(upgrade['operationId'] as String) ||
            upgrade['priorFingerprint'] is! String ||
            !RegExp(
              r'^[0-9a-f]{64}$',
            ).hasMatch(upgrade['priorFingerprint'] as String) ||
            upgrade['migrationManifestSha256'] is! String ||
            !RegExp(
              r'^[0-9a-f]{64}$',
            ).hasMatch(upgrade['migrationManifestSha256'] as String) ||
            upgrade['phase'] is! String ||
            !{'prepared', 'commit_authorized'}.contains(upgrade['phase']) ||
            upgrade['formatVersion'] != 1 ||
            data['pending'] != true)) {
      throw StateError('Recovery admission is quarantined');
    }
    return data;
  }

  static String _schemaUpgradeTransactionId(String operationId) =>
      'ventio_$operationId';

  Future<Map<String, dynamic>> _read() async {
    final data = await _readStoredState();
    if (data['pending'] != false || data['fingerprint'] is! String) {
      throw StateError('Recovery admission is quarantined');
    }
    return data;
  }

  /// Initializes or safely resumes first-install recovery for the Host service.
  /// A pending first-admin change is reconciled only when the database still
  /// matches the prior witness or contains the exact receipt-backed bootstrap.
  Future<void> prepareFirstAdministratorBootstrap(
    pg.Connection db, {
    required String requestId,
    required String tenantId,
    required String actorId,
    required String companyId,
    required String branchId,
    required String deviceId,
    required String credentialId,
    required String token,
    required DateTime expiresAt,
  }) => _exclusive(() async {
    if (!OpaqueToken.isValid(requestId) ||
        !OpaqueToken.isValid(token) ||
        requestId.isEmpty) {
      throw ArgumentError('First administrator receipt is invalid');
    }
    final fileType = await FileSystemEntity.type(path, followLinks: false);
    if (fileType == FileSystemEntityType.notFound) {
      final state = <String, dynamic>{
        'version': 1,
        'pending': true,
        'authorityId': OpaqueToken.generate(),
      };
      await _create(state);
      await _initializeFirstHostRecovery(db, state);
      return;
    }
    if (fileType != FileSystemEntityType.file) {
      throw StateError('Recovery authority path is not a regular file');
    }
    final state = await _readStoredState();
    if (state['pending'] == false) return;
    if (state['fingerprint'] == null) {
      await _initializeFirstHostRecovery(db, state);
      return;
    }
    final currentFingerprint = await db.runTx(_snapshotInTransaction);
    if (currentFingerprint == state['fingerprint']) {
      await _replace({...state, 'pending': false});
      return;
    }
    final reconciledFingerprint = await db.runTx((tx) async {
      await tx.execute(
        pg.Sql.named(
          'SELECT ventio_security.reconcile_pending_first_admin('
          '@authority,@request,@tenant,@actor,@company,@branch,@device,'
          '@credential,@digest,@expiresAt)',
        ),
        parameters: {
          'authority': state['authorityId'],
          'request': requestId,
          'tenant': tenantId,
          'actor': actorId,
          'company': companyId,
          'branch': branchId,
          'device': deviceId,
          'credential': credentialId,
          'digest': OpaqueToken.digest(token),
          'expiresAt': expiresAt.toUtc(),
        },
      );
      return snapshot(tx);
    });
    await _replace({
      ...state,
      'pending': false,
      'fingerprint': reconciledFingerprint,
    });
  });

  Future<void> _initializeFirstHostRecovery(
    pg.Connection db,
    Map<String, dynamic> state,
  ) async {
    final fingerprint = await db.runTx((tx) async {
      await tx.execute(
        pg.Sql.named(
          'SELECT ventio_security.initialize_first_host_recovery(@authority)',
        ),
        parameters: {'authority': state['authorityId']},
      );
      return snapshot(tx);
    });
    await _replace({...state, 'pending': false, 'fingerprint': fingerprint});
  }

  static Future<String> _snapshotInTransaction(pg.TxSession tx) => snapshot(tx);

  Future<void> admit(pg.TxSession tx) async {
    final Map<String, dynamic> state;
    try {
      state = await _read();
    } on RecoveryAdmissionUnavailable {
      rethrow;
    } catch (_) {
      // A pending, missing, malformed, or inaccessible independent witness
      // must reject admission as a typed safe failure. It is not a database
      // authorization result and must not be surfaced as a generic Host error.
      throw const RecoveryAdmissionUnavailable();
    }
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

  Future<T> _exclusive<T>(
    Future<T> Function() body, {
    Duration? timeout,
    RecoveryMutationTimings? timings,
  }) async {
    if (timeout != null && timeout <= Duration.zero) {
      throw ArgumentError('Recovery lock timeout must be positive.');
    }
    final acquisitionWatch = Stopwatch()..start();
    final queueWatch = Stopwatch()..start();
    final previous = _tails[path] ?? Future<void>.value();
    final release = Completer<void>();
    _tails[path] = release.future;
    var enteredQueue = false;
    var acquired = false;
    RandomAccessFile? lock;
    try {
      try {
        if (timeout == null) {
          await previous;
        } else {
          await previous.timeout(timeout);
        }
        enteredQueue = true;
      } on TimeoutException {
        if (timings != null) {
          timings.authorityQueueWaitMs = queueWatch.elapsedMilliseconds;
          timings.authorityLockAcquisitionMs =
              acquisitionWatch.elapsedMilliseconds;
        }
        throw const RecoveryAuthorityBusy();
      }
      if (timings != null) {
        timings.authorityQueueWaitMs = queueWatch.elapsedMilliseconds;
      }
      if ((trustedOwnerUid != null || trustedOwnerSid != null) &&
          !allowHostMutations)
        throw StateError('Read-only Host cannot administer authority');
      final lockPath = '$path.lock';
      final lockFileSetupWatch = Stopwatch()..start();
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
      final openedLock = await File(lockPath).open(mode: FileMode.append);
      lock = openedLock;
      if (timings != null) {
        timings.authorityLockFileSetupMs =
            lockFileSetupWatch.elapsedMilliseconds;
      }
      final osLockWatch = Stopwatch()..start();
      if (timeout == null) {
        await openedLock.lock(FileLock.exclusive);
      } else {
        final lockWatch = Stopwatch()..start();
        while (true) {
          try {
            await openedLock.lock(FileLock.exclusive);
            break;
          } on FileSystemException catch (error) {
            final code = error.osError?.errorCode;
            if (code != 11 && code != 32 && code != 33) rethrow;
            if (lockWatch.elapsed >= timeout) {
              throw const RecoveryAuthorityBusy();
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      }
      if (timings != null) {
        timings.authorityOsLockWaitMs = osLockWatch.elapsedMilliseconds;
        timings.authorityLockAcquisitionMs =
            acquisitionWatch.elapsedMilliseconds;
      }
      acquired = true;
      return await body();
    } catch (_) {
      if (timings != null && !acquired) {
        timings.authorityLockAcquisitionMs =
            acquisitionWatch.elapsedMilliseconds;
      }
      rethrow;
    } finally {
      if (lock != null) {
        try {
          await lock.unlock();
        } catch (_) {
          // Closing the handle releases a platform file lock if unlock failed.
        }
        await lock.close();
      }
      if (enteredQueue) {
        release.complete();
        if (identical(_tails[path], release.future)) _tails.remove(path);
      } else {
        // Preserve queue order after a timed-out waiter; it must not let later
        // operations enter while the operation ahead of it still holds the lock.
        unawaited(
          previous.whenComplete(() {
            if (!release.isCompleted) release.complete();
            if (identical(_tails[path], release.future)) _tails.remove(path);
          }),
        );
      }
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
  }) async {
    await changeMeasured(
      db,
      action,
      requireAdmissionProof: requireAdmissionProof,
    );
  }

  /// Performs the same crash-consistent, serialized mutation as [change] and
  /// returns stage timings for protected diagnostics. It never weakens the
  /// independent witness or database fingerprint checks.
  Future<RecoveryMutationTimings> changeMeasured(
    pg.Connection db,
    Future<void> Function(pg.TxSession) action, {
    bool requireAdmissionProof = false,
    Duration? lockTimeout,
    void Function(RecoveryMutationTimings timings)? onTimings,
  }) async {
    final timings = RecoveryMutationTimings();
    Map<String, dynamic>? priorState;
    var rejectedBeforeCommit = false;
    var commitAttempted = false;
    var databaseCommitted = false;
    try {
      return await _exclusive(
        () async {
          var stageWatch = Stopwatch()..start();
          final state = await _read();
          priorState = state;
          timings.witnessReadMs = stageWatch.elapsedMilliseconds;

          stageWatch = Stopwatch()..start();
          await _replace({...state, 'pending': true});
          timings.witnessPendingWriteMs = stageWatch.elapsedMilliseconds;
          await testBarrier?.call('before_database');

          stageWatch = Stopwatch()..start();
          final fingerprint = await db.runTx((tx) async {
            var queryWatch = Stopwatch()..start();
            await tx.execute('SELECT pg_advisory_xact_lock(86744321)');
            timings.databaseAdvisoryLockMs = queryWatch.elapsedMilliseconds;

            queryWatch = Stopwatch()..start();
            final before = await snapshot(tx);
            timings.databaseFingerprintBeforeMs =
                queryWatch.elapsedMilliseconds;
            if (before != state['fingerprint']) {
              throw StateError('Recovery evidence does not match database');
            }
            if (requireAdmissionProof) await _admitState(tx, state);

            queryWatch = Stopwatch()..start();
            try {
              await action(tx);
            } on pg.ServerException {
              rejectedBeforeCommit = true;
              rethrow;
            }
            timings.databaseMutationMs = queryWatch.elapsedMilliseconds;
            await testBarrier?.call('before_commit');

            queryWatch = Stopwatch()..start();
            final after = await snapshot(tx);
            timings.databaseFingerprintAfterMs = queryWatch.elapsedMilliseconds;
            // A failure after this point can leave COMMIT's result ambiguous.
            commitAttempted = true;
            return after;
          });
          timings.databaseTransactionMs = stageWatch.elapsedMilliseconds;
          databaseCommitted = true;

          try {
            await testBarrier?.call('after_commit');
            stageWatch = Stopwatch()..start();
            await _replace({
              ...state,
              'pending': false,
              'fingerprint': fingerprint,
            });
            timings.witnessFinalizeMs = stageWatch.elapsedMilliseconds;
          } catch (_) {
            throw RecoveryMutationOutcomeUnknown(timings);
          }
          return timings;
        },
        timeout: lockTimeout,
        timings: timings,
      );
    } on RecoveryMutationOutcomeUnknown {
      rethrow;
    } catch (error, stackTrace) {
      if (commitAttempted || databaseCommitted) {
        throw RecoveryMutationOutcomeUnknown(timings);
      }
      if (rejectedBeforeCommit && priorState != null) {
        try {
          // No COMMIT was sent: restore ready evidence only when PostgreSQL
          // still matches the exact previously trusted snapshot.
          final unchanged = await db.runTx((tx) async {
            await tx.execute('SELECT pg_advisory_xact_lock(86744321)');
            return await snapshot(tx) == priorState!['fingerprint'];
          });
          if (unchanged) {
            await _replace(priorState!);
          } else {
            throw const RecoveryAdmissionUnavailable();
          }
        } catch (_) {
          throw const RecoveryAdmissionUnavailable();
        }
      }
      if (error is pg.ServerException) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      if (error is RecoveryAuthorityBusy) rethrow;
      throw const RecoveryAdmissionUnavailable();
    } finally {
      try {
        onTimings?.call(timings);
      } catch (_) {
        // Observability callbacks never alter a recovery mutation outcome.
      }
    }
  }

  /// Applies a fixed, release-bundled schema upgrade using PostgreSQL
  /// prepared transactions to coordinate the independent Recovery Authority
  /// witness. Before the witness authorizes commit, any prepared transaction
  /// is safe to roll back and retry. After that durable authorization, retries
  /// only commit or reconcile the exact receipt-backed operation.
  Future<RecoveryMutationTimings> applySchemaUpgrade(
    pg.Connection db, {
    required String operationId,
    required String migrationManifestSha256,
    required Future<void> Function(pg.Session tx) applyAndValidate,
    Duration? lockTimeout,
    void Function(RecoveryMutationTimings timings)? onTimings,
  }) async {
    if (!RegExp(r'^upgrade_[0-9a-f]{32}$').hasMatch(operationId) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(migrationManifestSha256)) {
      throw ArgumentError('Host schema upgrade reference is invalid.');
    }
    final timings = RecoveryMutationTimings();
    var phase = 'preflight';
    var stagedState = <String, dynamic>{};
    Map<String, dynamic>? readyState;
    var transactionOpen = false;
    var databaseCommitted = false;
    final preparedTransactionId = _schemaUpgradeTransactionId(operationId);
    try {
      return await _exclusive(
        () async {
          final state = await _readStoredState();
          final existingUpgrade = state['schemaUpgrade'];

          // A repeated installer invocation after successful finalization is
          // safe only when its durable receipt names the exact same release
          // transition and the ready witness still matches PostgreSQL.
          if (state['pending'] == false && existingUpgrade == null) {
            final current = await db.runTx(_snapshotInTransaction);
            if (current != state['fingerprint']) {
              throw const RecoveryAdmissionUnavailable();
            }
            final receipt = await _readSchemaUpgradeReceipt(db, operationId);
            if (receipt != null &&
                receipt['migrationManifestSha256'] == migrationManifestSha256 &&
                receipt['resultingFingerprint'] == current) {
              return timings;
            }
            final prior = current;
            readyState = state;
            final pending = <String, dynamic>{
              ...state,
              'pending': true,
              'schemaUpgrade': {
                'formatVersion': 1,
                'operationId': operationId,
                'preparedTransactionId': preparedTransactionId,
                'priorFingerprint': prior,
                'migrationManifestSha256': migrationManifestSha256,
                'phase': 'prepared',
              },
            };
            stagedState = pending;
            phase = 'staged';
            await _replace(pending);
            await testBarrier?.call('schema_upgrade_staged');
          } else {
            if (state['pending'] != true ||
                existingUpgrade is! Map<String, dynamic> ||
                existingUpgrade['operationId'] != operationId ||
                existingUpgrade['migrationManifestSha256'] !=
                    migrationManifestSha256 ||
                existingUpgrade['preparedTransactionId'] !=
                    preparedTransactionId) {
              throw const RecoveryAdmissionUnavailable();
            }
            stagedState = state;
          }

          final upgrade = stagedState['schemaUpgrade'] as Map<String, dynamic>;
          phase = upgrade['phase'] as String;
          final priorFingerprint = upgrade['priorFingerprint'] as String;
          if (upgrade['phase'] == 'commit_authorized') {
            if (await _hasPreparedSchemaUpgrade(db, preparedTransactionId)) {
              await db.execute(
                "COMMIT PREPARED '$preparedTransactionId'",
                queryMode: pg.QueryMode.simple,
              );
              databaseCommitted = true;
              await testBarrier?.call('schema_upgrade_after_database_commit');
            }
            final current = await db.runTx(_snapshotInTransaction);
            final receipt = await _readSchemaUpgradeReceipt(db, operationId);
            if (receipt == null ||
                receipt['priorFingerprint'] != priorFingerprint ||
                receipt['migrationManifestSha256'] != migrationManifestSha256 ||
                receipt['resultingFingerprint'] != current) {
              throw RecoveryMutationOutcomeUnknown(timings);
            }
            await _replace(
              {
                ...stagedState,
                'pending': false,
                'fingerprint': current,
                'schemaUpgrade': null,
              }..remove('schemaUpgrade'),
            );
            return timings;
          }

          if (upgrade['phase'] == 'prepared') {
            // A prepared database transaction cannot be committed until the
            // independent witness records commit authorization. Its presence
            // in this phase therefore means it is safe to roll back and retry.
            if (await _hasPreparedSchemaUpgrade(db, preparedTransactionId)) {
              await db.execute(
                "ROLLBACK PREPARED '$preparedTransactionId'",
                queryMode: pg.QueryMode.simple,
              );
            }
            final current = await db.runTx(_snapshotInTransaction);
            final receipt = await _readSchemaUpgradeReceipt(db, operationId);
            if (current != priorFingerprint || receipt != null) {
              throw const RecoveryAdmissionUnavailable();
            }
          }

          await db.execute('BEGIN', queryMode: pg.QueryMode.simple);
          transactionOpen = true;
          await db.execute(
            'SELECT pg_advisory_xact_lock(86744321)',
            queryMode: pg.QueryMode.simple,
          );
          final before = await snapshot(db);
          if (before != priorFingerprint) {
            throw const RecoveryAdmissionUnavailable();
          }
          await applyAndValidate(db);
          final after = await snapshot(db);
          await db.execute(
            pg.Sql.named('''
                INSERT INTO public.host_schema_upgrade_receipts
                  (operation_id,prior_fingerprint,resulting_fingerprint,
                   migration_manifest_sha256)
                VALUES (@operation,@prior,@result,@manifest)
                ON CONFLICT (operation_id) DO NOTHING
              '''),
            parameters: {
              'operation': operationId,
              'prior': priorFingerprint,
              'result': after,
              'manifest': migrationManifestSha256,
            },
          );
          final receipt = await _readSchemaUpgradeReceiptIn(db, operationId);
          if (receipt == null ||
              receipt['priorFingerprint'] != priorFingerprint ||
              receipt['resultingFingerprint'] != after ||
              receipt['migrationManifestSha256'] != migrationManifestSha256) {
            throw StateError('Host schema upgrade receipt conflicts.');
          }
          await testBarrier?.call('schema_upgrade_before_commit_attempt');
          await db.execute(
            "PREPARE TRANSACTION '$preparedTransactionId'",
            queryMode: pg.QueryMode.simple,
          );
          transactionOpen = false;
          await testBarrier?.call('schema_upgrade_database_prepared');
          await _replace({
            ...stagedState,
            'schemaUpgrade': {...upgrade, 'phase': 'commit_authorized'},
          });
          phase = 'commit_authorized';
          await testBarrier?.call('schema_upgrade_commit_authorized');
          await db.execute(
            "COMMIT PREPARED '$preparedTransactionId'",
            queryMode: pg.QueryMode.simple,
          );
          databaseCommitted = true;
          await testBarrier?.call('schema_upgrade_after_database_commit');
          final fingerprint = await db.runTx(_snapshotInTransaction);
          final committedReceipt = await _readSchemaUpgradeReceipt(
            db,
            operationId,
          );
          if (committedReceipt == null ||
              committedReceipt['priorFingerprint'] != priorFingerprint ||
              committedReceipt['migrationManifestSha256'] !=
                  migrationManifestSha256 ||
              committedReceipt['resultingFingerprint'] != fingerprint) {
            throw RecoveryMutationOutcomeUnknown(timings);
          }
          await _replace(
            {...stagedState, 'pending': false, 'fingerprint': fingerprint}
              ..remove('schemaUpgrade'),
          );
          return timings;
        },
        timeout: lockTimeout,
        timings: timings,
      );
    } on RecoveryMutationOutcomeUnknown {
      rethrow;
    } catch (error, stackTrace) {
      if (phase == 'commit_authorized' || databaseCommitted) {
        throw RecoveryMutationOutcomeUnknown(timings);
      }
      if (stagedState.isNotEmpty && stagedState['pending'] == true) {
        try {
          if (transactionOpen) {
            await db.execute('ROLLBACK', queryMode: pg.QueryMode.simple);
            transactionOpen = false;
          }
          if (await _hasPreparedSchemaUpgrade(db, preparedTransactionId)) {
            await db.execute(
              "ROLLBACK PREPARED '$preparedTransactionId'",
              queryMode: pg.QueryMode.simple,
            );
          }
          final observation = await db.runTx((tx) async {
            await tx.execute('SELECT pg_advisory_xact_lock(86744321)');
            return {
              'fingerprint': await snapshot(tx),
              'receipt': await _readSchemaUpgradeReceiptIn(tx, operationId),
            };
          });
          final upgrade = stagedState['schemaUpgrade'] as Map;
          if (observation['fingerprint'] != upgrade['priorFingerprint'] ||
              observation['receipt'] != null) {
            throw const RecoveryAdmissionUnavailable();
          }
          final unchangedState =
              readyState ??
              (Map<String, dynamic>.from(stagedState)
                ..remove('schemaUpgrade')
                ..['pending'] = false
                ..['fingerprint'] = upgrade['priorFingerprint']);
          await _replace(unchangedState);
        } catch (_) {
          throw const RecoveryAdmissionUnavailable();
        }
      }
      if (error is pg.ServerException) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      if (error is RecoveryAuthorityBusy) rethrow;
      throw const RecoveryAdmissionUnavailable();
    } finally {
      onTimings?.call(timings);
    }
  }

  Future<Map<String, String>?> _readSchemaUpgradeReceipt(
    pg.Connection db,
    String operationId,
  ) async {
    try {
      return await db.runTx(
        (tx) => _readSchemaUpgradeReceiptIn(tx, operationId),
      );
    } on pg.ServerException catch (error) {
      if (error.code == '42P01') return null;
      rethrow;
    }
  }

  Future<Map<String, String>?> _readSchemaUpgradeReceiptIn(
    pg.Session tx,
    String operationId,
  ) async {
    try {
      final tableExists = await tx.execute(
        "SELECT to_regclass('public.host_schema_upgrade_receipts') IS NOT NULL",
      );
      if (tableExists.single[0] != true) return null;
      final rows = await tx.execute(
        pg.Sql.named('''
          SELECT prior_fingerprint,resulting_fingerprint,migration_manifest_sha256
          FROM public.host_schema_upgrade_receipts
          WHERE operation_id=@operation
        '''),
        parameters: {'operation': operationId},
      );
      if (rows.isEmpty) return null;
      if (rows.length != 1) {
        throw StateError('Host upgrade receipt is ambiguous.');
      }
      return {
        'priorFingerprint': rows.single[0] as String,
        'resultingFingerprint': rows.single[1] as String,
        'migrationManifestSha256': rows.single[2] as String,
      };
    } on pg.ServerException catch (error) {
      if (error.code == '42P01') return null;
      rethrow;
    }
  }

  Future<bool> _hasPreparedSchemaUpgrade(
    pg.Session session,
    String transactionId,
  ) async {
    final rows = await session.execute(
      pg.Sql.named('''
        SELECT EXISTS (
          SELECT 1 FROM pg_prepared_xacts
          WHERE gid=@gid AND database=current_database() AND owner=current_user
        )
      '''),
      parameters: {'gid': transactionId},
    );
    return rows.single[0] as bool;
  }
}
