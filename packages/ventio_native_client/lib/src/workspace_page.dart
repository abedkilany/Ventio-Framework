import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:ventio_core/ventio_core.dart';

import 'app_database.dart';
import 'app_localization.dart';
import 'command_id.dart';
import 'extension_store.dart';
import 'host_extension_packages.dart';
import 'workspace_store.dart';
import 'platform_administration_page.dart';
import 'document_activity_page.dart';
import 'host_operations_page.dart';
import 'extension_studio_page.dart' show DynamicRecordFormPage;
import 'local_command_queue.dart';

/// Native workspace. Only definitions/preferences are available offline here;
/// business records and reports always come from an authorized Host request.
class WorkspacePage extends StatefulWidget {
  const WorkspacePage({
    required this.client,
    required this.profile,
    required this.extensions,
    required this.queue,
    super.key,
  });
  final HostExtensionPackageClient client;
  final HostConnectionProfile profile;
  final LocalExtensionStore extensions;
  final LocalCommandQueue queue;
  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  WorkspaceStore? _store;
  HostSessionIdentity? _identity;
  final Map<String, ExtensionBundle> _bundles = {};
  final Map<String, ExtensionBundle> _cachedBundles = {};
  List<Map<String, dynamic>> _views = [],
      _dashboards = [],
      _customizations = [];
  List<Map<String, Object?>> _pendingJobs = [];
  List<dynamic> _jobs = [];
  List<QueueEntry> _recordDrafts = [];
  Set<String> _reconciledIds = {};
  Map<String, dynamic>? _configuration;
  Map<String, dynamic> _preferences = {
    'contractVersion': 1,
    'density': 'comfortable',
    'theme': 'system',
    'moduleOrder': <String>[],
  };
  String? _error;
  bool _busy = true;
  int _tab = 0;

