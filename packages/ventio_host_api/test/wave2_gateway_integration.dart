// PREPARED / NOT EXECUTED. Real authenticated HTTP, PostgreSQL functions/RLS.
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_host_api/ventio_host_api.dart';

import 'support/wave2_fixture.dart';
import 'test_support.dart' show send;

Future<void> main() async {
  final f = await W2Fixture.open();
  final cases = W2Cases();
  Map<String, dynamic> metadata({String version = '1.0.0'}) => {
    'moduleId': w2Module,
    'moduleVersion': version,
    'docType': 'Asset',
  };
  Map<String, dynamic> query({String version = '1.0.0'}) => {
    ...metadata(version: version),
    'columns': ['name'],
    'filters': <String, dynamic>{},
    'search': '',
    'descending': false,
    'limit': 2,
  };
  var configRevision = 0;
  var configRequest = 8000;
  Future<void> configure(Map<String, dynamic> changes) async {
    final result = await f.save(
      'configuration',
      'scope',
      {...w2Settings(), ...changes},
      request: configRequest++,
      expected: configRevision,
    );
    w2Expect(result['status'] == 'SAVED', 'Configuration not saved');
    configRevision = result['revision'] as int;
  }

  try {
    await cases.run(
      'W2-H001',
      'D09,J04',
      'Platform routes reject missing and invalid bearer credentials',
      () async {
        for (final token in <String?>[null, 'invalid']) {
          final reply = await send(
            f.api,
            path: '/api/v1/platform/settings/read',
            token: token,
            body: {
              'contractVersion': 1,
              'companyId': W2Fixture.company,
              'branchId': W2Fixture.branch,
            },
          );
          w2Expect(
            reply.status == 401 &&
                requireMap(reply.body['error'], 'error')['code'] ==
                    'UNAUTHENTICATED',
            'Anonymous request admitted',
          );
        }
      },
    );
    await cases.run(
      'W2-H002',
      'D09,B02',
      'Real session discovery resolves current authoritative actor and scope',
      () async {
        final reply = await send(
          f.api,
          path: '/api/v1/session',
          method: 'GET',
          token: f.author.token,
        );
        final identity = requireMap(reply.body['identity'], 'identity');
        w2Expect(
          reply.status == 200 &&
              identity['actorId'] == 'author' &&
              identity['tenantId'] == W2Fixture.tenant,
          'Wrong identity',
        );
        w2Expect(
          (await f.call('settings/read'))['status'] == 'SETTINGS',
          'Authenticated gateway unavailable',
        );
      },
    );
    await cases.run(
      'W2-H003',
      'J04,B02',
      'Platform methods content type versions and unknown properties fail strictly',
      () async {
        w2Expect(
          (await f.http('settings/read', method: 'GET')).status == 405,
          'Wrong method accepted',
        );
        w2Expect(
          (await f.http('settings/read', contentType: 'text/plain')).status ==
              415,
          'Wrong MIME accepted',
        );
        for (final fields in [
          {'contractVersion': 2},
          {'sql': 'select 1'},
          {'tenantId': 'spoof'},
        ]) {
          w2Expect(
            (await f.http('settings/read', fields: fields)).status == 400,
            'Invalid contract accepted',
          );
        }
        w2Expect(
          (await f.http(
                'outbound/run',
                fields: {'url': 'https://example.invalid'},
              )).status ==
              400,
          'Unknown integration action accepted',
        );
      },
    );
    await cases.run(
      'W2-H004',
      'J04',
      'Malformed UTF-8 oversized bodies and excessive nesting fail before gateway execution',
      () async {
        final client = HttpClient();
        try {
          for (final bytes in [
            <int>[0xff, 0xfe],
            utf8.encode('x' * 65537),
            utf8.encode('${'[' * 80}0${']' * 80}'),
          ]) {
            final request = await client.postUrl(
              Uri.parse(
                'http://127.0.0.1:${f.api.port}/api/v1/platform/settings/read',
              ),
            );
            request.headers
              ..set('Authorization', 'Bearer ${f.author.token}')
              ..contentType = ContentType.json;
            request.add(bytes);
            final response = await request.close();
            await response.drain<void>();
            w2Expect(
              response.statusCode == (bytes.length > 65536 ? 413 : 400),
              'Malformed wire body admitted',
            );
          }
        } finally {
          client.close(force: true);
        }
      },
    );
    await cases.run(
      'W2-H005',
      'M02,D09',
      'A stale authenticated snapshot cannot retain revoked configuration authority',
      () async {
        final editor = await f.provision(
          'revoked-config',
          permissions: ['platform.configuration.manage', 'host.status.read'],
        );
        final stale = await f.authenticator.authenticate(editor.token);
        await editor.admin.revokeGrant(
          editor.actor,
          W2Fixture.company,
          W2Fixture.branch,
          'platform.configuration.manage',
        );
        final result = await f.gateway.handle('definitions/save', {
          'contractVersion': 1,
          'companyId': W2Fixture.company,
          'branchId': W2Fixture.branch,
          'kind': 'configuration',
          'id': 'scope',
          'requestId': w2Id(5),
          'expectedRevision': 0,
          'body': w2Settings(),
        }, stale!);
        w2Expect(
          result['status'] == 'REJECTED' &&
              result['reasonCode'] == 'PERMISSION_DENIED',
          'Snapshot became authority',
        );
      },
    );
    await cases.run(
      'W2-H006',
      'M02,D09',
      'Later user grants cannot widen a credential ceiling',
      () async {
        final bounded = await f.provision(
          'ceiling-config',
          permissions: ['host.status.read'],
          ceiling: ['host.status.read'],
        );
        await bounded.admin.grant(
          bounded.actor,
          W2Fixture.company,
          W2Fixture.branch,
          'platform.configuration.manage',
        );
        final result = await f.save(
          'configuration',
          'scope',
          w2Settings(),
          request: 6,
          as: bounded,
          status: 403,
        );
        w2Expect(
          result['reasonCode'] == 'PERMISSION_DENIED',
          'Ceiling widened',
        );
      },
    );
    await cases.run(
      'W2-H007',
      'C09,K09',
      'Definition publication retries are idempotent and request reuse with different content conflicts',
      () async {
        final first = await f.save(
          'preferences',
          'mine',
          w2Preferences(),
          request: 7,
        );
        final replay = await f.save(
          'preferences',
          'mine',
          w2Preferences(),
          request: 7,
        );
        w2Equal(replay, first, 'Replay advanced revision');
        final changed = await f.save(
          'preferences',
          'mine',
          w2Preferences(theme: 'light'),
          request: 7,
          status: 409,
        );
        w2Expect(
          changed['reasonCode'] == 'REQUEST_ID_REUSED',
          'Reused identity overwrote content',
        );
      },
    );
    await cases.run(
      'W2-H008',
      'B09,C09,K09',
      'Concurrent same-revision saves yield exactly one winner',
      () async {
        final replies = await Future.wait([
          for (final id in [81, 82])
            f.http(
              'definitions/save',
              fields: {
                'kind': 'saved_view',
                'id': 'race',
                'expectedRevision': 0,
                'requestId': w2Id(id),
                'body': {...w2View(), 'title': 'View $id'},
              },
            ),
        ]);
        w2Equal(
          replies.map((r) => r.status).toList()..sort(),
          [200, 409],
          'CAS did not fence concurrent writers',
        );
      },
    );
    await cases.run(
      'W2-H009',
      'B09,C08,C09',
      'User-owned definitions stay separate for actors and tenants',
      () async {
        await f.save(
          'preferences',
          'mine',
          w2Preferences(theme: 'light'),
          request: 9,
          as: f.reader,
        );
        await f.save(
          'preferences',
          'mine',
          w2Preferences(theme: 'system'),
          request: 9,
          as: f.outsider,
        );
        for (final (identity, theme) in [
          (f.author, 'dark'),
          (f.reader, 'light'),
          (f.outsider, 'system'),
        ]) {
          final list = await f.call(
            'definitions/list',
            as: identity,
            fields: {'kind': 'preferences'},
          );
          w2Expect(
            requireList(list, 'definitions').single['body']['theme'] == theme,
            'Definition leaked across owner',
          );
        }
      },
    );
    await cases.run(
      'W2-H010',
      'C09,M02',
      'Company branch pairs are checked exactly and shared settings remain scoped',
      () async {
        final other = await f.call(
          'definitions/save',
          fields: {
            'companyId': 'company-b',
            'branchId': 'branch-b',
            'kind': 'configuration',
            'id': 'scope',
            'expectedRevision': 0,
            'requestId': w2Id(10),
            'body': {...w2Settings(), 'displayName': 'Other company'},
          },
        );
        w2Expect(other['status'] == 'SAVED', 'Other scoped fixture failed');
        final current = await f.call('settings/read');
        w2Expect(
          requireMap(current['settings'], 'settings')['displayName'] !=
              'Other company',
          'Settings crossed scopes',
        );
        w2Expect(
          (await f.http(
                'settings/read',
                fields: {'companyId': 'company-a', 'branchId': 'branch-b'},
              )).status ==
              403,
          'Invented scope pair admitted',
        );
      },
    );
    await cases.run(
      'W2-H011',
      'B09,C09',
      'Hundred-definition owner bound refuses the next save without dropping content',
      () async {
        final limited = await f.provision(
          'definition-limit',
          permissions: ['platform.workspace.use'],
        );
        for (var i = 0; i < 100; i++) {
          final result = await f.save(
            'saved_view',
            'view-$i',
            w2View(),
            request: 1100 + i,
            as: limited,
          );
          w2Expect(result['status'] == 'SAVED', 'Valid boundary entry lost');
        }
        final overflow = await f.save(
          'saved_view',
          'overflow',
          w2View(),
          request: 1200,
          as: limited,
          status: 403,
        );
        w2Expect(
          overflow['reasonCode'] == 'DEFINITION_LIMIT',
          'Definition limit not enforced',
        );
        w2Expect(
          requireList(
                await f.call(
                  'definitions/list',
                  fields: {'kind': 'saved_view'},
                  as: limited,
                ),
                'definitions',
              ).length ==
              100,
          'Overflow changed inventory',
        );
      },
    );
    await cases.run(
      'W2-H012',
      'M02',
      'Configuration persists through HTTP reassembly and denied writes have no effect',
      () async {
        await configure({
          'displayName': 'Prepared configuration',
          'defaultPageSize': 2,
        });
        final denied = await f.save(
          'configuration',
          'scope',
          w2Settings(),
          request: 12,
          expected: configRevision,
          as: f.reader,
          status: 403,
        );
        w2Expect(
          denied['reasonCode'] == 'PERMISSION_DENIED',
          'Reader changed configuration',
        );
        await f.restartHttp();
        final settings = requireMap(
          (await f.call('settings/read'))['settings'],
          'settings',
        );
        w2Expect(
          settings['displayName'] == 'Prepared configuration' &&
              settings['defaultPageSize'] == 2,
          'Configuration not durable',
        );
      },
    );
    await cases.run(
      'W2-H013',
      'A11,A12',
      'SQL and Core effective overlays agree while approved package bytes stay immutable',
      () async {
        final bundle = ExtensionBundle.fromJson(w2BundleJson());
        final overlay = w2Overlay(hash: f.digest(bundle));
        final saved = await f.save(
          'customization',
          '$w2Module:1.0.0:Asset',
          overlay,
          request: 13,
        );
        w2Expect(saved['status'] == 'SAVED', 'Overlay save failed');
        final effective = await f.call(
          'metadata/effective',
          fields: metadata(),
        );
        w2Equal(
          effective['package'],
          MetadataCustomization.fromJson(overlay).merge(bundle).toJson(),
          'Core/SQL merge mismatch',
        );
        final stored = await f.observer.execute(
          pg.Sql.named(
            'SELECT package_json::text,package_sha256 FROM public.ventio_extension_packages WHERE tenant_id=@tenant AND module_id=@module AND version=\'1.0.0\'',
          ),
          parameters: {'tenant': W2Fixture.tenant, 'module': w2Module},
        );
        w2Equal(
          jsonDecode(stored.single[0] as String),
          bundle.toJson(),
          'Approved bytes mutated',
        );
        w2Expect(stored.single[1] == f.digest(bundle), 'Base digest changed');
      },
    );
    await cases.run(
      'W2-H014',
      'A12,K09',
      'Wrong base digest and destructive field conversion fail without advancing revision',
      () async {
        final bundle = ExtensionBundle.fromJson(w2BundleJson());
        final stale = await f.save(
          'customization',
          '$w2Module:1.0.0:Asset',
          w2Overlay(hash: 'f' * 64),
          request: 14,
          expected: 1,
          status: 409,
        );
        w2Expect(
          stale['reasonCode'] == 'CUSTOMIZATION_BASE_CHANGED',
          'Stale digest accepted',
        );
        final body = w2Overlay(hash: f.digest(bundle))
          ..['fields'] = [w2CustomField('integer')];
        final converted = await f.save(
          'customization',
          '$w2Module:1.0.0:Asset',
          body,
          request: 140,
          expected: 1,
          status: 403,
        );
        w2Expect(
          converted['reasonCode'] == 'CUSTOMIZATION_MIGRATION_REQUIRED',
          'Destructive conversion accepted',
        );
      },
    );
    await cases.run(
      'W2-H015',
      'A12,D08',
      'Authoritative record writes use effective custom fields and preserve old records',
      () async {
        final receipt = await f.execute(
          f.command(
            150,
            values: {
              'name': 'Custom asset',
              'custom_note': 'Preserved note',
              'secret': 'protected-fixture',
            },
          ),
        );
        w2Expect(receipt['status'] == 'ACCEPTED', 'Custom record failed');
        final result = await f.call(
          'records/query',
          as: f.reader,
          fields: {
            ...query(),
            'recordId': 'asset-150',
            'columns': ['name', 'custom_note'],
          },
        );
        final values = requireMap(
          requireList(result, 'records').single['values'],
          'values',
        );
        w2Expect(
          values['custom_note'] == 'Preserved note' &&
              !values.containsKey('secret'),
          'Effective schema or masking failed',
        );
      },
    );
    await cases.run(
      'W2-H016',
      'D08,J01',
      'Import preview requires current create and field-write grants',
      () async {
        final fields = {
          ...metadata(),
          'csv': 'id,Name\na,Asset',
          'mapping': {'Name': 'name'},
          'recordIdHeader': 'id',
        };
        w2Expect(
          (await f.http(
                'imports/preview',
                fields: fields,
                as: f.reader,
              )).status ==
              403,
          'Read-only user imported',
        );
        final creator = await f.provision(
          'blind-creator',
          permissions: [
            'extension.package.read',
            '$w2Permission.read',
            '$w2Permission.create',
          ],
        );
        final denied = await f.http(
          'imports/preview',
          as: creator,
          fields: {
            ...fields,
            'mapping': {'Name': 'secret'},
          },
        );
        w2Expect(denied.status == 400, 'Write-only denial not enforced');
        w2Expect(
          !canonicalJson(denied.body).contains('protected-fixture'),
          'Hidden value leaked',
        );
      },
    );
    await cases.run(
      'W2-H017',
      'J01,J03',
      'Preview preserves sparse source rows and detects readable existing IDs',
      () async {
        final result = await f.call(
          'imports/preview',
          fields: {
            ...metadata(),
            'csv': 'id,Name\nasset-150,Existing\nnew-b\nnew-c,Valid',
            'mapping': {'Name': 'name'},
            'recordIdHeader': 'id',
          },
        );
        final rows = requireList(result, 'rows');
        w2Equal(rows.map((r) => r['rowNumber']).toList(), [
          2,
          3,
          4,
        ], 'Source rows renumbered');
        w2Expect(
          (rows[0]['errors'] as List).contains('RECORD_ALREADY_EXISTS') &&
              (rows[1]['errors'] as List).contains('COLUMN_COUNT_MISMATCH') &&
              result['validRows'] == 1,
          'Preview identity/correlation mismatch',
        );
      },
    );
    await cases.run(
      'W2-H018',
      'M02,J01',
      'Configured import row bound is consumed by the real gateway',
      () async {
        await configure({'maxImportRows': 1});
        final reply = await f.http(
          'imports/preview',
          fields: {
            ...metadata(),
            'csv': 'id,Name\na,One\nb,Two',
            'mapping': {'Name': 'name'},
            'recordIdHeader': 'id',
          },
        );
        w2Expect(reply.status == 400, 'Configured limit ignored');
        await configure({});
      },
    );
    await cases.run(
      'W2-H019',
      'K08,D08',
      'Export projection matches query and safely escapes formula strings',
      () async {
        await f.execute(f.command(190, values: {'name': '=formula'}));
        final fields = {
          ...query(),
          'filters': {'name': '=formula'},
        };
        final result = await f.call('exports/page', fields: fields);
        w2Expect(result['status'] == 'EXPORT', 'Export failed');
        w2Equal(
          StructuredCsv.decode(result['csv'] as String),
          [
            ['recordId', 'name'],
            ['asset-190', "'=formula"],
          ],
          'Export changed projection or formula escape',
        );
        w2Expect(
          (await f.http(
                'exports/page',
                as: f.reader,
                fields: {
                  ...fields,
                  'columns': ['secret'],
                },
              )).status ==
              403,
          'Hidden field exported',
        );
      },
    );
    await cases.run(
      'W2-H020',
      'K08,B09,D08',
      'Hidden fields cannot be used to filter or sort visible exports',
      () async {
        for (final fields in [
          {
            ...query(),
            'filters': {'secret': 'protected-fixture'},
          },
          {...query(), 'sortField': 'secret'},
        ]) {
          final reply = await f.http(
            'exports/page',
            as: f.reader,
            fields: fields,
          );
          w2Expect(reply.status == 403, 'Hidden-field inference admitted');
          w2Expect(
            !canonicalJson(reply.body).contains('protected-fixture'),
            'Hidden values disclosed',
          );
        }
      },
    );
    await cases.run(
      'W2-H021',
      'K08,B09',
      'Query cursors bind pagination to filter sort limit release and scope',
      () async {
        await f.execute(f.command(210));
        final first = await f.call(
          'records/query',
          fields: {...query(), 'limit': 1, 'sortField': 'name'},
        );
        final cursor = first['nextCursor'];
        w2Expect(
          first['hasMore'] == true && cursor is String,
          'Pagination fixture did not produce a cursor',
        );
        final second = await f.call(
          'records/query',
          fields: {
            ...query(),
            'limit': 1,
            'sortField': 'name',
            'cursor': cursor,
          },
        );
        w2Expect(
          requireList(first, 'records').single['recordId'] !=
              requireList(second, 'records').single['recordId'],
          'Cursor repeated first page',
        );
        for (final changed in [
          {
            'filters': {'name': 'Other'},
          },
          {'limit': 2},
          {'companyId': 'company-b', 'branchId': 'branch-b'},
        ]) {
          w2Expect(
            (await f.http(
                  'records/query',
                  fields: {
                    ...query(),
                    'limit': 1,
                    'sortField': 'name',
                    'cursor': cursor,
                    ...changed,
                  },
                )).status ==
                400,
            'Cursor replay across context admitted',
          );
        }
      },
    );
    await cases.run(
      'W2-H022',
      'H04',
      'History is ordered metadata-only activity and command replay creates no duplicate event',
      () async {
        final command = f.command(
          220,
          values: {'name': 'History', 'secret': 'history-hidden'},
        );
        await f.execute(command);
        await f.execute(command);
        final result = await f.call(
          'history/list',
          fields: {
            ...metadata(),
            'recordId': command.aggregateId,
            'limit': 100,
          },
        );
        final entries = requireList(result, 'entries');
        w2Expect(
          entries.length == 1 &&
              entries.single['commandId'] == command.commandId,
          'History duplicated command',
        );
        w2Expect(
          !canonicalJson(result).contains('history-hidden') &&
              !canonicalJson(result).contains('values'),
          'History disclosed field values',
        );
      },
    );
    await cases.run(
      'W2-H023',
      'H04',
      'History cursor and deleted-ID lookup stay record and tenant bound',
      () async {
        await f.installBundle(
          f.outsider,
          ExtensionBundle.fromJson(w2BundleJson()),
        );
        final result = await f.call(
          'history/list',
          fields: {...metadata(), 'recordId': 'asset-220'},
        );
        final cursor = requireList(result, 'entries').single['eventId'];
        w2Expect(
          (await f.http(
                'history/list',
                fields: {
                  ...metadata(),
                  'recordId': 'different',
                  'cursor': cursor,
                },
              )).status ==
              400,
          'Cursor crossed record',
        );
        w2Expect(
          (await f.http(
                'history/list',
                as: f.outsider,
                fields: {
                  ...metadata(),
                  'recordId': 'asset-220',
                  'cursor': cursor,
                },
              )).status ==
              400,
          'Cursor crossed tenant',
        );
        final deletion = ExtensionRecordCommand.delete(
          commandId: w2Id(231),
          tenantId: W2Fixture.tenant,
          companyId: W2Fixture.company,
          branchId: W2Fixture.branch,
          recordId: 'asset-220',
          expectedRevision: 1,
          actorId: f.author.actor,
          deviceId: f.author.device,
          moduleId: w2Module,
          moduleVersion: '1.0.0',
          docType: 'Asset',
          schemaVersion: 1,
        ).envelope;
        w2Expect(
          (await f.execute(deletion))['status'] == 'ACCEPTED',
          'Delete fixture failed',
        );
        final history = await f.call(
          'history/list',
          fields: {...metadata(), 'recordId': 'asset-220'},
        );
        w2Expect(
          requireList(history, 'entries').length == 2,
          'Deleted record lost authorized history',
        );
      },
    );
    await cases.run(
      'W2-H024',
      'M01',
      'Organization CAS retries do not duplicate entities or confer grants',
      () async {
        final change = {
          'kind': 'company',
          'id': 'company-created',
          'displayName': 'Created company',
          'archived': false,
          'expectedRevision': 0,
          'requestId': w2Id(24),
        };
        final before = await f.observer.execute(
          'SELECT count(*) FROM public.ventio_identity_grants',
        );
        final first = await f.call(
          'organization/change',
          fields: {'change': change},
        );
        w2Equal(
          await f.call('organization/change', fields: {'change': change}),
          first,
          'Retry changed revision',
        );
        final conflict = await f.call(
          'organization/change',
          status: 409,
          fields: {
            'change': {
              ...change,
              'requestId': w2Id(241),
              'displayName': 'Stale rename',
            },
          },
        );
        w2Expect(conflict['reasonCode'] == 'ENTITY_CHANGED', 'CAS ignored');
        w2Equal(
          (await f.observer.execute(
            'SELECT count(*) FROM public.ventio_identity_grants',
          )).single,
          before.single,
          'Creation granted authority',
        );
      },
    );
    await cases.run(
      'W2-H025',
      'M01,D09',
      'Current scope cannot be archived and unauthorized hierarchy changes are denied',
      () async {
        final change = {
          'kind': 'branch',
          'id': W2Fixture.branch,
          'parentId': W2Fixture.company,
          'displayName': 'Current',
          'archived': true,
          'expectedRevision': 1,
          'requestId': w2Id(25),
        };
        w2Expect(
          (await f.call(
                'organization/change',
                status: 403,
                fields: {'change': change},
              ))['reasonCode'] ==
              'CURRENT_SCOPE_IN_USE',
          'Current scope archived',
        );
        w2Expect(
          (await f.http(
                'organization/change',
                as: f.reader,
                fields: {'change': change},
              )).status ==
              403,
          'Reader altered hierarchy',
        );
      },
    );
    await cases.run(
      'W2-H026',
      'C12,F05',
      'Dashboard report query uses approved metadata and rejects unknown filters/report IDs',
      () async {
        final body = {
          'companyId': W2Fixture.company,
          'branchId': W2Fixture.branch,
          'moduleId': w2Module,
          'version': '1.0.0',
          'docType': 'Asset',
          'reportId': 'asset_count',
          'filters': <String, dynamic>{},
        };
        final reply = await send(
          f.api,
          path: '/api/v1/extensions/reports/query',
          token: f.reader.token,
          body: body,
        );
        w2Expect(
          reply.status == 200 &&
              requireMap(reply.body['reportResult'], 'report')['rowCount'] == 3,
          'Report rows differ from committed undeleted records',
        );
        final invalid = await send(
          f.api,
          path: '/api/v1/extensions/reports/query',
          token: f.reader.token,
          body: {
            ...body,
            'filters': {'secret': 'hidden'},
          },
        );
        w2Expect(
          invalid.status == 422 &&
              requireMap(
                    invalid.body['reportResult'],
                    'report',
                  )['reasonCode'] ==
                  'INVALID_REPORT_FILTER',
          'Undeclared filter accepted',
        );
        w2Expect(
          (await send(
                f.api,
                path: '/api/v1/extensions/reports/query',
                token: f.reader.token,
                body: {...body, 'reportId': 'missing'},
              )).status ==
              404,
          'Unknown report accepted',
        );
      },
    );
    await cases.run(
      'W2-H027',
      'M05,M09',
      'HTTP operation requests do not execute local operations when not provisioned',
      () async {
        final result = await f.call(
          'operations/prepare',
          status: 403,
          fields: {
            'operationId': w2Id(27),
            'operation': 'BACKUP_NOW',
            'body': <String, dynamic>{},
          },
        );
        w2Expect(
          result['reasonCode'] == 'LOCAL_OPERATIONS_NOT_PROVISIONED',
          'HTTP executed local backup',
        );
        final list = await f.call('operations/list');
        w2Expect(
          list['localDeliveryAvailable'] == false &&
              list['deliveryStatus'] == 'NOT_PROVISIONED',
          'Delivery status lied',
        );
      },
    );
    await cases.run(
      'W2-H028',
      'A12,K09',
      'Rebase agrees with Core and requires every affected scope atomically before approval',
      () async {
        final reviewer = await f.provision(
          'rebase-reviewer',
          permissions: W2Fixture.permissions,
          secondScope: true,
        );
        final secondScope = {'companyId': 'company-b', 'branchId': 'branch-b'};
        final secondSaved = await f.call(
          'definitions/save',
          fields: {
            ...secondScope,
            'kind': 'customization',
            'id': '$w2Module:1.0.0:Asset',
            'expectedRevision': 0,
            'requestId': w2Id(2800),
            'body': w2Overlay(
              hash: f.digest(ExtensionBundle.fromJson(w2BundleJson())),
            ),
          },
        );
        w2Expect(secondSaved['status'] == 'SAVED', 'Second scope not prepared');
        final target = ExtensionBundle.fromJson(w2BundleJson(version: '1.1.0'));
        final session = await f.authenticator.authenticate(f.author.token);
        w2Expect(
          (await f.packages.submit(
                session: session!,
                companyId: W2Fixture.company,
                branchId: W2Fixture.branch,
                bundle: target,
              ))['status'] ==
              'SUBMITTED',
          'Target not submitted',
        );
        final fields = {
          'moduleId': w2Module,
          'sourceVersion': '1.0.0',
          'targetVersion': '1.1.0',
          'docType': 'Asset',
        };
        final preview = await f.call(
          'customizations/rebase/preview',
          fields: fields,
          as: reviewer,
        );
        w2Expect(preview['status'] == 'REBASE_CANDIDATE', 'Rebase unavailable');
        w2Equal(
          preview['body'],
          MetadataCustomization.fromJson(
            requireMap(preview['source'], 'source'),
          ).rebase(target, f.digest(target)).json,
          'Rebase differs from Core',
        );
        final stale = await f.call(
          'customizations/rebase/prepare',
          status: 409,
          as: reviewer,
          fields: {...fields, 'sourceRevision': 99, 'body': preview['body']},
        );
        w2Expect(
          stale['reasonCode'] == 'REBASE_CHANGED',
          'Stale rebase accepted',
        );
        final prepared = await f.call(
          'customizations/rebase/prepare',
          as: reviewer,
          fields: {
            ...fields,
            'sourceRevision': preview['sourceRevision'],
            'body': preview['body'],
          },
        );
        w2Expect(prepared['status'] == 'REBASE_PREPARED', 'Preparation failed');
        Future<Object?> overlaySnapshot() async => (await f.observer.execute(
          pg.Sql.named('''
            SELECT coalesce(jsonb_agg(to_jsonb(d) ORDER BY company_id,branch_id,definition_id),'[]')::text
            FROM public.ventio_wave2_definitions d
            WHERE tenant_id=@tenant AND kind='customization' AND body->>'moduleId'=@module
          '''),
          parameters: {'tenant': W2Fixture.tenant, 'module': w2Module},
        )).single[0];
        final overlaysBefore = await overlaySnapshot();
        final reviewerSession = await f.authenticator.authenticate(
          reviewer.token,
        );
        pg.ServerException? blocked;
        try {
          await PostgresExtensionPackageReviewGateway(
            pool: f.apiPool,
            admission: f.authority,
          ).review(
            session: reviewerSession!,
            companyId: W2Fixture.company,
            branchId: W2Fixture.branch,
            moduleId: w2Module,
            version: '1.1.0',
            packageSha256: f.digest(target),
            decision: 'APPROVE',
          );
        } on pg.ServerException catch (error) {
          blocked = error;
        }
        w2Expect(
          blocked?.code == '23514',
          'Missing scope rebase did not block release',
        );
        w2Equal(
          await overlaySnapshot(),
          overlaysBefore,
          'Failed approval partially activated an overlay',
        );
        final candidate = await f.observer.execute(
          pg.Sql.named(
            'SELECT status FROM public.ventio_extension_packages WHERE tenant_id=@tenant AND module_id=@module AND version=\'1.1.0\'',
          ),
          parameters: {'tenant': W2Fixture.tenant, 'module': w2Module},
        );
        w2Expect(
          candidate.single[0] == 'SUBMITTED',
          'Failed approval changed candidate status',
        );
        final otherPreview = await f.call(
          'customizations/rebase/preview',
          as: reviewer,
          fields: {...fields, ...secondScope},
        );
        final otherPrepared = await f.call(
          'customizations/rebase/prepare',
          as: reviewer,
          fields: {
            ...fields,
            ...secondScope,
            'sourceRevision': otherPreview['sourceRevision'],
            'body': otherPreview['body'],
          },
        );
        w2Expect(
          otherPrepared['status'] == 'REBASE_PREPARED',
          'Second rebase preparation failed',
        );
        final approved = await send(
          f.api,
          token: reviewer.token,
          path: '/api/v1/extensions/review',
          body: {
            'companyId': W2Fixture.company,
            'branchId': W2Fixture.branch,
            'moduleId': w2Module,
            'version': '1.1.0',
            'packageSha256': f.digest(target),
            'decision': 'APPROVE',
          },
        );
        w2Expect(approved.status == 200, 'Prepared release approval failed');
        final otherEffective = await f.call(
          'metadata/effective',
          fields: {
            ...metadata(version: '1.1.0'),
            ...secondScope,
          },
        );
        w2Expect(
          ExtensionBundle.fromJson(
            requireMap(otherEffective['package'], 'package'),
          ).docTypes.single.fields.any((field) => field.name == 'custom_note'),
          'Approval failed to activate the second scope overlay',
        );
        final effective = await f.call(
          'metadata/effective',
          fields: metadata(version: '1.1.0'),
        );
        w2Expect(
          ExtensionBundle.fromJson(
            requireMap(effective['package'], 'package'),
          ).docTypes.single.fields.any((field) => field.name == 'custom_note'),
          'Atomic activation lost custom field',
        );
        final preserved = await f.call(
          'records/query',
          fields: {
            ...query(version: '1.1.0'),
            'recordId': 'asset-150',
            'columns': ['name', 'custom_note'],
          },
        );
        w2Expect(
          requireList(preserved, 'records').single['values']['custom_note'] ==
              'Preserved note',
          'Release lost stored values',
        );
      },
    );
    await cases.run(
      'W2-H029',
      'F05,C08,D09',
      'Release revocation denies metadata queries and dashboard reports despite stored local definitions',
      () async {
        await ExtensionPackageAdministration(
          connection: f.administrator,
          tenantId: W2Fixture.tenant,
          operatorLabel: 'wave2-fixture',
          authority: f.authority,
        ).revoke(
          moduleId: w2Module,
          version: '1.1.0',
          packageSha256: f.digest(
            ExtensionBundle.fromJson(w2BundleJson(version: '1.1.0')),
          ),
          reason: 'Disposable regression',
        );
        final reply = await f.http(
          'metadata/effective',
          fields: metadata(version: '1.1.0'),
        );
        w2Expect(
          reply.status == 403,
          'Revoked release supplied effective metadata',
        );
        final report = await send(
          f.api,
          token: f.author.token,
          path: '/api/v1/extensions/reports/query',
          body: {
            'companyId': W2Fixture.company,
            'branchId': W2Fixture.branch,
            'moduleId': w2Module,
            'version': '1.1.0',
            'docType': 'Asset',
            'reportId': 'asset_count',
            'filters': <String, dynamic>{},
          },
        );
        w2Expect(report.status == 404, 'Revoked release executed report');
      },
    );
  } finally {
    await f.close();
  }
}
