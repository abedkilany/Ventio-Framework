import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ventio_core/ventio_core.dart';

import 'app_localization.dart';
import 'client_credential_reissue.dart';
import 'extension_store.dart';
import 'host_credentials.dart';
import 'host_device_management.dart';
import 'performance_probe.dart';
import 'host_setup.dart';
import 'host_setup_windows.dart';
import 'host_user_management.dart';
import 'local_diagnostics.dart';

class DeviceManagementPage extends StatefulWidget {
  const DeviceManagementPage({
    required this.client,
    this.userDirectory,
    this.diagnosticEventSource,
    this.pairingRequestStateStore,
    super.key,
  });

  final HostDeviceManagementClient client;
  final HostUserManagementClient? userDirectory;
  final DiagnosticEventSource? diagnosticEventSource;
  final PairingRequestStateStore? pairingRequestStateStore;

  @override
  State<DeviceManagementPage> createState() => _DeviceManagementPageState();
}

class _DeviceManagementPageState extends State<DeviceManagementPage> {
  final _actorId = TextEditingController();
  HostDeviceSnapshot? _snapshot;
  Map<String, PendingHostCredentialReissue> _pendingCredentialReissues = {};
  List<HostManagedUser> _users = const [];
  String? _selectedUserId;
  HostPairingCredential? _pairing;
  List<String>? _trustedPairingPermissions;
  HostRotatedDeviceCredential? _rotatedCredential;
  WindowsTrustedCredentialReissueResult? _credentialReissue;
  String? _credentialReissueCode;
  String? _credentialReissueOperationId;
  HostDeviceManagementException? _error;
  bool _loading = false;
  bool _loadingUsers = false;
  bool _userDirectoryFailed = false;
  bool _busy = false;
  bool _restoringPairingRequest = false;
  String? _pairingRequestId;
  String? _pendingPairingActorId;
  DateTime? _pairingCodeExpiresAtUtc;
  Timer? _pairingExpiryTimer;

  @override
  void initState() {
    super.initState();
    final initialization = <Future<void>>[];
    if (_pairingStateStore != null) {
      _restoringPairingRequest = true;
      initialization.add(
        VentioPerformanceProbe.measure(
          'pairing.page.restore_request',
          _restorePairingRequest,
        ),
      );
    }
    if (widget.client.canManageDevices) {
      initialization.add(
        VentioPerformanceProbe.measure('pairing.page.devices_load', _load),
      );
    }
    if (widget.userDirectory?.canManageUsers ?? false) {
      initialization.add(
        VentioPerformanceProbe.measure('pairing.page.users_load', _loadUsers),
      );
    }
    unawaited(
      VentioPerformanceProbe.measure('pairing.page.initialize', () async {
        await Future.wait(initialization);
      }),
    );
  }

  Future<void> _restorePairingRequest() async {
    try {
      final store = _pairingStateStore;
      if (store != null) {
        final pending = await store.pendingPairingOperation(
          _pairingIdentityKey,
        );
        if (mounted && pending != null) {
          final validActor = _safePairingActorId(pending.actorId)
              ? pending.actorId
              : null;
          setState(() {
            _pairingRequestId = pending.requestId;
            _pendingPairingActorId = validActor;
            if (validActor == null) {
              // A request written by an older app version did not preserve its
              // target. Keep it unretryable until the full code lifetime has
              // elapsed, then allow a safe replacement.
              _pairingCodeExpiresAtUtc = DateTime.now().toUtc().add(
                const Duration(minutes: 5),
              );
            } else {
              _actorId.text = validActor;
            }
          });
          if (validActor == null) {
            _schedulePairingExpiryRefresh(_pairingCodeExpiresAtUtc);
          }
        }
      }
    } catch (_) {
      // Pairing remains available when the optional diagnostic store cannot be
      // read; the in-memory request ID still makes same-session retries safe.
    } finally {
      if (mounted) setState(() => _restoringPairingRequest = false);
    }
  }

  String get _pairingIdentityKey => sha256
      .convert(
        utf8.encode(
          [
            widget.client.endpoint.toString(),
            widget.client.verifiedIdentity.tenantId,
            widget.client.verifiedIdentity.actorId,
            widget.client.verifiedIdentity.deviceId,
            widget.client.companyId,
            widget.client.branchId,
          ].join('\n'),
        ),
      )
      .toString();

  PairingRequestStateStore? get _pairingStateStore =>
      widget.pairingRequestStateStore ??
      (widget.diagnosticEventSource is PairingRequestStateStore
          ? widget.diagnosticEventSource! as PairingRequestStateStore
          : null);

  Future<void> _savePairingRequestId(String requestId) async {
    final store = _pairingStateStore;
    if (store != null) {
      final actorId = _pendingPairingActorId;
      if (actorId == null) {
        throw StateError('Pending pairing target is missing.');
      }
      await store.savePendingPairingOperation(
        _pairingIdentityKey,
        requestId,
        actorId,
      );
      return;
    }
    throw StateError('Durable pending pairing storage is unavailable.');
  }

