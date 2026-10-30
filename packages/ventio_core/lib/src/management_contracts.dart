/// Versioned, Flutter-independent contracts for Host/Client management.
///
/// Device role describes infrastructure use only. It is never an authorization
/// grant; application permissions continue to come from the authenticated Host
/// principal and its exact company/branch grants.
const int managementApiVersion = 1;

const String hostStatusReadPermission = 'host.status.read';
const String hostDiagnosticsReadPermission = 'host.diagnostics.read';
const String identityUsersManagePermission = 'identity.users.manage';
const String identityDevicesManagePermission = 'identity.devices.manage';
const String identityPairingManagePermission = 'identity.pairing.manage';
const String identityRolesManagePermission = 'identity.roles.manage';

abstract final class HostManagementRoutes {
  static const String readiness = '/api/v1/management/readiness';
  static const String diagnostics = '/api/v1/management/diagnostics';
  static const String diagnosticsRecent = '$diagnostics/recent';
  static const String users = '/api/v1/management/users';
  static const String devices = '/api/v1/management/devices';
  static const String pairing = '/api/v1/management/pairing';
  static const String pairingCreate = '$pairing/create';
  static const String devicesList = '$devices/list';
  static const String devicesRevoke = '$devices/revoke';
  static const String devicesRotateCredential = '$devices/rotate-credential';
  static const String pairingRedeem = '/api/v1/pairing/redeem';
  static const String synchronization = '/api/v1/management/synchronization';
}

enum ManagementHealthState {
  ready('READY'),
  degraded('DEGRADED'),
  unavailable('UNAVAILABLE'),
  blocked('BLOCKED'),
  notConfigured('NOT_CONFIGURED'),
  unknown('UNKNOWN');

  const ManagementHealthState(this.wireValue);

  final String wireValue;

  static ManagementHealthState parse(Object? value) =>
      ManagementHealthState.values.firstWhere(
        (state) => state.wireValue == value,
        orElse: () => throw const FormatException(
          'Unknown management health state.',
        ),
      );
}

enum ManagementComponent {
  api('api'),
  database('database'),
  schema('schema'),
  recoveryAuthority('recovery_authority');

  const ManagementComponent(this.wireValue);

  final String wireValue;

  static ManagementComponent parse(Object? value) =>
      ManagementComponent.values.firstWhere(
        (component) => component.wireValue == value,
        orElse: () => throw const FormatException(
          'Unknown management component.',
        ),
      );
}

/// Safe readiness summary. It carries component states and allowlisted reason
/// codes only; connection strings, schema names and exception text are excluded.
class ManagementComponentHealth {
  ManagementComponentHealth({
    required this.component,
    required this.state,
    required DateTime checkedAtUtc,
    this.reasonCode,
  }) : checkedAtUtc = checkedAtUtc.toUtc() {
    if (reasonCode != null &&
        !RegExp(r'^[A-Z][A-Z0-9_]{0,79}$').hasMatch(reasonCode!)) {
      throw ArgumentError('Invalid management reason code.');
    }
  }

  final ManagementComponent component;
  final ManagementHealthState state;
  final DateTime checkedAtUtc;
  final String? reasonCode;

  Map<String, Object?> toJson() => {
        'component': component.wireValue,
        'state': state.wireValue,
        'checkedAtUtc': checkedAtUtc.toIso8601String(),
        if (reasonCode != null) 'reasonCode': reasonCode,
      };

  factory ManagementComponentHealth.fromJson(Object? value) {
    final json = _managementMap(value, 'component health');
    _managementKeys(json, const {
      'component',
      'state',
      'checkedAtUtc',
      'reasonCode',
    });
    final checkedAt =
        DateTime.tryParse(_managementString(json, 'checkedAtUtc'));
    if (checkedAt == null || !checkedAt.isUtc) {
      throw const FormatException('Management timestamp must be UTC.');
    }
    final reason = json['reasonCode'];
    if (reason != null && reason is! String) {
      throw const FormatException('Management reason code is invalid.');
    }
    return ManagementComponentHealth(
      component: ManagementComponent.parse(json['component']),
      state: ManagementHealthState.parse(json['state']),
      checkedAtUtc: checkedAt,
      reasonCode: reason as String?,
    );
  }
}

class HostReadinessSnapshot {
  HostReadinessSnapshot({
    required DateTime checkedAtUtc,
    required this.hostVersion,
    required Iterable<ManagementComponentHealth> components,
  })  : checkedAtUtc = checkedAtUtc.toUtc(),
        components = List.unmodifiable(components) {
    if (!RegExp(r'^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$')
        .hasMatch(hostVersion)) {
      throw ArgumentError('Invalid Host version.');
    }
    final ids = this.components.map((item) => item.component).toSet();
    if (this.components.isEmpty ||
        this.components.length > ManagementComponent.values.length ||
        ids.length != this.components.length) {
      throw ArgumentError('Readiness must contain unique known components.');
    }
  }