  String t(String key, String fallback) =>
      context.extensionMetadataText('native.wave2.$key', fallback);
  Map<String, Object?> get _scope => {
    'companyId': widget.profile.companyId,
    'branchId': widget.profile.branchId,
  };
  Set<String> get _permissions =>
      _identity?.scopes
          .where(
            (scope) =>
                scope.companyId == widget.profile.companyId &&
                scope.branchId == widget.profile.branchId,
          )
          .expand((scope) => scope.permissions)
          .toSet() ??
      {};

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _store?.close();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final directory = await ventioApplicationSupportDirectory();
      final store = await WorkspaceStore.open(
        factory: databaseFactoryForCurrentPlatform(),
        path: p.join(directory.path, 'ventio_workspace.sqlite3'),
        profile: widget.profile,
      );
      if (!mounted) {
        await store.close();
        return;
      }
      _store = store;
      await _local();
      await _refresh();
    } catch (error) {
      _failed(error);
    }
  }

  Future<void> _local() async {
    final store = _store!;
    final views = await store.list('saved_view');
    final dashboards = await store.list('dashboard');
    final customizations = await store.list('customization');
    final preferences = await store.list('preferences');
    final pending = await store.pendingJobs();
    final cached = await store.cachedBundles();
    final queued = await widget.queue.list(limit: 1000);
    if (!mounted) return;
    setState(() {
      _cachedBundles
        ..clear()
        ..addEntries(cached.map((bundle) => MapEntry(bundle.moduleId, bundle)));
      _views = views;
      _dashboards = dashboards;
      _customizations = customizations;
      _pendingJobs = pending;
      _reconciledIds = queued
          .map((e) => e.reconcilesCommandId)
          .whereType<String>()
          .toSet();
      _recordDrafts = queued
          .where(
            (e) =>
                !e.projectToLocalRecords &&
                e.envelope.tenantId == widget.profile.tenantId &&
                e.envelope.companyId == widget.profile.companyId &&
                e.envelope.branchId == widget.profile.branchId &&
                e.envelope.actorId == widget.profile.actorId &&
                e.envelope.deviceId == widget.profile.deviceId &&
                const {
                  HostCommandStatus.conflict,
                  HostCommandStatus.rejected,
                }.contains(e.hostStatus),
          )
          .toList();
      if (preferences.isNotEmpty)
        _preferences = requireMap(preferences.first['body'], 'preferences');
    });
  }

  Future<void> _checkLocalProfile() async {
    final current = await widget.extensions.getHostProfile();
    final expected = widget.profile;
    if (current == null ||
        current.endpoint != expected.endpoint ||
        current.tenantId != expected.tenantId ||
        current.actorId != expected.actorId ||
        current.deviceId != expected.deviceId ||
        current.companyId != expected.companyId ||
        current.branchId != expected.branchId) {
      throw const HostSessionIdentityException(
        'HOST_SESSION_IDENTITY_MISMATCH',
      );
    }
  }

  Future<void> _checkIdentity() async {
    await _checkLocalProfile();
    final expected = widget.profile;
    final identity = await widget.client.session();
    bindHostProfileToIdentity(profile: expected, identity: identity);
    if (mounted) setState(() => _identity = identity);
  }

  Future<Map<String, dynamic>> _request(
    String action,
    Map<String, Object?> body,
  ) async {
    await _checkIdentity();
    return widget.client.platformRequest(action, {..._scope, ...body});
  }

  Future<void> _refresh() async {
    if (!mounted || _store == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _bundles.clear();
      _jobs = [];
      _identity = null;
    });
    try {
      await _checkIdentity();
      if (_permissions.contains(wave2WorkspacePermission)) {
        for (final kind in ['saved_view', 'preferences', 'dashboard']) {
          final result = await _request('definitions/list', {'kind': kind});
          await _store!.receive(kind, requireList(result, 'definitions'));
        }
      }
      if (_permissions.contains('extension.package.read')) {
        final result = await _request('definitions/list', {
          'kind': 'customization',
        });
        await _store!.receive(
          'customization',
          requireList(result, 'definitions'),
        );
      }
      final installed = await widget.extensions.listExtensions();
      for (final extension in installed.where(
        (item) => item.state == ExtensionState.active,
      )) {
        try {
          final local = await widget.extensions.exportBundle(
            extension.moduleId,
          );
          final digest = sha256
              .convert(utf8.encode(canonicalJson(local.toJson())))
              .toString();
          final approved = await widget.client.readApproved(
            companyId: widget.profile.companyId,
            branchId: widget.profile.branchId,
            moduleId: extension.moduleId,
            version: extension.version,
            expectedPackageSha256: digest,
          );
          await _store!.cacheBundle(approved);
          if (mounted) setState(() => _bundles[approved.moduleId] = approved);
        } on HostPackageTransportException {
          // An unavailable/unapproved package contributes no workspace links.
        }
      }
      if (_permissions.contains(hostStatusReadPermission)) {
        final result = await _request('definitions/list', {
          'kind': 'configuration',
        });
        final definitions = requireList(result, 'definitions');
        if (mounted)
          setState(
            () => _configuration = definitions.isEmpty
                ? null
                : requireMap(definitions.first, 'configuration'),
          );
      }
      if (_permissions.contains(wave2JobsRunPermission) ||
          _permissions.contains(wave2JobsManagePermission)) {
        final result = await _request('jobs/list', {});
        if (mounted) setState(() => _jobs = requireList(result, 'jobs'));
      }
      await _local();
      if (mounted) setState(() => _busy = false);
    } catch (error) {
      _failed(error);
    }
  }

  void _failed(Object error) {
    if (!mounted) return;
    final code = switch (error) {
      HostPackageTransportException(:final code) => code,
      HostSessionIdentityException(:final code) => code,
      ContractError(:final code) => code,
      _ => 'WORKSPACE_UNAVAILABLE',
    };
    setState(() {
      _error = code;
      _busy = false;
      _identity = null;
      _bundles.clear();
      _configuration = null;
      _jobs = [];
    });
  }

  Future<void> _publish(Map<String, dynamic> entry) async {
    if (_store == null) return;
    try {
      final result = await _request('definitions/save', {
        'kind': entry['kind'],
        'id': entry['id'],
        'expectedRevision': entry['revision'],
        'requestId': entry['request_id'],
        'body': entry['body'],
      });
      await _store!.acknowledge(
        entry['kind'] as String,
        entry['id'] as String,
        entry['request_id'] as String,
        requireInt(result, 'revision', min: 1),
      );
      await _refresh();
    } catch (error) {
      _failed(error);
      await _local();
    }
  }

  Future<void> _rebase(Map<String, dynamic> entry) async {
    try {
      final kind = entry['kind'] as String;
      final result = await _request('definitions/list', {'kind': kind});
      final matches = requireList(result, 'definitions')
          .map((raw) => requireMap(raw, 'definition'))
          .where((item) => item['id'] == entry['id'])
          .toList();
      if (matches.length != 1) return;
      final remote = matches.single;
      var body = requireMap(entry['body'], 'body');
      if (kind == 'customization') {
        final remoteBody = requireMap(remote['body'], 'body');
        final fields = {
          for (final raw in requireList(remoteBody, 'fields'))
            requireString(requireMap(raw, 'field'), 'name'): requireMap(
              raw,
              'field',
            ),
        };
        for (final raw in requireList(body, 'fields')) {
          final field = requireMap(raw, 'field');
          fields[requireString(field, 'name')] = field;
        }
        body = {...body, 'fields': fields.values.toList()};
        final bundle =
            _bundles[body['moduleId']] ?? _cachedBundles[body['moduleId']];
        if (bundle == null) return;
        MetadataCustomization.fromJson(
          body,
        ).merge(bundle, previous: MetadataCustomization.fromJson(remoteBody));
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(t('rebase', 'Rebase preserved draft')),
          content: Text(
            '${t('rebase_explanation', 'Keep your draft values and publish against the displayed Host revision. New Host custom fields are retained.')} ${remote['revision']}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('cancel', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('rebase', 'Rebase preserved draft')),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      await _store!.rebaseDraft(
        kind,
        entry['id'] as String,
        requireInt(remote, 'revision', min: 1),
        body,
      );
      await _local();
    } catch (error) {
      _failed(error);
    }
  }

  Future<void> _configure() async {
    final body = _configuration == null
        ? <String, dynamic>{
            'contractVersion': 1,
            'displayName': widget.profile.branchId,
            'maintenanceNotice': '',
          }
        : requireMap(_configuration!['body'], 'configuration');
    final name = TextEditingController(text: body['displayName'] as String);
    final notice = TextEditingController(
      text: body['maintenanceNotice'] as String,
    );
    final page = TextEditingController(
      text: '${body['defaultPageSize'] ?? 50}',
    );
    final rows = TextEditingController(text: '${body['maxImportRows'] ?? 500}');
    final retention = TextEditingController(
      text: '${body['completedJobRetentionDays'] ?? 30}',
    );
    var maintenance = body['maintenanceMode'] == true;
    var paused = body['jobsPaused'] == true;
    final key = GlobalKey<FormState>();
    try {
      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: Text(t('configuration', 'Scoped configuration')),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Form(
                  key: key,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: name,
                        maxLength: 120,
                        decoration: InputDecoration(
                          labelText: context.ventioText(
                            'native.wave2.scope_display_name_2c4cbe78',
                          ),
                        ),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? 'Enter a name'
                            : null,
                      ),
                      TextFormField(
                        controller: notice,
                        maxLength: 1000,
                        maxLines: 3,
                        decoration: InputDecoration(
                          labelText: context.ventioText(
                            'native.wave2.operational_notice_cbdc54d3',
                          ),
                        ),
                      ),
                      SwitchListTile(
                        title: const VentioText(
                          'native.wave2.maintenance_mode_1e322b6f',
                        ),
                        subtitle: const VentioText(
                          'native.wave2.pause_new_business_writes_in_this_scope_saved_co_04f166d6',
                        ),
                        value: maintenance,
                        onChanged: (v) => update(() => maintenance = v),
                      ),
                      SwitchListTile(
                        title: const VentioText(
                          'native.wave2.pause_background_jobs_1cc36002',
                        ),
                        value: paused,
                        onChanged: (v) => update(() => paused = v),
                      ),
                      TextFormField(
                        controller: page,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: context.ventioText(
                            'native.wave2.default_page_size_1_100_a02b2226',
                          ),
                        ),
                        validator: (v) =>
                            (int.tryParse(v ?? '') ?? 0) < 1 ||
                                (int.tryParse(v ?? '') ?? 101) > 100
                            ? 'Enter 1 to 100'
                            : null,
                      ),
                      TextFormField(
                        controller: rows,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: context.ventioText(
                            'native.wave2.maximum_csv_data_rows_1_500_82fe4361',
                          ),
                        ),
                        validator: (v) =>
                            (int.tryParse(v ?? '') ?? 0) < 1 ||
                                (int.tryParse(v ?? '') ?? 501) > 500
                            ? 'Enter 1 to 500'
                            : null,
                      ),
                      TextFormField(
                        controller: retention,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: context.ventioText(
                            'native.wave2.completed_job_retention_days',
                          ),
                        ),
                        validator: (v) =>
                            (int.tryParse(v ?? '') ?? 0) < 1 ||
                                (int.tryParse(v ?? '') ?? 3651) > 3650
                            ? context.ventioText(
                                'native.wave2.enter_retention_days',
                              )
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const VentioText('native.wave2.cancel_19766ed6'),
              ),
              FilledButton(
                onPressed: () {
                  if (key.currentState!.validate())
                    Navigator.pop(context, {
                      ...body,
                      'displayName': name.text.trim(),
                      'maintenanceNotice': notice.text,
                      'maintenanceMode': maintenance,
                      'jobsPaused': paused,
                      'defaultPageSize': int.parse(page.text),
                      'maxImportRows': int.parse(rows.text),
                      'completedJobRetentionDays': int.parse(retention.text),
                    });
                },
                child: const VentioText('native.wave2.save_draft_3de10010'),
              ),
            ],
          ),
        ),
      );
      if (result == null) return;
      if (_configuration != null)
        await _store!.receive('configuration', [_configuration!]);
      final draft = await _store!.saveDraft(
        'configuration',
        _configuration?['id'] as String? ?? 'scope',
        result,
      );
      await _publish(draft);
    } finally {
      name.dispose();
      notice.dispose();
      page.dispose();
      rows.dispose();
      retention.dispose();
    }
  }

  Future<void> _retrySubmissions() async {
    try {
      for (final row in await _store!.pendingJobs()) {
        final result = await _request('jobs/submit', {
          'jobId': row['job_id'],
          'commands': jsonDecode(row['commands'] as String),
          if (row['import_id'] != null) 'importId': row['import_id'],
          'sourceRows': jsonDecode(row['source_rows'] as String),
        });
        if (result['status'] != 'JOB' || result['jobId'] != row['job_id']) {
          throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
        }
        await _store!.acknowledgeJob(row['job_id'] as String);
      }
      await _refresh();
    } catch (error) {
      _failed(error);
      await _local();
    }
  }

  Future<void> _newView(
    ExtensionBundle bundle,
    DocTypeDefinition definition,
  ) async {
    final body = <String, dynamic>{
      'contractVersion': 1,
      'title': definition.label,
      'moduleId': bundle.moduleId,
      'moduleVersion': bundle.version,
      'docType': definition.name,
      'search': '',
      'filters': <String, dynamic>{},
      'sortField': null,
      'descending': false,
      'columns': definition.listColumns,
    };
    await _editView(body);
  }

  Future<void> _editView(
    Map<String, dynamic> body, {
    Map<String, dynamic>? entry,
  }) async {
    final bundle =
        _bundles[body['moduleId']] ?? _cachedBundles[body['moduleId']];
    if (bundle == null) return;
    ExtensionBundle effectiveBundle = bundle;
    if (_identity != null) {
      final effective = await _request('metadata/effective', {
        'moduleId': bundle.moduleId,
        'moduleVersion': bundle.version,
        'docType': body['docType'],
      });
      effectiveBundle = ExtensionBundle.fromJson(
        requireMap(effective['package'], 'package'),
      );
    } else {
      effectiveBundle = _displayBundle(bundle);
    }
    final definition = effectiveBundle.docTypes.singleWhere(
      (item) => item.name == body['docType'],
    );
    if (!mounted) return;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ViewEditor(body: body, definition: definition),
    );
    if (result == null || !mounted) return;
    await _store!.saveDraft(
      'saved_view',
      entry?['id'] as String? ?? createCommandId(),
      result,
    );
    await _local();
  }

  Future<void> _openView(Map<String, dynamic> body) async {
    try {
      await _checkIdentity();
      final bundle = _bundles[body['moduleId']];
      if (bundle == null || bundle.version != body['moduleVersion']) {
        throw const HostPackageTransportException(
          'HOST_PACKAGE_INTEGRITY_FAILED',
        );
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _RecordViewPage(
            view: SavedRecordView.fromJson(body),
            request: _request,
            editRecord: _form,
          ),
        ),
      );
    } catch (error) {
      _failed(error);
    }
  }

  ExtensionBundle _displayBundle(ExtensionBundle base) {
    var effective = base;
    for (final entry in _customizations.where(
      (entry) => entry['state'] == 'SYNCED',
    )) {
      final body = requireMap(entry['body'], 'body');
      if (body['moduleId'] == base.moduleId &&
          body['moduleVersion'] == base.version) {
        effective = MetadataCustomization.fromJson(body).merge(effective);
      }
    }
    return effective;
  }

  Future<void> _form(
    Map<String, dynamic> view,
    Map<String, dynamic>? record, {
    QueueEntry? recovering,
  }) async {
    try {
      final metadata = await _request('metadata/effective', {
        'moduleId': view['moduleId'],
        'moduleVersion': view['moduleVersion'],
        'docType': view['docType'],
      });
      final effective = ExtensionBundle.fromJson(
        requireMap(metadata['package'], 'package'),
      );
      final definition = effective.docTypes.singleWhere(
        (item) => item.name == view['docType'],
      );
      final operation = record == null ? 'create' : 'update';
      if (!definition.operations.contains(operation) ||
          !_permissions.contains(definition.permissions[operation])) {
        throw const HostPackageTransportException('PERMISSION_DENIED');
      }

      final columns = definition.fields
          .where(
            (field) =>
                field.readPermission == null ||
                _permissions.contains(field.readPermission),
          )
          .map((field) => field.name)
          .take(20)
          .toList();
      final current = await _request('records/query', {
        'moduleId': effective.moduleId,
        'moduleVersion': effective.version,
        'docType': definition.name,
        'columns': columns,
        'limit': 1,
        'recordId': record?['recordId'],
        'search': '',
        'filters': <String, dynamic>{},
      });
      final rows = requireList(current, 'records');
      final latest = record == null
          ? null
          : rows.isEmpty
          ? null
          : requireMap(rows.single, 'record');
      if (record != null && latest == null)
        throw const HostPackageTransportException('RECORD_UNAVAILABLE');
      final scope = RecordScope(
        organizationId: widget.profile.tenantId,
        companyId: widget.profile.companyId,
        branchId: widget.profile.branchId,
      );
      final localRecord = latest == null
          ? null
          : LocalExtensionRecord(
              recordId: latest['recordId'] as String,
              moduleId: effective.moduleId,
              docTypeName: definition.name,
              scope: scope,
              schemaVersion: definition.schemaVersion,
              revision: latest['revision'] as int,
              hostRevision: latest['revision'] as int,
              authorityState: 'HOST_ACCEPTED',
              values: requireMap(latest['values'], 'values'),
              updatedAtUtc: DateTime.parse(latest['updatedAtUtc'] as String),
            );
      final readable = strings(
        requireList(current, 'readableFields'),
        'fields',
      ).toSet();
      final allowed = strings(
        requireList(
          current,
          localRecord == null ? 'creatableFields' : 'writableFields',
        ),
        'fields',
      ).toSet();
      final patch = recovering == null
          ? <String, dynamic>{}
          : {
              for (final item in ExtensionRecordCommand.fromEnvelope(
                recovering.envelope,
              ).values.entries)
                if (readable.contains(item.key) &&
                    allowed.contains(item.key) &&
                    definition.fields.any(
                      (f) =>
                          f.name == item.key &&
                          !f.readOnly &&
                          f.calculation == null,
                    ))
                  item.key: item.value,
            };
      if (!mounted) return;
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => DynamicRecordFormPage(
            store: widget.extensions,
            definition: definition,
            moduleId: effective.moduleId,
            scope: scope,
            moduleVersion: effective.version,
            hostProfile: widget.profile,
            record: localRecord,
            initialRecordId: recovering?.envelope.aggregateId,
            initialValues: recovering == null
                ? null
                : {...?localRecord?.values, ...patch},
            initialChangedFields: patch.keys.toSet(),
            readableFields: strings(
              requireList(current, 'readableFields'),
              'fields',
            ).toSet(),
            writableFields: strings(
              requireList(current, 'writableFields'),
              'fields',
            ).toSet(),
            creatableFields: strings(
              requireList(current, 'creatableFields'),
              'fields',
            ).toSet(),
            referenceLoader: (docType) async {
              await _checkIdentity();
              final page = await widget.client.queryRecords(
                companyId: widget.profile.companyId,
                branchId: widget.profile.branchId,
                moduleId: effective.moduleId,
                version: effective.version,
                docType: docType,
                limit: 100,
              );
              return [
                for (final record in page.records)
                  LocalExtensionRecord(
                    recordId: record.recordId,
                    moduleId: effective.moduleId,
                    docTypeName: docType,
                    scope: scope,
                    schemaVersion: 1,
                    revision: record.revision,
                    hostRevision: record.revision,
                    values: record.values,
                    updatedAtUtc: DateTime.parse(record.updatedAtUtc),
                    authorityState: 'HOST_ACCEPTED',
                  ),
              ];
            },
            submitGovernedDraft: (recordId, values) async {
              await _checkLocalProfile();
              final command = localRecord == null
                  ? ExtensionRecordCommand.create(
                      commandId: createCommandId(),
                      tenantId: widget.profile.tenantId,
                      companyId: scope.companyId,
                      branchId: scope.branchId,
                      actorId: widget.profile.actorId!,
                      deviceId: widget.profile.deviceId!,
                      recordId: recordId,
                      moduleId: effective.moduleId,
                      moduleVersion: effective.version,
                      docType: definition.name,
                      schemaVersion: definition.schemaVersion,
                      values: values,
                    )
                  : ExtensionRecordCommand.update(
                      commandId: createCommandId(),
                      tenantId: widget.profile.tenantId,
                      companyId: scope.companyId,
                      branchId: scope.branchId,
                      actorId: widget.profile.actorId!,
                      deviceId: widget.profile.deviceId!,
                      recordId: recordId,
                      expectedRevision: localRecord.hostRevision!,
                      moduleId: effective.moduleId,
                      moduleVersion: effective.version,
                      docType: definition.name,
                      schemaVersion: definition.schemaVersion,
                      values: values,
                    );
              await widget.queue.enqueue(
                command.envelope,
                projectToLocalRecords: false,
                reconcilesCommandId: recovering?.envelope.commandId,
              );
            },
          ),
        ),
      );
    } catch (error) {
      _failed(error);
    }
  }

  Future<void> _recoverRecordDraft(QueueEntry entry) async {
    try {
      final original = ExtensionRecordCommand.fromEnvelope(entry.envelope);
      final bundle = _bundles[original.moduleId];
      if (bundle == null)
        throw const HostPackageTransportException('CURRENT_PACKAGE_REQUIRED');
      final binding = <String, dynamic>{
        'moduleId': bundle.moduleId,
        'moduleVersion': bundle.version,
        'docType': original.docType,
      };
      final page = await _request('records/query', {
        ...binding,
        'columns': <String>[],
        'recordId': entry.envelope.aggregateId,
        'limit': 1,
      });
      final rows = requireList(page, 'records');
      if (!mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const VentioText('native.wave2.review_record_draft'),
          content: const VentioText(
            'native.wave2.review_record_draft_explanation',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const VentioText('native.wave2.cancel_19766ed6'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const VentioText('native.wave2.review_record_draft'),
            ),
          ],
        ),
      );
      if (approved != true) return;
      if (rows.isEmpty && original.operation != 'create')
        throw const HostPackageTransportException('RECORD_UNAVAILABLE');
      await _form(
        binding,
        rows.isEmpty ? null : requireMap(rows.single, 'record'),
        recovering: entry,
      );
      await _local();
    } catch (error) {
      _failed(error);
    }
  }

  Future<void> _prepareReleaseRebase(Map<String, dynamic> entry) async {
    final version = TextEditingController();
    try {
      final target = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          title: const VentioText(
            'native.wave2.rebase_customization_to_submitted_release_d15da783',
          ),
          content: TextField(
            controller: version,
            decoration: InputDecoration(
              labelText: context.ventioText(
                'native.wave2.target_module_version_for_example_2_0_0_2534fb19',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const VentioText('native.wave2.cancel_19766ed6'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, version.text.trim()),
              child: const VentioText('native.wave2.preview_324b134f'),
            ),
          ],
        ),
      );
      if (target == null) return;
      final body = requireMap(entry['body'], 'body');
      final binding = <String, dynamic>{
        'moduleId': body['moduleId'],
        'sourceVersion': body['moduleVersion'],
        'targetVersion': target,
        'docType': body['docType'],
      };
      final preview = await _request('customizations/rebase/preview', binding);
      if (preview['status'] != 'REBASE_CANDIDATE')
        throw HostPackageTransportException(
          preview['reasonCode'] as String? ?? 'REBASE_UNAVAILABLE',
        );
      if (!mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const VentioText(
            'native.wave2.review_release_rebase_47aa1031',
          ),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const VentioText(
                    'native.wave2.every_custom_field_value_constraint_and_permissi_fc9efb40',
                  ),
                  SelectableText(
                    const JsonEncoder.withIndent('  ').convert(preview['body']),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const VentioText('native.wave2.cancel_19766ed6'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const VentioText(
                'native.wave2.prepare_atomic_activation_6fb36cd5',
              ),
            ),
          ],
        ),
      );
      if (approved != true) return;
      final result = await _request('customizations/rebase/prepare', {
        ...binding,
        'sourceRevision': preview['sourceRevision'],
        'body': preview['body'],
      });
      if (result['status'] != 'REBASE_PREPARED')
        throw HostPackageTransportException(
          result['reasonCode'] as String? ?? 'REBASE_CHANGED',
        );
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: VentioText(
              'native.wave2.rebase_prepared_independent_package_approval_rec_055cb04c',
            ),
          ),
        );
    } catch (error) {
      _failed(error);
    } finally {
      version.dispose();
    }
  }

  Future<void> _customize(
    ExtensionBundle bundle,
    DocTypeDefinition definition,
  ) async {
    final id = '${bundle.moduleId}:${bundle.version}:${definition.name}';
    final entries = _customizations.where((item) => item['id'] == id).toList();
    final existing = entries.isEmpty ? null : entries.single;
    final namespace =
        'extension.${bundle.moduleId.replaceAll(RegExp(r'[^a-z0-9]+'), '_')}';
    final body = existing == null
        ? <String, dynamic>{
            'contractVersion': 1,
            'moduleId': bundle.moduleId,
            'moduleVersion': bundle.version,
            'docType': definition.name,
            'baseSha256': sha256
                .convert(utf8.encode(canonicalJson(bundle.toJson())))
                .toString(),
            'fields': <dynamic>[],
            'properties': <String, dynamic>{},
            'ui': {
              'listColumns': definition.listColumns,
              'formFields': definition.formFields,
              'detailFields': definition.detailFields,
            },
          }
        : requireMap(existing['body'], 'customization');
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _CustomizationEditor(
        base: bundle,
        body: body,
        definition: definition,
        namespace: namespace,
      ),
    );
    if (result == null || !mounted) return;
    MetadataCustomization.fromJson(result).merge(
      bundle,
      previous: existing == null
          ? null
          : MetadataCustomization.fromJson(
              requireMap(existing['body'], 'body'),
            ),
    );
    await _store!.saveDraft('customization', id, result);
    await _local();
  }

  Future<void> _import(
    ExtensionBundle bundle,
    DocTypeDefinition definition,
  ) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _ImportPage(
          bundle: bundle,
          definition: definition,
          profile: widget.profile,
          request: _request,
          store: _store!,
        ),
      ),
    );
    if (result == true && mounted) {
      await _local();
      await _retrySubmissions();
    }
  }

  Future<void> _addReport(
    ExtensionBundle bundle,
    ReportDefinition report,
  ) async {
    final existing = _dashboards.where((item) => item['id'] == 'home').toList();
    final body = existing.isEmpty
        ? <String, dynamic>{
            'contractVersion': 1,
            'title': t('my_dashboard', 'My dashboard'),
            'cards': <dynamic>[],
          }
        : requireMap(existing.single['body'], 'dashboard');
    final cards = List<dynamic>.of(requireList(body, 'cards'));
    cards.add({
      'title': report.label,
      'moduleId': bundle.moduleId,
      'moduleVersion': bundle.version,
      'docType': report.docType,
      'reportId': report.id,
      'filters': <String, dynamic>{},
    });
    await _store!.saveDraft('dashboard', 'home', {...body, 'cards': cards});
    await _local();
  }

  Future<void> _report(Map<String, dynamic> card) async {
    try {
      await _checkIdentity();
      final bundle = _bundles[card['moduleId']];
      if (bundle == null || bundle.version != card['moduleVersion']) {
        throw const HostPackageTransportException(
          'HOST_PACKAGE_INTEGRITY_FAILED',
        );
      }
      final result = await widget.client.queryReport(
        companyId: widget.profile.companyId,
        branchId: widget.profile.branchId,
        moduleId: bundle.moduleId,
        version: bundle.version,
        docType: card['docType'] as String,
        reportId: card['reportId'] as String,
        filters: requireMap(card['filters'], 'filters'),
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(card['title'] as String),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${result.rowCount} ${t('rows', 'rows')}'),
                  for (final group in result.groups)
                    ListTile(
                      title: Text('${group.key ?? t('all', 'All records')}'),
                      subtitle: Text(
                        group.aggregates.entries
                            .map((entry) => '${entry.key}: ${entry.value}')
                            .join('  '),
                      ),
                    ),
                  if (result.groups.isEmpty)
                    Text(t('empty', 'No data to display.')),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('close', 'Close')),
            ),
          ],
        ),
      );
    } catch (error) {
      _failed(error);
    }
  }

  Future<void> _preference(String key, Object value) async {
    await _store!.saveDraft('preferences', 'interface', {
      ..._preferences,
      key: value,
    });
    await _local();
  }

  Widget _draftTile(
    Map<String, dynamic> entry, {
    VoidCallback? onTap,
  }) => ListTile(
    title: Text(
      (entry['body'] as Map)['title'] as String? ?? entry['id'] as String,
    ),
    subtitle: Text(
      '${entry['state']} · ${t('revision', 'Revision')} ${entry['revision']}',
    ),
    onTap: onTap,
    trailing: entry['state'] == 'CONFLICT'
        ? IconButton(
            icon: const Icon(Icons.merge_type),
            tooltip: t('rebase', 'Rebase preserved draft'),
            onPressed: _busy ? null : () => _rebase(entry),
          )
        : entry['state'] == 'SYNCED'
        ? null
        : IconButton(
            icon: const Icon(Icons.cloud_upload_outlined),
            tooltip: t('publish', 'Publish to Host'),
            onPressed: _busy || entry['state'] == 'CONFLICT'
                ? null
                : () => _publish(entry),
          ),
  );

  List<ExtensionBundle> get _orderedBundles {
    final order = List<String>.from(_preferences['moduleOrder'] as List);
    int rank(String id) =>
        order.contains(id) ? order.indexOf(id) : order.length;
    return _bundles.values.toList()..sort((a, b) {
      final byRank = rank(a.moduleId).compareTo(rank(b.moduleId));
      return byRank == 0
          ? a.manifest.displayName.compareTo(b.manifest.displayName)
          : byRank;
    });
  }

  Widget _modules() => ListView(
    children: [
      if (_bundles.isEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t(
              'no_modules',
              'No authorized, installed Host-approved modules are available.',
            ),
          ),
        ),
      for (final bundle in _orderedBundles.map(_displayBundle))
        ExpansionTile(
          title: Text(bundle.manifest.displayName),
          trailing: IconButton(
            icon: const Icon(Icons.vertical_align_top),
            tooltip: t('move_first', 'Move first'),
            onPressed: () => _preference('moduleOrder', [
              bundle.moduleId,
              ..._orderedBundles
                  .where((item) => item.moduleId != bundle.moduleId)
                  .map((item) => item.moduleId),
            ]),
          ),
          children: [
            for (final definition
                in (bundle.docTypes.toList()
                  ..sort((a, b) => a.pageOrder.compareTo(b.pageOrder))))
              if (_permissions.contains(definition.permissions['read']))
                ListTile(
                  title: Text(definition.pageTitle),
                  onTap: () => _openView({
                    'contractVersion': 1,
                    'title': definition.label,
                    'moduleId': bundle.moduleId,
                    'moduleVersion': bundle.version,
                    'docType': definition.name,
                    'search': '',
                    'filters': <String, dynamic>{},
                    'sortField': null,
                    'descending': false,
                    'columns': definition.listColumns,
                  }),
                  trailing: Wrap(
                    children: [
                      IconButton(
                        tooltip: t('save_view', 'Save a view'),
                        icon: const Icon(Icons.bookmark_add_outlined),
                        onPressed:
                            _permissions.contains(wave2WorkspacePermission)
                            ? () async {
                                try {
                                  await _newView(bundle, definition);
                                } catch (e) {
                                  _failed(e);
                                }
                              }
                            : null,
                      ),
                      if (_permissions.contains(wave2JobsRunPermission) &&
                          _permissions.contains(
                            definition.permissions['create'],
                          ))
                        IconButton(
                          tooltip: t('import', 'Import CSV'),
                          icon: const Icon(Icons.upload_file),
                          onPressed: () => _import(bundle, definition),
                        ),
                      if (_permissions.contains(
                        wave2CustomizationManagePermission,
                      ))
                        IconButton(
                          tooltip: t('customize', 'Customize'),
                          icon: const Icon(Icons.tune),
                          onPressed: () async {
                            try {
                              final base = _bundles[bundle.moduleId]!;
                              await _customize(
                                base,
                                base.docTypes.singleWhere(
                                  (item) => item.name == definition.name,
                                ),
                              );
                            } catch (e) {
                              _failed(e);
                            }
                          },
                        ),
                    ],
                  ),
                ),
            for (final report in bundle.reports)
              if (_permissions.contains(
                bundle.docTypes
                    .singleWhere((item) => item.name == report.docType)
                    .permissions['read'],
              ))
                ListTile(
                  leading: const Icon(Icons.bar_chart),
                  title: Text(report.label),
                  onTap: () => _report({
                    'title': report.label,
                    'moduleId': bundle.moduleId,
                    'moduleVersion': bundle.version,
                    'docType': report.docType,
                    'reportId': report.id,
                    'filters': <String, dynamic>{},
                  }),
                  trailing: IconButton(
                    icon: const Icon(Icons.dashboard_customize),
                    tooltip: t('add_dashboard', 'Add to dashboard'),
                    onPressed: () async {
                      try {
                        await _addReport(bundle, report);
                      } catch (e) {
                        _failed(e);
                      }
                    },
                  ),
                ),
          ],
        ),
    ],
  );

  Widget _savedViews() => ListView(
    children: [
      if (_views.isEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t('no_views', 'Save a record view from Modules to begin.'),
          ),
        ),
      for (final entry in _views)
        Column(
          children: [
            _draftTile(
              entry,
              onTap: _identity == null
                  ? null
                  : () => _openView(requireMap(entry['body'], 'view')),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () async {
                  try {
                    await _editView(
                      requireMap(entry['body'], 'view'),
                      entry: entry,
                    );
                  } catch (e) {
                    _failed(e);
                  }
                },
                child: Text(t('edit', 'Edit')),
              ),
            ),
          ],
        ),
    ],
  );

  Widget _dashboard() => ListView(
    children: [
      if (_dashboards.isEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t(
              'no_dashboard',
              'Add approved reports from Modules to your dashboard.',
            ),
          ),
        ),
      for (final entry in _dashboards) ...[
        _draftTile(entry),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final raw in requireList(
                requireMap(entry['body'], 'dashboard'),
                'cards',
              ))
                SizedBox(
                  width: 280,
                  child: Card(
                    child: ListTile(
                      leading: const Icon(Icons.bar_chart),
                      title: Text(
                        requireString(requireMap(raw, 'card'), 'title'),
                      ),
                      subtitle: Text(
                        t('live_report', 'Open current Host report'),
                      ),
                      onTap: _identity == null
                          ? null
                          : () => _report(requireMap(raw, 'card')),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ],
  );

  Widget _jobList() => ListView(
    children: [
      if (_pendingJobs.isNotEmpty)
        ListTile(
          title: Text(
            '${_pendingJobs.length} ${t('pending_submissions', 'durable submissions await Host receipt')}',
          ),
          trailing: FilledButton(
            onPressed: _busy ? null : _retrySubmissions,
            child: Text(t('retry', 'Retry')),
          ),
        ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          t(
            'job_cancel_note',
            'Cancellation stops future rows. An operation already in flight may finish; its Host receipt remains authoritative.',
          ),
        ),
      ),
      if (_jobs.isEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(t('no_jobs', 'No visible Host jobs.')),
        ),
      for (final raw in _jobs)
        Builder(
          builder: (context) {
            final job = requireMap(raw, 'job');
            return ExpansionTile(
              title: Text(
                '${job['state']} · ${job['processed']}/${job['total']}',
              ),
              subtitle: Text(job['jobId'] as String),
              children: [
                if (const {
                  'QUEUED',
                  'RUNNING',
                  'RETRY_WAIT',
                }.contains(job['state']))
                  TextButton(
                    onPressed: () async {
                      try {
                        await _request('jobs/cancel', {'jobId': job['jobId']});
                        await _refresh();
                      } catch (e) {
                        _failed(e);
                      }
                    },
                    child: Text(t('cancel_job', 'Cancel remaining rows')),
                  ),
                for (final outcome in requireList(job, 'outcomes'))
                  ListTile(
                    title: Text(
                      '${(outcome as Map)['status']} · ${outcome['reasonCode'] ?? ''}',
                    ),
                    subtitle: Text(
                      '${outcome['sourceRow'] == null ? '' : 'CSV row ${outcome['sourceRow']} | '}${outcome['commandId']}',
                    ),
                  ),
              ],
            );
          },
        ),
    ],
  );

  Widget _settings() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      if (_permissions.contains(hostOperationsManagePermission))
        ListTile(
          title: const VentioText(
            'native.wave2.host_backup_scheduling_and_recovery_c5ebf39c',
          ),
          leading: const Icon(Icons.backup),
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => HostOperationsPage(
                profile: widget.profile,
                request: _request,
                pendingRequests: () => _store!.pendingOperations(),
                discardRetry: (id) => _store!.discardOperationRetry(id),
                localPolicy: () async {
                  final rows = await _store!.list('backup_policy');
                  return rows.isEmpty
                      ? null
                      : requireMap(rows.first['body'], 'body');
                },
                savePolicy: (body) async {
                  try {
                    final remote = await _request('definitions/list', {
                      'kind': 'backup_policy',
                    });
                    if (remote['status'] == 'DEFINITIONS')
                      await _store!.receive(
                        'backup_policy',
                        requireList(remote, 'definitions'),
                      );
                  } catch (_) {
                    /* Preserve an offline draft. */
                  }
                  final draft = await _store!.saveDraft(
                    'backup_policy',
                    'scope',
                    body,
                  );
                  await _publish(draft);
                },
                prepareOperation: (operation, body) async {
                  final request = await _store!.stageOperation(operation, body);
                  final reply = await _request('operations/prepare', request);
                  if (reply['status'] != 'OPERATION')
                    throw StateError('Operation denied');
                  await _store!.acknowledgeOperation(
                    request['operationId'] as String,
                  );
                },
                retryOperations: () async {
                  for (final request in await _store!.pendingOperations()) {
                    final reply = await _request('operations/prepare', request);
                    if (reply['status'] != 'OPERATION')
                      throw StateError('Operation denied');
                    await _store!.acknowledgeOperation(
                      request['operationId'] as String,
                    );
                  }
                },
              ),
            ),
          ),
        ),
      if (_permissions.contains(organizationAdministrationPermission))
        ListTile(
          title: const VentioText(
            'native.wave2.organization_companies_and_branches_741bdfb2',
          ),
          leading: const Icon(Icons.account_tree),
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => PlatformAdministrationPage(
                request: _request,
                profile: widget.profile,
              ),
            ),
          ),
        ),
      if (_permissions.contains(wave2ConfigurationPermission))
        ListTile(
          title: Text(t('configuration', 'Scoped configuration')),
          trailing: const Icon(Icons.tune),
          onTap: () async {
            try {
              await _configure();
            } catch (error) {
              _failed(error);
            }
          },
        ),
      Text(t('local_preferences', 'Interface preferences')),
      DropdownButtonFormField<String>(
        isExpanded: true,
        initialValue: _preferences['density'] as String,
        decoration: InputDecoration(labelText: t('density', 'Density')),
        items: ['comfortable', 'compact']
            .map((value) => DropdownMenuItem(value: value, child: Text(value)))
            .toList(),
        onChanged: (value) {
          if (value != null) _preference('density', value);
        },
      ),
      DropdownButtonFormField<String>(
        isExpanded: true,
        initialValue: _preferences['theme'] as String,
        decoration: InputDecoration(labelText: t('theme', 'Theme')),
        items: ['system', 'light', 'dark']
            .map((value) => DropdownMenuItem(value: value, child: Text(value)))
            .toList(),
        onChanged: (value) {
          if (value != null) _preference('theme', value);
        },
      ),
      FutureBuilder<List<Map<String, dynamic>>>(
        future: _store?.list('preferences'),
        builder: (context, snapshot) => Column(
          children: [
            for (final entry in snapshot.data ?? <Map<String, dynamic>>[])
              _draftTile(entry),
          ],
        ),
      ),
      const Divider(),
      if (_recordDrafts.isNotEmpty)
        const VentioText('native.wave2.record_drafts_requiring_review'),
      for (final entry in _recordDrafts)
        ListTile(
          title: Text(entry.envelope.aggregateId),
          subtitle: Text(
            '${entry.hostStatus.databaseValue} | ${entry.hostReceipt?.reasonCode ?? ''}',
          ),
          trailing: _reconciledIds.contains(entry.envelope.commandId)
              ? const VentioText('native.wave2.replacement_draft_queued')
              : TextButton(
                  onPressed: () => _recoverRecordDraft(entry),
                  child: const VentioText('native.wave2.review_record_draft'),
                ),
        ),
      if (_identity == null)
        for (final bundle in _cachedBundles.values)
          for (final doc in bundle.docTypes)
            ListTile(
              title: Text('${bundle.moduleId} / ${doc.name}'),
              subtitle: const VentioText(
                'native.wave2.cached_metadata_draft_only',
              ),
              onTap: () async {
                try {
                  await _customize(bundle, doc);
                } catch (error) {
                  _failed(error);
                }
              },
            ),
      Text(t('customization_drafts', 'Customization definitions')),
      for (final entry in _customizations)
        _draftTile(
          entry,
          onTap: () async {
            try {
              final body = requireMap(entry['body'], 'body');
              final bundle =
                  _bundles[body['moduleId']] ??
                  _cachedBundles[body['moduleId']];
              if (bundle != null)
                await _customize(
                  bundle,
                  bundle.docTypes.singleWhere(
                    (item) => item.name == body['docType'],
                  ),
                );
            } catch (error) {
              _failed(error);
            }
          },
        ),
      if (_permissions.contains(wave2CustomizationManagePermission) &&
          _permissions.contains('extension.package.review'))
        for (final entry in _customizations.where(
          (item) => item['state'] == 'SYNCED',
        ))
          ListTile(
            title: VentioText(
              'native.wave2.prepare_release_rebase_d4bbd000',
              params: {'v0': (entry['id'])},
            ),
            leading: const Icon(Icons.upgrade),
            onTap: () => _prepareReleaseRebase(entry),
          ),
      if (_customizations.any((item) => item['state'] == 'CONFLICT') ||
          _views.any((item) => item['state'] == 'CONFLICT'))
        Text(
          t(
            'conflict',
            'A Host revision changed. Your draft is preserved. Review and rebase it before publishing.',
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final labels = [
      t('modules', 'Modules'),
      t('views', 'Saved views'),
      t('dashboard', 'Dashboard'),
      t('jobs', 'Host jobs'),
      t('settings', 'Preferences'),
    ];
    const icons = [
      Icons.apps,
      Icons.bookmarks_outlined,
      Icons.dashboard_outlined,
      Icons.work_history_outlined,
      Icons.settings_outlined,
    ];
    final pages = [
      _modules(),
      _savedViews(),
      _dashboard(),
      _jobList(),
      _settings(),
    ];
    final base = Theme.of(context);
    final theme = switch (_preferences['theme']) {
      'dark' => ThemeData.dark(useMaterial3: true),
      'light' => ThemeData.light(useMaterial3: true),
      _ => base,
    };
    return Theme(
      data: theme.copyWith(
        visualDensity: _preferences['density'] == 'compact'
            ? VisualDensity.compact
            : VisualDensity.standard,
      ),
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _configuration == null
                ? t('title', 'Workspace')
                : requireString(
                    requireMap(_configuration!['body'], 'configuration'),
                    'displayName',
                  ),
          ),
          actions: [
            IconButton(
              onPressed: _busy ? null : _refresh,
              tooltip: t('refresh', 'Refresh authorization and data'),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_configuration != null &&
                (requireMap(
                          _configuration!['body'],
                          'configuration',
                        )['maintenanceNotice']
                        as String)
                    .isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  requireString(
                    requireMap(_configuration!['body'], 'configuration'),
                    'maintenanceNotice',
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (_error != null)
              MaterialBanner(
                content: Text(
                  '${t('offline', 'Host unavailable or access denied. Local drafts remain provisional.')}\n$_error',
                ),
                actions: [
                  TextButton(
                    onPressed: _refresh,
                    child: Text(t('retry', 'Retry')),
                  ),
                ],
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => constraints.maxWidth >= 850
                    ? Row(
                        children: [
                          NavigationRail(
                            selectedIndex: _tab,
                            labelType: NavigationRailLabelType.all,
                            onDestinationSelected: (index) =>
                                setState(() => _tab = index),
                            destinations: [
                              for (
                                var index = 0;
                                index < labels.length;
                                index++
                              )
                                NavigationRailDestination(
                                  icon: Icon(icons[index]),
                                  label: Text(labels[index]),
                                ),
                            ],
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(child: pages[_tab]),
                        ],
                      )
                    : pages[_tab],
              ),
            ),
          ],
        ),
        bottomNavigationBar: MediaQuery.sizeOf(context).width >= 850
            ? null
            : NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: (index) => setState(() => _tab = index),
                destinations: [
                  for (var index = 0; index < labels.length; index++)
                    NavigationDestination(
                      icon: Icon(icons[index]),
                      label: labels[index],
                    ),
                ],
              ),
      ),
    );
  }
}

