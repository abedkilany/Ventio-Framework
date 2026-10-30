import 'package:flutter/material.dart';

import 'app_localization.dart';
import 'host_setup.dart';
import 'host_setup_windows.dart';

class HostSetupPage extends StatefulWidget {
  const HostSetupPage({
    required this.credentialStore,
    this.platform,
    this.onComplete,
    super.key,
  });

  final HostSetupPlatform? platform;
  final HostSetupCredentialStore credentialStore;
  final VoidCallback? onComplete;

  @override
  State<HostSetupPage> createState() => _HostSetupPageState();
}

class _HostSetupPageState extends State<HostSetupPage> {
  late final HostSetupPlatform _platform =
      widget.platform ?? createHostSetupPlatform();
  late final HostSetupCredentialStore _credentialStore = widget.credentialStore;
  final _tenantId = TextEditingController();
  final _companyId = TextEditingController();
  final _branchId = TextEditingController();
  bool _checking = true;
  bool _isAdministrator = false;
  bool _busy = false;
  bool _complete = false;
  HostWindowsServiceState _postgresState = HostWindowsServiceState.unknown;
  HostWindowsServiceState _hostState = HostWindowsServiceState.unknown;
  HostSetupStep? _currentStep;
  String? _errorKey;

  @override
  void initState() {
    super.initState();
    _tenantId.addListener(_scopeChanged);
    _companyId.addListener(_scopeChanged);
    _branchId.addListener(_scopeChanged);
    _refreshStatus();
  }

  @override
  void dispose() {
    _tenantId.removeListener(_scopeChanged);
    _companyId.removeListener(_scopeChanged);
    _branchId.removeListener(_scopeChanged);
    _tenantId.dispose();
    _companyId.dispose();
    _branchId.dispose();
    super.dispose();
  }

  void _scopeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshStatus() async {
    if (!_platform.supportsHostSetup) {
      if (mounted) setState(() => _checking = false);
      return;
    }
    try {
      final isAdministrator = await _platform.isAdministrator();
      final postgres = await _platform.serviceState('VentioPostgres');
      final host = await _platform.serviceState('VentioHost');
      if (!mounted) return;
      setState(() {
        _isAdministrator = isAdministrator;
        _postgresState = postgres;
        _hostState = host;
        _checking = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _errorKey = 'native.ui.host_setup_status_unavailable';
      });
    }
  }

