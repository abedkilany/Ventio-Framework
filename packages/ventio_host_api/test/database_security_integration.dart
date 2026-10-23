import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';
import 'package:ventio_postgres/ventio_postgres.dart';

import 'test_support.dart';

Future<void> denied(Future<void> Function() operation, String label) async {
  var blocked = false;
  try {
    await operation();
  } on pg.ServerException catch (error) {
    // Assert authorization denial, not an unrelated network/syntax failure.
    blocked = error.code == '42501';
  }
  check(blocked, label);
}

Future<void> rejectsProfile(pg.Connection connection, String label) async {
  var rejected = false;
  try {
    await verifyRuntimeConnection(connection);
  } on pg.ServerException catch (error) {
    rejected = error.code == 'P0001' || error.code == '42501';
  }
  check(rejected, label);
}

Future<void> main() async {
  final env = Platform.environment;
  final ownerUrl = env['VENTIO_TEST_DATABASE_URL'];
  final runtimeUrl = env['VENTIO_TEST_RUNTIME_DATABASE_URL'];
  final adminUrl = env['VENTIO_TEST_ADMIN_DATABASE_URL'];
  final migrationUrl = env['VENTIO_TEST_MIGRATION_DATABASE_URL'];
  if (ownerUrl == null ||
      runtimeUrl == null ||
      adminUrl == null ||
      migrationUrl == null ||
      env['VENTIO_ALLOW_DATABASE_TESTS'] != 'yes' ||
      Uri.parse(ownerUrl).pathSegments.last != 'ventio_host_test') {
    stderr.writeln(
      'Database security tests require four disposable database roles and explicit opt-in.',
    );
    exitCode = 2;
    return;
  }
  final owner = await pg.Connection.openFromUrl(ownerUrl);
  final runtime = await pg.Connection.openFromUrl(runtimeUrl);
  final administration = await pg.Connection.openFromUrl(adminUrl);
  final migration = await pg.Connection.openFromUrl(migrationUrl);
  final tenant = 'rls-${DateTime.now().microsecondsSinceEpoch}';
  final otherTenant = '$tenant-other';
  final admin = IdentityAdministration(
    connection: administration,
    tenantId: tenant,
    operatorLabel: 'security-test',
  );
  final otherAdmin = IdentityAdministration(
    connection: administration,
    tenantId: otherTenant,
    operatorLabel: 'security-test',
  );
  final proto = bootstrapMaintenancePrototype('../../spec/v1.2');
  final executor = PersistentCommandExecutor(
    connect: () => pg.Connection.openFromUrl(runtimeUrl),
    modules: proto.modules,
    docTypes: proto.docTypes,
    bindings: const [
      TrustedCommandBinding('maintenance.create', 1, 'MaintenanceRequest'),
    ],
  );
  final auth = PersistentTokenAuthenticator(
    connect: () => pg.Connection.openFromUrl(runtimeUrl),
  );
  Future<String> provision(IdentityAdministration a) async {
    await a.createUser('user-001');
    await a.registerBranch('company-001', 'branch-001');
    await a.registerDevice('user-001', 'device-001');
    await a.grant(
      'user-001',
      'company-001',
      'branch-001',
      'maintenance.create',
    );
    return a.issueCredential(
      actorId: 'user-001',
      deviceId: 'device-001',
      credentialId: 'credential',
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
  }

  Future<void> bind(
    pg.TxSession tx,
    String digest,
    Map<String, dynamic> body,
  ) async {
    await const PostgresIdentityStore().resolve(
      tx,
      digest,
      command: CommandEnvelope.fromJson(body),
    );
  }

  Future<void> insertRecord(
    pg.Session tx,
    String scope,
    String company,
    String branch, {
    String record = 'direct-record',
    String docType = 'MaintenanceRequest',
  }) async {
    await tx.execute(
      pg.Sql.named('''INSERT INTO public.ventio_records
      (tenant_id, company_id, branch_id, doc_type, record_id, revision, record_data)
      VALUES (@tenant,@company,@branch,@doctype,@record,1,'{}')'''),
      parameters: {
        'tenant': scope,
        'company': company,
        'branch': branch,
        'doctype': docType,
        'record': record,
      },
    );
  }

  try {
    await verifyRuntimeConnection(runtime);
    check(true, 'Restricted runtime login passes the security profile');
    await rejectsProfile(
      owner,
      'Superuser connection is rejected for Host operation',
    );
    await rejectsProfile(
      administration,
      'Identity administration connection is rejected for Host operation',
    );
    await rejectsProfile(
      migration,
      'Migration login is rejected for Host operation',
    );
    await denied(
      () => runtime.execute('SET ROLE ventio_owner'),
      'Runtime cannot assume table-owner role',
    );
    await denied(
      () => runtime.execute('SET ROLE ventio_identity_admin'),
      'Runtime cannot assume administrator role',
    );
    await denied(
      () => runtime.execute('SET ROLE ventio_migrator'),
      'Runtime cannot assume migration role',
    );
    await denied(
      () => runtime.execute('CREATE ROLE ventio_forbidden_role'),
      'Runtime cannot create database roles',
    );
    await denied(
      () => runtime.execute(
        'CREATE TABLE public.ventio_forbidden_table (id int)',
      ),
      'Runtime cannot create public objects',
    );
    await denied(
      () => runtime.execute('CREATE TEMP TABLE ventio_forbidden_temp (id int)'),
      'Runtime cannot create temporary objects',
    );
    await denied(
      () => runtime.execute('CREATE TABLE ventio_security.forbidden (id int)'),
      'Runtime cannot shadow protected security objects',
    );
    await denied(
      () => runtime.execute(
        'ALTER TABLE public.ventio_records DISABLE ROW LEVEL SECURITY',
      ),
      'Runtime cannot disable RLS',
    );
    await denied(
      () => runtime.execute(
        'CREATE POLICY forbidden_allow ON public.ventio_records USING (true)',
      ),
      'Runtime cannot add permissive policies',
    );
    await denied(
      () => runtime.execute('TRUNCATE public.ventio_records'),
      'Runtime cannot bypass RLS with TRUNCATE',
    );
    await denied(
      () => runtime.execute('DELETE FROM public.ventio_outbox'),
      'Runtime cannot delete outbox rows',
    );
    await denied(
      () => runtime.execute(
        "UPDATE public.ventio_command_journal SET fingerprint = 'forged'",
      ),
      'Runtime cannot alter command identity or fingerprints',
    );
    await denied(
      () => runtime.execute("UPDATE public.ventio_records SET revision = 99"),
      'Operational-create runtime cannot update records',
    );
    await denied(
      () => runtime.execute('SELECT * FROM public.ventio_schema_migrations'),
      'Runtime cannot read the migration ledger',
    );
    await denied(
      () => runtime.execute("SELECT ventio_security.admin_change('{}')"),
      'Runtime cannot invoke administrative operations',
    );
    await denied(
      () => runtime.execute(
        "SELECT ventio_security.identity_snapshot('x',NULL,NULL)",
      ),
      'Runtime cannot invoke private identity helpers',
    );
    await denied(
      () => runtime.execute('SELECT * FROM ventio_security.command_bindings'),
      'Runtime cannot inspect private bindings',
    );
    for (final table in [
      'ventio_identity_users',
      'ventio_identity_devices',
      'ventio_identity_credentials',
      'ventio_identity_branches',
      'ventio_identity_grants',
      'ventio_identity_audit',
    ]) {
      await denied(
        () => runtime.execute('SELECT * FROM public.$table'),
        'Runtime has no direct SELECT on $table',
      );
      await denied(
        () => runtime.execute('DELETE FROM public.$table'),
        'Runtime has no direct DELETE on $table',
      );
    }
    await denied(
      () => administration.execute(
        'UPDATE public.ventio_identity_devices SET revoked_at = NULL',
      ),
      'Administrator cannot silently rewrite device state directly',
    );
    await denied(
      () => administration.execute('DELETE FROM public.ventio_identity_audit'),
      'Administrator cannot erase the security audit',
    );
    await denied(
      () => administration.execute(
        'ALTER TABLE public.ventio_identity_users ADD COLUMN forbidden int',
      ),
      'Administrator cannot perform schema migrations',
    );
    await denied(
      () => administration.execute('SELECT * FROM public.ventio_records'),
      'Administrator has no business-table access',
    );
    await denied(
      () => runtime.execute('ALTER ROLE ventio_runtime_test BYPASSRLS'),
      'Runtime cannot enable its own BYPASSRLS attribute',
    );
    await denied(
      () =>
          runtime.execute('GRANT ventio_identity_admin TO ventio_runtime_test'),
      'Runtime cannot grant itself administrative membership',
    );
    final token = await provision(admin);
    final otherToken = await provision(otherAdmin);
    final body = command(tenant, id: 1);
    final foreignBody = command(otherTenant, id: 1);
    final principal = (await auth.authenticate(token))!;
    check(
      (await executor.execute(
            CommandEnvelope.fromJson(body),
            principal,
          ))['status'] ==
          'ACCEPTED',
      'Durable command runs with real restricted runtime privileges',
    );
    check(
      (await executor.execute(
            CommandEnvelope.fromJson(foreignBody),
            (await auth.authenticate(otherToken))!,
          ))['status'] ==
          'ACCEPTED',
      'Another tenant has an independent authorized command',
    );
    await admin.registerBranch('company-002', 'branch-002');
    await admin.grant(
      'user-001',
      'company-002',
      'branch-002',
      'maintenance.create',
    );
    final anotherBranch = command(tenant, id: 2)
      ..['companyId'] = 'company-002'
      ..['branchId'] = 'branch-002';
    check(
      (await executor.execute(
            CommandEnvelope.fromJson(anotherBranch),
            principal,
          ))['status'] ==
          'ACCEPTED',
      'Second registered company and branch remain compatible',
    );
    final hiddenCollision = command(tenant, id: 1, record: 'hidden-collision')
      ..['companyId'] = 'company-002'
      ..['branchId'] = 'branch-002';
    final hiddenReply = await executor.execute(
      CommandEnvelope.fromJson(hiddenCollision),
      principal,
    );
    check(
      hiddenReply['reasonCode'] == 'COMMAND_ID_REUSED' &&
          hiddenReply['output'] == null,
      'Cross-branch command ID collision is rejected without exposing the hidden receipt',
    );
    for (final table in [
      'ventio_records',
      'ventio_command_journal',
      'ventio_audit_entries',
      'ventio_outbox',
    ]) {
      check(
        (await runtime.execute(
              'SELECT count(*) FROM public.$table',
            )).single[0] ==
            0,
        'No proof context reveals no rows in $table',
      );
    }
    await denied(
      () => insertRecord(runtime, tenant, 'company-001', 'branch-001'),
      'INSERT without proof context is rejected',
    );
    await runtime.runTx((tx) async {
      await tx.execute(
        "SELECT set_config('ventio.tenant_id','forged',true), set_config('ventio.actor_id','admin',true), set_config('ventio.company_id','company-001',true), set_config('ventio.branch_id','branch-001',true), set_config('ventio.command_type','maintenance.create',true), set_config('ventio.command_version','1',true)",
      );
      check(
        (await tx.execute(
              'SELECT count(*) FROM public.ventio_records',
            )).single[0] ==
            0,
        'Spoofed tenant/actor/scope GUCs cannot establish authority',
      );
    });
    await runtime.runTx((tx) async {
      await bind(tx, OpaqueToken.digest(token), body);
      for (final table in [
        'ventio_records',
        'ventio_command_journal',
        'ventio_audit_entries',
        'ventio_outbox',
      ]) {
        final rows = await tx.execute(
          'SELECT tenant_id, company_id, branch_id FROM public.$table',
        );
        check(
          rows.length == 1 &&
              rows.every(
                (r) =>
                    r[0] == tenant &&
                    r[1] == 'company-001' &&
                    r[2] == 'branch-001',
              ),
          'RLS isolates tenant/company/branch in $table',
        );
      }
      await tx.execute(
        "SELECT set_config('ventio.tenant_id','forged',true), set_config('ventio.actor_id','forged',true)",
      );
      check(
        (await tx.execute(
              pg.Sql.named(
                'SELECT count(*) FROM public.ventio_records WHERE tenant_id = @tenant',
              ),
              parameters: {'tenant': otherTenant},
            )).single[0] ==
            0,
        'Changing tenant claims cannot reveal another tenant',
      );
      await tx.execute(
        "SELECT set_config('ventio.company_id','company-001',true), set_config('ventio.branch_id','branch-002',true)",
      );
      check(
        (await tx.execute(
              'SELECT count(*) FROM public.ventio_records',
            )).single[0] ==
            0,
        'Combining granted company and branch values cannot forge an ungranted pair',
      );
    });
    check(
      (await runtime.execute(
            'SELECT count(*) FROM public.ventio_records',
          )).single[0] ==
          0,
      'Committed proof context cannot leak to the next transaction',
    );
    for (final alteration in [
      'tenant',
      'company',
      'branch',
      'doctype',
      'aggregate',
    ]) {
      final direct = command(tenant, id: 3, record: 'direct-record');
      await denied(
        () => runtime.runTx((tx) async {
          await bind(tx, OpaqueToken.digest(token), direct);
          await insertRecord(
            tx,
            alteration == 'tenant' ? otherTenant : tenant,
            alteration == 'company' ? 'company-002' : 'company-001',
            alteration == 'branch' ? 'branch-002' : 'branch-001',
            docType: alteration == 'doctype'
                ? 'EquipmentInspection'
                : 'MaintenanceRequest',
            record: alteration == 'aggregate'
                ? 'forged-aggregate'
                : 'direct-record',
          );
        }),
        'Direct SQL INSERT cannot forge $alteration',
      );
    }
    await denied(
      () => runtime.runTx((tx) async {
        await bind(tx, OpaqueToken.digest(token), body);
        await tx.execute('SET LOCAL row_security = off');
        await tx.execute('SELECT * FROM public.ventio_records');
      }),
      'Setting row_security=off cannot bypass policy enforcement',
    );
    await denied(
      () => runtime.runTx((tx) async {
        await bind(tx, OpaqueToken.digest(token), body);
        await tx.execute(
          pg.Sql.named(
            "INSERT INTO public.ventio_audit_entries (tenant_id,company_id,branch_id,actor_id,command_id,event_type,details) VALUES (@tenant,'company-001','branch-001','forged',@command,'maintenance.create','{}')",
          ),
          parameters: {'tenant': tenant, 'command': body['commandId']},
        );
      }),
      'Direct audit INSERT cannot forge actor identity',
    );
    await denied(
      () => runtime.runTx((tx) async {
        await bind(tx, OpaqueToken.digest(token), body);
        await tx.execute(
          pg.Sql.named(
            "INSERT INTO public.ventio_outbox (tenant_id,company_id,branch_id,command_id,event_type,payload) VALUES (@tenant,'company-001','branch-001','forged','MaintenanceRequest.created','{}')",
          ),
          parameters: {'tenant': tenant},
        );
      }),
      'Direct outbox INSERT cannot forge command identity',
    );
    await denied(
      () => runtime.runTx((tx) async {
        await bind(tx, OpaqueToken.digest(token), body);
        await tx.execute(
          pg.Sql.named(
            "INSERT INTO public.ventio_command_journal (tenant_id,command_id,company_id,branch_id,actor_id,device_id,fingerprint,receipt) VALUES (@tenant,'forged','company-001','branch-001','user-001','forged','hash','{}')",
          ),
          parameters: {'tenant': tenant},
        );
      }),
      'Direct journal INSERT cannot forge device or command identity',
    );
    await runtime.runTx((tx) async {
      await bind(tx, OpaqueToken.digest(token), body);
      final update = await tx.execute(
        pg.Sql.named(
          "UPDATE public.ventio_command_journal SET receipt='{}' WHERE tenant_id=@other",
        ),
        parameters: {'other': otherTenant},
      );
      check(
        update.affectedRows == 0,
        'Cross-tenant journal UPDATE affects no rows',
      );
      await bind(tx, List.filled(64, '0').join(), body);
      check(
        (await tx.execute(
              'SELECT count(*) FROM public.ventio_records',
            )).single[0] ==
            0,
        'Failed reauthentication clears the previous valid context',
      );
    });
    // Out-of-band accidental ACLs still encounter default-deny identity RLS.
    await owner.execute(
      'GRANT SELECT, UPDATE(revoked_at) ON public.ventio_identity_devices TO ventio_runtime_test',
    );
    try {
      await rejectsProfile(
        runtime,
        'Extra identity column privileges are detected before Host operation',
      );
      check(
        (await runtime.execute(
              'SELECT count(*) FROM public.ventio_identity_devices',
            )).single[0] ==
            0,
        'Forced identity RLS hides rows even after accidental SELECT grant',
      );
      check(
        (await runtime.execute(
              'UPDATE public.ventio_identity_devices SET revoked_at=NULL',
            )).affectedRows ==
            0,
        'Forced identity RLS blocks silent edits even after accidental UPDATE grant',
      );
    } finally {
      await owner.execute(
        'REVOKE SELECT, UPDATE(revoked_at) ON public.ventio_identity_devices FROM ventio_runtime_test',
      );
    }
    await owner.execute('GRANT ventio_identity_admin TO ventio_runtime_test');
    try {
      await rejectsProfile(
        runtime,
        'Extra administrative role membership is rejected',
      );
    } finally {
      await owner.execute(
        'REVOKE ventio_identity_admin FROM ventio_runtime_test',
      );
    }
    await owner.execute('GRANT CREATE ON SCHEMA public TO ventio_runtime_test');
    try {
      await rejectsProfile(
        runtime,
        'Unexpected schema creation privilege is rejected',
      );
    } finally {
      await owner.execute(
        'REVOKE CREATE ON SCHEMA public FROM ventio_runtime_test',
      );
    }
    await verifyRuntimeConnection(runtime);
    check(true, 'Runtime profile passes after excess privileges are removed');
    // Savepoint rollback releases locks, so proof settings must never cache policy.
    await runtime.runTx((tx) async {
      await tx.execute('SAVEPOINT before_auth');
      await bind(tx, OpaqueToken.digest(token), body);
      await tx.execute('ROLLBACK TO SAVEPOINT before_auth');
      await admin.revokeGrant(
        'user-001',
        'company-001',
        'branch-001',
        'maintenance.create',
      );
      await tx.execute(
        pg.Sql.named(
          "SELECT set_config('ventio.credential_digest',@proof,true), set_config('ventio.company_id','company-001',true), set_config('ventio.branch_id','branch-001',true), set_config('ventio.command_type','maintenance.create',true), set_config('ventio.command_version','1',true)",
        ),
        parameters: {'proof': OpaqueToken.digest(token)},
      );
      check(
        (await tx.execute(
              'SELECT count(*) FROM public.ventio_records',
            )).single[0] ==
            0,
        'Replayed proof settings cannot preserve a grant after savepoint rollback',
      );
    });
    await admin.grant(
      'user-001',
      'company-001',
      'branch-001',
      'maintenance.create',
    );
    final expiration =
        (await owner.execute('SELECT clock_timestamp()')).single[0] as DateTime;
    final expiringToken = await otherAdmin.issueCredential(
      actorId: 'user-001',
      deviceId: 'device-001',
      credentialId: 'sql-expiring',
      expiresAt: expiration.add(const Duration(seconds: 2)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    await runtime.runTx((tx) async {
      await bind(tx, OpaqueToken.digest(expiringToken), foreignBody);
      check(
        (await tx.execute(
              'SELECT count(*) FROM public.ventio_records',
            )).single[0] ==
            0,
        'Expired proof on an active user/device cannot read through direct SQL',
      );
    });
    await denied(
      () => runtime.runTx((tx) async {
        await bind(
          tx,
          OpaqueToken.digest(expiringToken),
          command(otherTenant, id: 3, record: 'direct-record'),
        );
        await insertRecord(tx, otherTenant, 'company-001', 'branch-001');
      }),
      'Expired proof on an active user/device cannot insert through direct SQL',
    );
    await admin.revokeDevice('device-001');
    await runtime.runTx((tx) async {
      await bind(tx, OpaqueToken.digest(token), body);
      check(
        (await tx.execute(
              'SELECT count(*) FROM public.ventio_records',
            )).single[0] ==
            0,
        'Direct SQL with revoked proof cannot read business data',
      );
    });
    await denied(
      () => runtime.runTx((tx) async {
        await bind(
          tx,
          OpaqueToken.digest(token),
          command(tenant, id: 3, record: 'direct-record'),
        );
        await insertRecord(tx, tenant, 'company-001', 'branch-001');
      }),
      'Direct SQL with revoked proof cannot insert business data',
    );
    check(
      (await executor.execute(
            CommandEnvelope.fromJson(body),
            principal,
          ))['reasonCode'] ==
          'AUTHENTICATION_REQUIRED',
      'Revoked credential cannot retrieve a durable receipt through restricted Host',
    );
    final audit = await owner.execute(
      pg.Sql.named(
        'SELECT database_actor FROM public.ventio_identity_audit WHERE tenant_id=@tenant',
      ),
      parameters: {'tenant': tenant},
    );
    check(
      audit.isNotEmpty && audit.every((r) => r[0] == 'ventio_admin_test'),
      'Audited administration preserves the real restricted database login',
    );
    await migration.execute('SET ROLE ventio_owner');
    check(
      (await PostgresMigrationRunner(
        migration,
        Directory('../../migrations/postgres'),
      ).apply()).isEmpty,
      'Dedicated migration login can verify and apply the existing ledger as owner',
    );
    await migration.execute(
      'ALTER TABLE public.ventio_identity_audit ADD COLUMN security_migration_probe integer',
    );
    await migration.execute(
      'ALTER TABLE public.ventio_identity_audit DROP COLUMN security_migration_probe',
    );
    check(true, 'Only the migration connection performs reviewed DDL');
    final startup = await Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/local_host.dart'],
      environment: {
        'VENTIO_ENABLE_LOCAL_HOST': 'yes',
        'VENTIO_HOST_DATABASE_URL': ownerUrl,
        'VENTIO_HOST_PORT': '0',
      },
    );
    check(
      startup.exitCode == 2 &&
          !(startup.stdout as String).contains('listening'),
      'Host launcher refuses a superuser URL before opening its listener',
    );
    // Explicit boundary: a DB login plus a valid proof can perform permitted SQL
    // in its own scope. RLS is not business validation or four-table atomicity.
    await runtime.runTx((tx) async {
      final allowed = command(otherTenant, id: 4, record: 'sql-scope-proof');
      await bind(tx, OpaqueToken.digest(otherToken), allowed);
      await insertRecord(
        tx,
        otherTenant,
        'company-001',
        'branch-001',
        record: 'sql-scope-proof',
      );
    });
    check(
      true,
      'Documented limit: valid scoped SQL proof permits an operational INSERT without Host business validation',
    );
    stdout.writeln('RESULT: $assertions passed, 0 failed');
  } finally {
    for (final table in [
      'ventio_outbox',
      'ventio_audit_entries',
      'ventio_command_journal',
      'ventio_records',
      'ventio_identity_audit',
      'ventio_identity_grants',
      'ventio_identity_credentials',
      'ventio_identity_devices',
      'ventio_identity_users',
      'ventio_identity_branches',
    ]) {
      await owner.execute(
        pg.Sql.named(
          'DELETE FROM public.$table WHERE tenant_id IN (@tenant,@other)',
        ),
        parameters: {'tenant': tenant, 'other': otherTenant},
      );
    }
    await migration.close();
    await administration.close();
    await runtime.close();
    await owner.close();
  }
}
