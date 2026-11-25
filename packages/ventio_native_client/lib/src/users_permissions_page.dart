import 'package:flutter/material.dart';

import 'app_localization.dart';
import 'host_user_management.dart';
import 'host_extension_packages.dart';
import 'account_sign_in.dart';

/// Host-authoritative user administration for one verified exact branch scope.
class UsersPermissionsPage extends StatefulWidget {
  const UsersPermissionsPage({required this.client, super.key});

  final HostUserManagementClient client;

  @override
  State<UsersPermissionsPage> createState() => _UsersPermissionsPageState();
}

class _UsersPermissionsPageState extends State<UsersPermissionsPage> {
  bool get _owner => widget.client.verifiedIdentity.scopes.any(
    (s) => s.permissions.contains('*'),
  );
  HostExtensionPackageClient get _accountClient => HostExtensionPackageClient(
    endpoint: widget.client.endpoint,
    credentials: widget.client.credentials,
  );

  Future<void> _accountAction(HostManagedUser user, String action) async {
    try {
      if (action == 'login') {
        final values = await showDialog<Map<String, String>>(
          context: context,
          builder: (context) => _AccountLoginDialog(
            username: user.username ?? '',
            self: user.actorId == widget.client.verifiedIdentity.actorId,
          ),
        );
        if (values == null) return;
        await _accountClient.account('manage', {
          'action': 'SET_LOGIN',
          'actorId': user.actorId,
          'companyId': widget.client.companyId,
          'branchId': widget.client.branchId,
          ...values,
        });
      } else {
        await _accountClient.account('manage', {
          'action': action == 'organization'
              ? 'SET_ORGANIZATION_ACCESS'
              : 'REVOKE_SESSIONS',
          'actorId': user.actorId,
          if (action == 'organization') 'enabled': !user.organizationWide,
        });
      }
      if (user.actorId == widget.client.verifiedIdentity.actorId) {
        await invalidateLocalAccountSession(
          widget.client.credentials,
          widget.client.endpoint,
        );
        return;
      }
      if (mounted) {
        await _load();
        _message(
          'Account updated. Password changes invalidate existing sign-in sessions.',
        );
      }
    } on HostPackageTransportException catch (e) {
      if (mounted) _message(e.code);
    } catch (_) {
      if (mounted) _message('Account update unavailable.');
    }
  }