  final DateTime checkedAtUtc;
  final String hostVersion;
  final List<ManagementComponentHealth> components;

  ManagementHealthState get overallState {
    if (components.any(
      (item) =>
          item.state == ManagementHealthState.unavailable ||
          item.state == ManagementHealthState.blocked,
    )) {
      return ManagementHealthState.unavailable;
    }
    if (components.any(
      (item) =>
          item.state == ManagementHealthState.unknown ||
          item.state == ManagementHealthState.notConfigured,
    )) {
      return ManagementHealthState.unknown;
    }
    if (components
        .any((item) => item.state == ManagementHealthState.degraded)) {
      return ManagementHealthState.degraded;
    }
    return ManagementHealthState.ready;
  }

  Map<String, Object?> toJson() => {
        'managementApiVersion': managementApiVersion,
        'hostVersion': hostVersion,
        'checkedAtUtc': checkedAtUtc.toIso8601String(),
        'overallState': overallState.wireValue,
        'components':
            components.map((component) => component.toJson()).toList(),
      };

  factory HostReadinessSnapshot.fromJson(Object? value) {
    final json = _managementMap(value, 'readiness');
    _managementKeys(json, const {
      'managementApiVersion',
      'hostVersion',
      'checkedAtUtc',
      'overallState',
      'components',
    });
    if (json['managementApiVersion'] != managementApiVersion ||
        json['components'] is! List) {
      throw const FormatException('Unsupported readiness contract.');
    }
    final checkedAt =
        DateTime.tryParse(_managementString(json, 'checkedAtUtc'));
    if (checkedAt == null || !checkedAt.isUtc) {
      throw const FormatException('Management timestamp must be UTC.');
    }
    final snapshot = HostReadinessSnapshot(
      checkedAtUtc: checkedAt,
      hostVersion: _managementString(json, 'hostVersion'),
      components:
          (json['components'] as List).map(ManagementComponentHealth.fromJson),
    );
    if (ManagementHealthState.parse(json['overallState']) !=
        snapshot.overallState) {
      throw const FormatException('Readiness summary does not match details.');
    }
    return snapshot;
  }
}

/// Stable HTTP error envelope. Correlation IDs are generated by the Host and
/// let a user/administrator match a safe UI message to protected local logs.
class ManagementApiError {
  ManagementApiError({
    required this.code,
    required this.messageKey,
    required this.message,
    required this.retryable,
    required this.correlationId,
  }) {
    if (!RegExp(r'^[A-Z][A-Z0-9_]{0,79}$').hasMatch(code) ||
        !RegExp(r'^[a-z][a-z0-9_.-]{0,159}$').hasMatch(messageKey) ||
        !RegExp(r'^cor_[a-f0-9]{32}$').hasMatch(correlationId) ||
        message.trim().isEmpty ||
        message.length > 1000 ||
        _containsCredentialMaterial(message)) {
      throw ArgumentError('Invalid or unsafe management error.');
    }
  }

  final String code;
  final String messageKey;
  final String message;
  final bool retryable;
  final String correlationId;

  Map<String, Object?> toJson() => {
        'apiVersion': managementApiVersion,
        'correlationId': correlationId,
        'error': {
          'code': code,
          'messageKey': messageKey,
          'message': message,
          'retryable': retryable,
        },
      };

  factory ManagementApiError.fromJson(Object? value) {
    final json = _managementMap(value, 'management error');
    _managementKeys(json, const {'apiVersion', 'correlationId', 'error'});
    if (json['apiVersion'] != managementApiVersion || json['error'] is! Map) {
      throw const FormatException('Unsupported management error contract.');
    }
    final error = _managementMap(json['error'], 'management error details');
    _managementKeys(error, const {
      'code',
      'messageKey',
      'message',
      'retryable',
    });
    if (error['retryable'] is! bool) {
      throw const FormatException('Invalid management retryable flag.');
    }
    return ManagementApiError(
      code: _managementString(error, 'code'),
      messageKey: _managementString(error, 'messageKey'),
      message: _managementString(error, 'message'),
      retryable: error['retryable'] as bool,
      correlationId: _managementString(json, 'correlationId'),
    );
  }
}

