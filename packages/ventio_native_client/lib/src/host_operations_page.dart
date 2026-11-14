import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ventio_core/ventio_core.dart';

import 'app_localization.dart';
import 'extension_store.dart';
import 'host_operations_windows.dart';
import 'platform_administration_page.dart';

class HostOperationsPage extends StatefulWidget {
  const HostOperationsPage({
    super.key,
    required this.profile,
    required this.request,
    required this.savePolicy,
    required this.localPolicy,
    required this.prepareOperation,
    required this.retryOperations,
    required this.pendingRequests,
    required this.discardRetry,
  });
  final Future<void> Function(String, Map<String, dynamic>) prepareOperation;
  final Future<void> Function() retryOperations;
  final Future<List<Map<String, dynamic>>> Function() pendingRequests;
  final Future<void> Function(String) discardRetry;
  final HostConnectionProfile profile;
  final PlatformAdministrationRequest request;
  final Future<void> Function(Map<String, dynamic>) savePolicy;
  final Future<Map<String, dynamic>?> Function() localPolicy;
  @override
  State<HostOperationsPage> createState() => _HostOperationsPageState();
}

class _HostOperationsPageState extends State<HostOperationsPage> {
  List<dynamic> _operations = [];
  List<Map<String, dynamic>> _pending = [];
  Map<String, dynamic>? _policy;
  bool _busy = true, _available = false;
  String? _error;
  String _deliveryStatus = 'UNKNOWN';
  bool get _local =>
      Platform.isWindows &&
      const {
        'localhost',
        '127.0.0.1',
        '::1',
      }.contains(Uri.parse(widget.profile.endpoint).host);
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _operations = [];
    });
    try {
      _pending = await widget.pendingRequests();
      final definitions = await widget.request('definitions/list', {
        'kind': 'backup_policy',
      });
      if (definitions['status'] != 'DEFINITIONS') {
        throw StateError('Backup policy access denied');
      }
      final entries = requireList(definitions, 'definitions');
      final operations = await widget.request('operations/list', {});
      if (operations['status'] != 'OPERATIONS') {
        throw StateError('Operations access denied');
      }
      if (mounted) {
        setState(() {
          _policy = entries.isEmpty
              ? null
              : requireMap(
                  requireMap(entries.first, 'definition')['body'],
                  'body',
                );
          _operations = requireList(operations, 'operations');
          _available = operations['localDeliveryAvailable'] == true;
          _deliveryStatus =
              operations['deliveryStatus'] as String? ?? 'UNKNOWN';
          _busy = false;
        });
      }
    } catch (_) {
      final draft = await widget.localPolicy();
      if (mounted) {
        setState(() {
          _busy = false;
          _policy = draft;
          _available = false;
          _error = context.ventioText(
            'native.wave2.host_operations_unavailable_offline_or_denied_on_66fad509',
          );
        });
      }
    }
  }

  Future<void> _editPolicy() async {
    final body =
        _policy ??
        <String, dynamic>{
          'contractVersion': 1,
          'enabled': false,
          'utcTime': '02:00',
          'retainDays': 30,
          'retainCopies': 7,
          'maximumAttempts': 3,
          'retryMinutes': 30,
        };
    final controls = {
      for (final key in [
        'utcTime',
        'retainDays',
        'retainCopies',
        'maximumAttempts',
        'retryMinutes',
      ])
        key: TextEditingController(text: '${body[key]}'),
    };
    var enabled = body['enabled'] == true;
    String? error;
    try {
      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const VentioText(
              'native.wave2.backup_policy_draft_d2e5eff3',
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const VentioText(
                      'native.wave2.physical_backups_include_the_complete_host_datab_06ca3cd6',
                    ),
                    SwitchListTile(
                      title: const VentioText(
                        'native.wave2.enable_daily_backup_e09ac9f1',
                      ),
                      value: enabled,
                      onChanged: (v) => update(() => enabled = v),
                    ),
                    for (final field in {
                      'utcTime': 'Daily UTC time (HH:mm)',
                      'retainDays': 'Retain days (1-3650)',
                      'retainCopies': 'Minimum copies (2-1000)',
                      'maximumAttempts': 'Maximum daily attempts (1-5)',
                      'retryMinutes': 'Retry delay minutes (5-1440)',
                    }.entries)
                      TextField(
                        controller: controls[field.key],
                        decoration: InputDecoration(labelText: field.value),
                      ),
                    if (error != null) Text(error!),
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
                  final value = <String, dynamic>{
                    'contractVersion': 1,
                    'enabled': enabled,
                    'utcTime': controls['utcTime']!.text,
                    for (final key in [
                      'retainDays',
                      'retainCopies',
                      'maximumAttempts',
                      'retryMinutes',
                    ])
                      key: int.tryParse(controls[key]!.text),
                  };
                  try {
                    BackupPolicy.fromJson(value);
                    Navigator.pop(context, value);
                  } on ContractError catch (e) {
                    update(() => error = e.details);
                  }
                },
                child: const VentioText(
                  'native.wave2.save_provisional_policy_1e94e921',
                ),
              ),
            ],
          ),
        ),
      );
      if (result != null) {
        await widget.savePolicy(result);
        await _load();
      }
    } finally {
      for (final control in controls.values) {
        control.dispose();
      }
    }
  }

  Future<void> _prepare(
    String operation, {
    Map<String, dynamic> body = const {},
  }) async {
    setState(() => _busy = true);
    try {
      await widget.prepareOperation(operation, body);
      await _load();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = context.ventioText(
            'native.wave2.operation_was_not_acknowledged_refresh_before_cr_e3f83598',
          );
        });
      }
    }
  }

  Future<void> _restorePlan() async {
    final name = TextEditingController();
    try {
      final backup = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          title: const VentioText('native.wave2.prepare_restore_plan_32c74e50'),
          content: TextField(
            controller: name,
            decoration: InputDecoration(
              labelText: context.ventioText(
                'native.wave2.exact_retained_backup_name_11163a25',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const VentioText('native.wave2.cancel_19766ed6'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, name.text.trim()),
              child: const VentioText(
                'native.wave2.prepare_integrity_and_compatibility_review_789189d3',
              ),
            ),
          ],
        ),
      );
      if (backup != null) {
        await _prepare('RESTORE_PLAN', body: {'backupName': backup});
      }
    } finally {
      name.dispose();
    }
  }

  Future<void> _restore(Map<String, dynamic> plan) async {
    final result = requireMap(plan['result'], 'result');
    final name = requireString(result, 'backupName');
    final typed = TextEditingController();
    try {
      final yes = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const VentioText(
            'native.wave2.controlled_database_restore_f25ea9ab',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                VentioText(
                  'native.wave2.restore_this_replaces_the_physical_host_database_fa68b2b9',
                  params: {'v0': (name)},
                ),
                TextField(
                  controller: typed,
                  decoration: InputDecoration(
                    labelText: context.ventioText(
                      'native.wave2.type_the_exact_backup_name_to_confirm_4d158aad',
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const VentioText('native.wave2.cancel_19766ed6'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, typed.text == name),
              child: const VentioText(
                'native.wave2.create_restore_request_625a0969',
              ),
            ),
          ],
        ),
      );
      if (yes == true) {
        await _prepare(
          'RESTORE',
          body: {
            'backupName': name,
            'planOperationId': plan['operationId'],
            'planSha256': result['planSha256'],
          },
        );
      }
    } finally {
      typed.dispose();
    }
  }

  Future<void> _approve(Map<String, dynamic> operation) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const VentioText(
          'native.wave2.approve_on_this_windows_host_9fcdd12a',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const VentioText(
                'native.wave2.uac_approval_grants_machine_wide_operational_aut_1d42b752',
              ),
              SelectableText(
                const JsonEncoder.withIndent('  ').convert(operation),
              ),
            ],
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
              'native.wave2.continue_to_local_administrator_approval_9ee72994',
            ),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      final launched = await approveLocalHostOperation(
        widget.profile.endpoint,
        requireString(operation, 'operationId'),
        restorePlanSha256: operation['operation'] == 'RESTORE'
            ? requireString(requireMap(operation['body'], 'body'), 'planSha256')
            : null,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              launched
                  ? 'Operator launched. Allow private delivery up to five seconds, then refresh after completion. The Host may be temporarily offline.'
                  : 'Local approval cancelled.',
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = context.ventioText(
            'native.wave2.local_approval_could_not_launch_use_the_installe_6f734747',
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const VentioText('native.wave2.host_backup_and_recovery_f9a73bdc'),
      actions: [
        IconButton(
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const VentioText(
          'native.wave2.shared_policies_require_host_acceptance_physical_fd11ebef',
        ),
        VentioText(
          'native.wave2.operation_delivery_status',
          params: {'state': _deliveryStatus},
        ),
        if (_busy) const LinearProgressIndicator(),
        for (final pending in _pending)
          ListTile(
            title: Text('${pending['operation']}'),
            subtitle: Text('${pending['operationId']}'),
            trailing: TextButton(
              onPressed: _busy
                  ? null
                  : () async {
                      final discard = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const VentioText(
                            'native.wave2.discard_local_retry',
                          ),
                          content: const VentioText(
                            'native.wave2.discard_local_retry_explanation',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const VentioText(
                                'native.wave2.cancel_19766ed6',
                              ),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const VentioText(
                                'native.wave2.discard_local_retry',
                              ),
                            ),
                          ],
                        ),
                      );
                      if (discard == true) {
                        await widget.discardRetry(
                          requireString(pending, 'operationId'),
                        );
                        await _load();
                      }
                    },
              child: const VentioText('native.wave2.discard_local_retry'),
            ),
          ),
        if (_error != null) Text(_error!),
        if (!_available && !_busy)
          const VentioText(
            'native.wave2.local_delivery_is_unavailable_provision_the_prot_c5a2d565',
          ),
        if (!_local)
          const VentioText(
            'native.wave2.review_requests_here_execute_them_using_a_local_9e080352',
          ),
        ListTile(
          title: const VentioText('native.wave2.daily_backup_policy_a4b1fd14'),
          subtitle: SelectableText(
            _policy == null
                ? 'No policy configured'
                : const JsonEncoder.withIndent('  ').convert(_policy),
          ),
          trailing: IconButton(
            onPressed: _busy ? null : _editPolicy,
            icon: const Icon(Icons.edit),
          ),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  try {
                    await widget.retryOperations();
                    await _load();
                  } catch (_) {
                    if (mounted) {
                      setState(
                        () => _error = context.ventioText(
                          'native.wave2.pending_requests_remain_provisional_until_host_a_281c011c',
                        ),
                      );
                    }
                  }
                },
          child: const VentioText(
            'native.wave2.retry_pending_operation_requests_with_their_save_7abc9ef8',
          ),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton(
              onPressed: _busy || !_available || _policy == null
                  ? null
                  : () => _prepare('APPLY_POLICY'),
              child: const VentioText(
                'native.wave2.request_policy_activation_2dfc5e36',
              ),
            ),
            OutlinedButton(
              onPressed: _busy || !_available
                  ? null
                  : () => _prepare('BACKUP_NOW'),
              child: const VentioText(
                'native.wave2.request_backup_now_1bdb860a',
              ),
            ),
            OutlinedButton(
              onPressed: _busy || !_available ? null : _restorePlan,
              child: const VentioText(
                'native.wave2.prepare_restore_plan_32c74e50',
              ),
            ),
          ],
        ),
        if (!_busy && _operations.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: VentioText(
              'native.wave2.no_retained_operational_requests_in_this_scope_6792bb92',
            ),
          ),
        for (final raw in _operations)
          Builder(
            builder: (_) {
              final op = requireMap(raw, 'operation');
              return Card(
                child: ExpansionTile(
                  title: Text('${op['operation']} | ${op['state']}'),
                  subtitle: Text(
                    '${op['operationId']} | ${op['updatedAtUtc']}',
                  ),
                  children: [
                    SelectableText(
                      const JsonEncoder.withIndent('  ').convert(op),
                    ),
                    if (op['state'] == 'AWAITING_LOCAL_APPROVAL' && _local)
                      TextButton(
                        onPressed: _busy ? null : () => _approve(op),
                        child: const VentioText(
                          'native.wave2.review_and_approve_locally_5a8ad37c',
                        ),
                      ),
                    if (op['operation'] == 'RESTORE_PLAN' &&
                        op['state'] == 'SUCCEEDED')
                      TextButton(
                        onPressed: _busy ? null : () => _restore(op),
                        child: const VentioText(
                          'native.wave2.create_controlled_restore_request_196e4cad',
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
      ],
    ),
  );
}