typedef _Request =
    Future<Map<String, dynamic>> Function(
      String action,
      Map<String, Object?> body,
    );

class _ViewEditor extends StatefulWidget {
  const _ViewEditor({required this.body, required this.definition});
  final Map<String, dynamic> body;
  final DocTypeDefinition definition;
  @override
  State<_ViewEditor> createState() => _ViewEditorState();
}

class _ViewEditorState extends State<_ViewEditor> {
  late final _title = TextEditingController(
    text: widget.body['title'] as String,
  );
  late final _search = TextEditingController(
    text: widget.body['search'] as String,
  );
  late final _filter = TextEditingController();
  late final _columns = Set<String>.from(widget.body['columns'] as List);
  late String? _sort = widget.body['sortField'] as String?;
  late bool _descending = widget.body['descending'] as bool;
  String? _filterField;
  String? _error;
  @override
  void dispose() {
    _title.dispose();
    _search.dispose();
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const VentioText('native.wave2.saved_record_view_e2c68077'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              decoration: InputDecoration(
                labelText: context.ventioText('native.wave2.title_7e8cd205'),
              ),
            ),
            TextField(
              controller: _search,
              decoration: InputDecoration(
                labelText: context.ventioText('native.wave2.search_49c266ba'),
              ),
            ),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: _sort,
              decoration: InputDecoration(
                labelText: context.ventioText(
                  'native.wave2.sort_field_e6d34452',
                ),
              ),
              items: [
                for (final field in widget.definition.fields)
                  DropdownMenuItem(value: field.name, child: Text(field.label)),
              ],
              onChanged: (value) => setState(() => _sort = value),
            ),
            SwitchListTile(
              title: const VentioText('native.wave2.descending_order_d1439cc4'),
              value: _descending,
              onChanged: (value) => setState(() => _descending = value),
            ),
            DropdownButtonFormField<String>(
              isExpanded: true,
              decoration: InputDecoration(
                labelText: context.ventioText(
                  'native.wave2.add_an_exact_filter_c8bc2ef3',
                ),
              ),
              items: [
                for (final field in widget.definition.fields.where(
                  (item) => item.type == 'text',
                ))
                  DropdownMenuItem(value: field.name, child: Text(field.label)),
              ],
              onChanged: (value) => _filterField = value,
            ),
            TextField(
              controller: _filter,
              decoration: InputDecoration(
                labelText: context.ventioText(
                  'native.wave2.filter_value_d9542a27',
                ),
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final field in widget.definition.fields)
                  FilterChip(
                    label: Text(field.label),
                    selected: _columns.contains(field.name),
                    onSelected: (selected) => setState(() {
                      selected
                          ? _columns.add(field.name)
                          : _columns.remove(field.name);
                    }),
                  ),
              ],
            ),
            if (_error != null) Text(_error!),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const VentioText('native.wave2.cancel_19766ed6'),
      ),
      FilledButton(
        onPressed: () {
          try {
            final result = {
              ...widget.body,
              'title': _title.text,
              'search': _search.text,
              'sortField': _sort,
              'descending': _descending,
              'columns': _columns.toList(),
              'filters': {
                ...requireMap(widget.body['filters'], 'filters'),
                if (_filterField != null) _filterField!: _filter.text,
              },
            };
            SavedRecordView.fromJson(result);
            Navigator.pop(context, result);
          } on ContractError catch (error) {
            setState(() => _error = error.details);
          }
        },
        child: const VentioText('native.wave2.save_local_draft_960fc7ca'),
      ),
    ],
  );
}