/// A structured, user-safe event. Protected exception text and secrets are not
/// fields in this public contract and therefore cannot be serialized by it.
class ManagementDiagnosticEvent {
  ManagementDiagnosticEvent({
    required this.code,
    required this.component,
    required this.category,
    required this.severity,
    required DateTime occurredAtUtc,
    required this.correlationId,
    required this.retryable,
    required this.messageKey,
    required this.safeExplanation,
    required this.recommendedAction,
    this.protectedTechnicalCode,
    this.protectedFailureType,
    this.protectedFailureSource,
  }) : occurredAtUtc = occurredAtUtc.toUtc() {
    if (!RegExp(r'^[A-Z][A-Z0-9_]{0,79}$').hasMatch(code) ||
        (protectedTechnicalCode != null &&
            !RegExp(r'^[0-9A-Z]{5}$').hasMatch(protectedTechnicalCode!)) ||
        (protectedFailureType != null &&
            !RegExp(r'^[A-Za-z][A-Za-z0-9_.]{0,79}$')
                .hasMatch(protectedFailureType!)) ||
        (protectedFailureSource != null &&
            !RegExp(r'^[A-Za-z0-9_.$<>]{1,120}$')
                .hasMatch(protectedFailureSource!)) ||
        !RegExp(r'^[a-z][a-z0-9_.-]{0,79}$').hasMatch(component) ||
        !RegExp(r'^cor_[a-f0-9]{32}$').hasMatch(correlationId) ||
        !RegExp(r'^[a-z][a-z0-9_.-]{0,159}$').hasMatch(messageKey) ||
        safeExplanation.trim().isEmpty ||
        safeExplanation.length > 1000 ||
        recommendedAction.trim().isEmpty ||
        recommendedAction.length > 1000) {
      throw ArgumentError('Invalid management diagnostic event.');
    }
    if (_containsCredentialMaterial(safeExplanation) ||
        _containsCredentialMaterial(recommendedAction)) {
      throw ArgumentError(
          'Diagnostic copy contains protected credential data.');
    }
  }

  final String code;
  final String component;
  final ManagementDiagnosticCategory category;
  final ManagementDiagnosticSeverity severity;
  final DateTime occurredAtUtc;
  final String correlationId;
  final bool retryable;
  final String messageKey;
  final String safeExplanation;
  final String recommendedAction;

  /// A bounded internal diagnostic code, such as a SQLSTATE. It is held only
  /// by protected Host diagnostics and is deliberately omitted from [toJson].
  final String? protectedTechnicalCode;

  /// Exception class only; messages and values remain outside the user-facing
  /// diagnostic contract.
  final String? protectedFailureType;

  /// Sanitized top stack frame symbol, without path, message or source line.
  final String? protectedFailureSource;

  Map<String, Object?> toJson() => {
        'managementApiVersion': managementApiVersion,
        'code': code,
        'component': component,
        'category': category.wireValue,
        'severity': severity.wireValue,
        'occurredAtUtc': occurredAtUtc.toIso8601String(),
        'correlationId': correlationId,
        'retryable': retryable,
        'messageKey': messageKey,
        'safeExplanation': safeExplanation,
        'recommendedAction': recommendedAction,
      };

  factory ManagementDiagnosticEvent.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Diagnostic event must be an object.');
    }
    const expectedKeys = {
      'managementApiVersion',
      'code',
      'component',
      'category',
      'severity',
      'occurredAtUtc',
      'correlationId',
      'retryable',
      'messageKey',
      'safeExplanation',
      'recommendedAction',
    };
    if (value.length != expectedKeys.length ||
        !value.keys.toSet().containsAll(expectedKeys) ||
        value['managementApiVersion'] != managementApiVersion ||
        value['retryable'] is! bool) {
      throw const FormatException('Diagnostic event contract is invalid.');
    }
    final occurredAt =
        DateTime.tryParse(value['occurredAtUtc'] as String? ?? '');
    if (occurredAt == null || !occurredAt.isUtc) {
      throw const FormatException('Diagnostic timestamp must be UTC.');
    }
    return ManagementDiagnosticEvent(
      code: value['code'] as String? ?? '',
      component: value['component'] as String? ?? '',
      category: ManagementDiagnosticCategory.parse(value['category']),
      severity: ManagementDiagnosticSeverity.parse(value['severity']),
      occurredAtUtc: occurredAt,
      correlationId: value['correlationId'] as String? ?? '',
      retryable: value['retryable'] as bool,
      messageKey: value['messageKey'] as String? ?? '',
      safeExplanation: value['safeExplanation'] as String? ?? '',
      recommendedAction: value['recommendedAction'] as String? ?? '',
    );
  }
}

