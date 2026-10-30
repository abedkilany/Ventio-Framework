import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';

import 'package:ventio_core/ventio_core.dart';

import 'app_localization.dart';
import 'host_diagnostics.dart';
import 'host_readiness.dart';
import 'local_diagnostics.dart';

typedef DiagnosticExportHandler = Future<void> Function(String json);

/// Local diagnostics remain available when authentication or Host connectivity
/// is unavailable. It presents only the safe fields stored by the local store.
class DiagnosticsCenterPage extends StatefulWidget {
  const DiagnosticsCenterPage({
    required this.store,
    this.exportHandler,
    this.hostClient,
    super.key,
  });

  final DiagnosticEventSource store;
  final DiagnosticExportHandler? exportHandler;
  final HostDiagnosticsClient? hostClient;

  @override
  State<DiagnosticsCenterPage> createState() => _DiagnosticsCenterPageState();
}

class _DiagnosticsCenterPageState extends State<DiagnosticsCenterPage> {
  List<ManagementDiagnosticEvent> _events = const [];
  bool _loading = true;
  bool _exporting = false;
  String? _loadError;
  List<ManagementDiagnosticEvent> _hostEvents = const [];
  String? _hostLoadError;
  bool _hostLoading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final events = await widget.store.recent();
      if (!mounted) return;
      setState(() {
        _events = events;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError = 'native.diagnostics.local_store_unavailable';
        _loading = false;
      });
    }
    if (widget.hostClient != null) await _refreshHost();
  }

  Future<void> _refreshHost() async {
    final client = widget.hostClient;
    if (client == null || !mounted) return;
    setState(() {
      _hostLoading = true;
      _hostLoadError = null;
    });
    try {
      final result = await client.recent();
      if (!mounted) return;
      setState(() {
        _hostEvents = result.events;
        _hostLoading = false;
      });
    } on HostReadinessException catch (error) {
      if (!mounted) return;
      setState(() {
        _hostLoadError = error.code;
        _hostLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hostLoadError = 'HOST_UNAVAILABLE';
        _hostLoading = false;
      });
    }
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final localEvents = await widget.store.recent();
      final json = const JsonEncoder.withIndent('  ').convert({
        'managementApiVersion': managementApiVersion,
        'exportedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'hostDiagnosticsStatus': widget.hostClient == null
            ? 'not_configured'
            : _hostLoadError ?? (_hostLoading ? 'pending' : 'available'),
        'events': [
          for (final event in localEvents)
            {'source': 'device', ...event.toJson()},
          for (final event in _hostEvents)
            {'source': 'host', ...event.toJson()},
        ],
      });
      final handler = widget.exportHandler;
      if (handler == null) {
        await Clipboard.setData(ClipboardData(text: json));
      } else {
        await handler(json);
      }
      if (mounted) _showMessage(_text('export_copied'));
    } catch (_) {
      if (mounted) _showMessage(_text('export_failed'));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String _text(String key) => context.extensionMetadataText(
    'native.diagnostics.$key',
    _diagnosticEnglish[key]!,
  );

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_text('title')),
      actions: [
        IconButton(
          tooltip: _text('refresh'),
          onPressed: _loading || _hostLoading ? null : _refresh,
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
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.health_and_safety_outlined),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _text('local_title'),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(_text('local_explanation')),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Chip(
                          avatar: const Icon(Icons.storage_outlined, size: 18),
                          label: Text(
                            _text('event_count').replaceAll(
                              '{count}',
                              _loading ? '…' : '${_events.length}',
                            ),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _loading || _hostLoading || _exporting
                              ? null
                              : _export,
                          icon: _exporting
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.copy_outlined),
                          label: Text(_text('export')),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (widget.hostClient != null) ...[
              _hostDiagnosticsCard(),
              const SizedBox(height: 8),
            ],
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_loadError != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: Text(_text('load_failed')),
                  subtitle: Text(_text('local_store_unavailable')),
                  trailing: IconButton(
                    tooltip: _text('retry'),
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh),
                  ),
                ),
              )
            else if (_events.isEmpty)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.check_circle_outline),
                  title: Text(_text('no_events')),
                  subtitle: Text(_text('no_events_details')),
                ),
              )
            else
              for (final event in _events) _eventCard(event),
          ],
        ),
      ),
    ),
  );

  Widget _hostDiagnosticsCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.dns_outlined),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _text('host_title'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: _text('refresh_host'),
                onPressed: _hostLoading ? null : _refreshHost,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(_text('host_explanation')),
          const SizedBox(height: 10),
          if (_hostLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_hostLoadError != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.error_outline),
              title: Text(_text('host_load_failed')),
              subtitle: Text(_hostFailureText(_hostLoadError!)),
            )
          else if (_hostEvents.isEmpty)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.check_circle_outline),
              title: Text(_text('host_no_events')),
              subtitle: Text(_text('host_no_events_details')),
            )
          else
            for (final event in _hostEvents) _eventCard(event),
        ],
      ),
    ),
  );

  String _hostFailureText(String code) => _text(switch (code) {
    'HOST_PERMISSION_DENIED' ||
    'PERMISSION_DENIED' ||
    'SCOPE_DENIED' => 'host_permission_denied',
    'HOST_CREDENTIAL_MISSING' ||
    'PERSISTENT_IDENTITY_REQUIRED' => 'host_credential_missing',
    'HOST_UNREACHABLE' ||
    'HOST_REQUEST_TIMEOUT' ||
    'HOST_UNAVAILABLE' => 'host_unreachable',
    'HOST_TLS_VALIDATION_FAILED' => 'host_tls_failed',
    'HOST_DIAGNOSTICS_UNAVAILABLE' => 'host_diagnostics_unavailable',
    _ => 'host_diagnostics_failed',
  });

  Widget _eventCard(ManagementDiagnosticEvent event) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(_severityIcon(event.severity), size: 19),
              Text(event.code, style: Theme.of(context).textTheme.titleMedium),
              Chip(label: Text(event.severity.wireValue)),
              Chip(label: Text(event.category.wireValue)),
              if (event.retryable) Chip(label: Text(_text('retryable'))),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _text('component_line').replaceAll('{component}', event.component),
          ),
          Text(
            _text(
              'time_line',
            ).replaceAll('{timestamp}', event.occurredAtUtc.toIso8601String()),
          ),
          const SizedBox(height: 10),
          Text(event.safeExplanation),
          const SizedBox(height: 8),
          Text(
            _text('recommended_action'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          Text(event.recommendedAction),
          const SizedBox(height: 8),
          SelectableText(
            _text(
              'correlation_line',
            ).replaceAll('{correlationId}', event.correlationId),
          ),
        ],
      ),
    ),
  );

  IconData _severityIcon(ManagementDiagnosticSeverity severity) =>
      switch (severity) {
        ManagementDiagnosticSeverity.info => Icons.info_outline,
        ManagementDiagnosticSeverity.warning => Icons.warning_amber_outlined,
        ManagementDiagnosticSeverity.error => Icons.error_outline,
        ManagementDiagnosticSeverity.critical => Icons.report_gmailerrorred,
      };
}

