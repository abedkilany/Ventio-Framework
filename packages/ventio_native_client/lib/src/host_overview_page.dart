import 'package:flutter/material.dart';
import 'package:ventio_core/ventio_core.dart';

import 'app_localization.dart';
import 'host_readiness.dart';

/// Authenticated Host readiness view for one verified exact branch scope.
class HostOverviewPage extends StatefulWidget {
  const HostOverviewPage({required this.client, super.key});

  final HostReadinessClient client;

  @override
  State<HostOverviewPage> createState() => _HostOverviewPageState();
}

class _HostOverviewPageState extends State<HostOverviewPage> {
  HostReadinessResult? _result;
  HostReadinessException? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    if (!widget.client.canReadStatus) {
      setState(() => _loading = false);
      return;
    }
    try {
      final result = await widget.client.checkReadiness();
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } on HostReadinessException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = const HostReadinessException('HOST_UNAVAILABLE');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const VentioText('native.ui.host_overview'),
      actions: [
        IconButton(
          tooltip: context.ventioText('native.ui.refresh_host_readiness'),
          onPressed: _loading || !widget.client.canReadStatus ? null : _refresh,
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
            _scopeCard(),
            const SizedBox(height: 12),
            if (!widget.client.canReadStatus)
              _accessRequiredCard()
            else if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 52),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              _errorCard(_error!)
            else if (_result != null) ...[
              _overallCard(_result!),
              const SizedBox(height: 8),
              for (final component in _orderedComponents)
                _componentCard(_healthFor(_result!.snapshot, component)),
              const SizedBox(height: 16),
              _unavailableInventoryCard(),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _scopeCard() => Card(
    child: ListTile(
      leading: const Icon(Icons.cloud_outlined),
      title: Text(
        context.ventioText(
          'native.ui.host_tenant_summary',
          params: {'tenantId': widget.client.verifiedIdentity.tenantId},
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
        message: context.ventioText('native.ui.host_checks_status_permission'),
        child: const Icon(Icons.verified_user_outlined),
      ),
    ),
  );

  Widget _accessRequiredCard() => Card(
    child: ListTile(
      leading: const Icon(Icons.lock_outline),
      title: const VentioText('native.ui.host_status_access_required'),
      subtitle: const VentioText(
        'native.ui.host_status_access_required_details',
      ),
    ),
  );

  Widget _overallCard(HostReadinessResult result) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_stateIcon(result.snapshot.overallState)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  context.ventioText(
                    'native.ui.host_overall_state',
                    params: {'state': result.snapshot.overallState.wireValue},
                  ),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            context.ventioText(
              'native.ui.host_version_checked',
              params: {
                'version': result.snapshot.hostVersion,
                'timestamp': _formatUtc(result.snapshot.checkedAtUtc),
              },
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            context.ventioText(
              'native.ui.correlation_reference',
              params: {'correlationId': result.correlationId},
            ),
          ),
        ],
      ),
    ),
  );

  Widget _componentCard(ManagementComponentHealth health) => Card(
    child: ListTile(
      leading: Icon(_stateIcon(health.state)),
      title: Text(context.ventioText(_componentTitleKey(health.component))),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_componentGuidance(context, health)),
            if (health.reasonCode != null) ...[
              const SizedBox(height: 4),
              SelectableText(
                context.ventioText(
                  'native.ui.host_readiness_reason_code',
                  params: {'code': health.reasonCode},
                ),
              ),
            ],
          ],
        ),
      ),
      trailing: Chip(label: Text(health.state.wireValue)),
    ),
  );

  Widget _unavailableInventoryCard() => Card(
    child: ListTile(
      leading: const Icon(Icons.devices_other_outlined),
      title: const VentioText('native.ui.device_inventory_unavailable'),
      subtitle: const VentioText(
        'native.ui.device_inventory_unavailable_details',
      ),
    ),
  );

  Widget _errorCard(HostReadinessException error) => Card(
    child: ListTile(
      leading: const Icon(Icons.cloud_off_outlined),
      title: const VentioText('native.ui.host_readiness_failed'),
      subtitle: Text(_friendlyError(context, error)),
      trailing: IconButton(
        tooltip: context.ventioText('native.ui.retry'),
        onPressed: _loading ? null : _refresh,
        icon: const Icon(Icons.refresh),
      ),
    ),
  );

  static const _orderedComponents = [
    ManagementComponent.api,
    ManagementComponent.database,
    ManagementComponent.schema,
    ManagementComponent.recoveryAuthority,
  ];

  ManagementComponentHealth _healthFor(
    HostReadinessSnapshot snapshot,
    ManagementComponent component,
  ) => snapshot.components.singleWhere(
    (health) => health.component == component,
  );
}

