import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ventio_core/ventio_core.dart';

import 'app_localization.dart';
import 'host_setup.dart';
import 'account_sign_in.dart';
import 'host_organization_initializer.dart';
import 'host_setup_identifiers.dart';
import 'host_setup_sidebar.dart';
import 'host_extension_packages.dart';
import 'host_setup_windows.dart';
import 'local_diagnostics.dart';
import 'performance_probe.dart';

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
  final _ownerUsername = TextEditingController();
  final _ownerPassword = TextEditingController();
  final _ownerConfirm = TextEditingController();
  final _organizationName = TextEditingController();
  final _companyName = TextEditingController();
  final _branchName = TextEditingController();
  final _tenantId = TextEditingController();
  final _companyId = TextEditingController();
  final _branchId = TextEditingController();
  int _wizardStep = 0;
  bool _setupAttempted = false;
  bool _checking = true;
  bool _restoringPendingScope = true;
  bool _pendingOperationFound = false;
  bool _pendingScopeMismatch = false;
  bool _busy = false;
  bool _showPassword = false;
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
    _ownerUsername.addListener(_scopeChanged);
    _ownerPassword.addListener(_scopeChanged);
    _ownerConfirm.addListener(_scopeChanged);
    _organizationName.addListener(_scopeChanged);
    _companyName.addListener(_scopeChanged);
    _branchName.addListener(_scopeChanged);

    final generated = generateHostSetupScope();
    _tenantId.text = generated.tenantId;
    _companyId.text = generated.companyId;
    _branchId.text = generated.branchId;

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
    _ownerUsername.dispose();
    _ownerPassword.dispose();
    _ownerConfirm.dispose();
    _organizationName.dispose();
    _companyName.dispose();
    _branchName.dispose();
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
      final store = _credentialStore;

      if (store is LocalHostSetupCredentialStore) {
        final draft = await store.store.getHostSetupDraft();

        if (!mounted) return;

        if (draft != null) {
          final sid = await _platform.currentUserSid();

          if (!mounted) return;

          if (draft['requester_sid'] != sid) {
            setState(() {
              _pendingScopeMismatch = true;
              _errorKey = 'native.ui.host_setup_pending_mismatch';
            });
            return;
          }

          final scope = HostSetupScope(
            tenantId: draft['tenant_id'] as String,
            companyId: draft['company_id'] as String,
            branchId: draft['branch_id'] as String,
          );

          _tenantId.text = scope.tenantId;
          _companyId.text = scope.companyId;
          _branchId.text = scope.branchId;

          _organizationName.text = draft['organization_name'] as String;
          _companyName.text = draft['company_name'] as String;
          _branchName.text = draft['branch_name'] as String;

          _setupAttempted = true;
        }
      }

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
      if (_setupAttempted &&
          (_tenantId.text != pending.scope.tenantId ||
              _companyId.text != pending.scope.companyId ||
              _branchId.text != pending.scope.branchId)) {
        setState(() {
          _pendingScopeMismatch = true;
          _errorKey = 'native.ui.host_setup_pending_mismatch';
        });
        return;
      }

      if (!_setupAttempted) {
        _organizationName.text = pending.scope.tenantId;
        _companyName.text = pending.scope.companyId;
        _branchName.text = pending.scope.branchId;
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
        _pendingScopeMismatch = true;
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
        _pendingScopeMismatch = true;
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

  Future<void> _runSetup() =>
      VentioPerformanceProbe.measure('host_setup.initial', _runSetupImpl);

  Future<void> _runSetupImpl() async {
    setState(() {
      _setupAttempted = true;
      _busy = true;
      _errorKey = null;
      _complete = false;
      _currentStep = HostSetupStep.administratorAccess;
      _setupDiagnostic = null;
      _diagnosticPersistenceFailed = false;
    });
    try {
      if (_credentialStore is LocalHostSetupCredentialStore &&
          (!AccountPassword.validUsername(_ownerUsername.text.trim()) ||
              !AccountPassword.validPassword(_ownerPassword.text) ||
              _ownerPassword.text != _ownerConfirm.text)) {
        throw ArgumentError('Owner login is invalid');
      }
      final scope = HostSetupScope(
        tenantId: _tenantId.text.trim(),
        companyId: _companyId.text.trim(),
        branchId: _branchId.text.trim(),
      );
      final draftStore = _credentialStore;

      if (draftStore is LocalHostSetupCredentialStore) {
        final sid = await _platform.currentUserSid();
        final draft = await draftStore.store.getHostSetupDraft();

        if (!_namesAreValid) {
          throw ArgumentError('Invalid organization names');
        }

        if (draft == null) {
          await draftStore.store.saveHostSetupDraft(
            requesterSid: sid,
            tenantId: scope.tenantId,
            companyId: scope.companyId,
            branchId: scope.branchId,
            organizationName: _organizationName.text.trim(),
            companyName: _companyName.text.trim(),
            branchName: _branchName.text.trim(),
          );
        } else if (draft['requester_sid'] != sid ||
            draft['tenant_id'] != scope.tenantId ||
            draft['company_id'] != scope.companyId ||
            draft['branch_id'] != scope.branchId ||
            draft['organization_name'] != _organizationName.text.trim() ||
            draft['company_name'] != _companyName.text.trim() ||
            draft['branch_name'] != _branchName.text.trim()) {
          throw const HostSetupException(
            'HOST_SETUP_PENDING_OPERATION_MISMATCH',
          );
        }
      }

      final coordinator = HostSetupCoordinator(
        platform: _platform,
        credentials: _credentialStore,
        onProgress: (step) {
          if (mounted) setState(() => _currentStep = step);
        },
      );
      final resumeStore = _credentialStore;

      if (resumeStore is LocalHostSetupCredentialStore) {
        final existing = await resumeStore.readProfile();

        if (existing != null) {
          if (!scope.matches(existing) ||
              existing.endpoint != hostSetupEndpoint) {
            throw const HostSetupException('HOST_PROFILE_ALREADY_CONFIGURED');
          }

          if (await _platform.currentProcessIsElevated()) {
            throw const HostSetupException('HOST_SETUP_APPLICATION_ELEVATED');
          }

          if (!await _platform.waitForHostReadiness()) {
            throw const HostSetupException('HOST_READINESS_TIMEOUT');
          }

          try {
            await resumeStore.verifyAndBindExistingProfile(existing);
          } on HostSetupException catch (error) {
            if (!const {
              'AUTHENTICATION_REQUIRED',
              'UNAUTHENTICATED',
              'HOST_CREDENTIAL_EXPIRED',
              'HOST_AUTHENTICATION_REQUIRED',
              'HOST_AUTHENTICATION_FAILED',
              'HOST_SESSION_AUTHENTICATION_FAILED',
              'HOST_BOOTSTRAP_CREDENTIAL_UNAVAILABLE',
            }.contains(error.code)) {
              rethrow;
            }

            await AccountSignIn(
              credentials: resumeStore.credentials,
              profile: existing,
            ).online(_ownerUsername.text.trim(), _ownerPassword.text);
          }
        }
      }

      final configuredProfile = await coordinator.run(scope);
      final store = _credentialStore;
      if (store is LocalHostSetupCredentialStore) {
        final endpoint = Uri.parse(hostSetupEndpoint);
        final client = HostExtensionPackageClient(
          timeout: const Duration(seconds: 60),
          endpoint: endpoint,
          credentials: store.credentials,
        );
        final self = await client.account('manage', {'action': 'SELF'});

        if (self['isOwner'] != true) {
          throw const HostSetupException('HOST_ORGANIZATION_OWNER_REQUIRED');
        }

        await HostOrganizationInitializer(client).apply(
          scope: scope,
          organizationName: _organizationName.text.trim(),
          companyName: _companyName.text.trim(),
          branchName: _branchName.text.trim(),
        );
        if (self['isOwner'] == true && self['needsPassword'] == true) {
          await store.credentials.preserveEnrollment(endpoint);
          await client.account('manage', {
            'action': 'SET_LOGIN',
            'username': _ownerUsername.text.trim(),
            'password': _ownerPassword.text,
          });
        }

        await AccountSignIn(
          credentials: store.credentials,
          profile: configuredProfile,
        ).online(_ownerUsername.text.trim(), _ownerPassword.text);

        final verifiedOwner = await client.account('manage', {
          'action': 'SELF',
        });

        if (verifiedOwner['isOwner'] != true ||
            verifiedOwner['needsPassword'] != false) {
          throw const HostSetupException('HOST_OWNER_ACCOUNT_INCOMPLETE');
        }

        await store.store.clearHostSetupDraft(
          requesterSid: await _platform.currentUserSid(),
          tenantId: scope.tenantId,
          companyId: scope.companyId,
          branchId: scope.branchId,
        );

        _ownerPassword.clear();
        _ownerConfirm.clear();
      }
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
      debugPrint('HOST SETUP ERROR TYPE: ${error.runtimeType}');
      debugPrintStack(stackTrace: stack);
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
    if (failure is HostPackageTransportException &&
        RegExp(r'^[A-Z][A-Z0-9_]{0,79}$').hasMatch(failure.code)) {
      code = failure.code;
    }
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
      recommendedAction: safeCode == 'POSTGRES_PORT_IN_USE'
          ? 'Ask an authorized Windows operator to free local port 54329, then retry Host setup.'
          : 'Keep existing Host data intact. Share this sanitized report with an authorized Host operator before attempting recovery.',
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
    'POSTGRES_PORT_IN_USE',
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
          {
            'source': 'device',
            ...event.toJson(),
            'technicalDetails': {
              'exceptionType': event.protectedFailureType,
              'failureSource': event.protectedFailureSource,
              'technicalCode': event.protectedTechnicalCode,
            },
          },
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

  bool get _ownerIsValid =>
      _credentialStore is! LocalHostSetupCredentialStore ||
      (AccountPassword.validUsername(_ownerUsername.text.trim()) &&
          AccountPassword.validPassword(_ownerPassword.text) &&
          _ownerPassword.text == _ownerConfirm.text);

  void _nextStep() {
    FocusScope.of(context).unfocus();
    setState(() => _wizardStep++);
  }

  void _previousStep() {
    FocusScope.of(context).unfocus();
    setState(() => _wizardStep--);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const titles = [
      'native.ui.host_wizard_organization',
      'native.ui.host_wizard_owner',
      'native.ui.host_wizard_prepare',
    ];

    const descriptions = [
      'native.ui.host_wizard_organization_details',
      'native.ui.host_wizard_owner_details',
      'native.ui.host_wizard_prepare_details',
    ];

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const VentioText('native.ui.host_wizard_title'),
          automaticallyImplyLeading: !_busy,
        ),
        bottomNavigationBar:
            !_platform.supportsHostSetup || _checking || _restoringPendingScope
            ? null
            : SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 900;
                    return Container(
                      color: colors.surface,
                      padding: EdgeInsets.only(
                        left: wide ? 300 : 20,
                        right: wide ? 40 : 20,
                        top: 12,
                        bottom: 12,
                      ),
                      child: Center(
                        heightFactor: 1,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 920),
                          child: Row(
                            children: [
                              if (_wizardStep > 0 && !_complete)
                                OutlinedButton(
                                  onPressed: _busy ? null : _previousStep,
                                  child: const VentioText(
                                    'native.ui.host_wizard_back',
                                  ),
                                ),
                              const Spacer(),
                              if (_wizardStep < 2)
                                FilledButton(
                                  onPressed:
                                      _pendingScopeMismatch ||
                                          (_wizardStep == 0 &&
                                              (!_scopeIsValid ||
                                                  !_namesAreValid)) ||
                                          (_wizardStep == 1 && !_ownerIsValid)
                                      ? null
                                      : _nextStep,
                                  child: const VentioText(
                                    'native.ui.host_wizard_next',
                                  ),
                                )
                              else if (_complete)
                                FilledButton(
                                  onPressed: _finish,
                                  child: const VentioText(
                                    'native.ui.host_setup_open_workspace',
                                  ),
                                )
                              else
                                FilledButton(
                                  onPressed:
                                      _busy ||
                                          _pendingScopeMismatch ||
                                          !_scopeIsValid ||
                                          !_ownerIsValid
                                      ? null
                                      : _runSetup,
                                  child: const VentioText(
                                    'native.ui.host_setup_start',
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;

            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide) HostSetupSidebar(currentStep: _wizardStep),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.all(wide ? 40 : 20),
                    children: [
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 920),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              VentioText(
                                titles[_wizardStep],
                                style: const TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              VentioText(
                                descriptions[_wizardStep],
                                style: TextStyle(
                                  fontSize: 16,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 28),
                              if (!_platform.supportsHostSetup)
                                _messageCard(
                                  icon: Icons.desktop_windows_outlined,
                                  messageKey:
                                      'native.ui.host_setup_windows_only',
                                )
                              else if (_checking || _restoringPendingScope)
                                const Center(child: CircularProgressIndicator())
                              else ...[
                                _wizardProgress(context),
                                const SizedBox(height: 28),
                                if (_wizardStep == 0)
                                  _organizationFields(context),
                                if (_wizardStep == 1) _ownerFields(context),
                                if (_wizardStep == 2) ...[
                                  _prepareProgressCard(context),
                                  const SizedBox(height: 12),
                                  ExpansionTile(
                                    leading: const Icon(
                                      Icons.settings_outlined,
                                    ),
                                    title: const VentioText(
                                      'native.ui.host_wizard_technical_details',
                                    ),
                                    children: [
                                      _messageCard(
                                        icon: Icons.lock_outline,
                                        messageKey:
                                            'native.ui.host_setup_credential_privacy',
                                      ),
                                      _setupSteps(context),
                                      _serviceCard(
                                        context,
                                        titleKey:
                                            'native.ui.host_setup_postgres',
                                        state: _postgresState,
                                      ),
                                      _serviceCard(
                                        context,
                                        titleKey:
                                            'native.ui.host_setup_service',
                                        state: _hostState,
                                      ),
                                    ],
                                  ),
                                ],
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
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            VentioText(
                                              'native.ui.host_setup_diagnostic_reference',
                                              params: {
                                                'referenceId': _setupDiagnostic!
                                                    .correlationId,
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
                                                      child:
                                                          CircularProgressIndicator(
                                                            strokeWidth: 2,
                                                          ),
                                                    )
                                                  : const Icon(
                                                      Icons
                                                          .content_copy_outlined,
                                                    ),
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

                                if (_complete)
                                  _messageCard(
                                    icon: Icons.check_circle_outline,
                                    messageKey: 'native.ui.host_setup_complete',
                                  ),
                                const SizedBox(height: 24),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _prepareProgressCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    final stage = switch (_currentStep) {
      null => 0,
      HostSetupStep.administratorAccess => 0,
      HostSetupStep.postgresService => 1,
      HostSetupStep.hostService => 2,
      HostSetupStep.firstAdministrator ||
      HostSetupStep.credentialStorage ||
      HostSetupStep.hostReadiness ||
      HostSetupStep.complete => 3,
    };

    final progress = _complete
        ? 1.0
        : _currentStep == null
        ? 0.0
        : stage / 4.0;

    const stages = [
      'native.ui.host_progress_approval',
      'native.ui.host_progress_database',
      'native.ui.host_progress_services',
      'native.ui.host_progress_verification',
    ];

    final titleKey = _complete
        ? 'native.ui.host_progress_ready'
        : _busy
        ? 'native.ui.host_progress_setting_up'
        : _currentStep != null
        ? 'native.ui.host_progress_paused'
        : 'native.ui.host_progress_start_ready';

    return Card(
      color: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    _complete ? Icons.check_circle_outline : Icons.dns_outlined,
                    color: colors.primary,
                    size: 34,
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      VentioText(
                        titleKey,
                        style: const TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      VentioText(
                        _busy
                            ? stages[stage]
                            : _complete
                            ? 'native.ui.host_progress_finished'
                            : 'native.ui.host_progress_instruction',
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: progress),
                    duration: const Duration(milliseconds: 350),
                    builder: (context, value, child) => LinearProgressIndicator(
                      value: value,
                      minHeight: 12,
                      borderRadius: BorderRadius.circular(12),
                      backgroundColor: colors.surfaceContainerHighest,
                      color: colors.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                Text(
                  '${(progress * 100).round()}%',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < stages.length; i++) ...[
              if (i > 0) Divider(height: 1, color: colors.outlineVariant),
              _prepareStageRow(
                context,
                stages[i],
                completed: _complete || (_currentStep != null && i < stage),
                active: _busy && i == stage,
                failed: !_busy && !_complete && _errorKey != null && i == stage,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _prepareStageRow(
    BuildContext context,
    String labelKey, {
    required bool completed,
    required bool active,
    required bool failed,
  }) {
    final colors = Theme.of(context).colorScheme;

    final statusColor = failed
        ? colors.error
        : completed
        ? const Color(0xFF15803D)
        : active
        ? colors.primary
        : colors.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: active
            ? colors.primary.withValues(alpha: 0.06)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: active
                ? CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: colors.primary,
                  )
                : Icon(
                    completed
                        ? Icons.check_circle
                        : failed
                        ? Icons.error_outline
                        : Icons.radio_button_unchecked,
                    color: statusColor,
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: VentioText(
              labelKey,
              style: TextStyle(
                fontSize: 15,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(20),
            ),
            child: VentioText(
              completed
                  ? 'native.ui.host_progress_completed'
                  : active
                  ? 'native.ui.host_progress_running'
                  : failed
                  ? 'native.ui.host_progress_failed'
                  : 'native.ui.host_progress_pending',
              style: TextStyle(
                color: statusColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
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
              LinearProgressIndicator(
                value: _currentStep == HostSetupStep.complete
                    ? null
                    : _progressValue(_currentStep!),
              ),
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

  Widget _wizardProgress(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const titles = [
      'native.ui.host_wizard_organization',
      'native.ui.host_wizard_owner',
      'native.ui.host_wizard_prepare',
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < titles.length; i++) ...[
          Expanded(
            flex: 3,
            child: Column(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: i <= _wizardStep
                      ? colors.primary
                      : colors.surfaceContainerHighest,
                  foregroundColor: i <= _wizardStep
                      ? colors.onPrimary
                      : colors.onSurfaceVariant,
                  child: i < _wizardStep
                      ? const Icon(Icons.check)
                      : Text('${i + 1}'),
                ),
                const SizedBox(height: 10),
                VentioText(
                  titles[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: i == _wizardStep
                        ? colors.primary
                        : colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (i < titles.length - 1)
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.only(top: 21),
                child: Divider(
                  thickness: 2,
                  color: i < _wizardStep
                      ? colors.primary
                      : colors.outlineVariant,
                ),
              ),
            ),
        ],
      ],
    );
  }

  bool get _namesAreValid =>
      [_organizationName, _companyName, _branchName].every(
        (controller) =>
            controller.text.trim().isNotEmpty &&
            controller.text.trim().length <= 120,
      );

  Widget _organizationFields(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final editable = !_setupAttempted && !_pendingOperationFound;

    final organization = _wizardField(
      context,
      _organizationName,
      'native.ui.host_wizard_organization_name',
      enabled: editable,
      maxLength: 120,
    );

    final company = _wizardField(
      context,
      _companyName,
      'native.ui.host_wizard_company_name',
      enabled: editable,
      maxLength: 120,
    );

    return Card(
      color: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.business_outlined, color: colors.primary, size: 32),
                const SizedBox(width: 14),
                const Expanded(
                  child: VentioText(
                    'native.ui.host_wizard_organization',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 580) {
                  return Column(
                    children: [
                      organization,
                      const SizedBox(height: 16),
                      company,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: organization),
                    const SizedBox(width: 20),
                    Expanded(child: company),
                  ],
                );
              },
            ),
            const SizedBox(height: 20),
            _wizardField(
              context,
              _branchName,
              'native.ui.host_wizard_branch_name',
              enabled: editable,
              maxLength: 120,
            ),
            const SizedBox(height: 20),
            ExpansionTile(
              initiallyExpanded: _pendingOperationFound,
              leading: const Icon(Icons.settings_outlined),
              title: const VentioText('native.ui.host_wizard_advanced'),
              children: [
                const SizedBox(height: 12),
                _wizardField(
                  context,
                  _tenantId,
                  'native.ui.host_setup_tenant_id',
                  enabled: false,
                  maxLength: 256,
                ),
                const SizedBox(height: 16),
                _wizardField(
                  context,
                  _companyId,
                  'native.ui.host_setup_company_id',
                  enabled: false,
                  maxLength: 256,
                ),
                const SizedBox(height: 16),
                _wizardField(
                  context,
                  _branchId,
                  'native.ui.host_setup_branch_id',
                  enabled: false,
                  maxLength: 256,
                ),
                const SizedBox(height: 12),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _ownerFields(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.surface,
    elevation: 1,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    surfaceTintColor: Colors.transparent,
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _wizardField(
            context,
            _ownerUsername,
            'native.ui.account_owner_username',
          ),
          const SizedBox(height: 20),
          _wizardField(
            context,
            _ownerPassword,
            'native.ui.account_owner_password',
            secret: true,
          ),
          const SizedBox(height: 20),
          _wizardField(
            context,
            _ownerConfirm,
            'native.ui.account_confirm_owner_password',
            secret: true,
          ),
          const SizedBox(height: 16),
          const VentioText(
            'native.ui.account_organization_owner_account_choose_a_username_and_a_password_of_at_least_15_characters',
          ),
        ],
      ),
    ),
  );

  Widget _wizardField(
    BuildContext context,
    TextEditingController controller,
    String labelKey, {
    bool enabled = true,
    bool secret = false,
    int? maxLength,
  }) => TextField(
    key: ValueKey(labelKey),
    controller: controller,
    enabled: enabled && !_busy,
    obscureText: secret && !_showPassword,
    enableSuggestions: !secret,
    autocorrect: !secret,
    maxLength: maxLength,
    decoration: InputDecoration(
      labelText: context.ventioText(labelKey),
      counterText: '',
      suffixIcon: secret
          ? IconButton(
              onPressed: () {
                setState(() => _showPassword = !_showPassword);
              },
              icon: Icon(
                _showPassword
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            )
          : null,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
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
      (_stepOrder(step) / 7).clamp(0.0, 1.0).toDouble();

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
    'POSTGRES_PORT_IN_USE' => 'native.ui.host_setup_postgres_port_in_use',
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