const _diagnosticEnglish = <String, String>{
  'title': 'Local diagnostics',
  'refresh': 'Refresh diagnostics',
  'local_title': 'Device diagnostics',
  'local_explanation':
      'These safe local events remain available when the Host cannot be reached or authentication is unavailable. Technical exception details are not stored here.',
  'host_title': 'Host diagnostics',
  'host_explanation':
      'These Host events require the dedicated diagnostic permission. The Host returns safe event details only; protected technical details stay on the Host.',
  'refresh_host': 'Refresh Host diagnostics',
  'host_load_failed': 'Host diagnostics could not be loaded',
  'host_permission_denied':
      'Your Host account does not have permission to read diagnostic events in this scope.',
  'host_credential_missing':
      'A saved Host credential is unavailable. Reconnect this device to the Host.',
  'host_unreachable':
      'The Host could not be reached. Check the connection and retry.',
  'host_tls_failed':
      'The Host identity could not be verified securely. Check the address and certificate.',
  'host_diagnostics_unavailable':
      'The Host diagnostic service is unavailable. Ask a Host operator to check its local diagnostics.',
  'host_diagnostics_failed':
      'The Host returned an invalid or unsupported diagnostic response.',
  'host_no_events': 'No recent Host diagnostic events',
  'host_no_events_details':
      'Operational errors recorded by the Host will appear here when available.',
  'event_count': '{count} recent event(s)',
  'export': 'Copy sanitized export',
  'export_copied': 'Sanitized diagnostics copied.',
  'export_failed': 'The diagnostic export could not be prepared.',
  'load_failed': 'Local diagnostics are unavailable',
  'local_store_unavailable':
      'Check local device storage and retry. No Host sign-in is required to read diagnostic events.',
  'retry': 'Retry loading diagnostics',
  'no_events': 'No local diagnostic events',
  'no_events_details':
      'Connection and setup failures recorded on this device will appear here.',
  'retryable': 'RETRYABLE',
  'component_line': 'Component: {component}',
  'time_line': 'Occurred (UTC): {timestamp}',
  'recommended_action': 'Recommended action',
  'correlation_line': 'Reference: {correlationId}',
};
