import 'dart:math';

import 'extension_store.dart';
import 'host_credentials.dart';
import 'host_extension_packages.dart';

const hostSetupEndpoint = 'http://127.0.0.1:8080';

enum HostSetupStep {
  administratorAccess,
  postgresService,
  hostService,
  firstAdministrator,
  credentialStorage,
  hostReadiness,
  complete,
}

enum HostWindowsServiceState {
  notInstalled,
  stopped,
  startPending,
  stopPending,
  running,
  unknown,
}

enum HostSetupOperationState { pending, running, complete, failed, unknown }

class HostSetupOperationStatus {
  const HostSetupOperationStatus({
    required this.state,
    this.phase,
    this.failureCode,
    this.updatedAtUtc,
  });

  final HostSetupOperationState state;
  final String? phase;
  final String? failureCode;
  final DateTime? updatedAtUtc;

  static Map<String, dynamic> normalizeJson(Map<String, dynamic> decoded) {
    const aliases = <String, String>{
      'formatVersion': 'formatVersion',
      'FormatVersion': 'formatVersion',
      'operationId': 'operationId',
      'OperationId': 'operationId',
      'state': 'state',
      'State': 'state',
      'phase': 'phase',
      'Phase': 'phase',
      'failureCode': 'failureCode',
      'FailureCode': 'failureCode',
      'updatedAtUtc': 'updatedAtUtc',
      'UpdatedAtUtc': 'updatedAtUtc',
    };
    final normalized = <String, dynamic>{};
    for (final entry in decoded.entries) {
      final key = aliases[entry.key];
      if (key == null || normalized.containsKey(key)) {
        throw const FormatException('Invalid Host setup status document.');
      }
      normalized[key] = entry.value;
    }
    return normalized;
  }
}

class HostSetupScope {
  HostSetupScope({
    required this.tenantId,
    required this.companyId,
    required this.branchId,
  }) {
    for (final value in [tenantId, companyId, branchId]) {
      if (value.trim().isEmpty ||
          value.length > 256 ||
          !_identifier.hasMatch(value)) {
        throw ArgumentError('Host setup scope is invalid.');
      }
    }
  }

  final String tenantId;
  final String companyId;
  final String branchId;

  bool matches(HostConnectionProfile profile) =>
      profile.tenantId == tenantId &&
      profile.companyId == companyId &&
      profile.branchId == branchId;

  static final _identifier = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}$');
}

class HostSetupPendingOperation {
  const HostSetupPendingOperation({
    required this.operationId,
    required this.requesterSid,
    required this.scope,
  });

  final String operationId;
  final String requesterSid;
  final HostSetupScope scope;
}

class HostFirstAdministratorReply {
  const HostFirstAdministratorReply({
    required this.success,
    required this.status,
    this.requestId,
    this.actorId,
    this.token,
    this.expiresAt,
  });

  final bool success;
  final String status;
  final String? requestId;
  final String? actorId;
  final String? token;
  final String? expiresAt;
}

abstract interface class HostSetupPlatform {
  bool get supportsHostSetup;
  Future<bool> currentProcessIsElevated();
  Future<String> currentUserSid();
  Future<HostSetupPendingOperation?> readPendingOperation();
  Future<void> savePendingOperation(HostSetupPendingOperation operation);
  Future<void> clearPendingOperation();
  Future<bool> requestAdministratorSetup(HostSetupPendingOperation operation);
  Future<HostSetupOperationStatus> setupOperationStatus(String operationId);
  Future<HostFirstAdministratorReply> readBootstrapResult(String operationId);
  Future<void> clearBootstrapResult(String operationId);
  Future<HostWindowsServiceState> serviceState(String serviceName);
  Future<bool> waitForHostReadiness();
}

abstract interface class HostSetupCredentialStore {
  Future<String?> readCredential(Uri endpoint);
  Future<HostConnectionProfile?> readProfile();
  Future<HostConnectionProfile> verifyAndBindExistingProfile(
    HostConnectionProfile profile,
  );
  Future<HostConnectionProfile> saveCredentialAndProfile({
    required Uri endpoint,
    required String token,
    required HostConnectionProfile profile,
  });
}

class LocalHostSetupCredentialStore implements HostSetupCredentialStore {
  LocalHostSetupCredentialStore({
    required this.credentials,
    required this.store,
    this.sessionLoader,
  });

