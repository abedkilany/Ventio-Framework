import 'package:flutter/material.dart';
import 'host_extension_packages.dart';

class RoleAdministrationPage extends StatefulWidget {
  const RoleAdministrationPage({
    required this.client,
    required this.tenantId,
    required this.companyId,
    required this.branchId,
    super.key,
  });

  final HostExtensionPackageClient client;
  final String tenantId;
  final String companyId;
  final String branchId;

  @override
  State<RoleAdministrationPage> createState() => _RoleAdministrationPageState();
}

class _RoleAdministrationPageState extends State<RoleAdministrationPage> {
  List<HostIdentityRole> _roles = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await widget.client.listRoles(
        companyId: widget.companyId,
        branchId: widget.branchId,
      );
      if (snapshot.tenantId != widget.tenantId ||
          snapshot.companyId != widget.companyId ||
          snapshot.branchId != widget.branchId) {
        throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
      }
      if (!mounted) return;
      setState(() {
        _roles = snapshot.roles;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(error);
        _loading = false;
      });
    }
  }

  Future<void> _change(Future<void> Function() action) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await action();
      await _load();
      if (mounted) _message('Role changes were accepted by Host.');
    } catch (error) {
      if (mounted) _message(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _createRole() async {
    final values = await _roleDialog(context, title: 'Create role');
    if (values == null || !mounted) return;
    await _change(
      () => widget.client.createRole(
        companyId: widget.companyId,
        branchId: widget.branchId,
        roleId: values.$1,
        displayName: values.$2,
      ),
    );
  }

  Future<void> _renameRole(HostIdentityRole role) async {
    final values = await _roleDialog(
      context,
      title: 'Rename ${role.roleId}',
      roleId: role.roleId,
      displayName: role.displayName,
      allowIdEdit: false,
    );
    if (values == null || !mounted) return;
    await _change(
      () => widget.client.renameRole(
        companyId: widget.companyId,
        branchId: widget.branchId,
        roleId: role.roleId,
        displayName: values.$2,
      ),
    );
  }

  Future<void> _deleteRole(HostIdentityRole role) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete role?'),
        content: Text(
          'Delete ${role.displayName}? Host only allows deletion after all branch assignments have been removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete role'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _change(
      () => widget.client.deleteRole(
        companyId: widget.companyId,
        branchId: widget.branchId,
        roleId: role.roleId,
      ),
    );
  }

  Future<void> _addPermission(HostIdentityRole role) async {
    final permission = await _textDialog(
      context,
      title: 'Add permission',
      label: 'Permission key',
      hint: 'extension.example.item.read',
      validator: (value) {
        if (!RegExp(r'^[a-z][a-z0-9_.]+$').hasMatch(value.trim())) {
          return 'Use a lower-case namespaced permission key.';
        }
        if (value.trim() == 'identity.roles.manage') {
          return 'Role management must be granted directly by a trusted operator.';
        }
        return null;
      },
    );
    if (permission == null || !mounted) return;
    await _change(
      () => widget.client.grantRolePermission(
        companyId: widget.companyId,
        branchId: widget.branchId,
        roleId: role.roleId,
        permission: permission,
      ),
    );
  }

  Future<void> _assignActor(HostIdentityRole role) async {
    final actorId = await _textDialog(
      context,
      title: 'Assign role',
      label: 'Existing user ID',
      hint: 'user-123',
      validator: (value) => value.trim().isEmpty || value.length > 256
          ? 'Enter an existing user ID.'
          : null,
    );
    if (actorId == null || !mounted) return;
    await _change(
      () => widget.client.assignRole(
        companyId: widget.companyId,
        branchId: widget.branchId,
        roleId: role.roleId,
        actorId: actorId,
      ),
    );
  }

  Future<void> _unassignActor(HostIdentityRole role, String actorId) async {
    await _change(
      () => widget.client.unassignRole(
        companyId: widget.companyId,
        branchId: widget.branchId,
        roleId: role.roleId,
        actorId: actorId,
      ),
    );
  }

  void _message(String value) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Roles & access'),
      actions: [
        IconButton(
          tooltip: 'Refresh roles',
          onPressed: _loading || _saving ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: Text('Host · ${widget.tenantId}'),
                subtitle: Text('${widget.companyId} / ${widget.branchId}'),
                trailing: const Tooltip(
                  message:
                      'Host validates this exact branch scope on every change',
                  child: Icon(Icons.verified_user_outlined),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Branch roles',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                FilledButton.icon(
                  onPressed: _loading || _saving ? null : _createRole,
                  icon: const Icon(Icons.add),
                  label: const Text('Create role'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Roles group permissions for this tenant. Host checks every affected branch before changing a shared role. The role management permission itself can only be granted directly by a trusted Host operator.',
            ),
            if (_saving) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.cloud_off_outlined),
                  title: const Text('Could not load Host roles'),
                  subtitle: Text(_error!),
                  trailing: IconButton(
                    tooltip: 'Retry',
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                  ),
                ),
              )
            else if (_roles.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No roles are defined yet. Create a role, add namespaced permissions, then assign it to an existing user in this branch.',
                  ),
                ),
              )
            else
              for (final role in _roles) _roleCard(role),
          ],
        ),
      ),
    ),
  );

  Widget _roleCard(HostIdentityRole role) => Card(
    margin: const EdgeInsets.only(top: 8),
    child: ExpansionTile(
      key: ValueKey('role-${role.roleId}'),
      leading: const Icon(Icons.badge_outlined),
      title: Text(role.displayName),
      subtitle: Text(
        '${role.roleId} · ${role.permissions.length} permissions · ${role.assignedActorIds.length} users in this branch',
      ),
      trailing: PopupMenuButton<String>(
        tooltip: 'Role actions',
        enabled: !_saving,
        onSelected: (action) {
          switch (action) {
            case 'rename':
              _renameRole(role);
            case 'delete':
              _deleteRole(role);
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Permissions',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              for (final permission in role.permissions)
                InputChip(
                  label: Text(permission),
                  onDeleted: _saving
                      ? null
                      : () => _change(
                          () => widget.client.revokeRolePermission(
                            companyId: widget.companyId,
                            branchId: widget.branchId,
                            roleId: role.roleId,
                            permission: permission,
                          ),
                        ),
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('Add permission'),
                onPressed: _saving ? null : () => _addPermission(role),
              ),
            ],
          ),
        ),
        const Divider(height: 28),
        Row(
          children: [
            Expanded(
              child: Text(
                'Users in this branch',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            OutlinedButton.icon(
              onPressed: _saving ? null : () => _assignActor(role),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Assign user'),
            ),
          ],
        ),
        if (role.assignedActorIds.isEmpty)
          const Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('No users are assigned in this branch.'),
            ),
          )
        else
          for (final actorId in role.assignedActorIds)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_outline),
              title: SelectableText(actorId),
              trailing: IconButton(
                tooltip: 'Remove role from $actorId',
                onPressed: _saving ? null : () => _unassignActor(role, actorId),
                icon: const Icon(Icons.person_remove_outlined),
              ),
            ),
      ],
    ),
  );
}