  Future<void> _selectBranch() async {
    final scopes = widget.client.verifiedIdentity.scopes;
    final selected = await showDialog<HostScopeGrant>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const VentioText('native.ui.account_manage_users_in_branch'),
        children: [
          for (final scope in scopes)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, scope),
              child: Text('${scope.companyId} / ${scope.branchId}'),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => UsersPermissionsPage(
          client: HostUserManagementClient(
            endpoint: widget.client.endpoint,
            credentials: widget.client.credentials,
            verifiedIdentity: widget.client.verifiedIdentity,
            companyId: selected.companyId,
            branchId: selected.branchId,
          ),
        ),
      ),
    );
    if (mounted) await _load();
  }

  HostManagedUserSnapshot? _snapshot;
  HostUserAuditSnapshot? _auditSnapshot;
  String? _createdActorId;
  bool _loading = true;
  bool _auditLoading = true;
  bool _saving = false;
  bool _changeConfirmed = false;
  HostUserManagementException? _error;
  HostUserManagementException? _changeError;
  HostUserManagementException? _auditError;
  final Map<String, int> _legacyIdentityNumbers = {};
  int _nextLegacyIdentityNumber = 1;

  String _displayIdentity(String actorId) {
    if (RegExp(r'^usr_[0-9a-f]{32}$').hasMatch(actorId)) return actorId;
    final number = _legacyIdentityNumbers.putIfAbsent(
      actorId,
      () => _nextLegacyIdentityNumber++,
    );
    return context.ventioText(
      'native.ui.legacy_identity_reference',
      params: {'number': number},
    );
  }

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
      _auditLoading = true;
      _auditError = null;
    });
    if (!widget.client.canManageUsers) {
      setState(() {
        _loading = false;
        _auditLoading = false;
      });
      return;
    }
    try {
      final snapshot = await widget.client.listUsers();
      if (snapshot.tenantId != widget.client.verifiedIdentity.tenantId ||
          snapshot.companyId != widget.client.companyId ||
          snapshot.branchId != widget.client.branchId) {
        throw const HostUserManagementException('HOST_INVALID_RESPONSE');
      }
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
    } on HostUserManagementException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = const HostUserManagementException('HOST_UNAVAILABLE');
        _loading = false;
      });
    }
    await _loadAudit();
  }

  Future<void> _loadAudit() async {
    if (!mounted || !widget.client.canManageUsers) return;
    setState(() {
      _auditLoading = true;
      _auditError = null;
    });
    try {
      final snapshot = await widget.client.listAudit();
      if (snapshot.tenantId != widget.client.verifiedIdentity.tenantId ||
          snapshot.companyId != widget.client.companyId ||
          snapshot.branchId != widget.client.branchId) {
        throw const HostUserManagementException('HOST_INVALID_RESPONSE');
      }
      if (!mounted) return;
      setState(() {
        _auditSnapshot = snapshot;
        _auditLoading = false;
      });
    } on HostUserManagementException catch (error) {
      if (!mounted) return;
      setState(() {
        _auditError = error;
        _auditLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _auditError = const HostUserManagementException('HOST_UNAVAILABLE');
        _auditLoading = false;
      });
    }
  }

  Future<void> _mutate(
    Future<void> Function() action, {
    required String successKey,
  }) async {
    if (_saving || !widget.client.canManageUsers) return;
    setState(() {
      _saving = true;
      _changeConfirmed = false;
      _changeError = null;
    });
    try {
      await action();
      if (!mounted) return;
      setState(() => _changeConfirmed = true);
      await _load();
      if (mounted) _message(context.ventioText(successKey));
    } on HostUserManagementException catch (error) {
      if (mounted) setState(() => _changeError = error);
    } catch (_) {
      if (mounted) {
        setState(
          () => _changeError = const HostUserManagementException(
            'HOST_UNAVAILABLE',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _createUser() async {
    if (_saving || !widget.client.canManageUsers) return;
    setState(() {
      _saving = true;
      _changeConfirmed = false;
      _changeError = null;
    });
    try {
      final actorId = await widget.client.createUser();
      if (!mounted) return;
      setState(() {
        _createdActorId = actorId;
        _changeConfirmed = true;
      });
      await _load();
      if (mounted) {
        _message(
          context.ventioText(
            'native.ui.user_created_with_id',
            params: {'actorId': actorId},
          ),
        );
      }
    } on HostUserManagementException catch (error) {
      if (mounted) setState(() => _changeError = error);
    } catch (_) {
      if (mounted) {
        setState(
          () => _changeError = const HostUserManagementException(
            'HOST_UNAVAILABLE',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _grantPermission(HostManagedUser user) async {
    final permission = await showDialog<String>(
      context: context,
      builder: (context) => const _PermissionDialog(),
    );
    if (permission == null || !mounted) return;
    await _mutate(
      () => widget.client.grantPermission(
        actorId: user.actorId,
        permission: permission,
      ),
      successKey: 'native.ui.user_permission_granted',
    );
  }

  Future<void> _revokePermission(
    HostManagedUser user,
    String permission,
  ) async {
    await _mutate(
      () => widget.client.revokePermission(
        actorId: user.actorId,
        permission: permission,
      ),
      successKey: 'native.ui.user_permission_revoked',
    );
  }

  Future<void> _disableUser(HostManagedUser user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.ventioText('native.ui.disable_user')),
        content: Text(
          context.ventioText(
            'native.ui.disable_user_confirmation',
            params: {'displayName': _displayIdentity(user.actorId)},
          ),
        ),
        actions: [
          if (_owner)
            IconButton(
              onPressed: _selectBranch,
              icon: const Icon(Icons.account_tree_outlined),
              tooltip: context.ventioText(
                'native.ui.account_choose_branch_for_user_permissions',
              ),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.ventioText('native.ui.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.ventioText('native.ui.disable_user')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _mutate(
      () => widget.client.disableUser(actorId: user.actorId),
      successKey: 'native.ui.user_disabled',
    );
  }

  Future<void> _enableUser(HostManagedUser user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.ventioText('native.ui.enable_user')),
        content: Text(
          context.ventioText(
            'native.ui.enable_user_confirmation',
            params: {'displayName': _displayIdentity(user.actorId)},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.ventioText('native.ui.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.ventioText('native.ui.enable_user')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _mutate(
      () => widget.client.enableUser(actorId: user.actorId),
      successKey: 'native.ui.user_enabled',
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
      title: const VentioText('native.ui.users_permissions'),
      actions: [
        if (_owner)
          IconButton(
            onPressed: _selectBranch,
            icon: const Icon(Icons.account_tree_outlined),
            tooltip: context.ventioText(
              'native.ui.account_choose_branch_for_user_permissions',
            ),
          ),
        IconButton(
          tooltip: context.ventioText('native.ui.refresh_users'),
          onPressed: _loading || _saving || !widget.client.canManageUsers
              ? null
              : _load,
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
                title: Text(
                  context.ventioText(
                    'native.ui.users_scope_summary',
                    params: {
                      'tenantId': widget.client.verifiedIdentity.tenantId,
                    },
                  ),
                ),
                subtitle: Text(
                  context.ventioText(
                    'native.ui.scope_identifiers',
                    params: {
                      'companyId': widget.client.companyId,
                      'branchId': widget.client.branchId,
                    },
                  ),
                ),
                trailing: Tooltip(
                  message: context.ventioText(
                    'native.ui.host_checks_user_management_permission',
                  ),
                  child: const Icon(Icons.verified_user_outlined),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: VentioText(
                    'native.ui.host_users',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                FilledButton.icon(
                  onPressed:
                      _loading ||
                          _saving ||
                          _error != null ||
                          !widget.client.canManageUsers
                      ? null
                      : _createUser,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const VentioText('native.ui.create_user'),
                ),
              ],
            ),
            if (_saving) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (_changeError != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: const VentioText(
                    'native.ui.user_change_not_confirmed',
                  ),
                  subtitle: Text(
                    _friendlyError(context, _changeError!, duringChange: true),
                  ),
                ),
              ),
            if (_createdActorId != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.person_add_alt_1),
                  title: const VentioText(
                    'native.ui.user_created_without_permissions',
                  ),
                  subtitle: SelectableText(
                    context.ventioText(
                      'native.ui.generated_user_id',
                      params: {'actorId': _createdActorId},
                    ),
                  ),
                ),
              ),
            if (!widget.client.canManageUsers)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const VentioText('native.ui.user_access_required'),
                  subtitle: const VentioText(
                    'native.ui.user_access_required_details',
                  ),
                ),
              )
            else if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              _errorCard(_error!)
            else if (_snapshot?.users.isEmpty ?? true)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: VentioText('native.ui.no_host_users'),
                ),
              )
            else
              for (final user in _snapshot!.users) _userCard(user),
            if (widget.client.canManageUsers) ...[
              const SizedBox(height: 28),
              VentioText(
                'native.ui.recent_user_activity',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              _auditSection(),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _errorCard(HostUserManagementException error) => Card(
    child: ListTile(
      leading: const Icon(Icons.cloud_off_outlined),
      title: const VentioText('native.ui.could_not_load_host_users'),
      subtitle: Text(
        _changeConfirmed
            ? '${context.ventioText('native.ui.user_change_confirmed_refresh_failed')}\n${_friendlyError(context, error)}'
            : _friendlyError(context, error),
      ),
      trailing: IconButton(
        tooltip: context.ventioText('native.ui.retry'),
        onPressed: _loading || _saving ? null : _load,
        icon: const Icon(Icons.refresh),
      ),
    ),
  );

  Widget _auditSection() {
    if (_auditLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_auditError != null) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.history_toggle_off_outlined),
          title: const VentioText('native.ui.audit_activity_load_failed'),
          subtitle: Text(_friendlyError(context, _auditError!)),
          trailing: IconButton(
            tooltip: context.ventioText('native.ui.retry'),
            onPressed: _saving ? null : _loadAudit,
            icon: const Icon(Icons.refresh),
          ),
        ),
      );
    }
    final events = _auditSnapshot?.events ?? const <HostUserAuditEvent>[];
    if (events.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: VentioText('native.ui.no_recent_user_activity'),
        ),
      );
    }
    return Card(
      child: Column(
        children: [
          for (final event in events)
            ListTile(
              key: ValueKey('user-audit-${event.eventId}'),
              leading: const Icon(Icons.history_outlined),
              title: Text(_auditActionTitle(context, event.action)),
              subtitle: Text(
                context.ventioText(
                  'native.ui.audit_event_summary',
                  params: {
                    'subjectId': _displayIdentity(event.subjectId),
                    'operator': _displayIdentity(event.operatorId),
                    'timestamp': _formatAuditTimestamp(event.occurredAtUtc),
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _userCard(HostManagedUser user) => Card(
    margin: const EdgeInsets.only(top: 8),
    child: ExpansionTile(
      key: ValueKey('managed-user-${user.actorId}'),
      leading: Icon(
        user.state == HostManagedUserState.active
            ? Icons.person_outline
            : Icons.person_off_outlined,
      ),
      title: Text(
        '${user.username ?? _displayIdentity(user.actorId)}${user.isOwner ? ' · Organization Owner' : ''}',
      ),
      subtitle: SelectableText(
        '${_displayIdentity(user.actorId)} · ${context.ventioText(user.state == HostManagedUserState.active ? 'native.ui.user_active' : 'native.ui.user_disabled_state')}',
      ),
      trailing: PopupMenuButton<String>(
        tooltip: context.ventioText('native.ui.user_actions'),
        enabled: !_saving && widget.client.canManageUsers,
        onSelected: (action) {
          if (action == 'disable') _disableUser(user);
          if (action == 'enable') _enableUser(user);
          if (['login', 'organization', 'revokeSessions'].contains(action)) {
            _accountAction(user, action);
          }
        },
        itemBuilder: (context) => [
          if (!user.isOwner ||
              user.actorId == widget.client.verifiedIdentity.actorId)
            const PopupMenuItem(
              value: 'login',
              child: VentioText('native.ui.account_set_username_and_password'),
            ),
          if (_owner && !user.isOwner)
            PopupMenuItem(
              value: 'organization',
              child: Text(
                user.organizationWide
                    ? 'Limit access to assigned branches'
                    : 'Grant organization-wide branch access',
              ),
            ),
          if (_owner && !user.isOwner)
            const PopupMenuItem(
              value: 'revokeSessions',
              child: VentioText(
                'native.ui.account_revoke_active_sign_in_sessions',
              ),
            ),
          if (!user.isOwner && user.state == HostManagedUserState.active)
            PopupMenuItem(
              value: 'disable',
              child: Text(context.ventioText('native.ui.disable_user')),
            )
          else if (!user.isOwner)
            PopupMenuItem(
              value: 'enable',
              child: Text(context.ventioText('native.ui.enable_user')),
            ),
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
              VentioText(
                'native.ui.direct_permissions',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (user.directPermissions.isEmpty)
                const VentioText('native.ui.no_direct_permissions'),
              for (final permission in user.directPermissions)
                InputChip(
                  label: Text(permission),
                  deleteButtonTooltipMessage: context.ventioText(
                    'native.ui.revoke_permission',
                  ),
                  onDeleted:
                      !user.isOwner &&
                          !_saving &&
                          widget.client.canManageUsers &&
                          (_owner ||
                              HostUserManagementClient.isGrantableNonManagementPermission(
                                permission,
                              ))
                      ? () => _revokePermission(user, permission)
                      : null,
                ),
              if (!user.isOwner && user.state == HostManagedUserState.active)
                ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: const VentioText('native.ui.grant_permission'),
                  onPressed: _saving || !widget.client.canManageUsers
                      ? null
                      : () => _grantPermission(user),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              VentioText(
                'native.ui.role_assignments',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (user.roles.isEmpty)
                const VentioText('native.ui.no_role_assignments'),
              for (final role in user.roles) Chip(label: Text(role)),
            ],
          ),
        ),
      ],
    ),
  );
}

class _AccountLoginDialog extends StatefulWidget {
  const _AccountLoginDialog({required this.username, required this.self});
  final String username;
  final bool self;
  @override
  State<_AccountLoginDialog> createState() => _AccountLoginDialogState();
}

class _AccountLoginDialogState extends State<_AccountLoginDialog> {
  late final username = TextEditingController(text: widget.username);
  final password = TextEditingController(),
      confirm = TextEditingController(),
      current = TextEditingController();
  String? error;
  @override
  void dispose() {
    username.dispose();
    password.dispose();
    confirm.dispose();
    current.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const VentioText('native.ui.account_organization_account_login'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const VentioText(
            'native.ui.account_use_at_least_15_characters_password_changes_revoke_online_sessions_offline_clients_may_ret',
          ),
          TextField(
            controller: username,
            decoration: InputDecoration(
              labelText: context.ventioText('native.ui.account_username'),
            ),
          ),
          if (widget.self)
            TextField(
              controller: current,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: context.ventioText(
                  'native.ui.account_current_password_if_already_configured',
                ),
              ),
            ),
          TextField(
            controller: password,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: context.ventioText('native.ui.account_new_password'),
            ),
          ),
          TextField(
            controller: confirm,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: context.ventioText(
                'native.ui.account_confirm_password',
              ),
            ),
          ),
          if (error != null) Text(error!),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const VentioText('native.ui.account_cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (password.text != confirm.text ||
              password.text.runes.length < 15 ||
              !RegExp(
                r'^[A-Za-z0-9][A-Za-z0-9_.@-]{2,63}$',
              ).hasMatch(username.text.trim())) {
            setState(
              () => error = 'Check username, password length and confirmation.',
            );
            return;
          }
          Navigator.pop(context, {
            'username': username.text.trim(),
            'password': password.text,
            if (widget.self) 'currentPassword': current.text,
          });
        },
        child: const VentioText('native.ui.account_save_login'),
      ),
    ],
  );
}

class _PermissionDialog extends StatefulWidget {
  const _PermissionDialog();

  @override
  State<_PermissionDialog> createState() => _PermissionDialogState();
}

class _PermissionDialogState extends State<_PermissionDialog> {
  final _formKey = GlobalKey<FormState>();
  final _permission = TextEditingController();

  @override
  void dispose() {
    _permission.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.ventioText('native.ui.grant_permission')),
    content: Form(
      key: _formKey,
      child: TextFormField(
        controller: _permission,
        maxLength: 256,
        decoration: InputDecoration(
          labelText: context.ventioText('native.ui.permission_key'),
          hintText: 'maintenance.create',
        ),
        validator: (value) {
          final permission = value?.trim() ?? '';
          if (!RegExp(r'^[a-z][a-z0-9_.]+$').hasMatch(permission) ||
              permission.length > 256) {
            return context.ventioText(
              'native.ui.permission_not_grantable_to_users',
            );
          }
          return null;
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.ventioText('native.ui.cancel')),
      ),
      FilledButton(
        onPressed: () {
          if (!_formKey.currentState!.validate()) return;
          Navigator.pop(context, _permission.text.trim());
        },
        child: Text(context.ventioText('native.ui.save')),
      ),
    ],
  );
}

String _friendlyError(
  BuildContext context,
  HostUserManagementException error, {
  bool duringChange = false,
}) {
  final key = switch (error.code) {
    'HOST_PERMISSION_DENIED' ||
    'PERMISSION_DENIED' ||
    'SCOPE_DENIED' => 'native.ui.user_management_denied_by_host',
    'HOST_CREDENTIAL_MISSING' ||
    'INVALID_CREDENTIAL' => 'native.ui.host_credential_unavailable',
    'HOST_UNREACHABLE' || 'HOST_REQUEST_TIMEOUT' || 'HOST_UNAVAILABLE' =>
      duringChange
          ? 'native.ui.host_not_reachable'
          : 'native.ui.host_user_read_unreachable',
    'HOST_TLS_VALIDATION_FAILED' => 'native.ui.host_tls_validation_failed',
    'HOST_API_VERSION_MISMATCH' => 'native.ui.host_api_version_not_supported',
    _ => 'native.ui.host_user_operation_failed',
  };
  final message = context.ventioText(key);
  final correlationId = error.correlationId;
  return correlationId == null
      ? message
      : '$message\n${context.ventioText('native.ui.correlation_reference', params: {'correlationId': correlationId})}';
}

String _auditActionTitle(BuildContext context, String action) =>
    context.ventioText(switch (action) {
      'USER_CREATED' => 'native.ui.audit_user_created',
      'USER_DISABLED' => 'native.ui.audit_user_disabled',
      'USER_ENABLED' => 'native.ui.audit_user_enabled',
      'PERMISSION_GRANTED' => 'native.ui.audit_permission_granted',
      'PERMISSION_REVOKED' => 'native.ui.audit_permission_revoked',
      'ROLE_CREATED' => 'native.ui.audit_role_created',
      'ROLE_RENAMED' => 'native.ui.audit_role_renamed',
      'ROLE_DELETED' => 'native.ui.audit_role_deleted',
      'ROLE_PERMISSION_GRANTED' => 'native.ui.audit_role_permission_granted',
      'ROLE_PERMISSION_REVOKED' => 'native.ui.audit_role_permission_revoked',
      'ROLE_ASSIGNED' => 'native.ui.audit_role_assigned',
      'ROLE_UNASSIGNED' => 'native.ui.audit_role_unassigned',
      _ => 'native.ui.audit_other_administration',
    });

String _formatAuditTimestamp(DateTime timestampUtc) {
  final utc = timestampUtc.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} UTC';
}
