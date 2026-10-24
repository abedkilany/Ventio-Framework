import 'package:flutter/material.dart';
import 'package:ventio_core/ventio_core.dart';

import 'command_id.dart';
import 'extension_store.dart';
import 'local_command_queue.dart';
import 'maintenance_request_page.dart';
import 'transport_fixture.dart';

class ExtensionStudioPage extends StatefulWidget {
  const ExtensionStudioPage({
    required this.store,
    required this.queue,
    this.scope = const RecordScope(
      organizationId: 'local-organization',
      companyId: 'local-company',
      branchId: 'local-branch',
    ),
    super.key,
  });

  final LocalExtensionStore store;
  final LocalCommandQueue queue;
  final RecordScope scope;

  @override
  State<ExtensionStudioPage> createState() => _ExtensionStudioPageState();
}

class _ExtensionStudioPageState extends State<ExtensionStudioPage> {
  bool _loading = true;
  List<LocalExtension> _extensions = const [];
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final extensions = await widget.store.listExtensions();
      if (!mounted) return;
      setState(() {
        _extensions = extensions;
        _loading = false;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString();
      });
    }
  }

  Future<void> _createExtension() async {
    final values = await showDialog<_ExtensionFormValues>(
      context: context,
      builder: (context) =>
          _ExtensionFormDialog(availableExtensions: _extensions),
    );
    if (values == null) return;
    try {
      await widget.store.createExtension(
        moduleId: values.moduleId,
        displayName: values.displayName,
        description: values.description,
        version: values.version,
        dependencies: values.dependencies,
      );
      await _load();
      if (!mounted) return;
      await _openExtension(values.moduleId);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _openExtension(String moduleId) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => ExtensionDetailsPage(
          store: widget.store,
          moduleId: moduleId,
          scope: widget.scope,
        ),
      ),
    );
    await _load();
  }

  Future<void> _openMaintenanceProof() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => MaintenanceRequestPage(
          queue: widget.queue,
          transport: const DeterministicTransportFixture(),
        ),
      ),
    );
  }

  void _message(String value) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ventio · Extension Builder'),
        actions: [
          if (MediaQuery.sizeOf(context).width < 720)
            IconButton(
              tooltip: 'Offline queue proof',
              onPressed: _openMaintenanceProof,
              icon: const Icon(Icons.cloud_off_outlined),
            )
          else
            TextButton.icon(
              onPressed: _openMaintenanceProof,
              icon: const Icon(Icons.cloud_off_outlined),
              label: const Text('Offline queue proof'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                _LocalOnlyNotice(
                  title: 'Device workspace',
                  body:
                      'Extension definitions and preview records are stored on this device. No authenticated Host connection is configured, so this workspace does not publish extensions or confirm shared data.',
                  icon: Icons.phonelink_setup_outlined,
                ),
                const SizedBox(height: 24),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 620;
                    final heading = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Build an extension',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Define reusable records, fields, relationships and screens without adding a page to the Flutter app.',
                        ),
                      ],
                    );
                    final create = FilledButton.icon(
                      onPressed: _createExtension,
                      icon: const Icon(Icons.add),
                      label: const Text('New extension'),
                    );
                    if (compact) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [heading, const SizedBox(height: 16), create],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: heading),
                        const SizedBox(width: 16),
                        create,
                      ],
                    );
                  },
                ),
                const SizedBox(height: 24),
                if (_loading)
                  const Center(child: CircularProgressIndicator())
                else if (_loadError != null)
                  _StateCard(
                    icon: Icons.error_outline,
                    title: 'Extensions could not be loaded',
                    body: _loadError!,
                    action: TextButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  )
                else if (_extensions.isEmpty)
                  _StateCard(
                    icon: Icons.extension_outlined,
                    title: 'Start with an extension',
                    body:
                        'Create a local draft, add one or more DocTypes, then preview the screens generated from your metadata.',
                    action: FilledButton.icon(
                      onPressed: _createExtension,
                      icon: const Icon(Icons.add),
                      label: const Text('Create your first extension'),
                    ),
                  )
                else ...[
                  Text(
                    'Your extensions',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  for (final extension in _extensions)
                    _ExtensionCard(
                      extension: extension,
                      onTap: () => _openExtension(extension.moduleId),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ExtensionDetailsPage extends StatefulWidget {
  const ExtensionDetailsPage({
    required this.store,
    required this.moduleId,
    required this.scope,
    super.key,
  });

  final LocalExtensionStore store;
  final String moduleId;
  final RecordScope scope;

  @override
  State<ExtensionDetailsPage> createState() => _ExtensionDetailsPageState();
}

class _ExtensionDetailsPageState extends State<ExtensionDetailsPage> {
  LocalExtension? _extension;
  List<Map<String, dynamic>> _docTypes = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait<Object?>([
        widget.store.getExtension(widget.moduleId),
        widget.store.listDocTypes(widget.moduleId),
      ]);
      if (!mounted) return;
      setState(() {
        _extension = values[0] as LocalExtension?;
        _docTypes = values[1] as List<Map<String, dynamic>>;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _editExtension() async {
    final extension = _extension;
    if (extension == null) return;
    final availableExtensions = await widget.store.listExtensions();
    if (!mounted) return;
    final values = await showDialog<_ExtensionFormValues>(
      context: context,
      builder: (context) => _ExtensionFormDialog(
        extension: extension,
        availableExtensions: availableExtensions,
      ),
    );
    if (values == null) return;
    await _run(() async {
      await widget.store.updateExtensionDetails(
        moduleId: extension.moduleId,
        displayName: values.displayName,
        description: values.description,
        version: values.version,
        dependencies: values.dependencies,
      );
    });
  }

  Future<void> _addDocType([Map<String, dynamic>? existing]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => DocTypeBuilderPage(
          store: widget.store,
          moduleId: widget.moduleId,
          existing: existing,
        ),
      ),
    );
    if (saved == true) await _load();
  }

  Future<void> _openPreview(
    Map<String, dynamic> metadata, {
    bool previewOnly = true,
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => DynamicDocTypePage(
          store: widget.store,
          moduleId: widget.moduleId,
          metadata: metadata,
          scope: widget.scope,
          previewOnly: previewOnly,
        ),
      ),
    );
  }

  Future<void> _changeState() async {
    final extension = _extension;
    if (extension == null) return;
    await _run(() async {
      if (extension.state == ExtensionState.active) {
        await widget.store.disable(widget.moduleId);
      } else {
        await widget.store.activate(widget.moduleId);
      }
    });
  }

  Future<void> _remove() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this local extension?'),
        content: const Text(
          'Removal is allowed only when the extension has no local records. This action cannot publish or revoke a shared Host extension.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (approved != true) return;
    try {
      await widget.store.remove(widget.moduleId);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } catch (error) {
      _message(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String value) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  Widget build(BuildContext context) {
    final extension = _extension;
    return Scaffold(
      appBar: AppBar(title: Text(extension?.displayName ?? 'Extension')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : extension == null
          ? const Center(child: Text('This extension was removed.'))
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1080),
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    _LocalOnlyNotice(
                      title: 'Saved on this device',
                      body:
                          'This extension has no Host approval. Its locally generated pages and records do not sync to other devices.',
                      icon: Icons.lock_clock_outlined,
                    ),
                    const SizedBox(height: 20),
                    _extensionHeader(extension),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'DocTypes',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: _busy ? null : () => _addDocType(),
                          icon: const Icon(Icons.add),
                          label: const Text('Add DocType'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_docTypes.isEmpty)
                      const _StateCard(
                        icon: Icons.schema_outlined,
                        title: 'No DocTypes yet',
                        body:
                            'A DocType defines the fields, relationships, validation and permissions for a kind of record.',
                      )
                    else
                      for (final metadata in _docTypes)
                        _DocTypeCard(
                          metadata: metadata,
                          active: extension.state == ExtensionState.active,
                          onEdit: () => _addDocType(metadata),
                          onPreview: () => _openPreview(metadata),
                          onOpen: () =>
                              _openPreview(metadata, previewOnly: false),
                        ),
                    const SizedBox(height: 20),
                    _permissionsCard(_docTypes),
                    const SizedBox(height: 20),
                    _lifecycleCard(extension),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _extensionHeader(LocalExtension extension) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  extension.displayName,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                _StatusPill(label: extension.state.databaseValue),
                const _StatusPill(label: 'LOCAL ONLY'),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              extension.description.isEmpty
                  ? 'No description.'
                  : extension.description,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _MetadataText(label: 'Module ID', value: extension.moduleId),
                _MetadataText(label: 'Version', value: extension.version),
                _MetadataText(
                  label: 'Dependencies',
                  value: extension.dependencies.isEmpty
                      ? 'None'
                      : extension.dependencies.entries
                            .map((entry) => _dependencyVersionRange(entry))
                            .join(', '),
                ),
                _MetadataText(
                  label: 'Updated',
                  value: extension.updatedAtUtc
                      .toLocal()
                      .toString()
                      .split('.')
                      .first,
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _busy ? null : _editExtension,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit extension details'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _permissionsCard(List<Map<String, dynamic>> definitions) {
    final permissions = <String>{};
    for (final metadata in definitions) {
      final raw = metadata['permissions'];
      if (raw is Map) permissions.addAll(raw.values.whereType<String>());
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Permissions and operations',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'The extension declares read, create and update permission keys. It cannot grant them to users or add trusted Host capabilities. A Host administrator must approve and grant each exact scope.',
            ),
            const SizedBox(height: 12),
            if (permissions.isEmpty)
              const Text('Add a DocType to define permission keys.')
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final permission in permissions)
                    Chip(
                      avatar: const Icon(Icons.key_outlined, size: 16),
                      label: Text(permission),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _lifecycleCard(LocalExtension extension) {
    final active = extension.state == ExtensionState.active;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 12,
          children: [
            SizedBox(
              width: 540,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Device lifecycle',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    active
                        ? 'Pages are active on this device. Disabling keeps local definitions and records.'
                        : 'Activate this local draft to use its generated forms and records on this device.',
                  ),
                ],
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _remove,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Remove'),
                ),
                FilledButton.icon(
                  onPressed: _busy ? null : _changeState,
                  icon: Icon(
                    active ? Icons.pause_circle_outline : Icons.play_arrow,
                  ),
                  label: Text(
                    active ? 'Disable on device' : 'Activate on device',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class DocTypeBuilderPage extends StatefulWidget {
  const DocTypeBuilderPage({
    required this.store,
    required this.moduleId,
    this.existing,
    super.key,
  });

  final LocalExtensionStore store;
  final String moduleId;
  final Map<String, dynamic>? existing;

  @override
  State<DocTypeBuilderPage> createState() => _DocTypeBuilderPageState();
}

class _DocTypeBuilderPageState extends State<DocTypeBuilderPage> {
  final _nameController = TextEditingController();
  final _labelController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final List<Map<String, dynamic>> _fields = [];
  final List<String> _listColumns = [];
  final List<String> _formFields = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final metadata = widget.existing;
    if (metadata != null) {
      _nameController.text = metadata['name'] as String;
      _labelController.text = metadata['label'] as String;
      _descriptionController.text = (metadata['description'] as String?) ?? '';
      _fields.addAll(
        (metadata['fields'] as List).map(
          (field) => Map<String, dynamic>.from(field as Map),
        ),
      );
      final names = _fields.map((field) => field['name']! as String).toList();
      final ui = metadata['ui'];
      final rawListColumns = ui is Map ? ui['listColumns'] : null;
      final rawFormFields = ui is Map ? ui['formFields'] : null;
      _listColumns.addAll(
        rawListColumns is List
            ? rawListColumns.whereType<String>().where(names.contains)
            : names.take(4),
      );
      _formFields.addAll(
        rawFormFields is List
            ? rawFormFields.whereType<String>().where(names.contains)
            : names,
      );
      for (final field in _fields.where((item) => item['required'] == true)) {
        final name = field['name']! as String;
        if (!_formFields.contains(name)) _formFields.add(name);
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _labelController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _addField([Map<String, dynamic>? existing]) async {
    final docTypes = await widget.store.listDocTypes(widget.moduleId);
    final targets = docTypes
        .map((item) => item['name']! as String)
        .where((name) => name != widget.existing?['name'])
        .toList();
    if (!mounted) return;
    final field = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _FieldEditorDialog(
        moduleId: widget.moduleId,
        docTypeName: _nameController.text,
        relationTargets: targets,
        existing: existing,
      ),
    );
    if (field == null) return;
    setState(() {
      if (existing == null) {
        _fields.add(field);
        final name = field['name']! as String;
        _formFields.add(name);
        if (_listColumns.length < 4) _listColumns.add(name);
      } else {
        final index = _fields.indexOf(existing);
        if (index >= 0) _fields[index] = field;
      }
    });
  }

  Future<void> _removeField(Map<String, dynamic> field) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove field from this draft?'),
        content: Text(
          'Removing ${field['name']} may be rejected if the saved schema already uses it. Existing records are preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep field'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove field'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      setState(() {
        _fields.remove(field);
        final name = field['name']! as String;
        _listColumns.remove(name);
        _formFields.remove(name);
      });
    }
  }

  void _toggleLayoutField(List<String> selected, String name, bool checked) {
    setState(() {
      if (checked && !selected.contains(name)) {
        selected.add(name);
      } else if (!checked) {
        selected.remove(name);
      }
    });
  }

  void _moveLayoutField(List<String> selected, int index, int delta) {
    final destination = index + delta;
    if (destination < 0 || destination >= selected.length) return;
    setState(() {
      final field = selected.removeAt(index);
      selected.insert(destination, field);
    });
  }

  Widget _layoutCard({
    required String title,
    required String description,
    required List<String> selected,
    required bool requiredFieldsOnly,
  }) {
    final selectedRequired = _fields
        .where((field) => field['required'] == true)
        .map((field) => field['name']! as String)
        .toSet();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(description),
            if (_fields.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('Add fields to configure this layout.'),
              ),
            for (final field in _fields)
              Builder(
                builder: (context) {
                  final name = field['name']! as String;
                  final index = selected.indexOf(name);
                  final isRequired = selectedRequired.contains(name);
                  return CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: index >= 0,
                    title: Text(field['label']! as String),
                    subtitle: Text('$name · ${field['type']}'),
                    secondary: index < 0
                        ? null
                        : Wrap(
                            spacing: 0,
                            children: [
                              IconButton(
                                tooltip: 'Move ${field['label']} up',
                                onPressed: index == 0
                                    ? null
                                    : () =>
                                          _moveLayoutField(selected, index, -1),
                                icon: const Icon(Icons.arrow_upward),
                              ),
                              IconButton(
                                tooltip: 'Move ${field['label']} down',
                                onPressed: index == selected.length - 1
                                    ? null
                                    : () =>
                                          _moveLayoutField(selected, index, 1),
                                icon: const Icon(Icons.arrow_downward),
                              ),
                            ],
                          ),
                    onChanged: requiredFieldsOnly && isRequired
                        ? null
                        : (checked) => _toggleLayoutField(
                            selected,
                            name,
                            checked ?? false,
                          ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_fields.isEmpty) {
      _message('Add at least one field to the DocType.');
      return;
    }
    if (_listColumns.isEmpty) {
      _message('Choose at least one list column.');
      return;
    }
    if (_formFields.isEmpty) {
      _message('Choose at least one generated form field.');
      return;
    }
    final name = _nameController.text.trim();
    final label = _labelController.text.trim();
    final previousVersion = widget.existing?['schemaVersion'] as int?;
    final fields = List<Map<String, dynamic>>.from(_fields);
    final namespace = _messageNamespace(widget.moduleId);
    final permissions = {
      for (final operation in ['read', 'create', 'update'])
        operation: permissionKey(widget.moduleId, name, operation),
    };
    final metadata = <String, dynamic>{
      'name': name,
      'moduleId': widget.moduleId,
      'schemaVersion': (previousVersion ?? 0) + 1,
      'kind': 'operational',
      'fields': fields,
      'permissions': permissions,
      'ui': {
        'listColumns': List<String>.of(_listColumns),
        'formFields': List<String>.of(_formFields),
      },
      'label': label,
      'labelKey': '$namespace.${name.toLowerCase()}.name',
      'description': _descriptionController.text.trim(),
      'descriptionKey': '$namespace.${name.toLowerCase()}.description',
    };
    setState(() => _saving = true);
    try {
      DocTypeDefinition.fromJson(metadata);
      await widget.store.saveDocType(metadata);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      _message(error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String value) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'Edit DocType' : 'New DocType')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const _LocalOnlyNotice(
                  title: 'Schema designer',
                  body:
                      'DocType definitions are validated metadata. They cannot contain SQL, scripts or downloaded executable code.',
                  icon: Icons.schema_outlined,
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _nameController,
                  readOnly: editing,
                  decoration: const InputDecoration(
                    labelText: 'DocType ID',
                    hintText: 'Asset',
                    helperText:
                        'Stable identifier. Use letters, numbers and underscores.',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => _identifierError(
                    value,
                    RegExp(r'^[A-Z][A-Za-z0-9_]*$'),
                    'Use an identifier such as Asset or AssetAssignment.',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _labelController,
                  decoration: const InputDecoration(
                    labelText: 'Display name',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) =>
                      _requiredText(value, 'Enter a display name.'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descriptionController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Fields (${_fields.length})',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => _addField(),
                      icon: const Icon(Icons.add),
                      label: const Text('Add field'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_fields.isEmpty)
                  const _StateCard(
                    icon: Icons.view_list_outlined,
                    title: 'Add the first field',
                    body:
                        'Fields define what the generated form validates and stores.',
                  )
                else
                  for (final field in _fields)
                    _FieldCard(
                      field: field,
                      onEdit: () => _addField(field),
                      onDelete: () => _removeField(field),
                    ),
                const SizedBox(height: 24),
                _layoutCard(
                  title: 'List page columns',
                  description:
                      'Choose visible columns and their order in generated lists.',
                  selected: _listColumns,
                  requiredFieldsOnly: false,
                ),
                const SizedBox(height: 12),
                _layoutCard(
                  title: 'Generated form fields',
                  description:
                      'Choose and order fields shown on create and edit forms. Required fields stay visible.',
                  selected: _formFields,
                  requiredFieldsOnly: true,
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Generated permissions',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Read, create and update keys are namespaced to this extension. A Host administrator grants these permissions; the extension cannot grant them to itself.',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(_saving ? 'Saving…' : 'Save DocType'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FieldEditorDialog extends StatefulWidget {
  const _FieldEditorDialog({
    required this.moduleId,
    required this.docTypeName,
    required this.relationTargets,
    this.existing,
  });

  final String moduleId;
  final String docTypeName;
  final List<String> relationTargets;
  final Map<String, dynamic>? existing;

  @override
  State<_FieldEditorDialog> createState() => _FieldEditorDialogState();
}

class _FieldEditorDialogState extends State<_FieldEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _label;
  late final TextEditingController _maxLength;
  late final TextEditingController _enumValues;
  String _type = 'text';
  String? _referenceTo;
  bool _required = false;

  @override
  void initState() {
    super.initState();
    final field = widget.existing;
    _name = TextEditingController(text: field?['name'] as String? ?? '');
    _label = TextEditingController(text: field?['label'] as String? ?? '');
    _maxLength = TextEditingController(
      text: field?['maxLength']?.toString() ?? '160',
    );
    _enumValues = TextEditingController(
      text: ((field?['enumValues'] as List?) ?? const []).join(', '),
    );
    _type = field?['type'] as String? ?? 'text';
    _referenceTo = field?['referenceTo'] as String?;
    _required = field?['required'] as bool? ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _label.dispose();
    _maxLength.dispose();
    _enumValues.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final fieldName = _name.text.trim();
    final label = _label.text.trim();
    final metadata = <String, dynamic>{
      'name': fieldName,
      'type': _type,
      'required': _required,
      'label': label,
      'labelKey':
          '${_messageNamespace(widget.moduleId)}.${widget.docTypeName.toLowerCase()}.${fieldName.toLowerCase()}',
    };
    if (_type == 'text') metadata['maxLength'] = int.parse(_maxLength.text);
    if (_type == 'reference') metadata['referenceTo'] = _referenceTo;
    if (_type == 'enum') {
      final values = _enumValues.text
          .split(',')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
      metadata['enumValues'] = values;
      metadata['enumLabels'] = {
        for (final value in values)
          value: {
            'label': value,
            'labelKey':
                '${_messageNamespace(widget.moduleId)}.${widget.docTypeName.toLowerCase()}.${fieldName}_${value.toLowerCase()}',
          },
      };
    }
    Navigator.pop(context, metadata);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add field' : 'Edit field'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Field ID',
                    hintText: 'serialNumber',
                  ),
                  validator: (value) => _identifierError(
                    value,
                    RegExp(r'^[a-z][A-Za-z0-9_]*$'),
                    'Use lower camel case, such as serialNumber.',
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _label,
                  decoration: const InputDecoration(labelText: 'Label'),
                  validator: (value) =>
                      _requiredText(value, 'Enter a field label.'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _type,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Data type'),
                  items: const [
                    DropdownMenuItem(value: 'text', child: Text('Text')),
                    DropdownMenuItem(
                      value: 'integer',
                      child: Text('Whole number'),
                    ),
                    DropdownMenuItem(value: 'decimal', child: Text('Decimal')),
                    DropdownMenuItem(value: 'boolean', child: Text('Yes / no')),
                    DropdownMenuItem(value: 'date', child: Text('Date')),
                    DropdownMenuItem(
                      value: 'datetime',
                      child: Text('Date and time'),
                    ),
                    DropdownMenuItem(value: 'enum', child: Text('Choice list')),
                    DropdownMenuItem(
                      value: 'reference',
                      child: Text('Relationship'),
                    ),
                  ],
                  onChanged: (value) => setState(() => _type = value ?? 'text'),
                ),
                if (_type == 'text') ...[
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _maxLength,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Maximum length',
                    ),
                    validator: (value) {
                      final parsed = int.tryParse(value ?? '');
                      if (parsed == null || parsed < 1 || parsed > 65535) {
                        return 'Enter a number from 1 to 65,535.';
                      }
                      return null;
                    },
                  ),
                ],
                if (_type == 'enum') ...[
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _enumValues,
                    minLines: 2,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Choice values',
                      hintText: 'new, active, retired',
                      helperText: 'Separate stable values with commas.',
                    ),
                    validator: (value) {
                      final values = (value ?? '')
                          .split(',')
                          .map((item) => item.trim())
                          .where((item) => item.isNotEmpty)
                          .toList();
                      if (values.isEmpty) return 'Add at least one choice.';
                      if (values.toSet().length != values.length) {
                        return 'Choice values must be unique.';
                      }
                      if (values.any((item) => !_enumValue.hasMatch(item))) {
                        return 'Use lowercase stable IDs, such as in_use.';
                      }
                      return null;
                    },
                  ),
                ],
                if (_type == 'reference') ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: _referenceTo,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Related DocType',
                    ),
                    items: [
                      for (final target in widget.relationTargets)
                        DropdownMenuItem(value: target, child: Text(target)),
                    ],
                    onChanged: (value) => setState(() => _referenceTo = value),
                    validator: (value) =>
                        value == null ? 'Select a DocType.' : null,
                  ),
                ],
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Required field'),
                  value: _required,
                  onChanged: (value) => setState(() => _required = value),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save field')),
      ],
    );
  }
}

class DynamicDocTypePage extends StatefulWidget {
  const DynamicDocTypePage({
    required this.store,
    required this.moduleId,
    required this.metadata,
    required this.scope,
    this.previewOnly = false,
    super.key,
  });

  final LocalExtensionStore store;
  final String moduleId;
  final Map<String, dynamic> metadata;
  final RecordScope scope;
  final bool previewOnly;

  @override
  State<DynamicDocTypePage> createState() => _DynamicDocTypePageState();
}

class _DynamicDocTypePageState extends State<DynamicDocTypePage> {
  final _searchController = TextEditingController();
  final _filterController = TextEditingController();
  List<LocalExtensionRecord> _records = const [];
  bool _loading = false;
  String? _error;
  String? _filterField;
  String? _sortField;
  bool _ascending = true;
  int _loadGeneration = 0;

  DocTypeDefinition get _definition =>
      DocTypeDefinition.fromJson(widget.metadata);

  @override
  void initState() {
    super.initState();
    _sortField = _definition.fields.first.name;
    if (!widget.previewOnly) _loadRecords();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _loadRecords() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final records = await widget.store.listRecords(
        moduleId: widget.moduleId,
        docTypeName: _definition.name,
        scope: widget.scope,
        search: _searchController.text,
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _records = records;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  List<LocalExtensionRecord> get _visibleRecords {
    final records = [..._records];
    final field = _sortField;
    records.sort((left, right) {
      final comparison = field == null
          ? left.updatedAtUtc.compareTo(right.updatedAtUtc)
          : (left.values[field]?.toString().toLowerCase() ?? '').compareTo(
              right.values[field]?.toString().toLowerCase() ?? '',
            );
      return _ascending ? comparison : -comparison;
    });
    final filter = _filterController.text.trim().toLowerCase();
    if (_filterField != null && filter.isNotEmpty) {
      return records
          .where(
            (record) =>
                record.values[_filterField]?.toString().toLowerCase().contains(
                  filter,
                ) ==
                true,
          )
          .toList(growable: false);
    }
    return records;
  }

  Future<void> _openForm([LocalExtensionRecord? record]) async {
    if (widget.previewOnly) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (context) => DynamicRecordFormPage(
            store: widget.store,
            moduleId: widget.moduleId,
            definition: _definition,
            scope: widget.scope,
            previewOnly: true,
          ),
        ),
      );
      return;
    }
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => DynamicRecordFormPage(
          store: widget.store,
          moduleId: widget.moduleId,
          definition: _definition,
          scope: widget.scope,
          record: record,
        ),
      ),
    );
    if (changed == true) await _loadRecords();
  }

  Future<void> _openDetails(LocalExtensionRecord record) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => DynamicRecordDetailsPage(
          store: widget.store,
          moduleId: widget.moduleId,
          definition: _definition,
          scope: widget.scope,
          record: record,
        ),
      ),
    );
    if (changed == true) await _loadRecords();
  }

  @override
  Widget build(BuildContext context) {
    final metadata = widget.metadata;
    final title = metadata['label'] as String;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: Icon(widget.previewOnly ? Icons.preview_outlined : Icons.add),
        label: Text(widget.previewOnly ? 'Preview form' : 'New record'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 96),
            children: [
              _LocalOnlyNotice(
                title: widget.previewOnly
                    ? 'Metadata preview'
                    : 'Local records',
                body: widget.previewOnly
                    ? 'This screen is rendered from the DocType definition. Saving is disabled until the extension is activated on this device.'
                    : 'Records are isolated in this local preview by organization, company and branch labels. Host authentication, authorization and synchronization are not connected.',
                icon: widget.previewOnly
                    ? Icons.visibility_outlined
                    : Icons.storage_outlined,
              ),
              const SizedBox(height: 20),
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              if (metadata['description'] case final String description
                  when description.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(description),
              ],
              const SizedBox(height: 12),
              if (!widget.previewOnly) ...[
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    labelText: 'Search records',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      onPressed: () {
                        _searchController.clear();
                        _loadRecords();
                      },
                      icon: const Icon(Icons.clear),
                    ),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => _loadRecords(),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String?>(
                        initialValue: _filterField,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Filter field',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('No filter'),
                          ),
                          for (final field in _definition.fields)
                            DropdownMenuItem<String?>(
                              value: field.name,
                              child: Text(field.label),
                            ),
                        ],
                        onChanged: (value) =>
                            setState(() => _filterField = value),
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: TextField(
                        controller: _filterController,
                        enabled: _filterField != null,
                        decoration: const InputDecoration(
                          labelText: 'Contains',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String?>(
                        initialValue: _sortField,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Sort by',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Last updated'),
                          ),
                          for (final field in _definition.fields)
                            DropdownMenuItem<String?>(
                              value: field.name,
                              child: Text(field.label),
                            ),
                        ],
                        onChanged: (value) =>
                            setState(() => _sortField = value),
                      ),
                    ),
                    IconButton(
                      tooltip: _ascending ? 'Ascending' : 'Descending',
                      onPressed: () => setState(() => _ascending = !_ascending),
                      icon: Icon(
                        _ascending ? Icons.arrow_upward : Icons.arrow_downward,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
              ],
              if (widget.previewOnly)
                _StateCard(
                  icon: Icons.view_list_outlined,
                  title: 'Generated list view',
                  body:
                      'The list shows ${_definition.listColumns.length} configured column${_definition.listColumns.length == 1 ? '' : 's'} and will support search and local filters when activated.',
                  action: OutlinedButton.icon(
                    onPressed: () => _openForm(),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open generated form'),
                  ),
                )
              else if (_loading)
                const Center(child: CircularProgressIndicator())
              else if (_error != null)
                _StateCard(
                  icon: Icons.error_outline,
                  title: 'Records could not be loaded',
                  body: _error!,
                  action: TextButton.icon(
                    onPressed: _loadRecords,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
                )
              else if (_visibleRecords.isEmpty)
                const _StateCard(
                  icon: Icons.inbox_outlined,
                  title: 'No matching records',
                  body:
                      'Create a record on this device or change your search and filters.',
                )
              else
                for (final record in _visibleRecords)
                  _RecordCard(
                    record: record,
                    columns: _listColumns,
                    onTap: () => _openDetails(record),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  List<FieldDefinition> get _listColumns {
    final byName = {for (final field in _definition.fields) field.name: field};
    return _definition.listColumns
        .map((name) => byName[name]!)
        .toList(growable: false);
  }
}

class DynamicRecordFormPage extends StatefulWidget {
  const DynamicRecordFormPage({
    required this.store,
    required this.moduleId,
    required this.definition,
    required this.scope,
    this.record,
    this.previewOnly = false,
    super.key,
  });

  final LocalExtensionStore store;
  final String moduleId;
  final DocTypeDefinition definition;
  final RecordScope scope;
  final LocalExtensionRecord? record;
  final bool previewOnly;

  @override
  State<DynamicRecordFormPage> createState() => _DynamicRecordFormPageState();
}

class _DynamicRecordFormPageState extends State<DynamicRecordFormPage> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, bool> _booleans = {};
  final Map<String, String?> _selections = {};
  final Map<String, List<LocalExtensionRecord>> _references = {};
  bool _loadingReferences = false;
  bool _saving = false;

  List<FieldDefinition> get _formFields {
    final byName = {
      for (final field in widget.definition.fields) field.name: field,
    };
    return widget.definition.formFields
        .map((name) => byName[name]!)
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    for (final field in _formFields) {
      final value = widget.record?.values[field.name];
      if (field.type == 'boolean') {
        _booleans[field.name] = value as bool? ?? false;
      } else if (field.type == 'enum' || field.type == 'reference') {
        _selections[field.name] = value as String?;
      } else {
        _controllers[field.name] = TextEditingController(
          text: value?.toString() ?? '',
        );
      }
    }
    _loadReferences();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadReferences() async {
    final fields = _formFields.where((field) => field.type == 'reference');
    if (fields.isEmpty) return;
    setState(() => _loadingReferences = true);
    try {
      for (final field in fields) {
        _references[field.name] = await widget.store.listRecords(
          moduleId: widget.moduleId,
          docTypeName: field.referenceTo!,
          scope: widget.scope,
          limit: 500,
        );
      }
    } catch (_) {
      // A reference list can be empty in a preview; saving still validates it.
    } finally {
      if (mounted) setState(() => _loadingReferences = false);
    }
  }

  Map<String, dynamic> _values() {
    final values = Map<String, dynamic>.of(widget.record?.values ?? const {});
    for (final field in _formFields) {
      if (field.type == 'boolean') {
        values[field.name] = _booleans[field.name] ?? false;
      } else if (field.type == 'enum' || field.type == 'reference') {
        values[field.name] = _selections[field.name];
      } else {
        final raw = _controllers[field.name]!.text.trim();
        if (raw.isEmpty) {
          values[field.name] = null;
        } else if (field.type == 'integer') {
          values[field.name] = int.tryParse(raw);
        } else if (field.type == 'decimal') {
          values[field.name] = num.tryParse(raw);
        } else {
          values[field.name] = raw;
        }
      }
    }
    return values;
  }

  Future<void> _save() async {
    if (widget.previewOnly) return;
    if (!_formKey.currentState!.validate()) return;
    final values = _values();
    final issues = widget.definition.validatePayload(values);
    if (issues.isNotEmpty) {
      _message(issues.join('\n'));
      return;
    }
    setState(() => _saving = true);
    try {
      if (widget.record == null) {
        await widget.store.createRecord(
          moduleId: widget.moduleId,
          docTypeName: widget.definition.name,
          scope: widget.scope,
          values: values,
          recordId: createCommandId(),
        );
      } else {
        await widget.store.updateRecord(
          recordId: widget.record!.recordId,
          scope: widget.scope,
          expectedRevision: widget.record!.revision,
          values: values,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      _message(error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String value) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.record != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          editing
              ? 'Edit ${widget.definition.label}'
              : 'New ${widget.definition.label}',
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                _LocalOnlyNotice(
                  title: widget.previewOnly
                      ? 'Preview form'
                      : 'Device-only record',
                  body: widget.previewOnly
                      ? 'Values are for preview and cannot be saved.'
                      : 'This record is stored in the local workspace. A Host has not accepted it.',
                  icon: widget.previewOnly
                      ? Icons.preview_outlined
                      : Icons.save_outlined,
                ),
                const SizedBox(height: 20),
                for (final field in _formFields) ...[
                  _fieldInput(field),
                  const SizedBox(height: 14),
                ],
                if (_loadingReferences) const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _saving || widget.previewOnly ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(
                      widget.previewOnly
                          ? 'Preview only'
                          : _saving
                          ? 'Saving…'
                          : editing
                          ? 'Save changes'
                          : 'Save on device',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fieldInput(FieldDefinition field) {
    if (field.type == 'boolean') {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(field.label),
        subtitle: Text(field.required ? 'Required' : 'Optional'),
        value: _booleans[field.name] ?? false,
        onChanged: widget.previewOnly
            ? null
            : (value) => setState(() => _booleans[field.name] = value),
      );
    }
    if (field.type == 'enum') {
      return DropdownButtonFormField<String?>(
        initialValue: _selections[field.name],
        isExpanded: true,
        decoration: InputDecoration(
          labelText: field.label,
          border: const OutlineInputBorder(),
        ),
        items: [
          if (!field.required)
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('Not set'),
            ),
          for (final value in field.enumValues)
            DropdownMenuItem<String?>(
              value: value,
              child: Text(_enumLabel(field, value)),
            ),
        ],
        onChanged: widget.previewOnly
            ? null
            : (value) => setState(() => _selections[field.name] = value),
        validator: (value) => field.required && value == null
            ? 'Select ${field.label.toLowerCase()}.'
            : null,
      );
    }
    if (field.type == 'reference') {
      final records = _references[field.name] ?? const <LocalExtensionRecord>[];
      return DropdownButtonFormField<String?>(
        initialValue: _selections[field.name],
        isExpanded: true,
        decoration: InputDecoration(
          labelText: field.label,
          helperText: 'Related ${field.referenceTo} in the current local scope',
          border: const OutlineInputBorder(),
        ),
        items: [
          if (!field.required)
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('Not set'),
            ),
          for (final record in records)
            DropdownMenuItem<String?>(
              value: record.recordId,
              child: Text(_recordTitle(record)),
            ),
        ],
        onChanged: widget.previewOnly
            ? null
            : (value) => setState(() => _selections[field.name] = value),
        validator: (value) => field.required && value == null
            ? 'Select a related ${field.referenceTo} record.'
            : null,
      );
    }
    return TextFormField(
      controller: _controllers[field.name],
      readOnly: widget.previewOnly,
      keyboardType: switch (field.type) {
        'integer' => TextInputType.number,
        'decimal' => const TextInputType.numberWithOptions(decimal: true),
        _ => TextInputType.text,
      },
      maxLength: field.type == 'text' ? field.maxLength : null,
      maxLines: field.type == 'text' && (field.maxLength ?? 0) > 500 ? 4 : 1,
      decoration: InputDecoration(
        labelText: field.label,
        helperText:
            '${field.type}${field.required ? ' · required' : ' · optional'}',
        border: const OutlineInputBorder(),
      ),
      validator: (value) {
        final raw = value?.trim() ?? '';
        if (field.required && raw.isEmpty) {
          return 'Enter ${field.label.toLowerCase()}.';
        }
        if (raw.isEmpty) return null;
        if (field.type == 'integer' && int.tryParse(raw) == null) {
          return 'Enter a whole number.';
        }
        if (field.type == 'decimal' && num.tryParse(raw) == null) {
          return 'Enter a number.';
        }
        if (field.type == 'date' && field.validate(raw) != null) {
          return 'Enter a valid date in YYYY-MM-DD format.';
        }
        if (field.type == 'datetime' && field.validate(raw) != null) {
          return 'Enter an ISO date and time with a time-zone offset.';
        }
        return null;
      },
    );
  }
}

class DynamicRecordDetailsPage extends StatelessWidget {
  const DynamicRecordDetailsPage({
    required this.store,
    required this.moduleId,
    required this.definition,
    required this.scope,
    required this.record,
    super.key,
  });

  final LocalExtensionStore store;
  final String moduleId;
  final DocTypeDefinition definition;
  final RecordScope scope;
  final LocalExtensionRecord record;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${definition.label} details')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final changed = await Navigator.of(context).push<bool>(
            MaterialPageRoute<bool>(
              builder: (context) => DynamicRecordFormPage(
                store: store,
                moduleId: moduleId,
                definition: definition,
                scope: scope,
                record: record,
              ),
            ),
          );
          if (context.mounted && changed == true) Navigator.pop(context, true);
        },
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Edit record'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const _LocalOnlyNotice(
                title: 'Device-only record',
                body:
                    'No Host receipt or shared approval is associated with this record.',
                icon: Icons.info_outline,
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final field in definition.fields) ...[
                        Text(
                          field.label,
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 4),
                        SelectableText(
                          _displayValue(field, record.values[field.name]),
                        ),
                        const Divider(height: 24),
                      ],
                      Text('Revision ${record.revision} · ${record.syncState}'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExtensionFormValues {
  const _ExtensionFormValues({
    required this.moduleId,
    required this.displayName,
    required this.description,
    required this.version,
    required this.dependencies,
  });

  final String moduleId;
  final String displayName;
  final String description;
  final String version;
  final Map<String, String> dependencies;
}

class _ExtensionFormDialog extends StatefulWidget {
  const _ExtensionFormDialog({
    this.extension,
    this.availableExtensions = const [],
  });

  final LocalExtension? extension;
  final List<LocalExtension> availableExtensions;

  @override
  State<_ExtensionFormDialog> createState() => _ExtensionFormDialogState();
}

class _ExtensionFormDialogState extends State<_ExtensionFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _moduleId;
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _version;
  late final Map<String, String> _dependencies;

  @override
  void initState() {
    super.initState();
    final extension = widget.extension;
    _moduleId = TextEditingController(
      text: extension?.moduleId ?? 'com.example.new_extension',
    );
    _name = TextEditingController(text: extension?.displayName ?? '');
    _description = TextEditingController(text: extension?.description ?? '');
    _version = TextEditingController(text: extension?.version ?? '0.1.0');
    _dependencies = Map.of(extension?.dependencies ?? const {});
  }

  @override
  void dispose() {
    _moduleId.dispose();
    _name.dispose();
    _description.dispose();
    _version.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _ExtensionFormValues(
        moduleId: _moduleId.text.trim(),
        displayName: _name.text.trim(),
        description: _description.text.trim(),
        version: _version.text.trim(),
        dependencies: Map.unmodifiable(_dependencies),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.extension != null;
    return AlertDialog(
      title: Text(editing ? 'Edit extension details' : 'Create extension'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _moduleId,
                  readOnly: editing,
                  decoration: const InputDecoration(
                    labelText: 'Module ID',
                    hintText: 'com.example.asset_register',
                    helperText:
                        'Stable namespaced ID; it cannot be changed later.',
                  ),
                  validator: (value) => _identifierError(
                    value,
                    RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$'),
                    'Use lowercase words separated by dots, such as com.example.assets.',
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Display name'),
                  validator: (value) => _requiredText(value, 'Enter a name.'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _description,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _version,
                  decoration: const InputDecoration(
                    labelText: 'Version',
                    helperText: 'Semantic version, for example 0.1.0.',
                  ),
                  validator: (value) {
                    final raw = value?.trim() ?? '';
                    if (!RegExp(
                      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
                    ).hasMatch(raw)) {
                      return 'Enter a semantic version such as 0.1.1.';
                    }
                    final previous = widget.extension?.version;
                    if (previous != null && compareSemver(raw, previous) < 0) {
                      return 'Version cannot move backwards.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Dependencies',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                    child: Text(
                      widget.extension?.state == ExtensionState.active
                          ? 'Disable this extension before changing dependencies.'
                          : 'Dependencies must be installed locally. Version 0.x dependencies accept patch updates only; later versions accept updates within the same major version.',
                    ),
                  ),
                ),
                if (widget.availableExtensions
                    .where(
                      (item) => item.moduleId != widget.extension?.moduleId,
                    )
                    .isEmpty)
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Create another extension to add a dependency.',
                    ),
                  )
                else
                  for (final dependency in widget.availableExtensions.where(
                    (item) => item.moduleId != widget.extension?.moduleId,
                  ))
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _dependencies.containsKey(dependency.moduleId),
                      title: Text(dependency.displayName),
                      subtitle: Text(
                        '${dependency.moduleId} · ${_dependencyVersionRange(MapEntry(dependency.moduleId, _dependencies[dependency.moduleId] ?? dependency.version))}',
                      ),
                      onChanged:
                          widget.extension?.state == ExtensionState.active
                          ? null
                          : (selected) {
                              setState(() {
                                if (selected == true) {
                                  _dependencies[dependency.moduleId] =
                                      _dependencies[dependency.moduleId] ??
                                      dependency.version;
                                } else {
                                  _dependencies.remove(dependency.moduleId);
                                }
                              });
                            },
                    ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(editing ? 'Save changes' : 'Create draft'),
        ),
      ],
    );
  }
}

class _ExtensionCard extends StatelessWidget {
  const _ExtensionCard({required this.extension, required this.onTap});

  final LocalExtension extension;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 10,
        ),
        leading: const CircleAvatar(child: Icon(Icons.extension_outlined)),
        title: Text(extension.displayName),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('${extension.moduleId} · v${extension.version}'),
        ),
        trailing: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _StatusPill(label: extension.state.databaseValue),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

class _DocTypeCard extends StatelessWidget {
  const _DocTypeCard({
    required this.metadata,
    required this.active,
    required this.onEdit,
    required this.onPreview,
    required this.onOpen,
  });

  final Map<String, dynamic> metadata;
  final bool active;
  final VoidCallback onEdit;
  final VoidCallback onPreview;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final fields = metadata['fields'] as List;
    final label = metadata['label'] as String;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(label, style: Theme.of(context).textTheme.titleMedium),
                _StatusPill(label: 'SCHEMA ${metadata['schemaVersion']}'),
                Text('${fields.length} fields'),
              ],
            ),
            const SizedBox(height: 4),
            Text('${metadata['name']} · operational DocType'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in fields.take(6))
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('${item['label']} · ${item['type']}'),
                  ),
                if (fields.length > 6)
                  Chip(label: Text('+${fields.length - 6} more')),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: onPreview,
                  icon: const Icon(Icons.preview_outlined),
                  label: const Text('Preview'),
                ),
                if (active)
                  FilledButton.tonalIcon(
                    onPressed: onOpen,
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open records'),
                  ),
                TextButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit schema'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FieldCard extends StatelessWidget {
  const _FieldCard({
    required this.field,
    required this.onEdit,
    required this.onDelete,
  });

  final Map<String, dynamic> field;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final detail = field['type'] == 'reference'
        ? 'Related to ${field['referenceTo']}'
        : field['type'] == 'enum'
        ? (field['enumValues'] as List).join(', ')
        : field['type'] == 'text'
        ? 'Maximum ${field['maxLength']} characters'
        : field['type'] as String;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.drag_indicator),
        title: Text('${field['label']} · ${field['name']}'),
        subtitle: Text(
          '$detail · ${field['required'] == true ? 'required' : 'optional'}',
        ),
        trailing: Wrap(
          children: [
            IconButton(
              onPressed: onEdit,
              tooltip: 'Edit field',
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              onPressed: onDelete,
              tooltip: 'Remove field',
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordCard extends StatelessWidget {
  const _RecordCard({
    required this.record,
    required this.columns,
    required this.onTap,
  });

  final LocalExtensionRecord record;
  final List<FieldDefinition> columns;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = columns.first;
    final summary = columns.skip(1).take(3).map((field) {
      return '${field.label}: ${_displayValue(field, record.values[field.name])}';
    }).toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: onTap,
        leading: const CircleAvatar(child: Icon(Icons.description_outlined)),
        title: Text(_displayValue(primary, record.values[primary.name])),
        subtitle: Text(
          [
            if (summary.isNotEmpty) summary.join(' · '),
            'Revision ${record.revision} · local only',
          ].join(' · '),
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _MetadataText extends StatelessWidget {
  const _MetadataText({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => RichText(
    text: TextSpan(
      style: DefaultTextStyle.of(context).style,
      children: [
        TextSpan(
          text: '$label: ',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        TextSpan(text: value),
      ],
    ),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(label, style: Theme.of(context).textTheme.labelSmall),
  );
}

class _LocalOnlyNotice extends StatelessWidget {
  const _LocalOnlyNotice({
    required this.title,
    required this.body,
    required this.icon,
  });
  final String title;
  final String body;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(body),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 30),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(body),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    ),
  );
}

String _messageNamespace(String moduleId) =>
    'extension.${moduleId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}';

String? _requiredText(String? value, String error) =>
    (value == null || value.trim().isEmpty) ? error : null;

String? _identifierError(String? value, RegExp pattern, String message) {
  final raw = value?.trim() ?? '';
  return pattern.hasMatch(raw) ? null : message;
}

String _enumLabel(FieldDefinition field, String value) {
  final raw = field.enumValues;
  if (!raw.contains(value)) return value;
  return value
      .replaceAll('_', ' ')
      .split(' ')
      .map((part) {
        if (part.isEmpty) return part;
        return '${part[0].toUpperCase()}${part.substring(1)}';
      })
      .join(' ');
}

String _displayValue(FieldDefinition field, Object? value) {
  if (value == null || value == '') return '—';
  if (field.type == 'enum') return _enumLabel(field, value.toString());
  return value.toString();
}

String _recordTitle(LocalExtensionRecord record) {
  final first = record.values.values.firstWhere(
    (value) => value != null && value.toString().isNotEmpty,
    orElse: () => record.recordId,
  );
  return first.toString();
}

String _dependencyVersionRange(MapEntry<String, String> dependency) {
  final version = semverParts(dependency.value);
  final upperBound = version[0] == 0
      ? '0.${version[1] + 1}.0'
      : '${version[0] + 1}.0.0';
  return '>=${dependency.value}, <$upperBound';
}

final RegExp _enumValue = RegExp(r'^[a-z][a-z0-9_]*$');