class _RecordViewPage extends StatefulWidget {
  const _RecordViewPage({
    required this.view,
    required this.request,
    required this.editRecord,
  });
  final SavedRecordView view;
  final _Request request;
  final Future<void> Function(
    Map<String, dynamic> view,
    Map<String, dynamic>? record,
  )
  editRecord;
  @override
  State<_RecordViewPage> createState() => _RecordViewPageState();
}

class _RecordViewPageState extends State<_RecordViewPage> {
  Map<String, dynamic>? _result;
  String? _error, _cursor;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  List<String> get _visibleColumns {
    if (_result == null) return const [];
    final readable = strings(
      requireList(_result!, 'readableFields'),
      'readableFields',
    ).toSet();
    return strings(
      requireList(widget.view.json, 'columns'),
      'columns',
    ).where(readable.contains).toList();
  }

  Map<String, Object?> get _query => {...widget.view.json}
    ..remove('title')
    ..remove('contractVersion');
  Future<void> _load({bool next = false}) async {
    setState(() {
      _busy = true;
      _error = null;
      if (!next) _cursor = null;
      _result = null;
    });
    try {
      final result = await widget.request('records/query', {
        ..._query,
        'columns': <String>[],
        'cursor': _cursor,
      });
      if (mounted)
        setState(() {
          _result = result;
          _busy = false;
        });
    } catch (error) {
      if (mounted)
        setState(() {
          _error = error is HostPackageTransportException
              ? error.code
              : 'RECORDS_UNAVAILABLE';
          _busy = false;
        });
    }
  }