  Future<void> _clearPairingRequestId() async {
    final store = _pairingStateStore;
    if (store != null) {
      await store.clearPendingPairingOperation(_pairingIdentityKey);
      return;
    }
    throw StateError('Durable pending pairing storage is unavailable.');
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
    } catch (_) {
      if (mounted) {
        setState(() {
          _userDirectoryFailed = true;
          _error = const HostDeviceManagementException('HOST_INVALID_RESPONSE');
        });
      }
    } finally {
      if (mounted) setState(() => _loadingUsers = false);
    }
  }

  @override
  void dispose() {
    _pairingExpiryTimer?.cancel();
    _actorId.dispose();
    super.dispose();
  }

  void _schedulePairingExpiryRefresh(DateTime? expiresAtUtc) {
    _pairingExpiryTimer?.cancel();
    if (expiresAtUtc == null) return;
    final delay = expiresAtUtc.toUtc().difference(DateTime.now().toUtc());
    if (delay <= Duration.zero) return;
    _pairingExpiryTimer = Timer(delay, () {
      if (mounted) setState(() {});
    });
  }

  Future<void> _load() async {
    if (!widget.client.canManageDevices || _loading || _busy) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await widget.client.listDevices();
      final pendingReissues = <String, PendingHostCredentialReissue>{};
      for (final device in snapshot.devices) {
        final pending = await widget.client.credentials
            .readPendingCredentialReissueRequest(
              widget.client.endpoint,
              device.deviceId,
            );
        if (pending != null) pendingReissues[device.deviceId] = pending;
      }
      if (mounted) {
        setState(() {
          _snapshot = snapshot;
          _pendingCredentialReissues = pendingReissues;
        });
      }
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

  Future<void> _createPairing() => VentioPerformanceProbe.measure(
    'pairing.code.generate',
    _createPairingImpl,
  );

  Future<void> _createPairingImpl() async {
    if (_busy || _restoringPairingRequest || !widget.client.canCreatePairings) {
      return;
    }
    if (_pairingStateStore == null) {
      if (mounted) {
        setState(
          () => _error = const HostDeviceManagementException(
            'LOCAL_PAIRING_STATE_UNAVAILABLE',
          ),
        );
      }
      return;
    }
    final previousRequestId = _pairingRequestId;
    final now = DateTime.now().toUtc();
    final previousWindowExpired =
        previousRequestId != null &&
        _pairingCodeExpiresAtUtc != null &&
        !_pairingCodeExpiresAtUtc!.isAfter(now);
    final actorId = previousRequestId != null && !previousWindowExpired
        ? (_pendingPairingActorId ?? '')
        : widget.userDirectory?.canManageUsers == true
        ? (_selectedUserId ?? '')
        : _actorId.text.trim();
    if (previousRequestId != null &&
        _pairingCodeExpiresAtUtc?.isAfter(now) == true) {
      return;
    }
    if (previousWindowExpired) {
      await _recordPairingDiagnostic(
        code: 'PAIRING_REQUEST_ABANDONED',
        correlationId: previousRequestId,
        severity: ManagementDiagnosticSeverity.info,
        retryable: false,
        safeExplanation:
            'The previous one-time pairing window expired before a replacement was requested.',
        recommendedAction: 'No pairing secret is stored in local diagnostics.',
      );
    }
    final requestId = previousWindowExpired
        ? newPairingRequestId()
        : previousRequestId ?? newPairingRequestId();
    try {
      _pendingPairingActorId = actorId;
      await _savePairingRequestId(requestId);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = const HostDeviceManagementException(
            'LOCAL_PAIRING_STATE_UNAVAILABLE',
          ),
        );
      }
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _pairing = null;
      _trustedPairingPermissions = null;
      _pairingRequestId = requestId;
      _pairingCodeExpiresAtUtc = null;
    });
    _pairingExpiryTimer?.cancel();
    await _recordPairingDiagnostic(
      code: 'PAIRING_REQUEST_STARTED',
      correlationId: requestId,
      severity: ManagementDiagnosticSeverity.info,
      retryable: false,
      safeExplanation: 'A Client pairing request started from this device.',
      recommendedAction:
          'Use the same request reference to reconcile an unknown outcome.',
    );
    final requestWatch = Stopwatch()..start();
    try {
      final pairing = await widget.client.createPairing(
        actorId,
        requestId: requestId,
      );
      if (!mounted) return;
      setState(() {
        _pairing = pairing;
        _pairingRequestId = null;
        _pendingPairingActorId = null;
        _pairingCodeExpiresAtUtc = null;
      });
      try {
        await _clearPairingRequestId();
      } catch (_) {
        // The code remains available in memory. A stale durable request ID is
        // safe: the Host will refuse to create a second code for that ID.
      }
      await _recordPairingDiagnostic(
        code: 'PAIRING_CREATED',
        correlationId: requestId,
        severity: ManagementDiagnosticSeverity.info,
        retryable: false,
        safeExplanation:
            'Host returned a one-time pairing code after ${requestWatch.elapsedMilliseconds}ms.',
        recommendedAction:
            'The code is displayed once and is not included in diagnostics.',
      );
    } on HostDeviceManagementException catch (error) {
      if (mounted) {
        final unavailableExpiry = error.code == 'PAIRING_CODE_UNAVAILABLE'
            ? error.pairingExpiresAtUtc ??
                  DateTime.now().toUtc().add(const Duration(minutes: 5))
            : null;
        setState(() {
          _error = error;
          final unresolved =
              error.outcomeUnknown ||
              error.code == 'PAIRING_CODE_UNAVAILABLE' ||
              previousRequestId != null;
          if (unresolved) {
            _pairingRequestId = requestId;
            _pendingPairingActorId = actorId;
            _pairingCodeExpiresAtUtc = unavailableExpiry;
          } else {
            _pairingRequestId = null;
            _pendingPairingActorId = null;
            _pairingCodeExpiresAtUtc = null;
          }
        });
      }
      if (error.code == 'PAIRING_CODE_UNAVAILABLE' && mounted) {
        _schedulePairingExpiryRefresh(_pairingCodeExpiresAtUtc);
      }
      final unknown =
          error.outcomeUnknown ||
          error.code == 'PAIRING_CODE_UNAVAILABLE' ||
          previousRequestId != null;
      if (!unknown) {
        try {
          await _clearPairingRequestId();
        } catch (_) {
          // Reusing this reference is safe if local cleanup must be retried.
        }
      }
      await _recordPairingDiagnostic(
        code: unknown
            ? error.code == 'PAIRING_CODE_UNAVAILABLE'
                  ? 'PAIRING_CODE_UNAVAILABLE'
                  : 'PAIRING_OUTCOME_UNKNOWN'
            : 'PAIRING_REQUEST_REJECTED',
        correlationId: requestId,
        severity: unknown
            ? ManagementDiagnosticSeverity.error
            : ManagementDiagnosticSeverity.warning,
        retryable: error.retryable,
        safeExplanation: unknown
            ? 'The Host may have accepted the pairing request, but the one-time code was not received or the existing request could not be reconciled.'
            : 'The Host did not create a pairing code for this request.',
        recommendedAction: unknown
            ? 'Keep the same request reference and target when checking again. If the Host reports that the code is unavailable, wait for its five-minute validity window before issuing a replacement.'
            : 'Resolve the reported Host or Recovery Authority error before creating another request.',
        elapsedMs: error.elapsedMs ?? requestWatch.elapsedMilliseconds,
      );
    } catch (_) {
      final unknown = HostDeviceManagementException(
        'PAIRING_OUTCOME_UNKNOWN',
        correlationId: requestId,
        retryable: true,
        requestId: requestId,
        elapsedMs: requestWatch.elapsedMilliseconds,
      );
      if (mounted) {
        setState(() {
          _pairingRequestId = requestId;
          _pendingPairingActorId = actorId;
          _pairingCodeExpiresAtUtc = null;
          _error = unknown;
        });
      }
      await _recordPairingDiagnostic(
        code: 'PAIRING_OUTCOME_UNKNOWN',
        correlationId: requestId,
        severity: ManagementDiagnosticSeverity.error,
        retryable: true,
        safeExplanation:
            'The pairing operation did not return a validated result; the Host may have accepted it.',
        recommendedAction:
            'Keep the same request reference and target when checking again. Do not create a replacement until the outcome is reconciled.',
        elapsedMs: requestWatch.elapsedMilliseconds,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createTrustedPairing() async {
    if (_busy ||
        !Platform.isWindows ||
        !widget.client.canCreatePairings ||
        widget.userDirectory?.canManageUsers != true ||
        _selectedUserId == null) {
      return;
    }
    final permissions = await showDialog<List<String>>(
      context: context,
      builder: (context) => _TrustedPairingPermissionsDialog(
        tenantId: widget.client.verifiedIdentity.tenantId,
        companyId: widget.client.companyId,
        branchId: widget.client.branchId,
      ),
    );
    if (permissions == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _pairing = null;
      _trustedPairingPermissions = null;
    });
    try {
      final token = await widget.client.credentials.read(
        widget.client.endpoint,
      );
      if (token == null || token.isEmpty) {
        throw const HostSetupException('HOST_CREDENTIAL_MISSING');
      }
      final operationId = newPairingRequestId().substring(4);
      final pairing = await WindowsTrustedPairingOperator().createPairing(
        operationId: operationId,
        tenantId: widget.client.verifiedIdentity.tenantId,
        operatorActorId: widget.client.verifiedIdentity.actorId,
        targetActorId: _selectedUserId!,
        companyId: widget.client.companyId,
        branchId: widget.client.branchId,
        permissions: permissions,
        operatorCredentialDigest: sha256.convert(utf8.encode(token)).toString(),
      );
      if (pairing == null || !mounted) return; // Windows UAC was cancelled.
      setState(() {
        _pairing = HostPairingCredential(
          pairingId: pairing.pairingId,
          actorId: pairing.actorId,
          code: pairing.code,
          expiresAtUtc: pairing.expiresAtUtc,
          correlationId: 'cor_$operationId',
        );
        _trustedPairingPermissions = pairing.permissions;
      });
      await _recordPairingDiagnostic(
        code: 'TRUSTED_PAIRING_CREATED',
        correlationId: 'cor_$operationId',
        severity: ManagementDiagnosticSeverity.info,
        retryable: false,
        safeExplanation:
            'A Windows administrator approved a new Client pairing with an exact permission ceiling.',
        recommendedAction:
            'Enroll the intended Client with this one-time code. Existing devices and credentials remain active until explicitly revoked.',
      );
    } on HostSetupException catch (error) {
      if (mounted) {
        setState(() => _error = HostDeviceManagementException(error.code));
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = const HostDeviceManagementException(
            'HOST_TRUSTED_PAIRING_FAILED',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recordPairingDiagnostic({
    required String code,
    required String correlationId,
    required ManagementDiagnosticSeverity severity,
    required bool retryable,
    required String safeExplanation,
    required String recommendedAction,
    int? elapsedMs,
  }) async {
    final source = widget.diagnosticEventSource;
    if (source == null) return;
    try {
      await source.record(
        LocalDiagnosticInput(
          code: code,
          component: 'client.pairing',
          category: ManagementDiagnosticCategory.pairing,
          severity: severity,
          retryable: retryable,
          messageKey: 'native.diagnostics.pairing_request',
          safeExplanation: elapsedMs == null
              ? safeExplanation
              : '$safeExplanation Duration: ${elapsedMs}ms.',
          recommendedAction: recommendedAction,
          correlationId: correlationId,
        ),
      );
    } catch (_) {
      // Local diagnostics are helpful but never become pairing authority.
    }
  }

  bool _safePairingActorId(String value) =>
      value.length <= 256 &&
      value.trim().isNotEmpty &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(value);

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

  Future<void> _trustedReissueCredential(
    HostManagedDevice device,
    HostManagedCredential credential,
  ) async {
    const additionalPermission = 'extension.package.read';
    final pendingForDevice = _pendingCredentialReissues[device.deviceId];
    final isRecoverableSource =
        pendingForDevice?.sourceCredentialId == credential.credentialId;
    if (_busy ||
        !Platform.isWindows ||
        !widget.client.canManageDevices ||
        device.state != HostManagedDeviceState.registered ||
        (credential.state != HostManagedCredentialState.active &&
            !(credential.state == HostManagedCredentialState.rotated &&
                isRecoverableSource)) ||
        credential.permissions.contains(additionalPermission)) {
      return;
    }
    final retained = credential.permissions.toSet();
    final requested = {...retained, additionalPermission}.toList()..sort();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.ventioText('native.ui.reissue_credential_title')),
        content: Text(
          context.ventioText(
            'native.ui.reissue_credential_confirmation',
            params: {
              'deviceId': device.deviceId,
              'tenantId': widget.client.verifiedIdentity.tenantId,
              'actorId': device.actorId,
              'companyId': widget.client.companyId,
              'branchId': widget.client.branchId,
              'permissions': requested.join(', '),
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.ventioText('native.ui.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              context.ventioText('native.ui.authorize_credential_update'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _credentialReissue = null;
      _credentialReissueCode = null;
    });
    String? operationId;
    try {
      final profile = HostConnectionProfile(
        endpoint: widget.client.endpoint.toString(),
        tenantId: widget.client.verifiedIdentity.tenantId,
        actorId: device.actorId,
        deviceId: device.deviceId,
        companyId: widget.client.companyId,
        branchId: widget.client.branchId,
      );
      final previous = await widget.client.credentials
          .readPendingCredentialReissueRequest(
            widget.client.endpoint,
            device.deviceId,
          );
      if (previous != null) {
        if (previous.tenantId != profile.tenantId ||
            previous.actorId != device.actorId ||
            previous.deviceId != device.deviceId ||
            previous.companyId != profile.companyId ||
            previous.branchId != profile.branchId ||
            previous.sourceCredentialId != credential.credentialId ||
            previous.approvedRemovals.isNotEmpty ||
            previous.permissions
                .toSet()
                .difference(requested.toSet())
                .isNotEmpty ||
            requested
                .toSet()
                .difference(previous.permissions.toSet())
                .isNotEmpty) {
          throw const HostSetupException(
            'HOST_TRUSTED_REISSUE_RECONCILIATION_REQUIRED',
          );
        }
        operationId = previous.operationId;
      } else {
        operationId = newPairingRequestId().substring(4);
        await widget.client.credentials.savePendingCredentialReissueRequest(
          widget.client.endpoint,
          operationId: operationId,
          tenantId: profile.tenantId,
          actorId: device.actorId,
          deviceId: device.deviceId,
          sourceCredentialId: credential.credentialId,
          companyId: profile.companyId,
          branchId: profile.branchId,
          permissions: requested,
          approvedRemovals: const [],
        );
      }
      final token = await widget.client.credentials.read(
        widget.client.endpoint,
      );
      if (token == null || token.isEmpty) {
        throw const HostSetupException('HOST_CREDENTIAL_MISSING');
      }
      final pending = await widget.client.credentials
          .readPendingCredentialReissueRequest(
            widget.client.endpoint,
            device.deviceId,
          );
      final effectivePermissions = pending?.permissions ?? requested;
      final effectiveRemovals = pending?.approvedRemovals ?? const <String>[];
      final result = await WindowsTrustedCredentialReissueOperator().request(
        operationId: operationId,
        tenantId: profile.tenantId,
        operatorActorId: widget.client.verifiedIdentity.actorId,
        targetActorId: device.actorId,
        companyId: profile.companyId,
        branchId: profile.branchId,
        deviceId: device.deviceId,
        sourceCredentialId: credential.credentialId,
        permissions: effectivePermissions,
        approvedRemovals: effectiveRemovals,
        operatorCredentialDigest: sha256.convert(utf8.encode(token)).toString(),
      );
      if (!mounted) return;
      if (result == null) {
        setState(() => _credentialReissueCode = 'UAC_APPROVAL_CANCELLED');
        return;
      }
      setState(() {
        _credentialReissue = result;
        _credentialReissueOperationId = result.operationId;
      });
      if (result.state == 'FINALIZED' ||
          result.state == 'EXPIRED' ||
          result.state == 'REJECTED') {
        await widget.client.credentials.clearPendingCredentialReissueRequest(
          widget.client.endpoint,
          device.deviceId,
        );
      }
      try {
        await _loadAfterMutation();
      } catch (_) {
        // The transition outcome remains visible even if inventory refresh fails.
      }
    } on HostSetupException catch (error) {
      if (mounted) {
        setState(() {
          _credentialReissueCode = error.code;
          _credentialReissueOperationId = operationId;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _credentialReissueCode = 'HOST_TRUSTED_REISSUE_FAILED';
          _credentialReissueOperationId = operationId;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkCredentialUpdate() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _credentialReissueCode = null;
      _credentialReissue = null;
    });
    final identity = widget.client.verifiedIdentity;
    final profile = HostConnectionProfile(
      endpoint: widget.client.endpoint.toString(),
      tenantId: identity.tenantId,
      actorId: identity.actorId,
      deviceId: identity.deviceId,
      companyId: widget.client.companyId,
      branchId: widget.client.branchId,
    );
    try {
      final result = await ClientCredentialReissueClient(
        profile: profile,
        credentials: widget.client.credentials,
        exchange: widget.client.exchange,
      ).checkAndApply();
      if (!mounted) return;
      setState(() {
        _credentialReissueCode = switch (result.state) {
          ClientCredentialReissueState.none => 'NO_CREDENTIAL_UPDATE',
          ClientCredentialReissueState.applied => 'CREDENTIAL_UPDATE_APPLIED',
          ClientCredentialReissueState.staged => 'CREDENTIAL_UPDATE_STAGED',
          ClientCredentialReissueState.rejected =>
            result.code ?? 'REISSUE_REJECTED',
        };
        _credentialReissueOperationId = result.operationId;
      });
      if (result.state == ClientCredentialReissueState.applied ||
          result.state == ClientCredentialReissueState.rejected) {
        await widget.client.credentials.clearPendingCredentialReissueRequest(
          widget.client.endpoint,
          identity.deviceId,
        );
      }
    } on ClientCredentialReissueException catch (error) {
      if (mounted) {
        setState(() {
          _credentialReissueCode = error.code;
          _credentialReissueOperationId = error.operationId;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _credentialReissueCode = 'HOST_UNAVAILABLE');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadAfterMutation() async {
    final snapshot = await widget.client.listDevices();
    final pendingReissues = <String, PendingHostCredentialReissue>{};
    for (final device in snapshot.devices) {
      final pending = await widget.client.credentials
          .readPendingCredentialReissueRequest(
            widget.client.endpoint,
            device.deviceId,
          );
      if (pending != null) pendingReissues[device.deviceId] = pending;
    }
    if (mounted) {
      setState(() {
        _snapshot = snapshot;
        _pendingCredentialReissues = pendingReissues;
      });
    }
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
            if (!widget.client.canManageDevices)
              _credentialReissueClientCard(context),
            if (!widget.client.canManageDevices && _credentialReissue != null)
              _credentialReissueOperatorResultCard(
                context,
                _credentialReissue!,
              ),
            if (!widget.client.canManageDevices &&
                _credentialReissueCode != null)
              _credentialReissueStatusCard(context, _credentialReissueCode!),
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
              else if (_snapshot == null)
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
            if (widget.client.canManageDevices && _credentialReissue != null)
              _credentialReissueOperatorResultCard(
                context,
                _credentialReissue!,
              ),
            if (widget.client.canManageDevices &&
                _credentialReissueCode != null)
              _credentialReissueStatusCard(context, _credentialReissueCode!),
            if (_rotatedCredential case final credential?)
              _rotatedCredentialCard(context, credential),
            if (widget.client.canManageDevices)
              _credentialReissueClientCard(context),
          ],
        ),
      ),
    ),
  );

  Widget _credentialReissueClientCard(BuildContext context) {
    final identity = widget.client.verifiedIdentity;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.key_outlined),
        title: Text(
          context.ventioText('native.ui.check_credential_update_title'),
        ),
        subtitle: Text(
          context.ventioText('native.ui.check_credential_update_details'),
        ),
        trailing: FilledButton.tonal(
          key: const ValueKey('check-host-credential-update'),
          onPressed: _busy || !identity.persistent || identity.deviceId.isEmpty
              ? null
              : _checkCredentialUpdate,
          child: Text(context.ventioText('native.ui.check_credential_update')),
        ),
      ),
    );
  }

  Widget _credentialReissueOperatorResultCard(
    BuildContext context,
    WindowsTrustedCredentialReissueResult result,
  ) => Card(
    color: Theme.of(context).colorScheme.primaryContainer,
    child: ListTile(
      leading: const Icon(Icons.verified_user_outlined),
      title: Text(
        context.ventioText(
          'native.ui.credential_reissue_operator_state',
          params: {'state': result.state},
        ),
      ),
      subtitle: SelectableText(
        [
          context.ventioText(
            'native.ui.credential_reissue_device',
            params: {'deviceId': result.deviceId},
          ),
          context.ventioText(
            'native.ui.credential_reissue_scope',
            params: {
              'tenantId': result.tenantId,
              'actorId': result.actorId,
              'companyId': result.companyId,
              'branchId': result.branchId,
            },
          ),
          context.ventioText(
            'native.ui.credential_reissue_permissions',
            params: {'permissions': result.permissions.join(', ')},
          ),
          context.ventioText(
            'native.ui.credential_reissue_expires',
            params: {'timestamp': _formatUtc(result.expiresAtUtc)},
          ),
          context.ventioText(
            'native.ui.credential_reissue_reference',
            params: {'operationId': result.operationId},
          ),
        ].join('\n'),
      ),
    ),
  );

  Widget _credentialReissueStatusCard(BuildContext context, String code) =>
      Card(
        child: ListTile(
          leading: Icon(
            code == 'CREDENTIAL_UPDATE_APPLIED'
                ? Icons.check_circle_outline
                : Icons.info_outline,
          ),
          title: Text(context.ventioText(_credentialReissueStatusKey(code))),
          subtitle: _credentialReissueOperationId == null
              ? null
              : SelectableText(
                  context.ventioText(
                    'native.ui.credential_reissue_reference',
                    params: {'operationId': _credentialReissueOperationId},
                  ),
                ),
        ),
      );

  String _credentialReissueStatusKey(String code) => switch (code) {
    'UAC_APPROVAL_CANCELLED' || 'HOST_TRUSTED_REISSUE_UAC_CANCELLED' =>
      'native.ui.credential_reissue_uac_cancelled',
    'NO_CREDENTIAL_UPDATE' => 'native.ui.credential_reissue_none',
    'CREDENTIAL_UPDATE_APPLIED' => 'native.ui.credential_reissue_applied',
    'CREDENTIAL_UPDATE_STAGED' => 'native.ui.credential_reissue_staged',
    'REISSUE_EXPIRED' ||
    'HOST_TRUSTED_REISSUE_EXPIRED' => 'native.ui.credential_reissue_expired',
    'REISSUE_REJECTED' ||
    'HOST_TRUSTED_REISSUE_REJECTED' => 'native.ui.credential_reissue_rejected',
    'PERMISSION_OR_GRANT_DENIED' ||
    'HOST_TRUSTED_REISSUE_PERMISSION_NOT_GRANTED' =>
      'native.ui.credential_reissue_permission_denied',
    'HOST_TRUSTED_REISSUE_RECONCILIATION_REQUIRED' =>
      'native.ui.credential_reissue_reconcile_first',
    'HOST_TRUSTED_REISSUE_ALREADY_PENDING' ||
    'HOST_TRUSTED_REISSUE_REFERENCE_CONFLICT' =>
      'native.ui.credential_reissue_reconcile_first',
    'HOST_TRUSTED_REISSUE_TARGET_UNAVAILABLE' =>
      'native.ui.device_error_target',
    'HOST_TRUSTED_REISSUE_RECOVERY_UNAVAILABLE' ||
    'HOST_TRUSTED_REISSUE_RECOVERY_BUSY' =>
      'native.ui.device_error_recovery_authority',
    'HOST_TRUSTED_REISSUE_OUTCOME_UNKNOWN' ||
    'HOST_TRUSTED_REISSUE_FAILED' => 'native.ui.credential_reissue_unknown',
    'HOST_REQUEST_TIMEOUT' ||
    'HOST_UNREACHABLE' ||
    'HOST_UNAVAILABLE' => 'native.ui.device_error_network',
    _ => 'native.ui.credential_reissue_failed',
  };

  Widget _pairingCard(BuildContext context) {
    final waitForExpiry =
        _pairingRequestId != null &&
        _pairingCodeExpiresAtUtc?.isAfter(DateTime.now().toUtc()) == true;
    final pairingActionKey = waitForExpiry
        ? 'native.ui.pairing_replacement_after_expiry'
        : _pairingRequestId != null
        ? 'native.ui.check_pairing_request_safely'
        : 'native.ui.generate_pairing_code';
    return Card(
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
            if (_pairingRequestId != null &&
                _pairingCodeExpiresAtUtc?.isAfter(DateTime.now().toUtc()) !=
                    false) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  context.ventioText('native.ui.pairing_pending_target'),
                ),
                subtitle: Text(
                  _pendingPairingActorId ??
                      context.ventioText(
                        'native.ui.device_error_pairing_unknown',
                      ),
                ),
              ),
            ] else if (widget.userDirectory?.canManageUsers == true) ...[
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
                enabled:
                    !_busy &&
                    !(_pairingRequestId != null &&
                        _pairingCodeExpiresAtUtc?.isAfter(
                              DateTime.now().toUtc(),
                            ) !=
                            false),
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
                      _restoringPairingRequest ||
                      waitForExpiry ||
                      _loadingUsers ||
                      _userDirectoryFailed ||
                      (widget.userDirectory?.canManageUsers == true &&
                          _selectedUserId == null)
                  ? null
                  : _createPairing,
              icon: const Icon(Icons.phonelink_setup_outlined),
              label: Text(
                context.ventioText(
                  pairingActionKey,
                  params: {
                    if (waitForExpiry && _pairingCodeExpiresAtUtc != null)
                      'timestamp': _formatUtc(_pairingCodeExpiresAtUtc!),
                  },
                ),
              ),
            ),
            if (Platform.isWindows &&
                widget.client.canCreatePairings &&
                widget.userDirectory?.canManageUsers == true) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const ValueKey('trusted-scoped-pairing'),
                onPressed:
                    _busy ||
                        _selectedUserId == null ||
                        _pairingRequestId != null
                    ? null
                    : _createTrustedPairing,
                icon: const Icon(Icons.admin_panel_settings_outlined),
                label: Text(
                  context.ventioText('native.ui.create_trusted_scoped_pairing'),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                context.ventioText('native.ui.trusted_scoped_pairing_help'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
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
                    if (_trustedPairingPermissions case final permissions?) ...[
                      const SizedBox(height: 8),
                      Text(
                        context.ventioText(
                          'native.ui.trusted_pairing_permission_ceiling',
                          params: {'permissions': permissions.join(', ')},
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        context.ventioText(
                          'native.ui.trusted_pairing_device_note',
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    SelectableText(
                      pairing.code,
                      key: const ValueKey('generated-pairing-code'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        key: const ValueKey('copy-generated-pairing-code'),
                        onPressed: () => _copySecretToClipboard(pairing.code),
                        icon: const Icon(Icons.copy_outlined),
                        label: Text(
                          context.ventioText('native.ui.copy_pairing_code'),
                        ),
                      ),
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
  }

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
                                (credential.state ==
                                        HostManagedCredentialState.active ||
                                    _canTrustedCredentialReissue(
                                      device,
                                      credential,
                                    ))
                            ? Wrap(
                                spacing: 4,
                                children: [
                                  if (credential.state ==
                                      HostManagedCredentialState.active)
                                    TextButton.icon(
                                      onPressed: _busy
                                          ? null
                                          : () => _rotateCredential(
                                              device,
                                              credential,
                                            ),
                                      icon: const Icon(Icons.key_outlined),
                                      label: Text(
                                        context.ventioText(
                                          'native.ui.rotate_credential',
                                        ),
                                      ),
                                    ),
                                  if (_canTrustedCredentialReissue(
                                    device,
                                    credential,
                                  ))
                                    OutlinedButton.icon(
                                      key: ValueKey(
                                        'reissue-credential-${device.deviceId}-${credential.credentialId}',
                                      ),
                                      onPressed: _busy
                                          ? null
                                          : () => _trustedReissueCredential(
                                              device,
                                              credential,
                                            ),
                                      icon: const Icon(
                                        Icons.admin_panel_settings_outlined,
                                      ),
                                      label: Text(
                                        context.ventioText(
                                          _pendingCredentialReissues[device
                                                          .deviceId]
                                                      ?.sourceCredentialId ==
                                                  credential.credentialId
                                              ? 'native.ui.reconcile_credential_update'
                                              : 'native.ui.reissue_credential',
                                        ),
                                      ),
                                    ),
                                ],
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

  bool _canTrustedCredentialReissue(
    HostManagedDevice device,
    HostManagedCredential credential,
  ) {
    final pending = _pendingCredentialReissues[device.deviceId];
    final samePendingSource =
        pending?.sourceCredentialId == credential.credentialId;
    return Platform.isWindows &&
        device.role.toUpperCase() != 'HOST' &&
        !credential.permissions.contains('extension.package.read') &&
        (credential.state == HostManagedCredentialState.active ||
            (credential.state == HostManagedCredentialState.rotated &&
                samePendingSource));
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
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('copy-rotated-device-credential'),
              onPressed: () => _copySecretToClipboard(credential.credential),
              icon: const Icon(Icons.copy_outlined),
              label: Text(
                context.ventioText('native.ui.copy_device_credential'),
              ),
            ),
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

  Future<void> _copySecretToClipboard(String value) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.ventioText('native.ui.copy_to_clipboard_failed'),
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.ventioText('native.ui.copied_to_clipboard')),
      ),
    );
  }

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

  Widget _errorCard(BuildContext context, HostDeviceManagementException error) {
    final pairingAwaitingExpiry =
        _pairingRequestId != null &&
        _pairingCodeExpiresAtUtc?.isAfter(DateTime.now().toUtc()) == true;
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: ListTile(
        leading: const Icon(Icons.error_outline),
        title: Text(context.ventioText('native.ui.device_action_failed')),
        subtitle: SelectableText(
          '${context.ventioText(_errorExplanation(error.code))}\n'
          '${context.ventioText('native.ui.safe_error_code', params: {'code': error.code})}'
          '${error.pairingExpiresAtUtc == null ? '' : '\n${context.ventioText('native.ui.pairing_code_expires', params: {'timestamp': _formatUtc(error.pairingExpiresAtUtc!)})}'}'
          '${error.correlationId == null ? '' : '\n${context.ventioText('native.ui.correlation_reference', params: {'correlationId': error.correlationId!})}'}',
        ),
        trailing:
            widget.client.canManageDevices &&
                !error.code.startsWith('HOST_TRUSTED_PAIRING_')
            ? IconButton(
                tooltip: context.ventioText(
                  _pairingRequestId == null
                      ? 'native.ui.retry'
                      : 'native.ui.check_pairing_request_safely',
                ),
                onPressed: _busy || _loading || pairingAwaitingExpiry
                    ? null
                    : _pairingRequestId == null
                    ? _load
                    : _createPairing,
                icon: const Icon(Icons.refresh),
              )
            : null,
      ),
    );
  }
}

String _errorExplanation(String code) => switch (code) {
  'PERMISSION_DENIED' ||
  'HOST_PERMISSION_DENIED' ||
  'SCOPE_DENIED' => 'native.ui.device_error_permission',
  'HOST_UNREACHABLE' ||
  'HOST_CONNECTION_TIMEOUT' ||
  'HOST_REQUEST_TIMEOUT' ||
  'HOST_UNAVAILABLE' => 'native.ui.device_error_network',
  'PAIRING_OUTCOME_UNKNOWN' => 'native.ui.device_error_pairing_unknown',
  'PAIRING_CODE_UNAVAILABLE' =>
    'native.ui.device_error_pairing_code_unavailable',
  'PAIRING_DATABASE_UNAVAILABLE' => 'native.ui.device_error_pairing_database',
  'HOST_PAIRING_IDEMPOTENCY_UNSUPPORTED' =>
    'native.ui.device_error_pairing_api_unsupported',
  'LOCAL_PAIRING_STATE_UNAVAILABLE' =>
    'native.ui.device_error_local_pairing_state',
  'RECOVERY_AUTHORITY_UNAVAILABLE' =>
    'native.ui.device_error_recovery_authority',
  'RECOVERY_AUTHORITY_BUSY' => 'native.ui.device_error_recovery_authority_busy',
  'HOST_TLS_VALIDATION_FAILED' => 'native.ui.device_error_tls',
  'HOST_CREDENTIAL_MISSING' ||
  'UNAUTHENTICATED' => 'native.ui.device_error_authentication',
  'PAIRING_TARGET_UNAVAILABLE' => 'native.ui.device_error_target',
  'PAIRING_RATE_LIMITED' => 'native.ui.device_error_rate_limit',
  'HOST_TRUSTED_PAIRING_PERMISSION_NOT_GRANTED' =>
    'native.ui.trusted_pairing_operator_permission_denied',
  'HOST_TRUSTED_PAIRING_TARGET_UNAVAILABLE' => 'native.ui.device_error_target',
  'HOST_TRUSTED_PAIRING_RECOVERY_UNAVAILABLE' ||
  'HOST_TRUSTED_PAIRING_RECOVERY_BUSY' =>
    'native.ui.device_error_recovery_authority',
  'HOST_TRUSTED_PAIRING_OUTCOME_UNKNOWN' =>
    'native.ui.trusted_pairing_outcome_unknown',
  'HOST_TRUSTED_PAIRING_RATE_LIMITED' => 'native.ui.device_error_rate_limit',
  'HOST_TRUSTED_PAIRING_CODE_UNAVAILABLE' =>
    'native.ui.trusted_pairing_code_unavailable',
  'DEVICE_NOT_FOUND' => 'native.ui.device_error_not_found',
  _ => 'native.ui.device_error_generic',
};

class _TrustedPairingPermissionsDialog extends StatefulWidget {
  const _TrustedPairingPermissionsDialog({
    required this.tenantId,
    required this.companyId,
    required this.branchId,
  });

  final String tenantId;
  final String companyId;
  final String branchId;

  @override
  State<_TrustedPairingPermissionsDialog> createState() =>
      _TrustedPairingPermissionsDialogState();
}

class _TrustedPairingPermissionsDialogState
    extends State<_TrustedPairingPermissionsDialog> {
  final _permissions = TextEditingController(text: 'extension.package.read');
  String? _validationError;

  @override
  void dispose() {
    _permissions.dispose();
    super.dispose();
  }

  void _submit() {
    final values = _permissions.text
        .split(RegExp(r'[,\n]'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (values.isEmpty ||
        values.toSet().length != values.length ||
        values.any(
          (permission) =>
              !HostUserManagementClient.isGrantableNonManagementPermission(
                permission,
              ),
        )) {
      setState(
        () => _validationError = context.ventioText(
          'native.ui.trusted_pairing_permissions_invalid',
        ),
      );
      return;
    }
    Navigator.pop(context, values);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.ventioText('native.ui.trusted_pairing_review_title')),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.ventioText(
              'native.ui.trusted_pairing_review_scope',
              params: {
                'tenantId': widget.tenantId,
                'companyId': widget.companyId,
                'branchId': widget.branchId,
              },
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _permissions,
            minLines: 2,
            maxLines: 5,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: context.ventioText(
                'native.ui.trusted_pairing_permissions',
              ),
              hintText: 'extension.package.read',
              helperText: context.ventioText(
                'native.ui.trusted_pairing_permissions_help',
              ),
              errorText: _validationError,
            ),
          ),
          const SizedBox(height: 8),
          Text(context.ventioText('native.ui.trusted_pairing_uac_review')),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.ventioText('native.ui.cancel')),
      ),
      FilledButton(
        onPressed: _submit,
        child: Text(context.ventioText('native.ui.review_and_continue')),
      ),
    ],
  );
}

String _formatUtc(DateTime timestamp) {
  final utc = timestamp.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} UTC';
}
