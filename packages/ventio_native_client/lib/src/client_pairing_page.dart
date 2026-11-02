import 'package:flutter/material.dart';
import 'package:ventio_core/ventio_core.dart';

import 'app_localization.dart';
import 'client_pairing.dart';
import 'extension_store.dart';
import 'host_credentials.dart';
import 'local_diagnostics.dart';

typedef ClientPairingClientFactory = ClientPairingClient Function(Uri endpoint);

class ClientPairingPage extends StatefulWidget {
  const ClientPairingPage({
    required this.store,
    required this.credentials,
    this.initialEndpoint,
    this.diagnosticEventSource,
    this.clientFactory,
    super.key,
  });

  final LocalExtensionStore store;
  final HostCredentialVault credentials;
  final String? initialEndpoint;
  final DiagnosticEventSource? diagnosticEventSource;
  final ClientPairingClientFactory? clientFactory;

  @override
  State<ClientPairingPage> createState() => _ClientPairingPageState();
}

class _ClientPairingPageState extends State<ClientPairingPage> {
  late final TextEditingController _endpoint = TextEditingController(
    text: widget.initialEndpoint ?? '',
  );
  final TextEditingController _fingerprint = TextEditingController();
  final TextEditingController _code = TextEditingController();
  ClientPairingException? _error;
  ClientPairingResult? _result;
  bool _submitting = false;

  @override
  void dispose() {
    _endpoint.dispose();
    _fingerprint.dispose();
    _code.dispose();
    super.dispose();
  }

  ClientPairingClient _client(Uri endpoint) =>
      widget.clientFactory?.call(endpoint) ??
      ClientPairingClient(
        endpoint: endpoint,
        credentials: widget.credentials,
        store: widget.store,
        expectedCertificateFingerprint: _fingerprint.text,
      );

  Future<void> _enroll() async {
    if (_submitting || _result != null) return;
    final endpointText = _endpoint.text.trim();
    final endpoint = Uri.tryParse(endpointText);
    if (endpoint == null ||
        !endpoint.isAbsolute ||
        endpoint.scheme != 'https') {
      setState(() {
        _error = const ClientPairingException('HOST_HTTPS_REQUIRED');
      });
      return;
    }
    final code = _code.text;
    if (code.trim().isEmpty) {
      setState(() {
        _error = const ClientPairingException('PAIRING_CODE_REQUIRED');
      });
      return;
    }
    if (widget.clientFactory == null &&
        HostCredentialVault.normalizeFingerprint(_fingerprint.text) == null) {
      setState(() {
        _error = const ClientPairingException('HOST_TLS_FINGERPRINT_REQUIRED');
      });
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final client = _client(endpoint);
      final result = await client.redeemAndSave(code: code);
      if (!mounted) return;
      setState(() {
        _result = result;
        _submitting = false;
      });
    } on ClientPairingException catch (error) {
      final safeError = _withCorrelation(error);
      await _recordFailure(safeError);
      if (!mounted) return;
      setState(() {
        _error = safeError;
        _submitting = false;
      });
    } on ArgumentError {
      final error = ClientPairingException(
        'HOST_HTTPS_REQUIRED',
        correlationId: newLocalCorrelationId(),
      );
      await _recordFailure(error);
      if (!mounted) return;
      setState(() {
        _error = error;
        _submitting = false;
      });
    } catch (_) {
      final error = ClientPairingException(
        'CLIENT_ENROLLMENT_FAILED',
        correlationId: newLocalCorrelationId(),
      );
      await _recordFailure(error);
      if (!mounted) return;
      setState(() {
        _error = error;
        _submitting = false;
      });
    } finally {
      // Pairing codes are one-time secrets; clear the editable control after
      // every attempt so it is not left in the widget tree or copied later.
      if (mounted) {
        _code.clear();
        if (_submitting) setState(() => _submitting = false);
      }
    }
  }

  ClientPairingException _withCorrelation(ClientPairingException error) =>
      error.correlationId != null
      ? error
      : ClientPairingException(
          error.code,
          statusCode: error.statusCode,
          correlationId: newLocalCorrelationId(),
          retryable: error.retryable,
        );

