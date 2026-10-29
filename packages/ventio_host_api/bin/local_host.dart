import 'dart:async';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

/// Persistent identity launcher. No development identity file or bypass.
/// Cleartext remains loopback-only; external listeners require TLS files.
Future<void> main() => runLocalHost();

/// Starts the persistent Host with capabilities selected by trusted code.
/// Package metadata never supplies executable handlers or bindings.
Future<void> runLocalHost({
  ModuleRegistry? modules,
  DocTypeRegistry? docTypes,
  Iterable<TrustedCommandBinding> bindings = const [],
}) async {
  if (Platform.environment['VENTIO_ENABLE_LOCAL_HOST'] != 'yes') {
    stderr.writeln('Local Host requires explicit opt-in.');
    exitCode = 2;
    return;
  }
  HostApi? api;
  pg.Pool<dynamic>? runtimePool;
  pg.Pool<dynamic>? identityApiPool;
  try {
    final url = Platform.environment['VENTIO_HOST_DATABASE_URL'];
    if (url == null || url.isEmpty)
      throw StateError('Missing database configuration');
    final witness = Platform.environment['VENTIO_RECOVERY_AUTHORITY_FILE'];
    if (witness == null)
      throw StateError('Independent recovery authority required');
    final hostWritesText =
        Platform.environment['VENTIO_RECOVERY_AUTHORITY_HOST_WRITES'];
    if (hostWritesText != null && hostWritesText != 'yes') {
      throw StateError('Invalid recovery authority Host-write setting');
    }
    final hostWritesAuthority = hostWritesText == 'yes';
    final legacyIdentityAdminUrl =
        Platform.environment['VENTIO_HOST_IDENTITY_ADMIN_DATABASE_URL'];
    if (legacyIdentityAdminUrl != null && legacyIdentityAdminUrl.isNotEmpty) {
      throw StateError(
        'The Host no longer accepts the trusted local identity-admin database login; configure a separate scoped API login',
      );
    }
    final identityApiUrl =
        Platform.environment['VENTIO_HOST_IDENTITY_API_DATABASE_URL'];
    final hasIdentityApi = identityApiUrl != null && identityApiUrl.isNotEmpty;
    if (hasIdentityApi != hostWritesAuthority) {
      throw StateError(
        'Remote identity administration requires a separate scoped API login and explicit Host-owned recovery authority writes',
      );
    }
    final int? writerUid;
    final String? writerSid;
    final String? readerSid;
    if (Platform.isLinux) {
      writerUid = int.tryParse(
        Platform.environment['VENTIO_RECOVERY_AUTHORITY_OWNER_UID'] ?? '',
      );
      if (writerUid == null || writerUid < 0) {
        throw StateError('Trusted witness owner UID required');
      }
      writerSid = null;
      readerSid = null;
    } else if (Platform.isWindows) {
      writerUid = null;
      writerSid = Platform.environment['VENTIO_RECOVERY_AUTHORITY_OWNER_SID'];
      readerSid = Platform.environment['VENTIO_RECOVERY_AUTHORITY_READER_SID'];
      final sidPattern = RegExp(r'^S-1-\d+(?:-\d+)+$');
      if (writerSid == null ||
          readerSid == null ||
          !sidPattern.hasMatch(writerSid) ||
          !sidPattern.hasMatch(readerSid)) {
        throw StateError('Trusted witness owner and reader SIDs required');
      }
    } else {
      throw StateError('Local Host private storage requires Windows or Linux');
    }
    final admission = RecoveryAuthority(
      witness,
      trustedOwnerUid: writerUid,
      trustedOwnerSid: writerSid,
      readerSid: readerSid,
      allowHostMutations: hostWritesAuthority,
    );
    final parsed = Uri.parse(url);
    final boundedUrl = _poolUrl(parsed, maxConnections: 16);
    final runtime = pg.Pool<dynamic>.withUrl(boundedUrl);
    runtimePool = runtime;
    PostgresIdentityRoleAdministrationGateway? roleAdministration;
    PostgresIdentityUserAdministrationGateway? userAdministration;
    if (identityApiUrl != null && identityApiUrl.isNotEmpty) {
      final parsedApiUrl = Uri.parse(identityApiUrl);
      final boundedApiUrl = _poolUrl(parsedApiUrl, maxConnections: 4);
      final administration = pg.Pool<dynamic>.withUrl(boundedApiUrl);
      identityApiPool = administration;
      await administration.withConnection(
        verifyIdentityAdministrationConnection,
      );
      await administration.withConnection(
        verifyScopedUserAdministrationConnection,
      );
      roleAdministration = PostgresIdentityRoleAdministrationGateway(
        runtimePool: runtime,
        administrationPool: administration,
        admission: admission,
      );
      userAdministration = PostgresIdentityUserAdministrationGateway(
        runtimePool: runtime,
        administrationPool: administration,
        admission: admission,
      );
    }
    await runtime.withConnection((probe) async {
      await verifyRuntimeConnection(probe);
      await probe.runTx((tx) => admission.admit(tx));
    });
    final addressText =
        Platform.environment['VENTIO_HOST_BIND_ADDRESS'] ?? '127.0.0.1';
    final address = InternetAddress.tryParse(addressText);
    if (address == null) throw StateError('Invalid Host bind address');
    SecurityContext? tlsContext;
    final certificate =
        Platform.environment['VENTIO_HOST_TLS_CERTIFICATE_FILE'];
    final privateKey = Platform.environment['VENTIO_HOST_TLS_PRIVATE_KEY_FILE'];
    if (!address.isLoopback || certificate != null || privateKey != null) {
      if (certificate == null ||
          privateKey == null ||
          !File(certificate).isAbsolute ||
          !File(privateKey).isAbsolute) {
        throw StateError(
          'External Host requires absolute TLS certificate files',
        );
      }
      await PrivateFiles.verifyPrivateFile(privateKey);
      tlsContext = SecurityContext()
        ..useCertificateChain(certificate)
        ..usePrivateKey(privateKey);
    }
    api = await HostApi.bind(
      port: int.parse(Platform.environment['VENTIO_HOST_PORT'] ?? '8080'),
      listenAddress: address,
      tlsContext: tlsContext,
      authenticator: PersistentTokenAuthenticator(
        pool: runtime,
        admission: admission,
      ),
      extensionPackages: PostgresExtensionPackageGateway(
        pool: runtime,
        admission: admission,
      ),
      extensionRecordQueries: PostgresExtensionRecordQueryGateway(
        pool: runtime,
        admission: admission,
      ),
      identityRoleAdministration: roleAdministration,
      identityUserAdministration: userAdministration,
      readinessProvider: PostgresHostReadinessProvider(
        pool: runtime,
        recoveryAuthority: admission,
      ),
      executor: PersistentCommandExecutor(
        pool: runtime,
        admission: admission,
        // The production Host is an extension platform. Business command
        // bindings are supplied only by trusted platform deployments; this
        // launcher starts with the generic metadata-backed record engine.
        modules: modules ?? ModuleRegistry(),
        docTypes: docTypes ?? DocTypeRegistry(),
        bindings: bindings,
      ),
    );
    final scheme = tlsContext == null ? 'http' : 'https';
    stdout.writeln(
      'Persistent Host listening on $scheme://$addressText:${api.port}',
    );
  } catch (error) {
    try {
      await _closePools(identityApiPool, runtimePool);
    } catch (_) {
      // Startup remains fail-closed and never exposes driver error details.
    }
    if (Platform.environment['VENTIO_HOST_TEST_DIAGNOSTICS'] == 'yes') {
      final diagnostic = switch (error) {
        pg.ServerException(:final code, :final message) =>
          'ServerException sqlstate=${code ?? 'unknown'}: ${_redactTestDiagnostic(message)}',
        StateError() => '${error.runtimeType}: ${error.message}',
        _ => error.runtimeType.toString(),
      };
      stderr.writeln('VENTIO_HOST_TEST_DIAGNOSTIC: $diagnostic');
    }
    stderr.writeln(
      'Local Host startup failed. Check private server configuration.',
    );
    exitCode = 2;
    return;
  }
  final shutdown = Completer<void>();
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  for (final signal in [
    ProcessSignal.sigint,
    if (!Platform.isWindows) ProcessSignal.sigterm,
  ]) {
    subscriptions.add(
      signal.watch().listen((_) {
        if (!shutdown.isCompleted) shutdown.complete();
      }),
    );
  }
  await shutdown.future;
  try {
    await api.close();
  } finally {
    try {
      await _closePools(identityApiPool, runtimePool);
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    }
  }
}

String _redactTestDiagnostic(String value) => value
    .replaceAll(
      RegExp(r'postgres(?:ql)?://\S+', caseSensitive: false),
      'postgresql://[redacted]',
    )
    .replaceAll(
      RegExp(
        r'(password|token|secret)\s*[=:]\s*[^\s,;]+',
        caseSensitive: false,
      ),
      '[redacted]',
    );

/// Applies fixed production caps independently of any oversized URL settings.
String _poolUrl(Uri source, {required int maxConnections}) => source
    .replace(
      queryParameters: {
        ...source.queryParameters,
        'connect_timeout': '5',
        'query_timeout': '20',
        'max_connection_count': '$maxConnections',
        'max_connection_age': '1800',
        'max_session_use': '300',
        'max_query_count': '5000',
      },
    )
    .toString();

Future<void> _closePools(
  pg.Pool<dynamic>? identityAdminPool,
  pg.Pool<dynamic>? runtimePool,
) async {
  await Future.wait([
    if (identityAdminPool != null) identityAdminPool.close(),
    if (runtimePool != null) runtimePool.close(),
  ]);
}
