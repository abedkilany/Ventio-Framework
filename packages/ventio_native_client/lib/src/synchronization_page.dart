import 'package:flutter/material.dart';

import 'app_localization.dart';
import 'local_command_queue.dart';
import 'host_sync_service.dart';

/// Shows the durable local command queue without implying that local data has
/// been accepted by the Host. Only a stored Host receipt is shown as accepted.
class SynchronizationPage extends StatefulWidget {
  const SynchronizationPage({
    required this.queue,
    this.onRetryPending,
    super.key,
  });

  final LocalCommandQueue queue;
  final Future<void> Function()? onRetryPending;

  @override
  State<SynchronizationPage> createState() => _SynchronizationPageState();
}

class _SynchronizationPageState extends State<SynchronizationPage> {
  List<QueueEntry> _entries = const [];
  bool _loading = true;
  bool _syncing = false;
  String? _errorKey;
  String? _errorCode;
  String? _correlationId;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _errorKey = null;
      _errorCode = null;
      _correlationId = null;
    });
    try {
      final entries = await widget.queue.list(limit: 1000);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorKey = 'sync_queue_unavailable';
        _loading = false;
      });
    }
  }

  Future<void> _retry() async {
    final action = widget.onRetryPending;
    if (_syncing || action == null) return;
    setState(() => _syncing = true);
    try {
      await action();
      await _refresh();
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorKey = 'sync_attempt_failed';
          _errorCode = error is HostSyncFailureException ? error.code : null;
          _correlationId = error is HostSyncFailureException
              ? error.correlationId
              : null;
          _loading = false;
        });
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  String _text(String key, {Map<String, Object?> params = const {}}) =>
      context.ventioText('native.ui.$key', params: params);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const VentioText('native.ui.synchronization'),
      actions: [
        IconButton(
          tooltip: _text('refresh_sync_status'),
          onPressed: _loading || _syncing ? null : _refresh,
          icon: const Icon(Icons.refresh),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _statusSummary(),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_errorKey != null)
              _errorCard()
            else if (_entries.isEmpty)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.check_circle_outline),
                  title: Text(_text('sync_queue_empty')),
                  subtitle: Text(_text('sync_queue_empty_details')),
                ),
              )
            else ...[
              if (_entries.length == 1000)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(_text('sync_recent_limit')),
                ),
              for (final entry in _entries) _entryCard(entry),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _statusSummary() {
    final accepted = _entries.where((entry) => entry.isHostConfirmed).length;
    final pending = _entries
        .where((entry) => entry.hostStatus == HostCommandStatus.pending)
        .length;
    final retryLater = _entries
        .where((entry) => entry.hostStatus == HostCommandStatus.retryLater)
        .length;
    final rejected = _entries
        .where((entry) => entry.hostStatus == HostCommandStatus.rejected)
        .length;
    final conflicts = _entries
        .where((entry) => entry.hostStatus == HostCommandStatus.conflict)
        .length;
    final latestAttempt = _entries
        .map((entry) => entry.lastAttemptAtUtc)
        .whereType<DateTime>()
        .fold<DateTime?>(null, (latest, candidate) {
          if (latest == null || candidate.isAfter(latest)) return candidate;
          return latest;
        });

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sync_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _text('sync_overview_title'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (widget.onRetryPending != null)
                  FilledButton.tonalIcon(
                    onPressed: _loading || _syncing ? null : _retry,
                    icon: _syncing
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync),
                    label: Text(_text('retry_pending_sync')),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              widget.onRetryPending == null
                  ? _text('sync_offline_explanation')
                  : _text('sync_host_retry_explanation'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _countChip('sync_pending_count', pending),
                _countChip('sync_retry_count', retryLater),
                _countChip('sync_confirmed_count', accepted),
                _countChip('sync_rejected_count', rejected),
                _countChip('sync_conflict_count', conflicts),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              latestAttempt == null
                  ? _text('sync_no_host_attempt')
                  : _text(
                      'sync_latest_attempt',
                      params: {'timestamp': _utcTimestamp(latestAttempt)},
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _countChip(String key, int count) => Chip(
    avatar: const Icon(Icons.circle, size: 12),
    label: Text(_text(key, params: {'count': count})),
  );

  Widget _entryCard(QueueEntry entry) {
    final receipt = entry.hostReceipt;
    final reasonCode = receipt?.reasonCode;
    final safeReasonCode =
        reasonCode != null &&
            RegExp(r'^[A-Z][A-Z0-9_]{0,79}$').hasMatch(reasonCode)
        ? reasonCode
        : null;
    final commandType =
        RegExp(r'^[a-z][a-z0-9_.:-]{0,127}$').hasMatch(entry.envelope.type)
        ? entry.envelope.type
        : _text('sync_operation');
    final accepted = entry.isHostConfirmed;
    final status = accepted
        ? _text('sync_confirmed')
        : _statusLabel(entry.hostStatus);

    return Card(
      child: ExpansionTile(
        key: ValueKey('sync-command-${entry.envelope.commandId}'),
        leading: Icon(_statusIcon(entry.hostStatus, accepted)),
        title: Text(commandType),
        subtitle: Text(
          _text(
            'sync_status_line',
            params: {'status': status, 'attempts': entry.attemptCount},
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  _text(
                    'sync_command_reference',
                    params: {'commandId': entry.envelope.commandId},
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _text(
                    'sync_created_at',
                    params: {'timestamp': _utcTimestamp(entry.createdAtUtc)},
                  ),
                ),
                Text(
                  _text(
                    'sync_updated_at',
                    params: {'timestamp': _utcTimestamp(entry.updatedAtUtc)},
                  ),
                ),
                if (entry.lastAttemptAtUtc case final attemptedAt?)
                  Text(
                    _text(
                      'sync_attempted_at',
                      params: {'timestamp': _utcTimestamp(attemptedAt)},
                    ),
                  ),
                if (safeReasonCode != null) ...[
                  const SizedBox(height: 6),
                  SelectableText(
                    _text('sync_host_reason', params: {'code': safeReasonCode}),
                  ),
                  Text(_text('sync_host_reason_guidance')),
                ],
                if (entry.fixtureReceipt != null) ...[
                  const SizedBox(height: 6),
                  Text(_text('sync_fixture_not_confirmation')),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _statusLabel(HostCommandStatus status) => switch (status) {
    HostCommandStatus.pending => _text('sync_pending_status'),
    HostCommandStatus.accepted => _text('sync_unconfirmed_status'),
    HostCommandStatus.rejected => _text('sync_rejected'),
    HostCommandStatus.conflict => _text('sync_conflict'),
    HostCommandStatus.retryLater => _text('sync_retry_later'),
  };

  IconData _statusIcon(HostCommandStatus status, bool accepted) => accepted
      ? Icons.cloud_done_outlined
      : switch (status) {
          HostCommandStatus.pending => Icons.schedule_outlined,
          HostCommandStatus.accepted => Icons.help_outline,
          HostCommandStatus.rejected => Icons.cancel_outlined,
          HostCommandStatus.conflict => Icons.compare_arrows_outlined,
          HostCommandStatus.retryLater => Icons.replay_outlined,
        };

  Widget _errorCard() => Card(
    child: ListTile(
      leading: const Icon(Icons.error_outline),
      title: Text(_text('sync_status_unavailable')),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_text(_errorKey!)),
          if (_errorCode != null) ...[
            const SizedBox(height: 6),
            SelectableText(
              _text('sync_failure_code', params: {'code': _errorCode}),
            ),
          ],
          if (_correlationId != null) ...[
            const SizedBox(height: 4),
            SelectableText(
              _text(
                'sync_failure_reference',
                params: {'correlationId': _correlationId},
              ),
            ),
          ],
        ],
      ),
      trailing: IconButton(
        tooltip: _text('refresh_sync_status'),
        onPressed: _refresh,
        icon: const Icon(Icons.refresh),
      ),
    ),
  );
}

String _utcTimestamp(DateTime value) =>
    '${value.toUtc().toIso8601String()} UTC';
