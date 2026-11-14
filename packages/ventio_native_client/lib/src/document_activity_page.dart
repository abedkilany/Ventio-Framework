import 'package:flutter/material.dart';
import 'package:ventio_core/ventio_core.dart';

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
          _error =
              'Activity unavailable, offline, or access denied. Reconnect and refresh.';
          _busy = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('Activity: ${widget.binding['recordId']}'),
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
        const Text(
          'Activity contains command identity, revision and operation only. Historical source commands are recovered from retained Host metadata. Cross-record effects before Wave 2 capture were not recorded.',
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Text(_error!),
        if (!_busy && _error == null && _entries.isEmpty)
          const Text('No retained activity for this document.'),
        for (final raw in _entries)
          Builder(
            builder: (_) {
              final row = requireMap(raw, 'activity');
              return ListTile(
                title: Text(
                  '${row['operation'] ?? 'Source command'} | revision ${row['revision'] ?? '?'}',
                ),
                subtitle: SelectableText(
                  '${row['actorId']} | ${row['occurredAtUtc']}\n${row['commandId']}${row['effectTarget'] == true ? ' | effect target' : ''}${row['historicalSource'] == true ? ' | historical source' : ''}',
                ),
              );
            },
          ),
        if (_cursor != null)
          FilledButton(
            onPressed: _busy ? null : () => _load(next: true),
            child: const Text('Older activity'),
          ),
      ],
    ),
  );
}