  Future<void> _recordFailure(ClientPairingException error) async {
    final safeCode = _safeCode(error.code);
    final correlationId = error.correlationId ?? newLocalCorrelationId();
    final source = widget.diagnosticEventSource;
    LocalDiagnosticsStore? ownedStore;
    try {
      final eventSource =
          source ?? (ownedStore = await openDefaultLocalDiagnosticsStore());
      final category = switch (safeCode) {
        'HOST_TLS_VALIDATION_FAILED' ||
        'HOST_TLS_FINGERPRINT_REQUIRED' ||
        'HOST_HTTPS_REQUIRED' ||
        'HOST_UNREACHABLE' ||
        'HOST_REQUEST_TIMEOUT' => ManagementDiagnosticCategory.networkTls,
        'CLIENT_CREDENTIAL_STORAGE_FAILED' =>
          ManagementDiagnosticCategory.credentials,
        'CLIENT_PROFILE_READ_FAILED' || 'CLIENT_ENROLLMENT_SAVE_FAILED' =>
          ManagementDiagnosticCategory.sqlitePersistence,
        'PAIRING_INVALID_OR_EXPIRED' ||
        'PAIRING_RATE_LIMITED' ||
        'DEVICE_ALREADY_REGISTERED' ||
        'PAIRING_CODE_INVALID_FORMAT' ||
        'PAIRING_CODE_REQUIRED' => ManagementDiagnosticCategory.pairing,
        _ => ManagementDiagnosticCategory.apiExecution,
      };
      final explanation = switch (safeCode) {
        'PAIRING_INVALID_OR_EXPIRED' =>
          'The pairing code is invalid, expired, or already used.',
        'HOST_TLS_VALIDATION_FAILED' =>
          'The Host certificate could not be validated.',
        'HOST_TLS_FINGERPRINT_REQUIRED' =>
          'A valid Host TLS certificate SHA-256 fingerprint is required.',
        'HOST_HTTPS_REQUIRED' =>
          'Client enrollment requires an HTTPS Host address.',
        'CLIENT_CREDENTIAL_STORAGE_FAILED' || 'CLIENT_ENROLLMENT_SAVE_FAILED' =>
          'The Client enrollment could not be saved securely on this device.',
        _ => 'Client enrollment could not be completed.',
      };
      final recommendedAction = switch (safeCode) {
        'PAIRING_INVALID_OR_EXPIRED' =>
          'Ask the Host administrator to generate a new pairing code, then retry.',
        'PAIRING_RATE_LIMITED' =>
          'Wait before trying again. Request a new code if the current code expires.',
        'DEVICE_ALREADY_REGISTERED' =>
          'Use a fresh Client device setup or ask the Host administrator to review the registered device.',
        'HOST_TLS_VALIDATION_FAILED' =>
          'Check the Host address and its trusted TLS certificate. Do not bypass certificate checks.',
        'HOST_TLS_FINGERPRINT_REQUIRED' =>
          'Copy the SHA-256 fingerprint from Host Settings and enter it before enrolling.',
        'HOST_UNREACHABLE' || 'HOST_REQUEST_TIMEOUT' =>
          'Check the network and Host service, then retry with a current pairing code.',
        'CLIENT_CREDENTIAL_STORAGE_FAILED' || 'CLIENT_ENROLLMENT_SAVE_FAILED' =>
          'Check secure device storage, then request a fresh pairing code before retrying.',
        _ =>
          'Retry with a valid pairing code. Share the reference with a Host administrator if the problem continues.',
      };
      await eventSource.record(
        LocalDiagnosticInput(
          code: safeCode,
          component: 'client.pairing',
          category: category,
          severity: ManagementDiagnosticSeverity.error,
          retryable: error.retryable,
          messageKey: 'native.diagnostics.host_sync_failed',
          safeExplanation: explanation,
          recommendedAction: recommendedAction,
          correlationId: correlationId,
        ),
      );
    } catch (_) {
      // Enrollment failure remains visible even if local diagnostics cannot be
      // written. Diagnostic paths never receive the code or credential.
    } finally {
      try {
        await ownedStore?.close();
      } catch (_) {
        // Keep the primary safe pairing error visible.
      }
    }
  }

  static String _safeCode(String code) =>
      const {
        'HOST_HTTPS_REQUIRED',
        'HOST_TLS_FINGERPRINT_REQUIRED',
        'HOST_TLS_VALIDATION_FAILED',
        'HOST_UNREACHABLE',
        'HOST_REQUEST_TIMEOUT',
        'HOST_API_VERSION_MISMATCH',
        'HOST_INVALID_RESPONSE',
        'HOST_RESPONSE_TOO_LARGE',
        'HOST_HTTP_ERROR',
        'HOST_UNAVAILABLE',
        'PAIRING_CODE_INVALID_FORMAT',
        'PAIRING_CODE_REQUIRED',
        'PAIRING_INVALID_OR_EXPIRED',
        'PAIRING_RATE_LIMITED',
        'DEVICE_ALREADY_REGISTERED',
        'CLIENT_DEVICE_ID_INVALID',
        'CLIENT_PROFILE_READ_FAILED',
        'CLIENT_CREDENTIAL_STORAGE_FAILED',
        'CLIENT_ENROLLMENT_SAVE_FAILED',
        'CLIENT_ENROLLMENT_FAILED',
      }.contains(code)
      ? code
      : 'CLIENT_ENROLLMENT_FAILED';