String _componentTitleKey(ManagementComponent component) => switch (component) {
  ManagementComponent.api => 'native.ui.host_component_api',
  ManagementComponent.database => 'native.ui.host_component_database',
  ManagementComponent.schema => 'native.ui.host_component_schema',
  ManagementComponent.recoveryAuthority => 'native.ui.host_component_recovery',
};

String _componentGuidance(
  BuildContext context,
  ManagementComponentHealth health,
) {
  if (health.state == ManagementHealthState.ready) {
    return context.ventioText(switch (health.component) {
      ManagementComponent.api => 'native.ui.host_api_ready_guidance',
      ManagementComponent.database => 'native.ui.host_database_ready_guidance',
      ManagementComponent.schema => 'native.ui.host_schema_ready_guidance',
      ManagementComponent.recoveryAuthority =>
        'native.ui.host_recovery_ready_guidance',
    });
  }
  if (health.state == ManagementHealthState.degraded) {
    return context.ventioText('native.ui.host_component_degraded_guidance');
  }
  if (health.state == ManagementHealthState.blocked) {
    return context.ventioText(
      health.component == ManagementComponent.recoveryAuthority
          ? 'native.ui.host_recovery_blocked_guidance'
          : 'native.ui.host_component_blocked_guidance',
    );
  }
  if (health.state == ManagementHealthState.notConfigured) {
    return context.ventioText('native.ui.host_component_not_configured');
  }
  if (health.state == ManagementHealthState.unknown) {
    return context.ventioText('native.ui.host_component_unknown');
  }
  return context.ventioText(switch (health.component) {
    ManagementComponent.api => 'native.ui.host_api_unavailable_guidance',
    ManagementComponent.database =>
      'native.ui.host_database_unavailable_guidance',
    ManagementComponent.schema => 'native.ui.host_schema_unavailable_guidance',
    ManagementComponent.recoveryAuthority =>
      'native.ui.host_recovery_unavailable_guidance',
  });
}

IconData _stateIcon(ManagementHealthState state) => switch (state) {
  ManagementHealthState.ready => Icons.check_circle_outline,
  ManagementHealthState.degraded => Icons.warning_amber_outlined,
  ManagementHealthState.unavailable ||
  ManagementHealthState.blocked => Icons.error_outline,
  ManagementHealthState.notConfigured ||
  ManagementHealthState.unknown => Icons.help_outline,
};

String _friendlyError(BuildContext context, HostReadinessException error) {
  final key = switch (error.code) {
    'HOST_PERMISSION_DENIED' ||
    'PERMISSION_DENIED' ||
    'SCOPE_DENIED' => 'native.ui.host_status_denied',
    'HOST_CREDENTIAL_MISSING' ||
    'PERSISTENT_IDENTITY_REQUIRED' => 'native.ui.host_credential_unavailable',
    'HOST_UNREACHABLE' ||
    'HOST_REQUEST_TIMEOUT' ||
    'HOST_UNAVAILABLE' => 'native.ui.host_not_reachable',
    'HOST_TLS_VALIDATION_FAILED' => 'native.ui.host_tls_validation_failed',
    'HOST_API_VERSION_MISMATCH' => 'native.ui.host_api_version_not_supported',
    _ => 'native.ui.host_readiness_failed_details',
  };
  final message = context.ventioText(key);
  final correlationId = error.correlationId;
  return correlationId == null
      ? message
      : '$message\n${context.ventioText('native.ui.correlation_reference', params: {'correlationId': correlationId})}';
}

String _formatUtc(DateTime timestamp) {
  final utc = timestamp.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} UTC';
}
