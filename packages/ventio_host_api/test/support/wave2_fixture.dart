// Test-only real PostgreSQL/HTTP assembly. Nothing executes on import.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import '../../../ventio_core/test/support/wave2_cases.dart';
import '../../../ventio_core/test/support/wave2_fixtures.dart';
import '../recovery/database_fixture.dart';
import '../test_support.dart' show Reply, send, createPrivateTestDirectory;

export '../../../ventio_core/test/support/wave2_cases.dart';
export '../../../ventio_core/test/support/wave2_fixtures.dart';
export '../test_support.dart' show Reply;

class W2Identity {
  W2Identity(this.admin, this.actor, this.device, this.token, this.credential);
  final IdentityAdministration admin;
  final String actor;
  final String device;
  final String token;
  final String credential;
  String get tenant => admin.tenantId;
}

class W2Fixture {
  W2Fixture._();
  late DatabaseFixture database;
  late pg.Connection observer;
  late pg.Connection administrator;
  late pg.Pool<dynamic> runtimePool;
  late pg.Pool<dynamic> apiPool;
  late Directory directory;
  late RecoveryAuthority authority;
  late PersistentTokenAuthenticator authenticator;
  late PersistentCommandExecutor executor;
  late PostgresExtensionPackageGateway packages;
  late PostgresExtensionRecordQueryGateway records;
  late PostgresWave2Gateway gateway;
  late HostApi api;
  late W2Identity author;
  late W2Identity reader;
  late W2Identity outsider;
  final diagnostics = ManagementDiagnosticBuffer();
  static const tenant = 'w2-prepared';
  static const company = 'company-a';
  static const branch = 'branch-a';
  static const permissions = [
    'extension.package.submit',
    'extension.package.read',
    'extension.package.review',
    '$w2Permission.read',
    '$w2Permission.create',
    '$w2Permission.update',
    '$w2Permission.delete',
    '$w2Permission.secret_read',
    '$w2Permission.secret_write',
    'platform.customizations.manage',
    'platform.workspace.use',
    'platform.configuration.manage',
    'platform.organizations.manage',
    'platform.operations.manage',
    'platform.jobs.run',
    'platform.jobs.manage',
    'host.status.read',
  ];

  static Future<W2Fixture> open() async {
    final env = Platform.environment;
    if (env['VENTIO_WAVE2_PREPARED_TESTS'] != 'yes' ||
        {
          'VENTIO-TEST-01',
          'VENTIO-TEST-02',
          'TEST-01',
          'TEST-02',
          'BAHAA',
        }.contains(Platform.localHostname.toUpperCase())) {
      throw StateError(
        'Explicit Wave 2 disposable-fixture opt-in required; physical lab hosts prohibited',
      );
    }
    final url = env['VENTIO_TEST_DATABASE_URL'] ?? '';
    final source = Uri.parse(url);
    for (final key in [
      'VENTIO_TEST_RUNTIME_DATABASE_URL',
      'VENTIO_TEST_ADMIN_DATABASE_URL',
      'VENTIO_TEST_API_ADMIN_DATABASE_URL',
    ]) {
      final candidate = Uri.parse(env[key] ?? '');
      if (candidate.scheme != 'postgresql' ||
          candidate.host != source.host ||
          candidate.port != source.port ||
          candidate.path != '/ventio_host_test') {
        throw StateError(
          'All least-privilege fixture roles must target the same loopback disposable database',
        );
      }
    }
    final f = W2Fixture._();
    f.database = await DatabaseFixture.guarded(url);
    f.observer = await pg.Connection.openFromUrl(url);
    final existing = await f.observer.execute(
      'SELECT (SELECT count(*) FROM public.ventio_identity_users), (SELECT count(*) FROM public.ventio_wave2_jobs), (SELECT count(*) FROM public.ventio_extension_packages)',
    );
    if (existing.single.any((value) => value != 0)) {
      await f.observer.close();
      throw StateError(
        'Fresh migrated/bootstrap fixture required; existing test state is not reset or deleted',
      );
    }
    f.administrator = await pg.Connection.openFromUrl(
      env['VENTIO_TEST_ADMIN_DATABASE_URL']!,
    );
    f.runtimePool = pg.Pool<dynamic>.withUrl(
      env['VENTIO_TEST_RUNTIME_DATABASE_URL']!,
    );
    f.apiPool = pg.Pool<dynamic>.withUrl(
      env['VENTIO_TEST_API_ADMIN_DATABASE_URL']!,
    );
    f.directory = await createPrivateTestDirectory('ventio-wave2-authority-');
    f.authority = RecoveryAuthority('${f.directory.path}/authority.json');
    await f.authority.resetForReenrollment(
      f.administrator,
      'wave2-disposable-reset',
    );
    f.author = await f.provision(
      'author',
      permissions: permissions,
      secondScope: true,
    );
    f.reader = await f.provision(
      'reader',
      permissions: [
        'extension.package.read',
        '$w2Permission.read',
        'platform.workspace.use',
        'platform.jobs.run',
      ],
    );
    f.outsider = await f.provision(
      'outsider',
      tenantId: 'w2-other-tenant',
      permissions: permissions,
    );
    f.authenticator = PersistentTokenAuthenticator(
      pool: f.runtimePool,
      admission: f.authority,
    );
    final prototype = bootstrapMaintenancePrototype('../../spec/v1.2');
    f.executor = PersistentCommandExecutor(
      pool: f.runtimePool,
      admission: f.authority,
      modules: prototype.modules,
      docTypes: prototype.docTypes,
      bindings: const [
        TrustedCommandBinding('maintenance.create', 1, 'MaintenanceRequest'),
      ],
    );
    f.packages = PostgresExtensionPackageGateway(
      pool: f.runtimePool,
      admission: f.authority,
    );
    f.records = PostgresExtensionRecordQueryGateway(
      pool: f.runtimePool,
      admission: f.authority,
    );
    f.gateway = PostgresWave2Gateway(
      runtimePool: f.runtimePool,
      administrationPool: f.apiPool,
      admission: f.authority,
      packages: f.packages,
      records: f.records,
    );
    await f.bind();
    await f.installBundle(f.author, ExtensionBundle.fromJson(w2BundleJson()));
    return f;
  }