enum ManagementDiagnosticCategory {
  hostStartup('host_startup'),
  hostLifecycle('host_lifecycle'),
  database('database'),
  schema('schema'),
  recovery('recovery'),
  pairing('pairing'),
  credentials('credentials'),
  authentication('authentication'),
  authorization('authorization'),
  tenantIsolation('tenant_isolation'),
  networkTls('network_tls'),
  apiExecution('api_execution'),
  sqlitePersistence('sqlite_persistence'),
  commandQueue('command_queue'),
  synchronization('synchronization'),
  commandValidation('command_validation'),
  upgrade('upgrade'),
  restoration('restoration');

  const ManagementDiagnosticCategory(this.wireValue);

  final String wireValue;

  static ManagementDiagnosticCategory parse(Object? value) =>
      ManagementDiagnosticCategory.values.firstWhere(
        (category) => category.wireValue == value,
        orElse: () => throw const FormatException(
          'Unknown management diagnostic category.',
        ),
      );
}

enum ManagementDiagnosticSeverity {
  info('INFO'),
  warning('WARNING'),
  error('ERROR'),
  critical('CRITICAL');

  const ManagementDiagnosticSeverity(this.wireValue);

  final String wireValue;

  static ManagementDiagnosticSeverity parse(Object? value) =>
      ManagementDiagnosticSeverity.values.firstWhere(
        (severity) => severity.wireValue == value,
        orElse: () => throw const FormatException(
          'Unknown management diagnostic severity.',
        ),
      );
}

enum HostDeviceRole {
  host('HOST'),
  client('CLIENT'),
  unknown('UNKNOWN');

  const HostDeviceRole(this.wireValue);

  final String wireValue;
}

enum DeviceRegistrationState {
  pending('PENDING'),
  registered('REGISTERED'),
  revoked('REVOKED');

  const DeviceRegistrationState(this.wireValue);

  final String wireValue;
}

enum CredentialLifecycleState {
  active('ACTIVE'),
  expired('EXPIRED'),
  revoked('REVOKED'),
  rotated('ROTATED'),
  unknown('UNKNOWN');

  const CredentialLifecycleState(this.wireValue);

  final String wireValue;
}

enum PairingLifecycleState {
  issued('ISSUED'),
  claimed('CLAIMED'),
  expired('EXPIRED'),
  revoked('REVOKED');

  const PairingLifecycleState(this.wireValue);

  final String wireValue;
}

enum SynchronizationState {
  idle('IDLE'),
  offline('OFFLINE'),
  syncing('SYNCING'),
  attentionRequired('ATTENTION_REQUIRED');

  const SynchronizationState(this.wireValue);

  final String wireValue;
}

enum AdministrativeOperationState {
  pending('PENDING'),
  applied('APPLIED'),
  rejected('REJECTED'),
  outcomeUnknown('OUTCOME_UNKNOWN');

  const AdministrativeOperationState(this.wireValue);

  final String wireValue;
}

/// Inventory projection. It contains device role metadata but no permission
/// claims; those are evaluated independently from the authenticated principal.
class ManagedDeviceSummary {
  ManagedDeviceSummary({
    required this.deviceId,
    required this.actorId,
    required this.role,
    required this.registrationState,
    required DateTime registeredAtUtc,
    DateTime? lastAuthenticatedAtUtc,
  })  : registeredAtUtc = registeredAtUtc.toUtc(),
        lastAuthenticatedAtUtc = lastAuthenticatedAtUtc?.toUtc();

  final String deviceId;
  final String actorId;
  final HostDeviceRole role;
  final DeviceRegistrationState registrationState;
  final DateTime registeredAtUtc;
  final DateTime? lastAuthenticatedAtUtc;

  Map<String, Object?> toJson() => {
        'managementApiVersion': managementApiVersion,
        'deviceId': deviceId,
        'actorId': actorId,
        'role': role.wireValue,
        'registrationState': registrationState.wireValue,
        'registeredAtUtc': registeredAtUtc.toIso8601String(),
        if (lastAuthenticatedAtUtc != null)
          'lastAuthenticatedAtUtc': lastAuthenticatedAtUtc!.toIso8601String(),
      };
}

/// Credential metadata only. The bearer secret and digest are never part of
/// this response contract.
class ManagedCredentialSummary {
  ManagedCredentialSummary({
    required this.credentialId,
    required this.deviceId,
    required this.state,
    required DateTime expiresAtUtc,
    DateTime? revokedAtUtc,
  })  : expiresAtUtc = expiresAtUtc.toUtc(),
        revokedAtUtc = revokedAtUtc?.toUtc();