  final HostCredentialVault credentials;
  final LocalExtensionStore store;
  final Future<HostSessionIdentity> Function(Uri endpoint)? sessionLoader;

  @override
  Future<String?> readCredential(Uri endpoint) => credentials.read(endpoint);

  @override
  Future<HostConnectionProfile?> readProfile() => store.getHostProfile();

  @override
  Future<HostConnectionProfile> verifyAndBindExistingProfile(
    HostConnectionProfile profile,
  ) async {
    final endpoint = Uri.parse(profile.endpoint);
    final savedCredential = await credentials.read(endpoint);
    if (savedCredential == null || !_isOpaqueToken(savedCredential)) {
      throw const HostSetupException('HOST_BOOTSTRAP_CREDENTIAL_UNAVAILABLE');
    }
    try {
      final identity = await _loadSession(endpoint);
      final verifiedProfile = bindHostProfileToIdentity(
        profile: profile,
        identity: identity,
        requireHostAdministration: true,
      );
      if (verifiedProfile.deviceId != profile.deviceId) {
        await store.saveHostProfile(verifiedProfile);
      }
      return verifiedProfile;
    } on HostSessionIdentityException catch (error) {
      throw HostSetupException(error.code);
    } on HostSetupException {
      rethrow;
    } on Object {
      throw const HostSetupException('HOST_SESSION_AUTHENTICATION_FAILED');
    }
  }

  @override
  Future<HostConnectionProfile> saveCredentialAndProfile({
    required Uri endpoint,
    required String token,
    required HostConnectionProfile profile,
  }) async {
    final existingProfile = await store.getHostProfile();
    if (existingProfile != null &&
        (existingProfile.endpoint != profile.endpoint ||
            existingProfile.tenantId != profile.tenantId ||
            existingProfile.companyId != profile.companyId ||
            existingProfile.branchId != profile.branchId ||
            existingProfile.actorId != profile.actorId ||
            (existingProfile.deviceId != null &&
                profile.deviceId != null &&
                existingProfile.deviceId != profile.deviceId))) {
      throw const HostSetupException('HOST_PROFILE_ALREADY_CONFIGURED');
    }

    final previousCredential = await credentials.read(endpoint);
    try {
      await credentials.save(endpoint, token);
    } on Object {
      throw const HostSetupException('HOST_CREDENTIAL_STORAGE_FAILED');
    }
    try {
      final identity = await _loadSession(endpoint);
      final verifiedProfile = bindHostProfileToIdentity(
        profile: profile,
        identity: identity,
        requireHostAdministration: true,
      );
      await store.saveHostProfile(verifiedProfile);
      return verifiedProfile;
    } on Object catch (error) {
      try {
        if (previousCredential == null) {
          await credentials.delete(endpoint);
        } else {
          await credentials.save(endpoint, previousCredential);
        }
      } catch (_) {
        // Keep storage failures generic and never expose credential contents.
      }
      if (error is HostSessionIdentityException) {
        throw HostSetupException(error.code);
      }
      if (error is HostSetupException) rethrow;
      if (error is HostPackageTransportException) {
        throw const HostSetupException('HOST_SESSION_AUTHENTICATION_FAILED');
      }
      throw const HostSetupException('HOST_CREDENTIAL_STORAGE_FAILED');
    }
  }

  Future<HostSessionIdentity> _loadSession(Uri endpoint) =>
      sessionLoader?.call(endpoint) ??
      HostExtensionPackageClient(
        endpoint: endpoint,
        credentials: credentials,
      ).session();

  static bool _isOpaqueToken(String value) =>
      RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);
}

class HostSetupException implements Exception {
  const HostSetupException(this.code, {this.phase});

  final String code;
  final String? phase;

  @override
  String toString() => 'Host setup failed: $code';
}

class HostSetupCoordinator {
  HostSetupCoordinator({
    required this.platform,
    required this.credentials,
    this.onProgress,
    this.brokerStatusStartTimeout = const Duration(seconds: 30),
  });

  final HostSetupPlatform platform;
  final HostSetupCredentialStore credentials;
  final void Function(HostSetupStep step)? onProgress;
  final Duration brokerStatusStartTimeout;
  HostSetupStep? _reportedStep;