  Future<void> _export() async {
    final columns = _visibleColumns;
    if (columns.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final result = await widget.request('exports/page', {
        ..._query,
        'columns': columns,
        'cursor': _cursor,
      });
      if (!mounted) return;
      final copy = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const VentioText(
            'native.wave2.csv_export_current_page_1e618968',
          ),
          content: SingleChildScrollView(
            child: SelectableText(
              requireString(result, 'csv', nonEmpty: false),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const VentioText('native.wave2.close_7d9eb7ac'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const VentioText('native.wave2.copy_csv_e64fbdd5'),
            ),
          ],
        ),
      );
      if (copy == true)
        await Clipboard.setData(ClipboardData(text: result['csv'] as String));
      await _load(next: true);
    } catch (error) {
      if (mounted)
        setState(() {
          _busy = false;
          _error = error is HostPackageTransportException
              ? error.code
              : 'EXPORT_UNAVAILABLE';
        });
    }
  }

  Future<void> _lookupHistory() async {
    final id = TextEditingController();
    try {
      final record = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          title: const VentioText('native.wave2.lookup_document_history'),
          content: TextField(
            controller: id,
            decoration: InputDecoration(
              labelText: context.ventioText(
                'native.wave2.record_id_including_deleted',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const VentioText('native.wave2.cancel_19766ed6'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, id.text.trim()),
              child: const VentioText('native.wave2.lookup_document_history'),
            ),
          ],
        ),
      );
      if (record == null || record.isEmpty || !mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => DocumentActivityPage(
            request: widget.request,
            binding: {
              'moduleId': widget.view.json['moduleId'],
              'moduleVersion': widget.view.json['moduleVersion'],
              'docType': widget.view.json['docType'],
              'recordId': record,
            },
          ),
        ),
      );
    } finally {
      id.dispose();
    }
  }

  Future<void> _detail(Map<String, dynamic> record) async {
    try {
      // Re-read the visible record immediately before opening detail so a
      // revoked field grant cannot leave an older list snapshot in the dialog.
      final current = await widget.request('records/query', {
        ..._query,
        'columns': <String>[],
        'search': '',
        'sortField': null,
        'filters': <String, dynamic>{},
        'limit': 1,
        'cursor': null,
        'recordId': record['recordId'],
      });
      final matches = requireList(current, 'records')
          .map((item) => requireMap(item, 'record'))
          .where((item) => item['recordId'] == record['recordId'])
          .toList();
      if (matches.length != 1 || !mounted) return;
      final values = requireMap(matches.single['values'], 'values');
      final metadata = await widget.request('metadata/effective', {
        'moduleId': widget.view.json['moduleId'],
        'moduleVersion': widget.view.json['moduleVersion'],
        'docType': widget.view.json['docType'],
      });
      final definition =
          ExtensionBundle.fromJson(requireMap(metadata['package'], 'package'))
              .docTypes
              .singleWhere((item) => item.name == widget.view.json['docType']);
      final fields = {for (final field in definition.fields) field.name: field};
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(record['recordId'] as String),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final name in definition.detailFields.where(
                    values.containsKey,
                  ))
                    ListTile(
                      title: Text(fields[name]!.label),
                      subtitle: SelectableText('${values[name] ?? ''}'),
                    ),
                  const Divider(),
                  TextButton.icon(
                    icon: const Icon(Icons.history),
                    label: const VentioText(
                      'native.wave2.open_authorized_document_activity_75b54388',
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.of(this.context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => DocumentActivityPage(
                            request: widget.request,
                            binding: {
                              'moduleId': widget.view.json['moduleId'],
                              'moduleVersion':
                                  widget.view.json['moduleVersion'],
                              'docType': widget.view.json['docType'],
                              'recordId': record['recordId'],
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                await widget.editRecord(widget.view.json, matches.single);
              },
              child: const VentioText(
                'native.wave2.edit_provisional_draft_dc2fefe0',
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const VentioText('native.wave2.close_7d9eb7ac'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted)
        setState(() {
          _result = null;
          _error = error is HostPackageTransportException
              ? error.code
              : 'HISTORY_UNAVAILABLE';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final records = _result == null
        ? <dynamic>[]
        : requireList(_result!, 'records');
    final columns = _visibleColumns;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.view.json['title'] as String),
        actions: [
          IconButton(
            onPressed: _busy ? null : _lookupHistory,
            tooltip: context.ventioText('native.wave2.lookup_document_history'),
            icon: const Icon(Icons.history),
          ),
          IconButton(
            onPressed: _busy
                ? null
                : () async {
                    setState(() {
                      _result = null;
                      _busy = true;
                    });
                    await widget.editRecord(widget.view.json, null);
                    if (mounted) await _load();
                  },
            tooltip: context.ventioText(
              'native.wave2.new_provisional_record_f47a13fc',
            ),
            icon: const Icon(Icons.add),
          ),
          IconButton(
            onPressed: _busy || _visibleColumns.isEmpty ? null : _export,
            tooltip: context.ventioText(
              'native.wave2.export_current_page_as_csv_b45b4c10',
            ),
            icon: const Icon(Icons.download),
          ),
          IconButton(
            onPressed: _busy ? null : () => _load(),
            tooltip: context.ventioText('native.wave2.refresh_0e916101'),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: VentioText(
                'native.wave2.data_unavailable_or_access_denied_291bc5c5',
                params: {'v0': (_error)},
              ),
            ),
          if (!_busy && _error == null && records.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: VentioText(
                'native.wave2.no_records_match_this_view_3bec7146',
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => constraints.maxWidth < 650
                  ? ListView(
                      children: [
                        for (final raw in records)
                          ListTile(
                            title: Text((raw as Map)['recordId'] as String),
                            subtitle: Text(
                              columns
                                  .map(
                                    (field) =>
                                        '$field: ${(raw['values'] as Map)[field] ?? ''}',
                                  )
                                  .join('\n'),
                            ),
                            onTap: () => _detail(requireMap(raw, 'record')),
                          ),
                      ],
                    )
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SingleChildScrollView(
                        child: DataTable(
                          columns: [
                            const DataColumn(
                              label: VentioText('native.wave2.record_bfdd5106'),
                            ),
                            for (final field in columns)
                              DataColumn(label: Text(field)),
                          ],
                          rows: [
                            for (final raw in records)
                              DataRow(
                                cells: [
                                  DataCell(
                                    Text((raw as Map)['recordId'] as String),
                                    onTap: () =>
                                        _detail(requireMap(raw, 'record')),
                                  ),
                                  for (final field in columns)
                                    DataCell(
                                      Text(
                                        '${(raw['values'] as Map)[field] ?? ''}',
                                      ),
                                    ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
          if (_result?['hasMore'] == true)
            FilledButton(
              onPressed: _busy
                  ? null
                  : () {
                      _cursor = _result!['nextCursor'] as String;
                      _load(next: true);
                    },
              child: const VentioText('native.wave2.next_page_c08ac736'),
            ),
        ],
      ),
    );
  }
}

class _CustomizationEditor extends StatefulWidget {
  const _CustomizationEditor({
    required this.body,
    required this.base,
    required this.definition,
    required this.namespace,
  });
  final Map<String, dynamic> body;
  final ExtensionBundle base;
  final DocTypeDefinition definition;
  final String namespace;
  @override
  State<_CustomizationEditor> createState() => _CustomizationEditorState();
}

class _CustomizationEditorState extends State<_CustomizationEditor> {
  late final _label = TextEditingController(
    text:
        (widget.body['properties'] as Map)['label'] as String? ??
        widget.definition.label,
  );
  late final _pageTitle = TextEditingController(
    text:
        (widget.body['ui'] as Map)['pageTitle'] as String? ??
        widget.definition.pageTitle,
  );
  late final _pageOrder = TextEditingController(
    text:
        '${(widget.body['ui'] as Map)['pageOrder'] ?? widget.definition.pageOrder}',
  );
  late String _pageIcon =
      (widget.body['ui'] as Map)['pageIcon'] as String? ??
      widget.definition.pageIcon;
  final _fieldName = TextEditingController(text: 'custom_');
  final _fieldLabel = TextEditingController();
  String _type = 'text';
  late final _fields = List<Map<String, dynamic>>.from(
    (widget.body['fields'] as List).map((field) => requireMap(field, 'field')),
  );
  late final _layouts = {
    for (final name in ['listColumns', 'formFields', 'detailFields'])
      name: List<String>.from((widget.body['ui'] as Map)[name] as List),
  };
  String? _error;
  @override
  void dispose() {
    _label.dispose();
    _pageTitle.dispose();
    _pageOrder.dispose();
    _fieldName.dispose();
    _fieldLabel.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _body => {
    ...widget.body,
    'fields': _fields,
    'properties': {
      'label': _label.text,
      'labelKey': _labelKey('label', _label.text),
    },
    'ui': {
      ...requireMap(widget.body['ui'], 'ui'),
      ..._layouts,
      'pageTitle': _pageTitle.text,
      'pageTitleKey': _labelKey('page_title', _pageTitle.text),
      'pageIcon': _pageIcon,
      'pageOrder': int.tryParse(_pageOrder.text) ?? -1,
    },
  };
  String _labelKey(String part, String value) =>
      '${widget.namespace}.custom.${widget.definition.name.toLowerCase()}.$part.v_${sha256.convert(utf8.encode(value))}';
  Future<void> _editCustomLabel(Map<String, dynamic> field) async {
    final controller = TextEditingController(text: field['label'] as String);
    try {
      final value = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          title: const VentioText('native.wave2.edit_custom_field_label'),
          content: TextField(controller: controller, maxLength: 120),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const VentioText('native.wave2.cancel_19766ed6'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const VentioText('native.wave2.save_reviewed_label'),
            ),
          ],
        ),
      );
      if (value == null || value.isEmpty || !mounted) return;
      setState(() {
        field['label'] = value;
        field['labelKey'] = _labelKey(
          (field['name'] as String).toLowerCase(),
          value,
        );
      });
    } finally {
      controller.dispose();
    }
  }

  void _addField() {
    try {
      final candidate = <String, dynamic>{
        'name': _fieldName.text,
        'type': _type,
        'required': false,
        'label': _fieldLabel.text,
        'labelKey': _labelKey(_fieldName.text.toLowerCase(), _fieldLabel.text),
        if (_type == 'text' || _type == 'long_text')
          'maxLength': _type == 'text' ? 255 : 4000,
        if (_type == 'decimal') 'precision': 2,
        'readPermission': widget.definition.permissions['read'],
        'writePermission': widget.definition.permissions['update'],
      };
      MetadataCustomization.fromJson({
        ..._body,
        'fields': [..._fields, candidate],
      });
      setState(() {
        _fields.add(candidate);
        for (final layout in _layouts.values) {
          layout.add(candidate['name'] as String);
        }
        _fieldName.text = 'custom_';
        _fieldLabel.clear();
        _error = null;
      });
    } on ContractError catch (error) {
      setState(() => _error = error.details);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const VentioText('native.wave2.customize_metadata_4327cfc6'),
    content: SizedBox(
      width: 680,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const VentioText(
              'native.wave2.saved_changes_remain_a_local_draft_until_the_hos_d77e3ea8',
            ),
            TextField(
              controller: _label,
              decoration: InputDecoration(
                labelText: context.ventioText(
                  'native.wave2.doctype_label_ad7cd347',
                ),
              ),
            ),
            TextField(
              controller: _pageTitle,
              maxLength: 120,
              decoration: InputDecoration(
                labelText: context.ventioText(
                  'native.wave2.navigation_title_16e6d160',
                ),
              ),
            ),
            TextField(
              controller: _pageOrder,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: context.ventioText(
                  'native.wave2.navigation_order_0_to_10000_cbbe3acf',
                ),
              ),
            ),
            DropdownButtonFormField<String>(
              initialValue: _pageIcon,
              decoration: InputDecoration(
                labelText: context.ventioText(
                  'native.wave2.navigation_icon_0f9ef86b',
                ),
              ),
              items: [
                for (final icon in [
                  'list',
                  'folder',
                  'article',
                  'location',
                  'business',
                  'tag',
                  'event',
                  'checklist',
                  'grid',
                ])
                  DropdownMenuItem(value: icon, child: Text(icon)),
              ],
              onChanged: (value) => setState(() => _pageIcon = value!),
            ),
            const Divider(),
            for (final field in _fields)
              ListTile(
                title: Text(field['label'] as String),
                subtitle: Text('${field['name']} · ${field['type']}'),
              ),
            TextField(
              controller: _fieldName,
              decoration: InputDecoration(
                labelText: context.ventioText(
                  'native.wave2.custom_field_identifier_b1bffb4f',
                ),
              ),
            ),
            TextField(
              controller: _fieldLabel,
              decoration: InputDecoration(
                labelText: context.ventioText(
                  'native.wave2.custom_field_label_aac7f6f5',
                ),
              ),
            ),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: _type,
              decoration: InputDecoration(
                labelText: context.ventioText(
                  'native.wave2.field_type_01f04ff7',
                ),
              ),
              items:
                  [
                        'text',
                        'long_text',
                        'integer',
                        'decimal',
                        'boolean',
                        'date',
                        'datetime',
                      ]
                      .map(
                        (type) =>
                            DropdownMenuItem(value: type, child: Text(type)),
                      )
                      .toList(),
              onChanged: (value) => setState(() => _type = value!),
            ),
            TextButton.icon(
              onPressed: _addField,
              icon: const Icon(Icons.add),
              label: const VentioText(
                'native.wave2.add_optional_field_ecf829c3',
              ),
            ),
            for (final field in _fields)
              ListTile(
                title: Text(field['label'] as String),
                subtitle: Text('${field['name']} / ${field['type']}'),
                trailing: IconButton(
                  onPressed: () => _editCustomLabel(field),
                  icon: const Icon(Icons.edit),
                ),
              ),
            for (final layout in _layouts.entries) ...[
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(switch (layout.key) {
                  'listColumns' => 'List columns',
                  'formFields' => 'Form fields',
                  _ => 'Detail fields',
                }),
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final field in <Map<String, dynamic>>[
                    for (final field in widget.definition.fields)
                      {'name': field.name, 'label': field.label},
                    ..._fields,
                  ])
                    FilterChip(
                      label: Text(field['label'] as String),
                      selected: layout.value.contains(field['name']),
                      onSelected: (selected) => setState(() {
                        selected
                            ? layout.value.add(field['name'] as String)
                            : layout.value.remove(field['name']);
                      }),
                    ),
                ],
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final name in layout.value)
                    ActionChip(
                      label: Text('$name ↑'),
                      onPressed: () => setState(() {
                        final index = layout.value.indexOf(name);
                        if (index > 0) {
                          layout.value.removeAt(index);
                          layout.value.insert(index - 1, name);
                        }
                      }),
                    ),
                ],
              ),
            ],
            if (_error != null) Text(_error!),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const VentioText('native.wave2.cancel_19766ed6'),
      ),
      FilledButton(
        onPressed: () {
          try {
            MetadataCustomization.fromJson(_body).merge(widget.base);
            Navigator.pop(context, _body);
          } on ContractError catch (error) {
            setState(() => _error = error.details);
          }
        },
        child: const VentioText('native.wave2.save_local_draft_960fc7ca'),
      ),
    ],
  );
}

class _ImportPage extends StatefulWidget {
  const _ImportPage({
    required this.bundle,
    required this.definition,
    required this.profile,
    required this.request,
    required this.store,
  });
  final ExtensionBundle bundle;
  final DocTypeDefinition definition;
  final HostConnectionProfile profile;
  final _Request request;
  final WorkspaceStore store;
  @override
  State<_ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<_ImportPage> {
  final _csv = TextEditingController();
  List<String> _headers = [];
  final Map<String, String> _mapping = {};
  String? _idHeader;
  List<dynamic>? _preview;
  List<FieldDefinition> _fields = [];
  int? _schemaVersion;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _metadata();
  }

  @override
  void dispose() {
    _csv.dispose();
    super.dispose();
  }

  Future<void> _metadata() async {
    try {
      final result = await widget.request('metadata/effective', {
        'moduleId': widget.bundle.moduleId,
        'moduleVersion': widget.bundle.version,
        'docType': widget.definition.name,
      });
      final definition = ExtensionBundle.fromJson(
        requireMap(result['package'], 'package'),
      ).docTypes.singleWhere((item) => item.name == widget.definition.name);
      if (mounted)
        setState(
          () => _fields = definition.fields
              .where(
                (field) => !field.readOnly && field.calculation == null && true,
              )
              .toList(),
        );
    } catch (error) {
      _fail(error);
    }
  }

  void _fail(Object error) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _preview = null;
      _error = switch (error) {
        ContractError(:final details) => details,
        HostPackageTransportException(:final code) => code,
        _ => 'IMPORT_UNAVAILABLE',
      };
    });
  }

  void _readHeaders() {
    try {
      final rows = StructuredCsv.decode(_csv.text);
      setState(() {
        _headers = rows.first;
        _idHeader = _headers.contains('recordId') ? 'recordId' : _headers.first;
        _mapping.clear();
        _preview = null;
        _error = null;
      });
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _validate() async {
    setState(() {
      _busy = true;
      _preview = null;
      _error = null;
    });
    try {
      final result = await widget.request('imports/preview', {
        'moduleId': widget.bundle.moduleId,
        'moduleVersion': widget.bundle.version,
        'docType': widget.definition.name,
        'csv': _csv.text,
        'mapping': _mapping,
        'recordIdHeader': _idHeader,
      });
      if (mounted)
        setState(() {
          _preview = requireList(result, 'rows');
          _schemaVersion = requireInt(result, 'schemaVersion', min: 1);
          _busy = false;
        });
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _stage() async {
    setState(() => _busy = true);
    try {
      final batches = <List<Map<String, dynamic>>>[];
      final sourceRows = <String, int>{};
      var batch = <Map<String, dynamic>>[];
      for (final raw in _preview!) {
        final row = requireMap(raw, 'row');
        if (requireList(row, 'errors').isNotEmpty) continue;
        final command = ExtensionRecordCommand.create(
          commandId: createCommandId(),
          tenantId: widget.profile.tenantId,
          companyId: widget.profile.companyId,
          branchId: widget.profile.branchId,
          recordId: requireString(row, 'recordId'),
          actorId: widget.profile.actorId!,
          deviceId: widget.profile.deviceId!,
          moduleId: widget.bundle.moduleId,
          moduleVersion: widget.bundle.version,
          docType: widget.definition.name,
          schemaVersion: _schemaVersion!,
          values: requireMap(row['values'], 'values'),
        );
        if (batch.length == 25 ||
            utf8
                    .encode(
                      canonicalJson([...batch, command.envelope.original]),
                    )
                    .length >
                49152) {
          if (batch.isEmpty)
            throw const ContractError(
              'ROW_TOO_LARGE',
              'A row exceeds the import batch size.',
            );
          batches.add(batch);
          batch = [];
        }
        sourceRows[command.envelope.commandId] = requireInt(
          row,
          'rowNumber',
          min: 2,
        );
        batch.add(command.envelope.original);
      }
      if (batch.isNotEmpty) batches.add(batch);
      if (batches.isEmpty)
        throw const ContractError(
          'EMPTY_IMPORT',
          'No valid rows are available.',
        );
      await widget.store.stageJobs(
        batches,
        importId: createCommandId(),
        sourceRows: sourceRows,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      _fail(error);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: VentioText(
        'native.wave2.import_csv_b996b0f7',
        params: {'v0': (widget.definition.label)},
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const VentioText(
          'native.wave2.create_records_from_utf_8_csv_maximum_500_rows_h_2a840a66',
        ),
        TextField(
          controller: _csv,
          maxLines: 8,
          decoration: InputDecoration(
            labelText: context.ventioText('native.wave2.csv_content_af497e28'),
          ),
          onChanged: (_) => setState(() {
            _preview = null;
            _headers = [];
            _mapping.clear();
          }),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: _busy ? null : _readHeaders,
            child: const VentioText('native.wave2.read_headers_cad53df4'),
          ),
        ),
        if (_headers.isNotEmpty) ...[
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _idHeader,
            decoration: InputDecoration(
              labelText: context.ventioText(
                'native.wave2.record_id_column_286e88e6',
              ),
            ),
            items: [
              for (final header in _headers)
                DropdownMenuItem(value: header, child: Text(header)),
            ],
            onChanged: (value) => setState(() {
              _idHeader = value;
              _mapping.remove(value);
              _preview = null;
            }),
          ),
          for (final header in _headers.where((item) => item != _idHeader))
            DropdownButtonFormField<String>(
              isExpanded: true,
              decoration: InputDecoration(labelText: header),
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: VentioText('native.wave2.ignore_column_5151f9e5'),
                ),
                for (final field in _fields)
                  DropdownMenuItem(value: field.name, child: Text(field.label)),
              ],
              onChanged: (value) => setState(() {
                if (value == null || value.isEmpty) {
                  _mapping.remove(header);
                } else {
                  _mapping[header] = value;
                }
                _preview = null;
              }),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: _busy || _mapping.isEmpty ? null : _validate,
              child: const VentioText(
                'native.wave2.validate_with_host_30c3751c',
              ),
            ),
          ),
        ],
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Text(_error!),
        if (_preview != null) ...[
          for (final raw in _preview!)
            ListTile(
              title: VentioText(
                'native.wave2.row_15d860a1',
                params: {
                  'v0': ((raw as Map)['rowNumber']),
                  'v1': (raw['recordId']),
                },
              ),
              subtitle: Text(
                (raw['errors'] as List).isEmpty
                    ? 'Valid provisional row'
                    : (raw['errors'] as List).join(', '),
              ),
            ),
          FilledButton(
            onPressed: _busy ? null : _stage,
            child: const VentioText(
              'native.wave2.submit_valid_rows_as_host_jobs_e266c3b4',
            ),
          ),
        ],
      ],
    ),
  );
}