  final String credentialId;
  final String deviceId;
  final CredentialLifecycleState state;
  final DateTime expiresAtUtc;
  final DateTime? revokedAtUtc;

  Map<String, Object?> toJson() => {
        'managementApiVersion': managementApiVersion,
        'credentialId': credentialId,
        'deviceId': deviceId,
        'state': state.wireValue,
        'expiresAtUtc': expiresAtUtc.toIso8601String(),
        if (revokedAtUtc != null)
          'revokedAtUtc': revokedAtUtc!.toIso8601String(),
      };
}

/// Pairing inventory intentionally omits the one-time pairing code.
class ManagedPairingSummary {
  ManagedPairingSummary({
    required this.pairingId,
    required this.deviceRole,
    required this.state,
    required DateTime expiresAtUtc,
  }) : expiresAtUtc = expiresAtUtc.toUtc();

  final String pairingId;
  final HostDeviceRole deviceRole;
  final PairingLifecycleState state;
  final DateTime expiresAtUtc;

  Map<String, Object?> toJson() => {
        'managementApiVersion': managementApiVersion,
        'pairingId': pairingId,
        'deviceRole': deviceRole.wireValue,
        'state': state.wireValue,
        'expiresAtUtc': expiresAtUtc.toIso8601String(),
      };
}

class HostSynchronizationSummary {
  HostSynchronizationSummary({
    required this.state,
    required this.pending,
    required this.accepted,
    required this.rejected,
    required this.conflicts,
    required this.retryable,
    this.lastAttemptAtUtc,
    String? lastErrorCode,
  }) : lastErrorCode = lastErrorCode {
    if (pending < 0 ||
        accepted < 0 ||
        rejected < 0 ||
        conflicts < 0 ||
        retryable < 0 ||
        (lastErrorCode != null &&
            !RegExp(r'^[A-Z][A-Z0-9_]{0,79}$').hasMatch(lastErrorCode))) {
      throw ArgumentError('Invalid synchronization summary.');
    }
  }

  final SynchronizationState state;
  final int pending;
  final int accepted;
  final int rejected;
  final int conflicts;
  final int retryable;
  final DateTime? lastAttemptAtUtc;
  final String? lastErrorCode;

  Map<String, Object?> toJson() => {
        'managementApiVersion': managementApiVersion,
        'state': state.wireValue,
        'pending': pending,
        'accepted': accepted,
        'rejected': rejected,
        'conflicts': conflicts,
        'retryable': retryable,
        if (lastAttemptAtUtc != null)
          'lastAttemptAtUtc': lastAttemptAtUtc!.toUtc().toIso8601String(),
        if (lastErrorCode != null) 'lastErrorCode': lastErrorCode,
      };
}

class AdministrativeOperationSummary {
  AdministrativeOperationSummary({
    required this.operationId,
    required this.operation,
    required this.state,
    required this.correlationId,
    required DateTime occurredAtUtc,
  }) : occurredAtUtc = occurredAtUtc.toUtc() {
    if (!RegExp(r'^[a-z][a-z0-9_.-]{0,79}$').hasMatch(operation) ||
        !RegExp(r'^cor_[a-f0-9]{32}$').hasMatch(correlationId)) {
      throw ArgumentError('Invalid administrative operation summary.');
    }
  }

  final String operationId;
  final String operation;
  final AdministrativeOperationState state;
  final String correlationId;
  final DateTime occurredAtUtc;

  Map<String, Object?> toJson() => {
        'managementApiVersion': managementApiVersion,
        'operationId': operationId,
        'operation': operation,
        'state': state.wireValue,
        'correlationId': correlationId,
        'occurredAtUtc': occurredAtUtc.toIso8601String(),
      };
}

bool _containsCredentialMaterial(String text) =>
    RegExp(r'bearer\s+[a-z0-9_-]{32,}', caseSensitive: false).hasMatch(text) ||
    RegExp(
      r'postgres(?:ql)?://[^\s/@:]+:[^\s/@]+@',
      caseSensitive: false,
    ).hasMatch(text) ||
    RegExp(
      r'(?:token|password|secret)\s*[=:]\s*[^\s,;]{8,}',
      caseSensitive: false,
    ).hasMatch(text);

Map<String, dynamic> _managementMap(Object? value, String name) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('Invalid $name contract.');
  }
  return Map<String, dynamic>.from(value);
}

void _managementKeys(Map<String, dynamic> value, Set<String> allowed) {
  if (value.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('Unsupported management contract field.');
  }
}

String _managementString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty || value.length > 256) {
    throw FormatException('Invalid management field: $key.');
  }
  return value;
}