  Future<HostConnectionProfile> run(HostSetupScope scope) async {
    if (await platform.currentProcessIsElevated()) {
      throw const HostSetupException('HOST_SETUP_APPLICATION_ELEVATED');
    }
    final endpoint = Uri.parse(hostSetupEndpoint);
    final configuredProfile = await credentials.readProfile();
    if (configuredProfile != null) {
      if (!scope.matches(configuredProfile) ||
          configuredProfile.endpoint != endpoint.toString()) {
        throw const HostSetupException('HOST_PROFILE_ALREADY_CONFIGURED');
      }
      final savedCredential = await credentials.readCredential(endpoint);
      if (savedCredential == null || !_isOpaqueToken(savedCredential)) {
        throw const HostSetupException('HOST_BOOTSTRAP_CREDENTIAL_UNAVAILABLE');
      }
      onProgress?.call(HostSetupStep.hostReadiness);
      if (!await platform.waitForHostReadiness()) {
        throw const HostSetupException('HOST_READINESS_TIMEOUT');
      }
      final verifiedProfile = await credentials.verifyAndBindExistingProfile(
        configuredProfile,
      );
      onProgress?.call(HostSetupStep.complete);
      return verifiedProfile;
    }

    final requesterSid = await platform.currentUserSid();
    var operation = await platform.readPendingOperation();
    var operationCreatedForThisAttempt = false;
    if (operation != null) {
      if (!operation.scope.matches(_profileForScope(scope, endpoint)) ||
          operation.requesterSid != requesterSid ||
          !_isOperationId(operation.operationId)) {
        throw const HostSetupException('HOST_SETUP_PENDING_OPERATION_MISMATCH');
      }
    } else {
      for (final name in ['VentioPostgres', 'VentioHost']) {
        final state = await platform.serviceState(name);
        if (state == HostWindowsServiceState.unknown) {
          throw const HostSetupException('HOST_SETUP_STATUS_UNAVAILABLE');
        }
        if (state != HostWindowsServiceState.notInstalled) {
          throw const HostSetupException(
            'HOST_EXISTING_INSTALLATION_REQUIRES_RECOVERY',
          );
        }
      }
      operation = HostSetupPendingOperation(
        operationId: _newOperationId(),
        requesterSid: requesterSid,
        scope: scope,
      );
      await platform.savePendingOperation(operation);
      operationCreatedForThisAttempt = true;
    }

    var status = await platform.setupOperationStatus(operation.operationId);
    if (status.state == HostSetupOperationState.pending &&
        !operationCreatedForThisAttempt) {
      throw const HostSetupException(
        'HOST_SETUP_INTERRUPTED_REQUIRES_RECOVERY',
      );
    }
    _rejectStaleOperation(status);
    if (status.state == HostSetupOperationState.failed) {
      throw HostSetupException(
        status.failureCode ?? 'HOST_SETUP_PROVISIONING_FAILED',
        phase: status.phase,
      );
    }
    var awaitingBrokerStart = false;
    if (status.state != HostSetupOperationState.running &&
        status.state != HostSetupOperationState.complete) {
      onProgress?.call(HostSetupStep.administratorAccess);
      late final bool started;
      try {
        started = await platform.requestAdministratorSetup(operation);
      } on Object {
        if (operationCreatedForThisAttempt) {
          await platform.clearPendingOperation();
        }
        rethrow;
      }
      if (!started) {
        if (operationCreatedForThisAttempt) {
          await platform.clearPendingOperation();
        }
        throw const HostSetupException('HOST_SETUP_ELEVATION_CANCELLED');
      }
      awaitingBrokerStart = true;
    }

    final brokerStartDeadline = DateTime.now().add(brokerStatusStartTimeout);
    final deadline = DateTime.now().add(const Duration(minutes: 45));
    while (DateTime.now().isBefore(deadline)) {
      status = await platform.setupOperationStatus(operation.operationId);
      _rejectStaleOperation(status);
      _reportPhase(status.phase);
      if (status.state == HostSetupOperationState.complete) break;
      if (status.state == HostSetupOperationState.failed) {
        throw HostSetupException(
          status.failureCode ?? 'HOST_SETUP_PROVISIONING_FAILED',
          phase: status.phase,
        );
      }
      if (status.state == HostSetupOperationState.running) {
        awaitingBrokerStart = false;
      } else if (awaitingBrokerStart &&
          DateTime.now().isAfter(brokerStartDeadline)) {
        throw const HostSetupException('HOST_SETUP_BROKER_START_TIMEOUT');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (status.state != HostSetupOperationState.complete) {
      throw const HostSetupException('HOST_SETUP_OPERATION_TIMEOUT');
    }

    onProgress?.call(HostSetupStep.firstAdministrator);
    if (!await platform.waitForHostReadiness()) {
      throw const HostSetupException('HOST_READINESS_TIMEOUT');
    }
    final reply = await platform.readBootstrapResult(operation.operationId);
    final requestId = reply.requestId;
    final actorId = reply.actorId;
    final token = reply.token;
    final expiresAt = reply.expiresAt;
    final expires = expiresAt == null ? null : DateTime.tryParse(expiresAt);
    if (!reply.success ||
        reply.status != 'pending' ||
        requestId == null ||
        actorId == null ||
        token == null ||
        expiresAt == null ||
        !_isOpaqueToken(requestId) ||
        !_isOpaqueToken(token) ||
        !RegExp(r'^usr_[A-Za-z0-9_-]{43}$').hasMatch(actorId) ||
        expires == null ||
        !expires.toUtc().isAfter(DateTime.now().toUtc()) ||
        expires.toUtc().isAfter(
          DateTime.now().toUtc().add(const Duration(days: 30)),
        )) {
      throw const HostSetupException(
        'HOST_FIRST_ADMINISTRATOR_RESPONSE_INVALID',
      );
    }

    final profile = HostConnectionProfile(
      endpoint: endpoint.toString(),
      tenantId: scope.tenantId,
      companyId: scope.companyId,
      branchId: scope.branchId,
      actorId: actorId,
    );
    onProgress?.call(HostSetupStep.credentialStorage);
    final verifiedProfile = await credentials.saveCredentialAndProfile(
      endpoint: endpoint,
      token: token,
      profile: profile,
    );
    await platform.clearBootstrapResult(operation.operationId);
    await platform.clearPendingOperation();

    onProgress?.call(HostSetupStep.hostReadiness);
    onProgress?.call(HostSetupStep.complete);
    return verifiedProfile;
  }

  void _reportPhase(String? phase) {
    final step = switch (phase) {
      'PAYLOAD_VALIDATION' ||
      'POSTGRES_SERVICE_PROVISIONING' ||
      'DATABASE_INITIALIZATION' ||
      'MIGRATION_CREDENTIAL_PROTECTION' => HostSetupStep.postgresService,
      'HOST_SERVICE_REGISTRATION' ||
      'HOST_CONFIGURATION_PROTECTION' ||
      'HOST_LAN_CONFIGURATION' ||
      'HOST_SERVICE_STARTUP' => HostSetupStep.hostService,
      'FIRST_ADMINISTRATOR_BOOTSTRAP' ||
      'BOOTSTRAP_CREDENTIAL_PROTECTION' => HostSetupStep.firstAdministrator,
      'HOST_READINESS' => HostSetupStep.hostReadiness,
      _ => null,
    };
    if (step != null && step != _reportedStep) {
      _reportedStep = step;
      onProgress?.call(step);
    }
  }

  void _rejectStaleOperation(HostSetupOperationStatus status) {
    if (status.state != HostSetupOperationState.running) return;
    final updatedAt = status.updatedAtUtc;
    if (updatedAt == null) {
      throw const HostSetupException(
        'HOST_SETUP_INTERRUPTED_REQUIRES_RECOVERY',
      );
    }
    final age = DateTime.now().toUtc().difference(updatedAt.toUtc());
    const maximumHeartbeatAge = Duration(seconds: 30);
    if (age > maximumHeartbeatAge || age < -maximumHeartbeatAge) {
      throw const HostSetupException(
        'HOST_SETUP_INTERRUPTED_REQUIRES_RECOVERY',
      );
    }
  }

  static bool _isOpaqueToken(String value) =>
      RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);

  static bool _isOperationId(String value) =>
      RegExp(r'^[a-f0-9]{32}$').hasMatch(value);

  static String _newOperationId() {
    final random = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
    return random
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static final _secureRandom = _createSecureRandom();

  static Random _createSecureRandom() => Random.secure();

  static HostConnectionProfile _profileForScope(
    HostSetupScope scope,
    Uri endpoint,
  ) => HostConnectionProfile(
    endpoint: endpoint.toString(),
    tenantId: scope.tenantId,
    companyId: scope.companyId,
    branchId: scope.branchId,
  );
}
