import 'package:flutter/material.dart';
import 'package:ventio_core/ventio_core.dart';

import 'app_localization.dart';

/// Metadata-only activity. Every page reauthorizes current Host scope and
/// DocType read permission; field values are never stored or displayed here.
class DocumentActivityPage extends StatefulWidget {
  const DocumentActivityPage({
    super.key,
    required this.request,
    required this.binding,
  });
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  request;
  final Map<String, dynamic> binding;
  @override
  State<DocumentActivityPage> createState() => _DocumentActivityPageState();
}

class _DocumentActivityPageState extends State<DocumentActivityPage> {
  List<dynamic> _entries = [];
  String? _cursor;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool next = false}) async {
    setState(() {
      _busy = true;
      _error = null;
      _entries = [];
    });
    try {
      final result = await widget.request('history/list', {
        ...widget.binding,
        'limit': 50,
        'cursor': next ? _cursor : null,
      });
      if (result['status'] != 'HISTORY')
        throw StateError('Activity access denied');
      if (mounted)
        setState(() {
          _entries = requireList(result, 'entries');
          _cursor = result['nextCursor'] as String?;
          _busy = false;
        });
    } catch (_) {
      if (mounted)
        setState(() {
          _entries = [];
          _cursor = null;
          _error = context.ventioText(
            'native.wave2.activity_unavailable_offline_or_access_denied_re_91c72b91',
          );
          _busy = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: VentioText(
        'native.wave2.activity_4de06f3f',
        params: {'v0': (widget.binding['recordId'])},
      ),
      actions: [
        IconButton(
          onPressed: _busy ? null : () => _load(),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const VentioText(
          'native.wave2.activity_contains_command_identity_revision_and_344d5f9c',
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Text(_error!),
        if (!_busy && _error == null && _entries.isEmpty)
          const VentioText(
            'native.wave2.no_retained_activity_for_this_document_d0203467',
          ),
        for (final raw in _entries)
          Builder(
            builder: (_) {
              final row = requireMap(raw, 'activity');
              return ListTile(
                title: VentioText(
                  'native.wave2.revision_22fc7179',
                  params: {
                    'v0':
                        (row['operation'] ??
                        context.ventioText('native.wave2.source_command')),
                    'v1': (row['revision'] ?? '?'),
                  },
                ),
                subtitle: SelectableText(
                  context.ventioText(
                    'native.wave2.activity_identity',
                    params: {
                      'actor': row['actorId'],
                      'time': row['occurredAtUtc'],
                      'command': row['commandId'],
                      'target': row['effectTarget'] == true
                          ? context.ventioText('native.wave2.effect_target')
                          : '',
                      'historical': row['historicalSource'] == true
                          ? context.ventioText('native.wave2.historical_source')
                          : '',
                    },
                  ),
                ),
              );
            },
          ),
        if (_cursor != null)
          FilledButton(
            onPressed: _busy ? null : () => _load(next: true),
            child: const VentioText('native.wave2.older_activity_0eed19ab'),
          ),
      ],
    ),
  );
}