  Future<W2Identity> provision(
    String actor, {
    String tenantId = tenant,
    List<String> permissions = const [],
    List<String>? ceiling,
    bool secondScope = false,
  }) async {
    final admin = IdentityAdministration(
      connection: administrator,
      tenantId: tenantId,
      operatorLabel: 'wave2-fixture',
      authority: authority,
    );
    await admin.createUser(actor);
    await admin.registerBranch(company, branch);
    await admin.registerDevice(actor, 'device-$actor');
    for (final permission in permissions) {
      await admin.grant(actor, company, branch, permission);
    }
    if (secondScope) {
      await admin.registerBranch('company-b', 'branch-b');
      for (final permission in permissions) {
        await admin.grant(actor, 'company-b', 'branch-b', permission);
      }
    }
    final file = '${directory.path}/$tenantId-$actor.json';
    await admin.provisionToFile(
      actorId: actor,
      deviceId: 'device-$actor',
      credentialId: 'credential-$actor',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 2)),
      allowedScopes: [
        {
          'companyId': company,
          'branchId': branch,
          'permissions': ceiling ?? permissions,
        },
        if (secondScope)
          {
            'companyId': 'company-b',
            'branchId': 'branch-b',
            'permissions': ceiling ?? permissions,
          },
      ],
      outputPath: file,
    );
    final token =
        (jsonDecode(await PrivateFiles.read(file)) as Map)['token'] as String;
    return W2Identity(
      admin,
      actor,
      'device-$actor',
      token,
      'credential-$actor',
    );
  }

  Future<void> bind({int port = 0}) async {
    api = await HostApi.bind(
      authenticator: authenticator,
      executor: executor,
      extensionPackages: packages,
      extensionRecordQueries: records,
      extensionPackageReview: PostgresExtensionPackageReviewGateway(
        pool: apiPool,
        admission: authority,
      ),
      extensionReportQueries: PostgresExtensionReportQueryGateway(
        pool: runtimePool,
        admission: authority,
      ),
      wave2: gateway,
      diagnostics: diagnostics,
      port: port,
    );
  }

  Future<void> restartHttp() async {
    final port = api.port;
    await api.close();
    await bind(port: port);
  }

  Future<Reply> http(
    String action, {
    Map<String, dynamic> fields = const {},
    W2Identity? as,
    String method = 'POST',
    String contentType = 'application/json',
  }) => send(
    api,
    path: '/api/v1/platform/$action',
    token: (as ?? author).token,
    method: method,
    contentType: contentType,
    body: {
      'contractVersion': 1,
      'companyId': company,
      'branchId': branch,
      ...fields,
    },
  );

  Future<Map<String, dynamic>> call(
    String action, {
    Map<String, dynamic> fields = const {},
    W2Identity? as,
    int status = 200,
  }) async {
    final reply = await http(action, fields: fields, as: as);
    final recent = diagnostics.recent(limit: 1);
    final sqlState = recent.isEmpty ? null : recent.first.protectedTechnicalCode;
    final failureType = recent.isEmpty ? null : recent.first.protectedFailureType;
    final failureSource = recent.isEmpty ? null : recent.first.protectedFailureSource;
    w2Expect(
      reply.status == status,
      'Unexpected HTTP status for $action: ${reply.status}; fixture SQLSTATE=$sqlState type=$failureType source=$failureSource',
    );
    w2Expect(
      reply.body['apiVersion'] == 1 && reply.body['contractVersion'] == 1,
      'Response contract missing',
    );
    return requireMap(reply.body['result'], 'result');
  }

  Future<Map<String, dynamic>> save(
    String kind,
    String id,
    Map<String, dynamic> body, {
    required int request,
    int expected = 0,
    W2Identity? as,
    int status = 200,
  }) => call(
    'definitions/save',
    as: as,
    status: status,
    fields: {
      'kind': kind,
      'id': id,
      'expectedRevision': expected,
      'requestId': w2Id(request),
      'body': body,
    },
  );

  String digest(ExtensionBundle bundle) =>
      sha256.convert(utf8.encode(canonicalJson(bundle.toJson()))).toString();
  Future<void> installBundle(
    W2Identity identity,
    ExtensionBundle bundle,
  ) async {
    final session = await authenticator.authenticate(identity.token);
    w2Expect(session != null, 'Fixture authentication failed');
    final submitted = await packages.submit(
      session: session!,
      companyId: company,
      branchId: branch,
      bundle: bundle,
    );
    w2Expect(
      submitted['status'] == 'SUBMITTED',
      'Fixture package submission failed',
    );
    await ExtensionPackageAdministration(
      connection: administrator,
      tenantId: identity.tenant,
      operatorLabel: 'wave2-fixture',
      authority: authority,
    ).approve(
      moduleId: bundle.moduleId,
      version: bundle.version,
      packageSha256: digest(bundle),
    );
  }

  CommandEnvelope command(
    int id, {
    W2Identity? as,
    String? record,
    Map<String, dynamic>? values,
  }) {
    final identity = as ?? author;
    return w2Create(
      id,
      tenant: identity.tenant,
      actor: identity.actor,
      device: identity.device,
      record: record,
      values: values,
    );
  }

  Future<Map<String, dynamic>> execute(
    CommandEnvelope command, {
    W2Identity? as,
    int status = 200,
  }) async {
    final reply = await send(
      api,
      token: (as ?? author).token,
      body: command.original,
    );
    w2Expect(
      reply.status == status,
      'Unexpected command HTTP status ${reply.status}',
    );
    return requireMap(reply.body['receipt'], 'receipt');
  }

  Future<Map<String, dynamic>> submit(
    int job,
    List<CommandEnvelope> commands, {
    W2Identity? as,
    int status = 200,
    int? import,
    List<int>? sourceRows,
  }) => call(
    'jobs/submit',
    as: as,
    status: status,
    fields: {
      'jobId': w2Id(job),
      'commands': commands.map((c) => c.original).toList(),
      if (import != null) 'importId': w2Id(import),
      'sourceRows': ?sourceRows,
    },
  );
  Future<Map<String, dynamic>> job(int id) async {
    final list = await call('jobs/list');
    return requireList(list, 'jobs')
        .map((r) => requireMap(r, 'job'))
        .singleWhere((r) => r['jobId'] == w2Id(id));
  }

  Future<T> administrative<T>(Future<T> Function(pg.TxSession) action) =>
      apiPool.withConnection((db) async {
        await verifyIdentityAdministrationConnection(db);
        return db.runTx((tx) async {
          await authority.admit(tx);
          return action(tx);
        });
      });
  Future<Map<String, dynamic>?> claim() => administrative((tx) async {
    final rows = await tx.execute(
      'SELECT ventio_security.wave2_claim_job()::text',
    );
    return rows.single[0] == null
        ? null
        : requireMap(jsonDecode(rows.single[0] as String), 'claim');
  });
  Future<void> finish(
    Map<String, dynamic> claim,
    Map<String, dynamic> outcome, {
    bool retry = false,
  }) => administrative((tx) async {
    await tx.execute(
      pg.Sql.named(
        'SELECT ventio_security.wave2_finish_job(@tenant,@job,@lease,CAST(@outcome AS jsonb),@retry)',
      ),
      parameters: {
        'tenant': claim['tenantId'],
        'job': claim['jobId'],
        'lease': claim['leaseId'],
        'outcome': canonicalJson(outcome),
        'retry': retry,
      },
    );
  });
  Future<void> advanceJob(
    int id, {
    bool expireLease = false,
    bool ageTerminal = false,
  }) async {
    // Deterministic test-only clock setup: restrict to this suite's exact row.
    await observer.execute(
      pg.Sql.named(
        'UPDATE public.ventio_wave2_jobs SET available_at=clock_timestamp()-interval \'1 second\'${expireLease ? ", lease_until=clock_timestamp()-interval '1 second'" : ""}${ageTerminal ? ", updated_at=clock_timestamp()-interval '4000 days'" : ""} WHERE tenant_id=@tenant AND job_id=@id',
      ),
      parameters: {'tenant': tenant, 'id': w2Id(id)},
    );
  }

  Future<void> cancel(int id) async {
    await call('jobs/cancel', fields: {'jobId': w2Id(id)});
  }

  Wave2JobWorker worker() => Wave2JobWorker(
    administrationPool: apiPool,
    admission: authority,
    executor: executor,
    diagnostics: diagnostics,
    interval: const Duration(milliseconds: 25),
  );
  Future<Map<String, dynamic>> waitJob(int id, Set<String> states) async {
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < const Duration(seconds: 15)) {
      final current = await job(id);
      if (states.contains(current['state'])) return current;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    throw StateError('Bounded wait expired for job state');
  }

  Future<void> close() async {
    await api.close();
    await runtimePool.close();
    await apiPool.close();
    await administrator.close();
    await observer.close();
    await database.close();
    await directory.delete(recursive: true);
  }
}