  String _errorText(ClientPairingException error) {
    final key = switch (error.code) {
      'HOST_HTTPS_REQUIRED' => 'native.ui.client_pairing_https_required',
      'HOST_TLS_FINGERPRINT_REQUIRED' =>
        'native.ui.client_pairing_fingerprint_required',
      'PAIRING_CODE_REQUIRED' ||
      'PAIRING_CODE_INVALID_FORMAT' => 'native.ui.client_pairing_code_invalid',
      'PAIRING_INVALID_OR_EXPIRED' => 'native.ui.client_pairing_code_expired',
      'PAIRING_RATE_LIMITED' => 'native.ui.client_pairing_rate_limited',
      'DEVICE_ALREADY_REGISTERED' =>
        'native.ui.client_pairing_device_registered',
      'HOST_TLS_VALIDATION_FAILED' => 'native.ui.client_pairing_tls_failed',
      'HOST_UNREACHABLE' ||
      'HOST_REQUEST_TIMEOUT' ||
      'HOST_UNAVAILABLE' => 'native.ui.client_pairing_host_unreachable',
      'HOST_API_VERSION_MISMATCH' =>
        'native.ui.client_pairing_version_mismatch',
      'CLIENT_CREDENTIAL_STORAGE_FAILED' ||
      'CLIENT_ENROLLMENT_SAVE_FAILED' ||
      'CLIENT_PROFILE_READ_FAILED' =>
        'native.ui.client_pairing_local_save_failed',
      _ => 'native.ui.client_pairing_failed',
    };
    final message = context.ventioText(key);
    final correlationId = error.correlationId;
    if (correlationId == null) return message;
    return '$message\n${context.ventioText('native.ui.correlation_reference', params: {'correlationId': correlationId})}';
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_submitting,
    child: Scaffold(
      appBar: AppBar(title: const VentioText('native.ui.enroll_client')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.ventioText('native.ui.client_pairing_heading'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      const VentioText('native.ui.client_pairing_explanation'),
                      const SizedBox(height: 10),
                      const VentioText(
                        'native.ui.client_role_is_not_permission',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_result case final result?)
                _successCard(result)
              else ...[
                TextField(
                  key: const ValueKey('client-pairing-host'),
                  controller: _endpoint,
                  enabled: !_submitting,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: context.ventioText('native.ui.host_origin'),
                    hintText: 'https://ventio-host.example.com:8443',
                    helperText: context.ventioText(
                      'native.ui.client_pairing_https_only',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('client-pairing-fingerprint'),
                  controller: _fingerprint,
                  enabled: !_submitting,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: context.ventioText(
                      'native.ui.client_pairing_fingerprint',
                    ),
                    helperText: context.ventioText(
                      'native.ui.client_pairing_fingerprint_help',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('client-pairing-code'),
                  controller: _code,
                  enabled: !_submitting,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  decoration: InputDecoration(
                    labelText: context.ventioText(
                      'native.ui.client_pairing_code',
                    ),
                    helperText: context.ventioText(
                      'native.ui.client_pairing_single_use',
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (_error case final error?) ...[
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.ventioText(
                              'native.ui.client_pairing_failed_title',
                            ),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 6),
                          SelectableText(_errorText(error)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                FilledButton.icon(
                  key: const ValueKey('client-pairing-submit'),
                  onPressed: _submitting ? null : _enroll,
                  icon: _submitting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.phonelink_setup_outlined),
                  label: Text(
                    context.ventioText(
                      _submitting
                          ? 'native.ui.client_pairing_enrolling'
                          : 'native.ui.enroll_client',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );

  Widget _successCard(ClientPairingResult result) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle_outline),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.ventioText('native.ui.client_pairing_success'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            context.ventioText(
              'native.ui.client_pairing_scope',
              params: {
                'companyId': result.profile.companyId,
                'branchId': result.profile.branchId,
              },
            ),
          ),
          const SizedBox(height: 6),
          Text(
            context.ventioText(
              'native.ui.client_pairing_credential_expiry',
              params: {'timestamp': _formatUtc(result.expiresAtUtc)},
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            context.ventioText(
              'native.ui.correlation_reference',
              params: {'correlationId': result.correlationId},
            ),
          ),
          const SizedBox(height: 14),
          const VentioText('native.ui.client_pairing_success_details'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const VentioText('native.ui.done'),
          ),
        ],
      ),
    ),
  );
}

String _formatUtc(DateTime timestamp) {
  final utc = timestamp.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} UTC';
}
