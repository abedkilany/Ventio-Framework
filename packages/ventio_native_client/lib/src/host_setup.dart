import 'extension_store.dart';
import 'host_credentials.dart';

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

class HostSetupScope {
  HostSetupScope({
    required this.tenantId,
    required this.companyId,
    required this.branchId,
  }) {
    for (final value in [tenantId, companyId, branchId]) {
      if (value.trim().isEmpty ||
          value.length > 256 ||
          _containsControl(value)) {
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

  static bool _containsControl(String value) =>
      value.runes.any((rune) => rune < 0x20 || (rune >= 0x7f && rune <= 0x9f));
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
  Future<bool> isAdministrator();
  Future<bool> requestAdministratorSetup();
  Future<HostWindowsServiceState> serviceState(String serviceName);
  Future<void> startService(String serviceName);
  Future<HostFirstAdministratorReply> bootstrapFirstAdministrator(
    HostSetupScope scope,
  );
  Future<void> acknowledgeFirstAdministrator(String requestId);
  Future<bool> waitForHostReadiness();
}

abstract interface class HostSetupCredentialStore {
  Future<String?> readCredential(Uri endpoint);
  Future<HostConnectionProfile?> readProfile();
  Future<void> saveCredentialAndProfile({
    required Uri endpoint,
    required String token,
    required HostConnectionProfile profile,
  });
}

class LocalHostSetupCredentialStore implements HostSetupCredentialStore {
  LocalHostSetupCredentialStore({
    required this.credentials,
    required this.store,
  });

  final HostCredentialVault credentials;
  final LocalExtensionStore store;

  @override
  Future<String?> readCredential(Uri endpoint) => credentials.read(endpoint);

  @override
  Future<HostConnectionProfile?> readProfile() => store.getHostProfile();

  @override
  Future<void> saveCredentialAndProfile({
    required Uri endpoint,
    required String token,
    required HostConnectionProfile profile,
  }) async {
    final existingProfile = await store.getHostProfile();
    if (existingProfile != null &&
        (existingProfile.endpoint != profile.endpoint ||
            existingProfile.tenantId != profile.tenantId ||
            existingProfile.companyId != profile.companyId ||
            existingProfile.branchId != profile.branchId)) {
      throw const HostSetupException('HOST_PROFILE_ALREADY_CONFIGURED');
    }

    final previousCredential = await credentials.read(endpoint);
    await credentials.save(endpoint, token);
    try {
      await store.saveHostProfile(profile);
    } catch (_) {
      try {
        if (previousCredential == null) {
          await credentials.delete(endpoint);
        } else {
          await credentials.save(endpoint, previousCredential);
        }
      } catch (_) {
        // Keep storage failures generic and never expose credential contents.
      }
      throw const HostSetupException('HOST_CREDENTIAL_STORAGE_FAILED');
    }
  }
}

class HostSetupException implements Exception {
  const HostSetupException(this.code);

  final String code;

  @override
  String toString() => 'Host setup failed: $code';
}

class HostSetupCoordinator {
  HostSetupCoordinator({
    required this.platform,
    required this.credentials,
    this.onProgress,
  });

  final HostSetupPlatform platform;
  final HostSetupCredentialStore credentials;
  final void Function(HostSetupStep step)? onProgress;

  Future<HostConnectionProfile> run(HostSetupScope scope) async {
    onProgress?.call(HostSetupStep.administratorAccess);
    if (!await platform.isAdministrator()) {
      throw const HostSetupException('HOST_SETUP_REQUIRES_ADMINISTRATOR');
    }

    onProgress?.call(HostSetupStep.postgresService);
    await _ensureService('VentioPostgres');
    onProgress?.call(HostSetupStep.hostService);
    await _ensureService('VentioHost');

    onProgress?.call(HostSetupStep.firstAdministrator);
    final endpoint = Uri.parse(hostSetupEndpoint);
    final reply = await platform.bootstrapFirstAdministrator(scope);
    if (!reply.success) {
      throw const HostSetupException('HOST_FIRST_ADMINISTRATOR_FAILED');
    }

    late final HostConnectionProfile profile;
    if (reply.status == 'pending') {
      final requestId = reply.requestId;
      final actorId = reply.actorId;
      final token = reply.token;
      final expiresAt = reply.expiresAt;
      if (requestId == null ||
          actorId == null ||
          token == null ||
          expiresAt == null ||
          !_isOpaqueToken(requestId) ||
          !_isOpaqueToken(token) ||
          !RegExp(r'^usr_[A-Za-z0-9_-]{43}$').hasMatch(actorId) ||
          DateTime.tryParse(expiresAt) == null) {
        throw const HostSetupException(
          'HOST_FIRST_ADMINISTRATOR_RESPONSE_INVALID',
        );
      }

      profile = HostConnectionProfile(
        endpoint: endpoint.toString(),
        tenantId: scope.tenantId,
        companyId: scope.companyId,
        branchId: scope.branchId,
        actorId: actorId,
      );
      onProgress?.call(HostSetupStep.credentialStorage);
      await credentials.saveCredentialAndProfile(
        endpoint: endpoint,
        token: token,
        profile: profile,
      );
      await platform.acknowledgeFirstAdministrator(requestId);
    } else if (reply.status == 'acknowledged') {
      final savedProfile = await credentials.readProfile();
      final savedCredential = await credentials.readCredential(endpoint);
      if (savedProfile == null ||
          !scope.matches(savedProfile) ||
          savedProfile.endpoint != endpoint.toString() ||
          savedCredential == null ||
          !_isOpaqueToken(savedCredential)) {
        throw const HostSetupException('HOST_BOOTSTRAP_CREDENTIAL_UNAVAILABLE');
      }
      profile = savedProfile;
    } else {
      throw const HostSetupException('HOST_FIRST_ADMINISTRATOR_FAILED');
    }

    onProgress?.call(HostSetupStep.hostReadiness);
    if (!await platform.waitForHostReadiness()) {
      throw const HostSetupException('HOST_READINESS_TIMEOUT');
    }
    onProgress?.call(HostSetupStep.complete);
    return profile;
  }

  Future<void> _ensureService(String serviceName) async {
    final state = await platform.serviceState(serviceName);
    if (state == HostWindowsServiceState.notInstalled) {
      throw const HostSetupException('HOST_SERVICE_NOT_INSTALLED');
    }
    if (state == HostWindowsServiceState.unknown) {
      throw const HostSetupException('HOST_SERVICE_STATUS_UNAVAILABLE');
    }
    if (state != HostWindowsServiceState.running) {
      await platform.startService(serviceName);
    }
  }

  static bool _isOpaqueToken(String value) =>
      RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);
}
