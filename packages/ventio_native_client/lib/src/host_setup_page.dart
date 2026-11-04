import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ventio_core/ventio_core.dart';

import 'app_localization.dart';
import 'host_setup.dart';
import 'host_setup_windows.dart';
import 'local_diagnostics.dart';

typedef HostSetupDiagnosticExportHandler = Future<void> Function(String json);

class HostSetupPage extends StatefulWidget {
  const HostSetupPage({
    required this.credentialStore,
    this.platform,
    this.diagnosticEventSource,
    this.diagnosticExportHandler,
    this.onComplete,
    super.key,
  });

  final HostSetupPlatform? platform;
  final HostSetupCredentialStore credentialStore;
  final DiagnosticEventSource? diagnosticEventSource;
  final HostSetupDiagnosticExportHandler? diagnosticExportHandler;
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
  bool _restoringPendingScope = true;
  bool _pendingOperationFound = false;
  bool _pendingScopeMismatch = false;
  bool _busy = false;
  bool _complete = false;
  HostWindowsServiceState _postgresState = HostWindowsServiceState.unknown;
  HostWindowsServiceState _hostState = HostWindowsServiceState.unknown;
  HostSetupStep? _currentStep;
  String? _errorKey;
  ManagementDiagnosticEvent? _setupDiagnostic;
  LocalDiagnosticsStore? _ownedDiagnosticStore;
  bool _diagnosticPersistenceFailed = false;
  bool _exportingDiagnostic = false;

  @override
  void initState() {
    super.initState();
    _tenantId.addListener(_scopeChanged);
    _companyId.addListener(_scopeChanged);
    _branchId.addListener(_scopeChanged);
    _refreshStatus();
    _restorePendingScope();
  }

  @override
  void dispose() {
    _tenantId.removeListener(_scopeChanged);
    _companyId.removeListener(_scopeChanged);
    _branchId.removeListener(_scopeChanged);
    _tenantId.dispose();
    _companyId.dispose();
    _branchId.dispose();
    final store = _ownedDiagnosticStore;
    if (store != null) unawaited(store.close());
    super.dispose();
  }

  void _scopeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _restorePendingScope() async {
    try {
      final pending = await _platform.readPendingOperation();
      if (!mounted || pending == null) return;
      _pendingOperationFound = true;
      if (pending.requesterSid != await _platform.currentUserSid()) {
        setState(() {
          _pendingScopeMismatch = true;
          _errorKey = 'native.ui.host_setup_pending_mismatch';
        });
        return;
      }
      _tenantId.text = pending.scope.tenantId;
      _companyId.text = pending.scope.companyId;
      _branchId.text = pending.scope.branchId;
    } on HostSetupException catch (error, stack) {
      final event = await _captureSetupFailure(
        error.code,
        failure: error,
        stack: stack,
        phase: error.phase,
      );
      if (!mounted) return;
      setState(() {
        _errorKey = _errorMessageKey(error.code);
        _setupDiagnostic = event;
      });
    } on Object catch (error, stack) {
      final event = await _captureSetupFailure(
        'HOST_SETUP_STATE_UNAVAILABLE',
        failure: error,
        stack: stack,
      );
      if (!mounted) return;
      setState(() {
        _errorKey = 'native.ui.host_setup_state_unavailable';
        _setupDiagnostic = event;
      });
    } finally {
      if (mounted) setState(() => _restoringPendingScope = false);
    }
  }

  Future<void> _refreshStatus() async {
    if (!_platform.supportsHostSetup) {
      if (mounted) setState(() => _checking = false);
      return;
    }
    try {
      final postgres = await _platform.serviceState('VentioPostgres');
      final host = await _platform.serviceState('VentioHost');
      if (!mounted) return;
      setState(() {
        _postgresState = postgres;
        _hostState = host;
        _checking = false;
      });
    } on Object catch (error, stack) {
      final event = await _captureSetupFailure(
        'HOST_SETUP_STATUS_UNAVAILABLE',
        failure: error,
        stack: stack,
        phase: 'HOST_READINESS',
      );
      if (!mounted) return;
      setState(() {
        _checking = false;
        _errorKey = 'native.ui.host_setup_status_unavailable';
        _setupDiagnostic = event;
      });
    }
  }

