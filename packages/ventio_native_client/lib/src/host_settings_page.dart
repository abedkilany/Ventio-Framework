import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_localization.dart';
import 'extension_store.dart';
import 'host_credentials.dart';
import 'host_extension_packages.dart';
import 'host_lan_info.dart';

class HostSettingsPage extends StatelessWidget {
  const HostSettingsPage({
    required this.profile,
    required this.identity,
    required this.onConfigure,
    super.key,
  });

  final HostConnectionProfile? profile;
  final HostSessionIdentity? identity;
  final VoidCallback onConfigure;

  HostScopeGrant? _selectedScope() {
    final selectedProfile = profile;
    final session = identity;
    if (selectedProfile == null || session == null) return null;
    for (final scope in session.scopes) {
      if (scope.companyId == selectedProfile.companyId &&
          scope.branchId == selectedProfile.branchId) {
        return scope;
      }
    }
    return null;
  }

  String _displayEndpoint(BuildContext context, String endpoint) {
    try {
      final uri = HostCredentialVault.normalizeEndpoint(Uri.parse(endpoint));
      return '${uri.origin}${uri.path == '/' ? '' : uri.path}';
    } on FormatException {
      return context.ventioText('native.ui.invalid_saved_host_address');
    } on ArgumentError {
      return context.ventioText('native.ui.invalid_saved_host_address');
    }
  }

  bool _usesLocalHost(String endpoint) {
    try {
      final uri = HostCredentialVault.normalizeEndpoint(Uri.parse(endpoint));
      return uri.port == 8080 &&
          (uri.host == '127.0.0.1' || uri.host.toLowerCase() == 'localhost');
    } on FormatException {
      return false;
    } on ArgumentError {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedProfile = profile;
    final session = identity;
    final selectedScope = _selectedScope();
    final permissions = selectedScope?.permissions.toList() ?? <String>[];
    permissions.sort();

    return Scaffold(
      appBar: AppBar(title: const VentioText('native.ui.host_settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (selectedProfile == null)
                _noticeCard(
                  context,
                  icon: Icons.cloud_off_outlined,
                  title: context.ventioText(
                    'native.ui.no_host_connection_configured',
                  ),
                  body: context.ventioText(
                    'native.ui.host_settings_connection_missing_details',
                  ),
                )
              else ...[
                _sectionCard(
                  context,
                  title: context.ventioText('native.ui.device_host_connection'),
                  icon: Icons.cloud_outlined,
                  children: [
                    _detail(
                      context.ventioText('native.ui.host_address'),
                      _displayEndpoint(context, selectedProfile.endpoint),
                    ),
                    _detail(
                      context.ventioText('native.ui.tenant'),
                      selectedProfile.tenantId,
                    ),
                    _detail(
                      context.ventioText('native.ui.company'),
                      selectedProfile.companyId,
                    ),
                    _detail(
                      context.ventioText('native.ui.branch'),
                      selectedProfile.branchId,
                    ),
                  ],
                ),
                if (_usesLocalHost(selectedProfile.endpoint))
                  FutureBuilder<HostLanEndpointInfo?>(
                    future: HostLanEndpointInfo.loadForWindows(),
                    builder: (context, snapshot) {
                      final lan = snapshot.data;
                      if (lan == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: _sectionCard(
                          context,
                          title: context.ventioText(
                            'native.ui.lan_host_listener',
                          ),
                          icon: Icons.wifi_tethering_outlined,
                          children: [
                            _detail(
                              context.ventioText('native.ui.lan_endpoint'),
                              lan.endpoint,
                            ),
                            if (lan.alternativeEndpoints.isNotEmpty)
                              _detail(
                                context.ventioText(
                                  'native.ui.lan_ip_endpoints',
                                ),
                                lan.alternativeEndpoints.join('\n'),
                              ),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        context.ventioText(
                                          'native.ui.lan_certificate_fingerprint',
                                        ),
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                      SelectableText(lan.certificateSha256),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: context.ventioText(
                                    'native.ui.copy_tls_fingerprint',
                                  ),
                                  onPressed: () async {
                                    final messenger = ScaffoldMessenger.of(
                                      context,
                                    );
                                    final copiedMessage = context.ventioText(
                                      'native.ui.tls_fingerprint_copied',
                                    );
                                    await Clipboard.setData(
                                      ClipboardData(
                                        text: lan.certificateSha256,
                                      ),
                                    );
                                    messenger.showSnackBar(
                                      SnackBar(content: Text(copiedMessage)),
                                    );
                                  },
                                  icon: const Icon(Icons.copy_outlined),
                                ),
                              ],
                            ),
                            _detail(
                              context.ventioText(
                                'native.ui.lan_public_certificate',
                              ),
                              lan.certificatePath,
                            ),
                            Text(
                              context.ventioText(
                                'native.ui.lan_certificate_trust_notice',
                              ),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 12),
                if (session == null)
                  _noticeCard(
                    context,
                    icon: Icons.lock_outline,
                    title: context.ventioText(
                      'native.ui.host_session_not_verified',
                    ),
                    body: context.ventioText(
                      'native.ui.host_settings_session_unavailable_details',
                    ),
                  )
                else if (selectedScope == null)
                  _noticeCard(
                    context,
                    icon: Icons.gpp_bad_outlined,
                    title: context.ventioText(
                      'native.ui.selected_host_scope_not_granted',
                    ),
                    body: context.ventioText(
                      'native.ui.host_settings_scope_unavailable_details',
                    ),
                  )
                else
                  _sectionCard(
                    context,
                    title: context.ventioText(
                      'native.ui.verified_host_session',
                    ),
                    icon: Icons.verified_user_outlined,
                    children: [
                      _detail(
                        context.ventioText('native.ui.actor_identifier'),
                        session.actorId,
                      ),
                      _detail(
                        context.ventioText('native.ui.device_identifier'),
                        session.deviceId,
                      ),
                      _detail(
                        context.ventioText('native.ui.credential_storage'),
                        context.ventioText(
                          'native.ui.secure_device_credential_vault',
                        ),
                      ),
                      const Divider(),
                      Text(
                        context.ventioText(
                          'native.ui.permissions_for_selected_scope',
                        ),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      if (permissions.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            context.ventioText(
                              'native.ui.no_permissions_for_selected_scope',
                            ),
                          ),
                        )
                      else
                        ...permissions.map(
                          (permission) => ListTile(
                            dense: true,
                            leading: const Icon(Icons.key_outlined),
                            title: SelectableText(permission),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: 12),
                _noticeCard(
                  context,
                  icon: Icons.security_outlined,
                  title: context.ventioText(
                    'native.ui.host_connection_security',
                  ),
                  body: context.ventioText(
                    'native.ui.host_settings_security_details',
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('host-settings-configure-connection'),
                onPressed: onConfigure,
                icon: const Icon(Icons.edit_outlined),
                label: Text(
                  context.ventioText(
                    selectedProfile == null
                        ? 'native.ui.configure_host_connection'
                        : 'native.ui.change_host_connection',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.ventioText(
                  'native.ui.host_settings_device_local_notice',
                ),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionCard(
    BuildContext context, {
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  );

  Widget _noticeCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String body,
  }) => Card(
    child: ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(body),
      ),
    ),
  );

  Widget _detail(String label, String value) => ListTile(
    dense: true,
    title: Text(label),
    subtitle: SelectableText(value),
    contentPadding: EdgeInsets.zero,
  );
}
