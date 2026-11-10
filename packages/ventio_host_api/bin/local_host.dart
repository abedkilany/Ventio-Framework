import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
  HostApi? lanApi;
  pg.Pool<dynamic>? runtimePool;
  pg.Pool<dynamic>? identityApiPool;
  ManagementDiagnosticSink diagnostics = ManagementDiagnosticBuffer();
  try {
    final diagnosticsPath =
        Platform.environment['VENTIO_HOST_DIAGNOSTICS_FILE'];
    if (diagnosticsPath != null && diagnosticsPath.isNotEmpty) {
      diagnostics = await ProtectedManagementDiagnosticLog.open(
        diagnosticsPath,
      );
    }
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
    PostgresIdentityPairingGateway? pairingAdministration;
    PostgresIdentityDeviceAdministrationGateway? deviceAdministration;
    IdentityCredentialReissueGateway? credentialReissues;
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
      pairingAdministration = PostgresIdentityPairingGateway(
        administrationPool: administration,
        admission: admission,
      );
      deviceAdministration = PostgresIdentityDeviceAdministrationGateway(
        runtimePool: runtime,
        administrationPool: administration,
        admission: admission,
      );
      credentialReissues = IdentityCredentialReissueGateway(
        apiPool: administration,
        connectApi: null,
        authority: admission,
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
    final lanAddressText = Platform.environment['VENTIO_HOST_LAN_BIND_ADDRESS'];
    final lanPortText = Platform.environment['VENTIO_HOST_LAN_PORT'];
    final lanListenerConfigured = lanAddressText != null || lanPortText != null;
    if ((lanAddressText == null) != (lanPortText == null) ||
        (lanListenerConfigured && !address.isLoopback)) {
      throw StateError('LAN listener configuration is invalid');
    }
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
    final localTlsContext = lanListenerConfigured ? null : tlsContext;
    final authenticator = PersistentTokenAuthenticator(
      pool: runtime,
      admission: admission,
    );
    final extensionPackages = PostgresExtensionPackageGateway(
      pool: runtime,
      permissionDiagnosticPool: identityApiPool,
      admission: admission,
    );
    final extensionPackageReview = identityApiPool == null
        ? null
        : PostgresExtensionPackageReviewGateway(
            pool: identityApiPool,
            admission: admission,
          );
    final extensionRecordQueries = PostgresExtensionRecordQueryGateway(
      pool: runtime,
      admission: admission,
    );
    final readinessProvider = PostgresHostReadinessProvider(
      pool: runtime,
      recoveryAuthority: admission,
    );
    final executor = PersistentCommandExecutor(
      pool: runtime,
      admission: admission,
      // The production Host is an extension platform. Business command
      // bindings are supplied only by trusted platform deployments; this
      // launcher starts with the generic metadata-backed record engine.
      modules: modules ?? ModuleRegistry(),
      docTypes: docTypes ?? DocTypeRegistry(),
      bindings: bindings,
    );
    api = await HostApi.bind(
      port: int.parse(Platform.environment['VENTIO_HOST_PORT'] ?? '8080'),
      listenAddress: address,
      tlsContext: localTlsContext,
      authenticator: authenticator,
      extensionPackages: extensionPackages,
      extensionPackageReview: extensionPackageReview,
      extensionRecordQueries: extensionRecordQueries,
      identityRoleAdministration: roleAdministration,
      identityUserAdministration: userAdministration,
      identityPairing: pairingAdministration,
      identityDeviceAdministration: deviceAdministration,
      credentialReissues: credentialReissues,
      readinessProvider: readinessProvider,
      diagnostics: diagnostics,
      executor: executor,
    );
    final scheme = localTlsContext == null ? 'http' : 'https';
    stdout.writeln(
      'Persistent Host listening on $scheme://$addressText:${api.port}',
    );
    if (lanAddressText != null && lanPortText != null) {
      final lanAddress = InternetAddress.tryParse(lanAddressText);
      final lanPort = int.tryParse(lanPortText);
      if (lanAddress == null ||
          lanAddress.isLoopback ||
          lanPort == null ||
          lanPort < 1 ||
          lanPort > 65535 ||
          tlsContext == null) {
        throw StateError('Invalid protected LAN listener configuration');
      }
      lanApi = await HostApi.bind(
        port: lanPort,
        listenAddress: lanAddress,
        tlsContext: tlsContext,
        authenticator: authenticator,
        extensionPackages: extensionPackages,
        extensionPackageReview: extensionPackageReview,
        extensionRecordQueries: extensionRecordQueries,
        identityRoleAdministration: roleAdministration,
        identityUserAdministration: userAdministration,
        identityPairing: pairingAdministration,
        identityDeviceAdministration: deviceAdministration,
        credentialReissues: credentialReissues,
        readinessProvider: readinessProvider,
        diagnostics: diagnostics,
        executor: executor,
      );
      stdout.writeln(
        'Persistent Host LAN listener ready on https://$lanAddressText:${lanApi.port}',
      );
    }
    stdout.writeln('VENTIO_HOST_READY');
  } catch (error) {
    try {
      await lanApi?.close();
      await api?.close();
    } catch (_) {
      // Startup failure remains fail-closed; preserve the original result.
    }
    try {
      await diagnostics.record(
        ManagementDiagnosticEvent(
          code: 'HOST_STARTUP_FAILED',
          component: 'host.startup',
          category: ManagementDiagnosticCategory.hostStartup,
          severity: ManagementDiagnosticSeverity.critical,
          occurredAtUtc: DateTime.now().toUtc(),
          correlationId: _startupCorrelationId(),
          retryable: true,
          messageKey: 'native.diagnostics.host_startup_failed',
          safeExplanation:
              'The Host service could not complete its startup checks.',
          recommendedAction:
              'Review the protected Host diagnostic log and correct the reported component issue.',
          protectedTechnicalCode: switch (error) {
            pg.ServerException(:final code)
                when code != null && RegExp(r'^[0-9A-Z]{5}$').hasMatch(code) =>
              code,
            _ => null,
          },
          protectedFailureType: error.runtimeType.toString(),
        ),
      );
    } catch (_) {
      // Diagnostics must never replace the original fail-closed startup result.
    }
    try {
      await _closePools(identityApiPool, runtimePool);
    } catch (_) {
      // Startup remains fail-closed and never exposes driver error details.
    }
    if (Platform.environment['VENTIO_HOST_TEST_DIAGNOSTICS'] == 'yes') {
      final diagnostic = switch (error) {
        pg.ServerException(:final code, :final message) =>
          'ServerException sqlstate=${code ?? 'unknown'}: ${code == '42883' ? 'undefinedFunction=${_undefinedFunctionDiagnostic(message) ?? 'unidentified'}' : 'PostgreSQL startup failure'}',
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
    await lanApi?.close();
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

/// Emits only a parsed PostgreSQL function identifier and argument types for
/// undefined-function diagnostics. The server message itself may contain data
/// supplied by the database and is never written to the service log.
String? _undefinedFunctionDiagnostic(String message) {
  final functionMatches = [
    RegExp(
      r"function\s+([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?)\(([^()\r\n]{0,256})\)\s+does not exist",
      caseSensitive: false,
    ),
    // has_function_privilege(text, text, text) quotes the unresolved
    // signature as one identifier, e.g. "schema.function(text,integer)".
    RegExp(
      r'function\s+"([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?\(([^()\r\n]{0,256})\))"\s+does not exist',
      caseSensitive: false,
    ),
  ];
  for (final pattern in functionMatches) {
    final match = pattern.firstMatch(message);
    if (match != null) {
      final name = match.group(1)!;
      final arguments = match.group(2)!;
      if (RegExp(r'^[A-Za-z0-9_ .,\[\]"]*$').hasMatch(arguments)) {
        return '$name($arguments)';
      }
    }
  }
  final operator = RegExp(
    r'operator does not exist:\s*([A-Za-z0-9_ .\[\]"]{1,96})\s*([!~<>=]{1,3})\s*([A-Za-z0-9_ .\[\]"]{1,96})',
    caseSensitive: false,
  ).firstMatch(message);
  if (operator == null) return null;
  final leftType = operator.group(1)!.trim();
  final token = operator.group(2)!;
  final rightType = operator.group(3)!.trim();
  if (leftType.isEmpty || rightType.isEmpty) return null;
  return 'operator($leftType $token $rightType)';
}

String _startupCorrelationId() {
  final random = math.Random.secure();
  final value = List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return 'cor_$value';
}

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
