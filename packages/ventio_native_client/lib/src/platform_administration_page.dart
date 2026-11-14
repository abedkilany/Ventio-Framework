import 'app_localization.dart';
import 'package:flutter/material.dart';
import 'package:ventio_core/ventio_core.dart';

import 'command_id.dart';
import 'extension_store.dart';
import 'host_extension_packages.dart';

typedef PlatformAdministrationRequest =
    Future<Map<String, dynamic>> Function(
      String action,
      Map<String, Object?> body,
    );

class PlatformAdministrationPage extends StatefulWidget {
  const PlatformAdministrationPage({
    required this.request,
    required this.profile,
    super.key,
  });
  final PlatformAdministrationRequest request;
  final HostConnectionProfile profile;
  @override
  State<PlatformAdministrationPage> createState() =>
      _PlatformAdministrationPageState();
}

class _PlatformAdministrationPageState
    extends State<PlatformAdministrationPage> {
  List<Map<String, dynamic>> _entities = [];
  bool _busy = true, _canCreateCompany = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _entities = [];
    });
    try {
      final result = await widget.request('organization/list', {});
      if (!mounted) return;
      setState(() {
        _entities = requireList(
          result,
          'entities',
        ).map((raw) => requireMap(raw, 'entity')).toList();
        _canCreateCompany = result['canCreateCompany'] == true;
        _busy = false;
      });
    } catch (error) {
      _failed(error);
    }
  }

  void _failed(Object error) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _entities = [];
      _error = error is HostPackageTransportException
          ? error.code
          : 'ADMINISTRATION_UNAVAILABLE';
    });
  }

  Future<void> _edit(String kind, [Map<String, dynamic>? entity]) async {
    final id = TextEditingController(text: entity?['id'] as String? ?? '');
    final title = TextEditingController(
      text: entity?['displayName'] as String? ?? '',
    );
    var parent = entity?['parentId'] as String?;
    var archived = entity?['archived'] == true;
    String? validation;
    final companies = _entities
        .where((item) => item['kind'] == 'company' && item['archived'] == false)
        .toList();
    if (kind == 'branch' && parent == null && companies.isNotEmpty)
      parent = companies.first['id'] as String;
    final currentScope =
        kind == 'organization' ||
        (kind == 'company' && entity?['id'] == widget.profile.companyId) ||
        (kind == 'branch' &&
            entity?['id'] == widget.profile.branchId &&
            parent == widget.profile.companyId);
    try {
      final change = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: Text('${entity == null ? 'Create' : 'Manage'} $kind'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: id,
                      readOnly: entity != null,
                      maxLength: 128,
                      decoration: InputDecoration(
                        labelText: context.ventioText(
                          'native.wave2.identifier_9b10587f',
                        ),
                      ),
                    ),
                    TextField(
                      controller: title,
                      maxLength: 120,
                      decoration: InputDecoration(
                        labelText: context.ventioText(
                          'native.wave2.display_name_2b7f6a84',
                        ),
                      ),
                    ),
                    if (kind == 'branch')
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: parent,
                        decoration: InputDecoration(
                          labelText: context.ventioText(
                            'native.wave2.company_de4743c8',
                          ),
                        ),
                        items: [
                          for (final company in companies)
                            DropdownMenuItem(
                              value: company['id'] as String,
                              child: Text(company['displayName'] as String),
                            ),
                        ],
                        onChanged: entity != null
                            ? null
                            : (value) => update(() => parent = value),
                      ),
                    SwitchListTile(
                      title: const VentioText('native.wave2.archived_bdb86505'),
                      subtitle: Text(
                        currentScope
                            ? 'The current scope and tenant identity must remain active.'
                            : 'Archiving retains data and grants, and blocks business access until authorized reactivation.',
                      ),
                      value: archived,
                      onChanged: currentScope
                          ? null
                          : (value) => update(() => archived = value),
                    ),
                    if (entity == null)
                      const VentioText(
                        'native.wave2.creating_a_scope_does_not_create_users_permissio_f3b1c038',
                      ),
                    if (validation != null) Text(validation!),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const VentioText('native.wave2.cancel_19766ed6'),
              ),
              FilledButton(
                onPressed: () {
                  final value = <String, dynamic>{
                    'kind': kind,
                    'id': id.text,
                    'parentId': parent,
                    'displayName': title.text,
                    'archived': archived,
                    'expectedRevision': entity?['revision'] ?? 0,
                    'requestId': createCommandId(),
                  };
                  try {
                    validateOrganizationChange(value);
                    Navigator.pop(dialogContext, value);
                  } on ContractError catch (error) {
                    update(() => validation = error.details);
                  }
                },
                child: const VentioText('native.wave2.save_with_host_fbe98751'),
              ),
            ],
          ),
        ),
      );
      if (change == null) return;
      setState(() => _busy = true);
      await widget.request('organization/change', {'change': change});
      await _load();
    } catch (error) {
      _failed(error);
    } finally {
      id.dispose();
      title.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const VentioText(
        'native.wave2.organization_administration_02c74fa5',
      ),
      actions: [
        IconButton(
          onPressed: _busy ? null : _load,
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
            padding: const EdgeInsets.all(20),
            child: VentioText(
              'native.wave2.administration_unavailable_or_denied_98d6b952',
              params: {'v0': (_error)},
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              if (_canCreateCompany)
                FilledButton.icon(
                  onPressed: _busy ? null : () => _edit('company'),
                  icon: const Icon(Icons.add_business),
                  label: const VentioText('native.wave2.new_company_8bc7f6e6'),
                ),
              FilledButton.icon(
                onPressed:
                    _busy ||
                        _entities.every((item) => item['kind'] != 'company')
                    ? null
                    : () => _edit('branch'),
                icon: const Icon(Icons.add_location_alt_outlined),
                label: const VentioText('native.wave2.new_branch_7f445154'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final entity in _entities)
                ListTile(
                  leading: Icon(switch (entity['kind']) {
                    'organization' => Icons.account_tree,
                    'company' => Icons.business,
                    _ => Icons.location_on_outlined,
                  }),
                  title: Text(entity['displayName'] as String),
                  subtitle: VentioText(
                    'native.wave2.revision_8f4ec9c5',
                    params: {
                      'v0': (entity['kind']),
                      'v1': (entity['parentId'] ?? widget.profile.tenantId),
                      'v2': (entity['id']),
                      'v3': (entity['revision']),
                      'v4': (entity['archived'] == true ? ' - archived' : ''),
                    },
                  ),
                  onTap: _busy
                      ? null
                      : () => _edit(entity['kind'] as String, entity),
                ),
              if (!_busy && _error == null && _entities.isEmpty)
                const ListTile(
                  title: VentioText(
                    'native.wave2.no_manageable_organization_entities_1f26b28a',
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