  Future<void> _requestElevation() async {
    setState(() {
      _busy = true;
      _errorKey = null;
    });
    try {
      final started = await _platform.requestAdministratorSetup();
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (!started) _errorKey = 'native.ui.host_setup_elevation_failed';
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorKey = 'native.ui.host_setup_elevation_failed';
      });
    }
  }

  Future<void> _runSetup() async {
    setState(() {
      _busy = true;
      _errorKey = null;
      _complete = false;
      _currentStep = HostSetupStep.administratorAccess;
    });
    try {
      final scope = HostSetupScope(
        tenantId: _tenantId.text.trim(),
        companyId: _companyId.text.trim(),
        branchId: _branchId.text.trim(),
      );
      final coordinator = HostSetupCoordinator(
        platform: _platform,
        credentials: _credentialStore,
        onProgress: (step) {
          if (mounted) setState(() => _currentStep = step);
        },
      );
      await coordinator.run(scope);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _complete = true;
      });
      await _refreshStatus();
    } on HostSetupException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorKey = _errorMessageKey(error.code);
      });
    } on ArgumentError {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorKey = 'native.ui.host_setup_scope_invalid';
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorKey = 'native.ui.host_setup_failed_generic';
      });
    }
  }

  void _finish() {
    final callback = widget.onComplete;
    if (callback != null) {
      callback();
    } else {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final supported = _platform.supportsHostSetup;
    return Scaffold(
      appBar: AppBar(title: const VentioText('native.ui.host_setup_title')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Set up this installation as a Ventio Host',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'This guided setup starts the installed PostgreSQL and Host services, creates the first Host administrator through the protected local broker, stores its credential securely, and checks Host readiness.',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (!supported)
                _messageCard(
                  icon: Icons.desktop_windows_outlined,
                  messageKey: 'native.ui.host_setup_windows_only',
                )
              else if (_checking)
                const Center(child: CircularProgressIndicator())
              else if (!_isAdministrator)
                _administratorCard()
              else ...[
                _serviceCard(
                  context,
                  titleKey: 'native.ui.host_setup_postgres',
                  state: _postgresState,
                ),
                _serviceCard(
                  context,
                  titleKey: 'native.ui.host_setup_service',
                  state: _hostState,
                ),
                const SizedBox(height: 12),
                _setupSteps(context),
                const SizedBox(height: 12),
                _scopeFields(context),
                const SizedBox(height: 12),
                _messageCard(
                  icon: Icons.lock_outline,
                  messageKey: 'native.ui.host_setup_credential_privacy',
                ),
                if (_errorKey != null) ...[
                  const SizedBox(height: 12),
                  _messageCard(
                    icon: Icons.error_outline,
                    messageKey: _errorKey!,
                    isError: true,
                  ),
                ],
                if (_complete) ...[
                  const SizedBox(height: 12),
                  _messageCard(
                    icon: Icons.check_circle_outline,
                    messageKey: 'native.ui.host_setup_complete',
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _busy || !_scopeIsValid ? null : _runSetup,
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.rocket_launch_outlined),
                  label: VentioText(
                    _complete
                        ? 'native.ui.host_setup_retry'
                        : 'native.ui.host_setup_start',
                  ),
                ),
                if (_complete) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _finish,
                    icon: const Icon(Icons.arrow_forward),
                    label: const VentioText(
                      'native.ui.host_setup_open_workspace',
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _administratorCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.admin_panel_settings_outlined),
              SizedBox(width: 10),
              Expanded(
                child: VentioText('native.ui.host_setup_admin_required'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const VentioText('native.ui.host_setup_admin_explanation'),
          if (_errorKey != null) ...[
            const SizedBox(height: 12),
            _messageCard(
              icon: Icons.error_outline,
              messageKey: _errorKey!,
              isError: true,
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _requestElevation,
            icon: const Icon(Icons.lock_open_outlined),
            label: const VentioText('native.ui.host_setup_continue_as_admin'),
          ),
        ],
      ),
    ),
  );

  Widget _serviceCard(
    BuildContext context, {
    required String titleKey,
    required HostWindowsServiceState state,
  }) => Card(
    child: ListTile(
      leading: Icon(_serviceIcon(state)),
      title: VentioText(titleKey),
      trailing: Chip(label: Text(context.ventioText(_serviceStateKey(state)))),
    ),
  );

  Widget _setupSteps(BuildContext context) {
    const steps = [
      HostSetupStep.postgresService,
      HostSetupStep.hostService,
      HostSetupStep.firstAdministrator,
      HostSetupStep.credentialStorage,
      HostSetupStep.hostReadiness,
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const VentioText('native.ui.host_setup_progress_title'),
            const SizedBox(height: 10),
            for (final step in steps)
              ListTile(
                dense: true,
                leading: Icon(_stepIcon(step)),
                title: VentioText(_stepTitleKey(step)),
                trailing: _stepStatus(step),
              ),
            if (_busy && _currentStep != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _progressValue(_currentStep!)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stepStatus(HostSetupStep step) {
    final current = _currentStep;
    if (_complete ||
        (current != null && _stepOrder(step) < _stepOrder(current))) {
      return const Icon(Icons.check_circle, color: Colors.green);
    }
    if (_busy && current == step) {
      return const SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return const Icon(Icons.radio_button_unchecked);
  }

  Widget _scopeFields(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const VentioText('native.ui.host_setup_scope_title'),
          const SizedBox(height: 8),
          const VentioText('native.ui.host_setup_scope_explanation'),
          const SizedBox(height: 12),
          TextField(
            controller: _tenantId,
            enabled: !_busy,
            maxLength: 256,
            decoration: InputDecoration(
              labelText: context.ventioText('native.ui.host_setup_tenant_id'),
            ),
          ),
          TextField(
            controller: _companyId,
            enabled: !_busy,
            maxLength: 256,
            decoration: InputDecoration(
              labelText: context.ventioText('native.ui.host_setup_company_id'),
            ),
          ),
          TextField(
            controller: _branchId,
            enabled: !_busy,
            maxLength: 256,
            decoration: InputDecoration(
              labelText: context.ventioText('native.ui.host_setup_branch_id'),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _messageCard({
    required IconData icon,
    required String messageKey,
    bool isError = false,
  }) => Card(
    color: isError ? Theme.of(context).colorScheme.errorContainer : null,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon),
          const SizedBox(width: 10),
          Expanded(child: VentioText(messageKey)),
        ],
      ),
    ),
  );

  bool get _scopeIsValid =>
      _tenantId.text.trim().isNotEmpty &&
      _companyId.text.trim().isNotEmpty &&
      _branchId.text.trim().isNotEmpty &&
      _tenantId.text.trim().length <= 256 &&
      _companyId.text.trim().length <= 256 &&
      _branchId.text.trim().length <= 256;

  IconData _serviceIcon(HostWindowsServiceState state) => switch (state) {
    HostWindowsServiceState.running => Icons.check_circle_outline,
    HostWindowsServiceState.startPending => Icons.hourglass_top,
    HostWindowsServiceState.stopPending => Icons.hourglass_bottom,
    HostWindowsServiceState.notInstalled => Icons.remove_circle_outline,
    HostWindowsServiceState.stopped => Icons.pause_circle_outline,
    HostWindowsServiceState.unknown => Icons.help_outline,
  };

  String _serviceStateKey(HostWindowsServiceState state) => switch (state) {
    HostWindowsServiceState.notInstalled =>
      'native.ui.host_setup_not_installed',
    HostWindowsServiceState.stopped => 'native.ui.host_setup_stopped',
    HostWindowsServiceState.startPending =>
      'native.ui.host_setup_start_pending',
    HostWindowsServiceState.stopPending => 'native.ui.host_setup_stop_pending',
    HostWindowsServiceState.running => 'native.ui.host_setup_running',
    HostWindowsServiceState.unknown => 'native.ui.host_setup_unknown',
  };

  String _stepTitleKey(HostSetupStep step) => switch (step) {
    HostSetupStep.administratorAccess => 'native.ui.host_setup_admin_required',
    HostSetupStep.postgresService => 'native.ui.host_setup_postgres',
    HostSetupStep.hostService => 'native.ui.host_setup_service',
    HostSetupStep.firstAdministrator => 'native.ui.host_setup_first_admin',
    HostSetupStep.credentialStorage => 'native.ui.host_setup_store_credential',
    HostSetupStep.hostReadiness => 'native.ui.host_setup_readiness',
    HostSetupStep.complete => 'native.ui.host_setup_complete',
  };

  IconData _stepIcon(HostSetupStep step) => switch (step) {
    HostSetupStep.postgresService => Icons.storage_outlined,
    HostSetupStep.hostService => Icons.dns_outlined,
    HostSetupStep.firstAdministrator => Icons.person_add_alt_1_outlined,
    HostSetupStep.credentialStorage => Icons.lock_outline,
    HostSetupStep.hostReadiness => Icons.health_and_safety_outlined,
    _ => Icons.checklist,
  };

  int _stepOrder(HostSetupStep step) => switch (step) {
    HostSetupStep.administratorAccess => 0,
    HostSetupStep.postgresService => 1,
    HostSetupStep.hostService => 2,
    HostSetupStep.firstAdministrator => 3,
    HostSetupStep.credentialStorage => 4,
    HostSetupStep.hostReadiness => 5,
    HostSetupStep.complete => 6,
  };

  double _progressValue(HostSetupStep step) =>
      (_stepOrder(step) / 6).clamp(0.0, 1.0).toDouble();

  String _errorMessageKey(String code) => switch (code) {
    'HOST_SETUP_REQUIRES_ADMINISTRATOR' =>
      'native.ui.host_setup_admin_required',
    'HOST_SERVICE_NOT_INSTALLED' => 'native.ui.host_setup_install_role_missing',
    'HOST_SERVICE_CONTROL_UNAVAILABLE' =>
      'native.ui.host_setup_service_control_denied',
    'HOST_SERVICE_STATUS_UNAVAILABLE' =>
      'native.ui.host_setup_status_unavailable',
    'HOST_SERVICE_START_FAILED' => 'native.ui.host_setup_service_start_failed',
    'HOST_SERVICE_START_TIMEOUT' => 'native.ui.host_setup_service_timeout',
    'HOST_PROFILE_ALREADY_CONFIGURED' =>
      'native.ui.host_setup_existing_profile',
    'HOST_CREDENTIAL_STORAGE_FAILED' =>
      'native.ui.host_setup_credential_save_failed',
    'HOST_FIRST_ADMINISTRATOR_RESPONSE_INVALID' =>
      'native.ui.host_setup_response_invalid',
    'HOST_BOOTSTRAP_CREDENTIAL_UNAVAILABLE' =>
      'native.ui.host_setup_credential_unavailable',
    'HOST_BOOTSTRAP_BROKER_UNAVAILABLE' =>
      'native.ui.host_setup_broker_unavailable',
    'HOST_BOOTSTRAP_ACKNOWLEDGEMENT_FAILED' =>
      'native.ui.host_setup_acknowledgement_failed',
    'HOST_READINESS_TIMEOUT' => 'native.ui.host_setup_readiness_timeout',
    'HOST_SETUP_WINDOWS_ONLY' => 'native.ui.host_setup_windows_only',
    _ => 'native.ui.host_setup_failed_generic',
  };
}