Future<(String, String)?> _roleDialog(
  BuildContext context, {
  required String title,
  String roleId = '',
  String displayName = '',
  bool allowIdEdit = true,
}) => showDialog<(String, String)>(
  context: context,
  builder: (_) => _RoleDialog(
    title: title,
    roleId: roleId,
    displayName: displayName,
    allowIdEdit: allowIdEdit,
  ),
);

class _RoleDialog extends StatefulWidget {
  const _RoleDialog({
    required this.title,
    required this.roleId,
    required this.displayName,
    required this.allowIdEdit,
  });

  final String title;
  final String roleId;
  final String displayName;
  final bool allowIdEdit;

  @override
  State<_RoleDialog> createState() => _RoleDialogState();
}

class _RoleDialogState extends State<_RoleDialog> {
  late final TextEditingController _idController;
  late final TextEditingController _nameController;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _idController = TextEditingController(text: widget.roleId);
    _nameController = TextEditingController(text: widget.displayName);
  }

  @override
  void dispose() {
    _idController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 420,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _idController,
              enabled: widget.allowIdEdit,
              decoration: const InputDecoration(
                labelText: 'Role ID',
                hintText: 'inventory-editor',
              ),
              validator: (value) =>
                  RegExp(
                    r'^[a-z][a-z0-9_.-]{0,127}$',
                  ).hasMatch(value?.trim() ?? '')
                  ? null
                  : 'Use a lowercase ID with letters, numbers, dots, dashes or underscores.',
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameController,
              autofocus: !widget.allowIdEdit,
              decoration: const InputDecoration(labelText: 'Display name'),
              validator: (value) {
                final name = value?.trim() ?? '';
                return name.isEmpty || name.length > 120
                    ? 'Enter a name up to 120 characters.'
                    : null;
              },
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_formKey.currentState!.validate()) {
            Navigator.pop(context, (
              _idController.text.trim(),
              _nameController.text.trim(),
            ));
          }
        },
        child: const Text('Save'),
      ),
    ],
  );
}

Future<String?> _textDialog(
  BuildContext context, {
  required String title,
  required String label,
  required String hint,
  required String? Function(String value) validator,
}) => showDialog<String>(
  context: context,
  builder: (_) =>
      _TextDialog(title: title, label: label, hint: hint, validator: validator),
);

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.label,
    required this.hint,
    required this.validator,
  });

  final String title;
  final String label;
  final String hint;
  final String? Function(String value) validator;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 420,
      child: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
          ),
          validator: (value) => widget.validator(value ?? ''),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_formKey.currentState!.validate()) {
            Navigator.pop(context, _controller.text.trim());
          }
        },
        child: const Text('Save'),
      ),
    ],
  );
}

String _friendlyError(Object error) {
  if (error is! HostPackageTransportException) return 'Host request failed.';
  return switch (error.code) {
    'PERMISSION_DENIED' =>
      'This credential needs a direct identity.roles.manage grant for this branch.',
    'PERSISTENT_IDENTITY_REQUIRED' => 'Connect a persistent Host identity.',
    'ROLE_ALREADY_EXISTS' => 'A role with that ID already exists.',
    'ROLE_NOT_FOUND' => 'The role no longer exists on Host.',
    'ROLE_CHANGE_CONFLICT' =>
      'Remove all branch assignments before deleting this role.',
    'ROLE_HAS_ASSIGNMENTS' =>
      'Remove all branch assignments before deleting this role.',
    'ROLE_CHANGE_REJECTED' =>
      'Host rejected the change. Check the role and user IDs, then try again.',
    'INVALID_ROLE_CHANGE' => 'Host rejected the role details.',
    'HOST_UNREACHABLE' => 'Host is unreachable. Try again when connected.',
    'HOST_REQUEST_TIMEOUT' => 'Host did not respond in time. Try again.',
    _ => 'Host request failed (${error.code}).',
  };
}