  Future<void> _runSetup() async {
    setState(() {
      _busy = true;
      _errorKey = null;
      _complete = false;
      _currentStep = HostSetupStep.administratorAccess;
      _setupDiagnostic = null;
      _diagnosticPersistenceFailed = false;
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
    } on HostSetupException catch (error, stack) {
      final event = await _captureSetupFailure(
        error.code,
        failure: error,
        stack: stack,
        phase: error.phase,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorKey = _errorMessageKey(error.code);
        _setupDiagnostic = event;
      });
    } on ArgumentError {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorKey = 'native.ui.host_setup_scope_invalid';
      });
    } on Object catch (error, stack) {
      final event = await _captureSetupFailure(
        'HOST_SETUP_UNEXPECTED_FAILURE',
        failure: error,
        stack: stack,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorKey = 'native.ui.host_setup_failed_generic';
        _setupDiagnostic = event;
      });
    }
  }

  Future<ManagementDiagnosticEvent> _captureSetupFailure(
    String code, {
    required Object failure,
    required StackTrace stack,
    String? phase,
  }) async {
    final safeCode = RegExp(r'^[A-Z][A-Z0-9_]{0,79}$').hasMatch(code)
        ? code
        : 'HOST_SETUP_UNEXPECTED_FAILURE';
    final safePhase = _safeDiagnosticPhase(phase);
    final category = _diagnosticCategory(safeCode);
    final correlationId = newLocalCorrelationId();
    final occurredAtUtc = DateTime.now().toUtc();
    final input = LocalDiagnosticInput(
      code: safeCode,
      component: 'client.host_setup.${safePhase.toLowerCase()}',
      category: category,
      severity: safeCode == 'HOST_SETUP_ELEVATION_CANCELLED'
          ? ManagementDiagnosticSeverity.warning
          : ManagementDiagnosticSeverity.error,
      retryable: _isRetryableDiagnostic(safeCode),
      messageKey: 'native.diagnostics.host_setup_failed',
      safeExplanation:
          'Host setup failed during ${safePhase.replaceAll('_', ' ').toLowerCase()}.',
      recommendedAction:
          'Keep existing Host data intact. Share this sanitized report with an authorized Host operator before attempting recovery.',
      occurredAtUtc: occurredAtUtc,
      correlationId: correlationId,
      protectedFailureType: safeDiagnosticFailureType(failure),
      protectedFailureSource: safeDiagnosticFailureSource(stack),
    );
    final fallback = ManagementDiagnosticEvent(
      code: input.code,
      component: input.component,
      category: input.category,
      severity: input.severity,
      occurredAtUtc: occurredAtUtc,
      correlationId: correlationId,
      retryable: input.retryable,
      messageKey: input.messageKey,
      safeExplanation: input.safeExplanation,
      recommendedAction: input.recommendedAction,
      protectedFailureType: input.protectedFailureType,
      protectedFailureSource: input.protectedFailureSource,
    );

    try {
      final source = await _diagnosticSource();
      final event = await source.record(input);
      if (event.code != safeCode || event.correlationId != correlationId) {
        throw const FormatException('Diagnostic event identity mismatch.');
      }
      _diagnosticPersistenceFailed = false;
      return event;
    } on Object {
      _diagnosticPersistenceFailed = true;
      return fallback;
    }
  }

  Future<DiagnosticEventSource> _diagnosticSource() async {
    final supplied = widget.diagnosticEventSource;
    if (supplied != null) return supplied;
    return _ownedDiagnosticStore ??= await openDefaultLocalDiagnosticsStore();
  }

  String _safeDiagnosticPhase(String? phase) {
    const allowed = {
      'ADMINISTRATOR_ACCESS',
      'PAYLOAD_VALIDATION',
      'POSTGRES_SERVICE_PROVISIONING',
      'DATABASE_INITIALIZATION',
      'MIGRATION_CREDENTIAL_PROTECTION',
      'HOST_SERVICE_REGISTRATION',
      'HOST_CONFIGURATION_PROTECTION',
      'HOST_LAN_CONFIGURATION',
      'HOST_SERVICE_STARTUP',
      'HOST_READINESS',
      'FIRST_ADMINISTRATOR_BOOTSTRAP',
      'BOOTSTRAP_CREDENTIAL_PROTECTION',
    };
    if (phase != null && allowed.contains(phase)) return phase;
    return switch (_currentStep) {
      HostSetupStep.administratorAccess => 'ADMINISTRATOR_ACCESS',
      HostSetupStep.postgresService => 'POSTGRES_SERVICE_PROVISIONING',
      HostSetupStep.hostService => 'HOST_SERVICE_REGISTRATION',
      HostSetupStep.firstAdministrator => 'FIRST_ADMINISTRATOR_BOOTSTRAP',
      HostSetupStep.credentialStorage => 'BOOTSTRAP_CREDENTIAL_PROTECTION',
      HostSetupStep.hostReadiness || HostSetupStep.complete => 'HOST_READINESS',
      null => 'HOST_READINESS',
    };
  }

  ManagementDiagnosticCategory _diagnosticCategory(String code) {
    if (code.contains('RECOVERY')) {
      return ManagementDiagnosticCategory.recovery;
    }
    if (code.contains('DATABASE') || code.contains('POSTGRES')) {
      return ManagementDiagnosticCategory.database;
    }
    if (code.contains('CREDENTIAL') || code.contains('TOKEN')) {
      return ManagementDiagnosticCategory.credentials;
    }
    if (code.contains('AUTHORIZATION') || code.contains('PERMISSION')) {
      return ManagementDiagnosticCategory.authorization;
    }
    return ManagementDiagnosticCategory.hostStartup;
  }

  bool _isRetryableDiagnostic(String code) => const {
    'HOST_SETUP_STATUS_UNAVAILABLE',
    'HOST_SETUP_BROKER_START_TIMEOUT',
    'HOST_SETUP_OPERATION_TIMEOUT',
    'HOST_SERVICE_START_TIMEOUT',
    'HOST_READINESS_TIMEOUT',
  }.contains(code);

  Future<void> _exportSetupDiagnostic() async {
    final event = _setupDiagnostic;
    if (event == null || _exportingDiagnostic) return;
    setState(() => _exportingDiagnostic = true);
    try {
      final json = const JsonEncoder.withIndent('  ').convert({
        'managementApiVersion': managementApiVersion,
        'exportedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'events': [
          {'source': 'device', ...event.toJson()},
        ],
      });
      final handler = widget.diagnosticExportHandler;
      if (handler == null) {
        await Clipboard.setData(ClipboardData(text: json));
      } else {
        await handler(json);
      }
      if (mounted) {
        _showDiagnosticMessage('native.ui.host_setup_diagnostic_copy_success');
      }
    } on Object {
      if (mounted) {
        _showDiagnosticMessage('native.ui.host_setup_diagnostic_copy_failed');
      }
    } finally {
      if (mounted) setState(() => _exportingDiagnostic = false);
    }
  }

  void _showDiagnosticMessage(String key) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(context.ventioText(key))));
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
                        'This guided setup provisions PostgreSQL, applies Host migrations, registers the Windows services, creates the first Host administrator through the trusted local service, stores its credential securely, and verifies readiness. Windows requests Administrator approval only for the protected setup component.',
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
              else if (_checking || _restoringPendingScope)
                const Center(child: CircularProgressIndicator())
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
                  if (_setupDiagnostic != null) ...[
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            VentioText(
                              'native.ui.host_setup_diagnostic_reference',
                              params: {
                                'referenceId': _setupDiagnostic!.correlationId,
                              },
                            ),
                            if (_diagnosticPersistenceFailed) ...[
                              const SizedBox(height: 6),
                              const VentioText(
                                'native.ui.host_setup_diagnostic_not_saved',
                              ),
                            ],
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              onPressed: _exportingDiagnostic
                                  ? null
                                  : _exportSetupDiagnostic,
                              icon: _exportingDiagnostic
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.content_copy_outlined),
                              label: const VentioText(
                                'native.ui.host_setup_copy_diagnostics',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
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
                  onPressed: _busy || _pendingScopeMismatch || !_scopeIsValid
                      ? null
                      : _runSetup,
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.rocket_launch_outlined),
                  label: VentioText(
                    _complete
                        ? 'native.ui.host_setup_check_readiness'
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
      HostSetupStep.administratorAccess,
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
            enabled: !_busy && !_pendingOperationFound,
            maxLength: 256,
            decoration: InputDecoration(
              labelText: context.ventioText('native.ui.host_setup_tenant_id'),
            ),
          ),
          TextField(
            controller: _companyId,
            enabled: !_busy && !_pendingOperationFound,
            maxLength: 256,
            decoration: InputDecoration(
              labelText: context.ventioText('native.ui.host_setup_company_id'),
            ),
          ),
          TextField(
            controller: _branchId,
            enabled: !_busy && !_pendingOperationFound,
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
    'HOST_SETUP_APPLICATION_ELEVATED' =>
      'native.ui.host_setup_application_elevated',
    'HOST_SETUP_ELEVATION_CANCELLED' =>
      'native.ui.host_setup_elevation_cancelled',
    'HOST_SETUP_BROKER_START_TIMEOUT' =>
      'native.ui.host_setup_broker_start_timeout',
    'HOST_SETUP_OPERATION_TIMEOUT' => 'native.ui.host_setup_operation_timeout',
    'HOST_SETUP_PENDING_OPERATION_MISMATCH' =>
      'native.ui.host_setup_pending_mismatch',
    'HOST_EXISTING_INSTALLATION_REQUIRES_RECOVERY' =>
      'native.ui.host_setup_existing_installation',
    'HOST_EXISTING_SERVICES_REQUIRE_RECOVERY' =>
      'native.ui.host_setup_existing_installation',
    'HOST_EXISTING_DATA_REQUIRES_REPAIR' =>
      'native.ui.host_setup_existing_installation',
    'HOST_PARTIAL_SERVICE_INSTALLATION' =>
      'native.ui.host_setup_existing_installation',
    'HOST_SERVICE_IDENTITY_CONFLICT' =>
      'native.ui.host_setup_service_identity_conflict',
    'HOST_DATABASE_MIGRATION_LEDGER_INVALID' =>
      'native.ui.host_setup_migration_ledger_invalid',
    'HOST_SETUP_ALREADY_RUNNING' => 'native.ui.host_setup_already_running',
    'HOST_SETUP_INTERRUPTED_REQUIRES_RECOVERY' =>
      'native.ui.host_setup_interrupted_requires_recovery',
    'HOST_SETUP_SCRIPT_HASH_INVALID' =>
      'native.ui.host_setup_payload_verification_failed',
    'HOST_SETUP_PAYLOAD_MANIFEST_INVALID' =>
      'native.ui.host_setup_payload_verification_failed',
    'HOST_LAN_PRIVATE_NETWORK_REQUIRED' ||
    'HOST_LAN_TRUSTED_NETWORK_REQUIRED' =>
      'native.ui.host_setup_lan_network_required',
    'HOST_LAN_FIREWALL_BASELINE_UNSAFE' ||
    'HOST_LAN_FIREWALL_RULE_CONFLICT' ||
    'HOST_LAN_FIREWALL_RULE_NOT_EFFECTIVE' =>
      'native.ui.host_setup_lan_firewall_failed',
    'HOST_SETUP_STATUS_UNAVAILABLE' =>
      'native.ui.host_setup_status_unavailable',
    'HOST_FIRST_ADMIN_REQUEST_INVALID' =>
      'native.ui.host_setup_first_admin_request_invalid',
    'HOST_FIRST_ADMIN_DATABASE_CONNECTION_FAILED' =>
      'native.ui.host_setup_first_admin_database_failed',
    'HOST_FIRST_ADMIN_RECOVERY_AUTHORITY_FAILED' =>
      'native.ui.host_setup_first_admin_recovery_failed',
    'HOST_FIRST_ADMIN_IDENTITY_BOOTSTRAP_FAILED' =>
      'native.ui.host_setup_first_admin_identity_failed',
    'HOST_FIRST_ADMIN_HELPER_TIMEOUT' =>
      'native.ui.host_setup_first_admin_helper_timeout',
    'HOST_FIRST_ADMIN_RESULT_INVALID' =>
      'native.ui.host_setup_first_admin_result_invalid',
    'HOST_FIRST_ADMIN_HELPER_FAILED' =>
      'native.ui.host_setup_first_admin_helper_failed',
    'HOST_SETUP_STATE_UNAVAILABLE' => 'native.ui.host_setup_state_unavailable',
    'HOST_SETUP_STATE_ALREADY_EXISTS' =>
      'native.ui.host_setup_state_unavailable',
    'HOST_SETUP_IDENTITY_UNAVAILABLE' =>
      'native.ui.host_setup_identity_unavailable',
    'HOST_SETUP_BROKER_UNAVAILABLE' =>
      'native.ui.host_setup_broker_unavailable',
    'HOST_SETUP_ADMIN_ELEVATION_REQUIRED' =>
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
    'HOST_SETUP_REQUESTER_IDENTITY_MISMATCH' =>
      'native.ui.host_setup_requester_identity_mismatch',
    _ => 'native.ui.host_setup_failed_generic',
  };
}
