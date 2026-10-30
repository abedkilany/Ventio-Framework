import 'package:flutter/material.dart';

import 'app_localization.dart';
import 'host_device_management.dart';
import 'host_user_management.dart';

class DeviceManagementPage extends StatefulWidget {
  const DeviceManagementPage({
    required this.client,
    this.userDirectory,
    super.key,
  });

  final HostDeviceManagementClient client;
  final HostUserManagementClient? userDirectory;

  @override
  State<DeviceManagementPage> createState() => _DeviceManagementPageState();
}

class _DeviceManagementPageState extends State<DeviceManagementPage> {
  final _actorId = TextEditingController();
  HostDeviceSnapshot? _snapshot;
  List<HostManagedUser> _users = const [];
  String? _selectedUserId;
  HostPairingCredential? _pairing;
  HostRotatedDeviceCredential? _rotatedCredential;
  HostDeviceManagementException? _error;
  bool _loading = false;
  bool _loadingUsers = false;
  bool _userDirectoryFailed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.client.canManageDevices) _load();
    if (widget.userDirectory?.canManageUsers ?? false) _loadUsers();
  }

  Future<void> _loadUsers() async {
    final directory = widget.userDirectory;
    if (directory == null || !directory.canManageUsers || _loadingUsers) return;
    setState(() {
      _loadingUsers = true;
      _userDirectoryFailed = false;
    });
    try {
      final snapshot = await directory.listUsers();
      final active = snapshot.users
          .where((user) => user.state == HostManagedUserState.active)
          .toList(growable: false);
      if (mounted) {
        setState(() {
          _users = active;
          if (!_users.any((user) => user.actorId == _selectedUserId)) {
            _selectedUserId = _users.isEmpty ? null : _users.first.actorId;
          }
        });
      }
    } on HostUserManagementException catch (error) {
      if (mounted) {
        setState(() {
          _userDirectoryFailed = true;
          _error = HostDeviceManagementException(
            error.code,
            statusCode: error.statusCode,
            correlationId: error.correlationId,
            retryable: error.retryable,
          );
        });
      }
    } finally {
      if (mounted) setState(() => _loadingUsers = false);
    }
  }

  @override
  void dispose() {
    _actorId.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!widget.client.canManageDevices || _loading || _busy) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await widget.client.listDevices();
      if (mounted) setState(() => _snapshot = snapshot);
    } on HostDeviceManagementException catch (error) {
      if (mounted) setState(() => _error = error);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = const HostDeviceManagementException(
            'HOST_INVALID_RESPONSE',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createPairing() async {
    final actorId = widget.userDirectory?.canManageUsers == true
        ? (_selectedUserId ?? '')
        : _actorId.text.trim();
    if (_busy || !widget.client.canCreatePairings) return;
    setState(() {
      _busy = true;
      _error = null;
      _pairing = null;
    });
    try {
      final pairing = await widget.client.createPairing(actorId);
      if (!mounted) return;
      setState(() => _pairing = pairing);
    } on HostDeviceManagementException catch (error) {
      if (mounted) setState(() => _error = error);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = const HostDeviceManagementException(
            'HOST_INVALID_RESPONSE',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(HostManagedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.ventioText('native.ui.revoke_device_title')),
        content: Text(
          context.ventioText(
            'native.ui.revoke_device_confirmation',
            params: {'deviceId': device.deviceId},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.ventioText('native.ui.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.ventioText('native.ui.revoke_device')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.client.revoke(device.deviceId);
      if (mounted) await _loadAfterMutation();
    } on HostDeviceManagementException catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rotateCredential(
    HostManagedDevice device,
    HostManagedCredential credential,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.ventioText('native.ui.rotate_credential_title')),
        content: Text(
          context.ventioText(
            'native.ui.rotate_credential_confirmation',
            params: {'deviceId': device.deviceId},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.ventioText('native.ui.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.ventioText('native.ui.rotate_credential')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _rotatedCredential = null;
    });
    try {
      final replacement = await widget.client.rotateCredential(
        deviceId: device.deviceId,
        credentialId: credential.credentialId,
      );
      if (!mounted) return;
      setState(() => _rotatedCredential = replacement);
      await _loadAfterMutation();
    } on HostDeviceManagementException catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadAfterMutation() async {
    final snapshot = await widget.client.listDevices();
    if (mounted) setState(() => _snapshot = snapshot);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(context.ventioText('native.ui.host_devices')),
      actions: [
        IconButton(
          tooltip: context.ventioText('native.ui.refresh_devices'),
          onPressed: _loading || _busy || !widget.client.canManageDevices
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
                leading: const Icon(Icons.devices_other_outlined),
                title: Text(
                  context.ventioText('native.ui.device_scope_summary'),
                ),
                subtitle: Text(
                  '${widget.client.companyId} · ${widget.client.branchId}',
                ),
                trailing: const Icon(Icons.verified_user_outlined),
              ),
            ),
            if (!widget.client.canManageDevices &&
                !widget.client.canCreatePairings)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: Text(
                    context.ventioText('native.ui.device_access_required'),
                  ),
                  subtitle: Text(
                    context.ventioText(
                      'native.ui.device_access_required_details',
                    ),
                  ),
                ),
              ),
            if (widget.client.canCreatePairings) ...[
              const SizedBox(height: 12),
              _pairingCard(context),
            ],
            if (_busy) const LinearProgressIndicator(),
            if (_error case final error?) _errorCard(context, error),
            if (_rotatedCredential case final credential?)
              _rotatedCredentialCard(context, credential),
            if (widget.client.canManageDevices) ...[
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.ventioText('native.ui.registered_devices'),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  if (_snapshot case final snapshot?)
                    Text('${snapshot.devices.length}'),
                ],
              ),
              if (_loading && _snapshot == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_snapshot == null && _error == null)
                Card(
                  child: ListTile(
                    title: Text(
                      context.ventioText('native.ui.no_device_inventory'),
                    ),
                    trailing: TextButton(
                      onPressed: _load,
                      child: Text(context.ventioText('native.ui.retry')),
                    ),
                  ),
                )
              else if (_snapshot?.devices.isEmpty ?? false)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      context.ventioText('native.ui.no_registered_devices'),
                    ),
                  ),
                )
              else
                for (final device in _snapshot!.devices)
                  _deviceCard(context, device),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _pairingCard(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.ventioText('native.ui.generate_pairing_code'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Text(
            context.ventioText(
              widget.userDirectory?.canManageUsers == true
                  ? 'native.ui.pairing_select_active_user'
                  : 'native.ui.pairing_target_help',
            ),
          ),
          const SizedBox(height: 12),
          if (widget.userDirectory?.canManageUsers == true) ...[
            if (_loadingUsers)
              const LinearProgressIndicator()
            else if (_userDirectoryFailed)
              ListTile(
                leading: const Icon(Icons.person_search_outlined),
                title: Text(
                  context.ventioText('native.ui.pairing_users_unavailable'),
                ),
                trailing: IconButton(
                  tooltip: context.ventioText('native.ui.retry'),
                  onPressed: _busy ? null : _loadUsers,
                  icon: const Icon(Icons.refresh),
                ),
              )
            else if (_users.isEmpty)
              Text(context.ventioText('native.ui.pairing_no_active_users'))
            else
              DropdownButtonFormField<String>(
                key: const ValueKey('pairing-target-user'),
                initialValue: _selectedUserId,
                decoration: InputDecoration(
                  labelText: context.ventioText(
                    'native.ui.pairing_target_user_id',
                  ),
                ),
                items: [
                  for (final entry in _users.indexed)
                    DropdownMenuItem(
                      value: entry.$2.actorId,
                      child: Text(_safeUserLabel(entry.$2, entry.$1)),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _selectedUserId = value),
              ),
          ] else
            TextField(
              key: const ValueKey('pairing-target-actor'),
              controller: _actorId,
              enabled: !_busy,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: context.ventioText(
                  'native.ui.pairing_target_user_id',
                ),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('generate-pairing-code'),
            onPressed:
                _busy ||
                    _loadingUsers ||
                    _userDirectoryFailed ||
                    (widget.userDirectory?.canManageUsers == true &&
                        _selectedUserId == null)
                ? null
                : _createPairing,
            icon: const Icon(Icons.phonelink_setup_outlined),
            label: Text(context.ventioText('native.ui.generate_pairing_code')),
          ),
          if (_pairing case final pairing?) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.ventioText('native.ui.pairing_code_once')),
                  const SizedBox(height: 8),
                  SelectableText(
                    pairing.code,
                    key: const ValueKey('generated-pairing-code'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.ventioText(
                      'native.ui.pairing_code_expires',
                      params: {'timestamp': _formatUtc(pairing.expiresAtUtc)},
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    context.ventioText(
                      'native.ui.correlation_reference',
                      params: {'correlationId': pairing.correlationId},
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => setState(() => _pairing = null),
                      child: Text(context.ventioText('native.ui.clear_code')),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _deviceCard(BuildContext context, HostManagedDevice device) {
    final isRegistered = device.state == HostManagedDeviceState.registered;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            ListTile(
              leading: Icon(
                device.role == 'HOST'
                    ? Icons.dns_outlined
                    : Icons.laptop_chromebook_outlined,
              ),
              title: Text(device.deviceId),
              subtitle: Text(
                context.ventioText(
                  'native.ui.device_role_and_state',
                  params: {
                    'role': device.role,
                    'state': context.ventioText(
                      isRegistered
                          ? 'native.ui.device_registered'
                          : 'native.ui.device_revoked',
                    ),
                  },
                ),
              ),
              trailing: isRegistered
                  ? IconButton(
                      tooltip: context.ventioText('native.ui.revoke_device'),
                      onPressed: _busy ? null : () => _revoke(device),
                      icon: const Icon(Icons.block_outlined),
                    )
                  : const Icon(Icons.block_outlined),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.ventioText(
                      'native.ui.device_registered_at',
                      params: {'timestamp': _formatUtc(device.registeredAtUtc)},
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    device.lastAuthenticatedAtUtc == null
                        ? context.ventioText(
                            'native.ui.device_activity_unavailable',
                          )
                        : context.ventioText(
                            'native.ui.device_last_authenticated',
                            params: {
                              'timestamp': _formatUtc(
                                device.lastAuthenticatedAtUtc!,
                              ),
                            },
                          ),
                  ),
                  const SizedBox(height: 8),
                  if (device.credentials.isEmpty)
                    Text(context.ventioText('native.ui.no_device_credentials'))
                  else
                    for (final credential in device.credentials)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          context.ventioText(
                            'native.ui.device_credential_state',
                            params: {
                              'id': credential.credentialId,
                              'state': _credentialState(
                                context,
                                credential.state,
                              ),
                              'expires': _formatUtc(credential.expiresAtUtc),
                            },
                          ),
                        ),
                        trailing:
                            isRegistered &&
                                credential.state ==
                                    HostManagedCredentialState.active
                            ? TextButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () =>
                                          _rotateCredential(device, credential),
                                icon: const Icon(Icons.key_outlined),
                                label: Text(
                                  context.ventioText(
                                    'native.ui.rotate_credential',
                                  ),
                                ),
                              )
                            : null,
                      ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _rotatedCredentialCard(
    BuildContext context,
    HostRotatedDeviceCredential credential,
  ) => Card(
    color: Theme.of(context).colorScheme.primaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.ventioText('native.ui.rotated_credential_once'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          SelectableText(
            credential.credential,
            key: const ValueKey('rotated-device-credential'),
          ),
          const SizedBox(height: 8),
          Text(
            context.ventioText(
              'native.ui.device_credential_rotated_details',
              params: {
                'deviceId': credential.deviceId,
                'expires': _formatUtc(credential.expiresAtUtc),
              },
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            context.ventioText(
              'native.ui.correlation_reference',
              params: {'correlationId': credential.correlationId},
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => _rotatedCredential = null),
              child: Text(context.ventioText('native.ui.clear_credential')),
            ),
          ),
        ],
      ),
    ),
  );

  String _credentialState(
    BuildContext context,
    HostManagedCredentialState state,
  ) => context.ventioText(switch (state) {
    HostManagedCredentialState.active => 'native.ui.credential_active',
    HostManagedCredentialState.expired => 'native.ui.credential_expired',
    HostManagedCredentialState.revoked => 'native.ui.credential_revoked',
    HostManagedCredentialState.rotated => 'native.ui.credential_rotated',
    HostManagedCredentialState.unknown => 'native.ui.credential_unknown',
  });

  String _safeUserLabel(HostManagedUser user, int index) =>
      user.displayName == 'Legacy identity'
      ? 'Legacy identity ${index + 1}'
      : user.displayName;

  Widget _errorCard(
    BuildContext context,
    HostDeviceManagementException error,
  ) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: ListTile(
      leading: const Icon(Icons.error_outline),
      title: Text(context.ventioText('native.ui.device_action_failed')),
      subtitle: SelectableText(
        '${context.ventioText(_errorExplanation(error.code))}\n'
        '${context.ventioText('native.ui.safe_error_code', params: {'code': error.code})}'
        '${error.correlationId == null ? '' : '\n${context.ventioText('native.ui.correlation_reference', params: {'correlationId': error.correlationId!})}'}',
      ),
      trailing: widget.client.canManageDevices
          ? IconButton(
              tooltip: context.ventioText('native.ui.retry'),
              onPressed: _busy || _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            )
          : null,
    ),
  );
}

String _errorExplanation(String code) => switch (code) {
  'PERMISSION_DENIED' ||
  'HOST_PERMISSION_DENIED' ||
  'SCOPE_DENIED' => 'native.ui.device_error_permission',
  'HOST_UNREACHABLE' ||
  'HOST_REQUEST_TIMEOUT' ||
  'HOST_UNAVAILABLE' => 'native.ui.device_error_network',
  'HOST_TLS_VALIDATION_FAILED' => 'native.ui.device_error_tls',
  'HOST_CREDENTIAL_MISSING' ||
  'UNAUTHENTICATED' => 'native.ui.device_error_authentication',
  'PAIRING_TARGET_UNAVAILABLE' => 'native.ui.device_error_target',
  'PAIRING_RATE_LIMITED' => 'native.ui.device_error_rate_limit',
  'DEVICE_NOT_FOUND' => 'native.ui.device_error_not_found',
  _ => 'native.ui.device_error_generic',
};

String _formatUtc(DateTime timestamp) {
  final utc = timestamp.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} UTC';
}
