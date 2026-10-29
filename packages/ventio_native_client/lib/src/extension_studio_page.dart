import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';
import 'package:ventio_core/ventio_core.dart';

import 'app_localization.dart';
import 'client_pairing_page.dart';
import 'command_id.dart';
import 'diagnostics_center_page.dart';
import 'device_management_page.dart';
import 'extension_store.dart';
import 'host_credentials.dart';
import 'host_device_management.dart';
import 'host_extension_packages.dart';
import 'host_overview_page.dart';
import 'host_readiness.dart';
import 'host_user_management.dart';
import 'host_sync_service.dart';
import 'host_transport.dart';
import 'local_command_queue.dart';
import 'local_diagnostics.dart';
import 'maintenance_request_page.dart';
import 'print_format_renderer.dart';
import 'queued_record_reconciliation.dart';
import 'role_administration_page.dart';
import 'synchronization_page.dart';
import 'transport_fixture.dart';
import 'users_permissions_page.dart';

enum _StudioMenuAction {
  connect,
  sync,
  manageUsers,
  manageDevices,
  hostOverview,
  pairClient,
  localDiagnostics,
  synchronization,
  installFromHost,
  installPackage,
  offlineProof,
}

const Map<String, IconData> _generatedPageIcons = {
  'list': Icons.view_list_outlined,
  'folder': Icons.folder_outlined,
  'article': Icons.article_outlined,
  'location': Icons.place_outlined,
  'business': Icons.business_outlined,
  'tag': Icons.sell_outlined,
  'event': Icons.event_outlined,
  'checklist': Icons.checklist,
  'grid': Icons.grid_view_outlined,
};

IconData _generatedPageIcon(String? id) =>
    _generatedPageIcons[id] ?? _generatedPageIcons['list']!;

String _extensionMessageKey(String moduleId, String message) {
  final namespace = moduleId.toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]+'),
    '_',
  );
  return 'extension.$namespace.module.$message';
}

String _localDiagnosticsLabel(BuildContext context) => context
    .extensionMetadataText('native.ui.local_diagnostics', 'Local diagnostics');

Future<HostSyncFailureException> _recordHostSyncFailure(
  Object error, {
  DiagnosticEventSource? source,
}) async {
  final code = switch (error) {
    HostTransportException() => error.code,
    HostPackageTransportException() => error.code,
    HostSyncIdentityMismatchException() => 'HOST_QUEUE_IDENTITY_MISMATCH',
    _ => 'HOST_SYNC_FAILED',
  };
  final safeCode = RegExp(r'^[A-Z][A-Z0-9_]{0,79}$').hasMatch(code)
      ? code
      : 'HOST_SYNC_FAILED';
  final correlationId =
      error is HostTransportException && error.correlationId != null
      ? error.correlationId!
      : newLocalCorrelationId();
  final retryable = error is HostTransportException
      ? error.retryable
      : error is HostPackageTransportException && error.retryable;
  final category = switch (safeCode) {
    'HOST_UNREACHABLE' ||
    'HOST_REQUEST_TIMEOUT' ||
    'HOST_TLS_VALIDATION_FAILED' => ManagementDiagnosticCategory.networkTls,
    'UNAUTHENTICATED' ||
    'HOST_CREDENTIAL_MISSING' => ManagementDiagnosticCategory.authentication,
    'PERMISSION_DENIED' ||
    'SCOPE_DENIED' ||
    'HOST_QUEUE_IDENTITY_MISMATCH' ||
    'HOST_PROFILE_IDENTITY_CHANGED' =>
      ManagementDiagnosticCategory.authorization,
    _ => ManagementDiagnosticCategory.synchronization,
  };
  final input = LocalDiagnosticInput(
    code: safeCode,
    component: 'client.synchronization',
    category: category,
    severity: ManagementDiagnosticSeverity.error,
    retryable: retryable,
    messageKey: 'native.diagnostics.host_sync_failed',
    safeExplanation:
        'Host synchronization failed. Pending operations remain saved on this device.',
    recommendedAction:
        'Check Host connectivity and permissions, then retry. Share the correlation reference with an administrator if the issue continues.',
    correlationId: correlationId,
  );
  LocalDiagnosticsStore? ownedStore;
  try {
    if (source != null) {
      await source.record(input);
    } else {
      ownedStore = await openDefaultLocalDiagnosticsStore();
      await ownedStore.record(input);
    }
  } catch (_) {
    // A diagnostic write failure must never replace the original safe error.
  } finally {
    try {
      await ownedStore?.close();
    } catch (_) {
      // Queue state remains available if diagnostic persistence fails.
    }
  }
  return HostSyncFailureException(
    code: safeCode,
    correlationId: correlationId,
    retryable: retryable,
  );
}

class ExtensionStudioPage extends StatefulWidget {
  const ExtensionStudioPage({
    required this.store,
    required this.queue,
    this.credentialVault,
    this.hostPackageClientFactory,
    this.diagnosticEventSource,
    this.scope = const RecordScope(
      organizationId: 'local-organization',
      companyId: 'local-company',
      branchId: 'local-branch',
    ),
    super.key,
  });

  final LocalExtensionStore store;
  final LocalCommandQueue queue;
  final HostCredentialVault? credentialVault;
  final HostExtensionPackageClientFactory? hostPackageClientFactory;
  final DiagnosticEventSource? diagnosticEventSource;
  final RecordScope scope;

  @override
  State<ExtensionStudioPage> createState() => _ExtensionStudioPageState();
}

class _ExtensionStudioPageState extends State<ExtensionStudioPage> {
  bool _loading = true;
  List<LocalExtension> _extensions = const [];
  HostConnectionProfile? _hostProfile;
  HostSessionIdentity? _hostIdentity;
  String? _loadError;
  String? _queueRecoveryWarning;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait<Object?>([
        widget.store.listExtensions(),
        widget.store.getHostProfile(),
      ]);
      if (!mounted) return;
      setState(() {
        _extensions = values[0] as List<LocalExtension>;
        _hostProfile = values[1] as HostConnectionProfile?;
        _loading = false;
        _loadError = null;
        _queueRecoveryWarning = null;
      });
      unawaited(_refreshHostIdentity());
      await reconcileQueuedRecords(widget.store, widget.queue);
      await _enqueueOrphanedHostRecords();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString();
      });
    }
  }

  Future<void> _refreshHostIdentity() async {
    final profile = _hostProfile;
    final vault = widget.credentialVault;
    if (profile == null || vault == null) {
      if (mounted) setState(() => _hostIdentity = null);
      return;
    }
    try {
      final identity = await _hostPackageClient(
        endpoint: Uri.parse(profile.endpoint),
        vault: vault,
      ).session();
      if (!mounted || _hostProfile?.endpoint != profile.endpoint) return;
      final selectedScopeIsStillGranted = identity.scopes.any(
        (scope) =>
            scope.companyId == profile.companyId &&
            scope.branchId == profile.branchId,
      );
      setState(() {
        _hostIdentity =
            identity.persistent &&
                identity.tenantId == profile.tenantId &&
                identity.actorId == profile.actorId &&
                identity.deviceId == profile.deviceId &&
                selectedScopeIsStillGranted
            ? identity
            : null;
      });
    } catch (_) {
      if (mounted && _hostProfile?.endpoint == profile.endpoint) {
        setState(() => _hostIdentity = null);
      }
    }
  }

  bool get _canManageRoles {
    final profile = _hostProfile;
    final identity = _hostIdentity;
    if (profile == null ||
        identity == null ||
        !identity.roleAdministrationAvailable) {
      return false;
    }
    return identity.scopes.any(
      (scope) =>
          scope.companyId == profile.companyId &&
          scope.branchId == profile.branchId &&
          scope.permissions.contains('identity.roles.manage'),
    );
  }

  bool get _canManageUsers {
    final profile = _hostProfile;
    final identity = _hostIdentity;
    if (profile == null || identity == null || !identity.persistent) {
      return false;
    }
    return identity.scopes.any(
      (scope) =>
          scope.companyId == profile.companyId &&
          scope.branchId == profile.branchId &&
          scope.permissions.contains(identityUsersManagePermission),
    );
  }

  bool get _canManageDevices {
    final profile = _hostProfile;
    final identity = _hostIdentity;
    if (profile == null || identity == null || !identity.persistent) {
      return false;
    }
    return identity.scopes.any(
      (scope) =>
          scope.companyId == profile.companyId &&
          scope.branchId == profile.branchId &&
          scope.permissions.contains(manageHostDevicesPermission),
    );
  }

  bool get _canManagePairings {
    final profile = _hostProfile;
    final identity = _hostIdentity;
    if (profile == null || identity == null || !identity.persistent) {
      return false;
    }
    return identity.scopes.any(
      (scope) =>
          scope.companyId == profile.companyId &&
          scope.branchId == profile.branchId &&
          scope.permissions.contains(manageHostPairingPermission),
    );
  }

  Future<void> _openDeviceManagement() async {
    final profile = _hostProfile;
    final identity = _hostIdentity;
    final vault = widget.credentialVault;
    if ((!_canManageDevices && !_canManagePairings) ||
        profile == null ||
        identity == null ||
        vault == null) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => DeviceManagementPage(
          client: HostDeviceManagementClient(
            endpoint: Uri.parse(profile.endpoint),
            credentials: vault,
            verifiedIdentity: identity,
            companyId: profile.companyId,
            branchId: profile.branchId,
          ),
          userDirectory: _canManageUsers
              ? HostUserManagementClient(
                  endpoint: Uri.parse(profile.endpoint),
                  credentials: vault,
                  verifiedIdentity: identity,
                  companyId: profile.companyId,
                  branchId: profile.branchId,
                )
              : null,
        ),
      ),
    );
    await _refreshHostIdentity();
  }

  bool get _canReadHostStatus {
    final profile = _hostProfile;
    final identity = _hostIdentity;
    if (profile == null || identity == null || !identity.persistent) {
      return false;
    }
    return identity.scopes.any(
      (scope) =>
          scope.companyId == profile.companyId &&
          scope.branchId == profile.branchId &&
          scope.permissions.contains(hostStatusReadPermission),
    );
  }

  Future<void> _openUserManagement() async {
    final profile = _hostProfile;
    final identity = _hostIdentity;
    final vault = widget.credentialVault;
    if (!_canManageUsers ||
        profile == null ||
        identity == null ||
        vault == null) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => UsersPermissionsPage(
          client: HostUserManagementClient(
            endpoint: Uri.parse(profile.endpoint),
            credentials: vault,
            verifiedIdentity: identity,
            companyId: profile.companyId,
            branchId: profile.branchId,
          ),
        ),
      ),
    );
    await _refreshHostIdentity();
  }

  Future<void> _openHostOverview() async {
    final profile = _hostProfile;
    final identity = _hostIdentity;
    final vault = widget.credentialVault;
    if (!_canReadHostStatus ||
        profile == null ||
        identity == null ||
        vault == null) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => HostOverviewPage(
          client: HostReadinessClient(
            endpoint: Uri.parse(profile.endpoint),
            credentials: vault,
            verifiedIdentity: identity,
            companyId: profile.companyId,
            branchId: profile.branchId,
          ),
        ),
      ),
    );
  }

  Future<void> _openClientPairing() async {
    final vault = widget.credentialVault;
    if (vault == null) {
      _message('Secure Host credential storage is unavailable on this build.');
      return;
    }
    final enrolled = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => ClientPairingPage(
          store: widget.store,
          credentials: vault,
          initialEndpoint: _hostProfile?.endpoint,
          diagnosticEventSource: widget.diagnosticEventSource,
        ),
      ),
    );
    if (enrolled == true) await _load();
  }

  Future<void> _openLocalDiagnostics() async {
    DiagnosticEventSource? source = widget.diagnosticEventSource;
    LocalDiagnosticsStore? ownedStore;
    try {
      if (source == null) {
        ownedStore = await openDefaultLocalDiagnosticsStore();
        source = ownedStore;
      }
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (context) => DiagnosticsCenterPage(store: source!),
        ),
      );
    } catch (_) {
      if (mounted) {
        _message('Local diagnostics are unavailable on this device.');
      }
    } finally {
      try {
        await ownedStore?.close();
      } catch (_) {
        // Do not replace a completed UI flow with a raw local-storage error.
      }
    }
  }

  Future<void> _openRoleAdministration() async {
    final profile = _hostProfile;
    final vault = widget.credentialVault;
    if (!_canManageRoles || profile == null || vault == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => RoleAdministrationPage(
          client: _hostPackageClient(
            endpoint: Uri.parse(profile.endpoint),
            vault: vault,
          ),
          tenantId: profile.tenantId,
          companyId: profile.companyId,
          branchId: profile.branchId,
        ),
      ),
    );
    await _refreshHostIdentity();
  }

  Future<void> _enqueueOrphanedHostRecords() async {
    final profile = _hostProfile;
    if (profile == null ||
        profile.actorId == null ||
        profile.deviceId == null) {
      return;
    }
    final scope = RecordScope(
      organizationId: profile.tenantId,
      companyId: profile.companyId,
      branchId: profile.branchId,
    );
    final records = await widget.store.listUnqueuedRecords(scope: scope);
    for (final record in records) {
      final extension = await widget.store.getExtension(record.moduleId);
      if (extension?.state != ExtensionState.active) continue;
      final metadata = await widget.store.listDocTypes(record.moduleId);
      final matching = metadata.where(
        (definition) => definition['name'] == record.docTypeName,
      );
      if (matching.length != 1) continue;
      final definition = DocTypeDefinition.fromJson(matching.single);
      final operation = record.hostRevision == null ? 'create' : 'update';
      if (!definition.operations.contains(operation)) continue;
      try {
        await _queueDynamicRecordCommand(
          queue: widget.queue,
          store: widget.store,
          profile: profile,
          record: record,
          moduleVersion: extension!.version,
          definition: definition,
          values: record.values,
        );
      } catch (error) {
        if (mounted) {
          setState(() => _queueRecoveryWarning = error.toString());
        }
      }
    }
  }

  Future<void> _createExtension() async {
    final values = await showDialog<_ExtensionFormValues>(
      context: context,
      builder: (context) =>
          _ExtensionFormDialog(availableExtensions: _extensions),
    );
    if (values == null) return;
    try {
      await widget.store.createExtension(
        moduleId: values.moduleId,
        displayName: values.displayName,
        description: values.description,
        version: values.version,
        dependencies: values.dependencies,
      );
      await _load();
      if (!mounted) return;
      await _openExtension(values.moduleId);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _installBundle() async {
    final source = await showDialog<String>(
      context: context,
      builder: (context) => const _ExtensionBundleImportDialog(),
    );
    if (source == null || source.isEmpty) return;

    try {
      if (source.length > ExtensionBundle.maxEncodedBytes) {
        throw const FormatException('Package JSON exceeds 1 MiB.');
      }
      final decoded = jsonDecode(source);
      if (decoded is! Map) {
        throw const FormatException('Package JSON must be an object.');
      }
      final bundle = ExtensionBundle.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      if (!mounted) return;
      final install = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const VentioText('native.ui.review_extension_package'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.extensionMetadataText(
                    bundle.manifest.displayNameKey,
                    bundle.manifest.displayName,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText('${bundle.moduleId} · ${bundle.version}'),
                const SizedBox(height: 12),
                Text(
                  context.ventioText(
                    'native.ui.doctypes_summary',
                    params: {
                      'names': bundle.docTypes
                          .map((type) => type.name)
                          .join(', '),
                    },
                  ),
                ),
                const SizedBox(height: 12),
                _LocalOnlyNotice(
                  title: context.ventioText(
                    'native.ui.local_installation_only',
                  ),
                  body: context.ventioText(
                    'native.ui.installing_this_package_saves_a_local_draft_on_this_device_it_does_not_a',
                  ),
                  icon: Icons.phonelink_lock_outlined,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const VentioText('native.ui.cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const VentioText('native.ui.install_on_this_device'),
            ),
          ],
        ),
      );
      if (install != true) return;
      await widget.store.installBundle(bundle);
      await _load();
      if (!mounted) return;
      _message('Package installed locally as a draft.');
      await _openExtension(bundle.moduleId);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _configureHost() async {
    final vault = widget.credentialVault;
    if (vault == null) {
      _message('Secure Host credential storage is unavailable on this build.');
      return;
    }
    final values = await showDialog<_HostConnectionValues>(
      context: context,
      builder: (context) => _HostConnectionDialog(profile: _hostProfile),
    );
    if (values == null) return;
    Uri? endpoint;
    String? previousToken;
    var replacedCredential = false;
    var profileSaved = false;
    try {
      endpoint = HostCredentialVault.normalizeEndpoint(
        Uri.parse(values.endpoint.trim()),
      );
      previousToken = await vault.read(endpoint);
      if (values.token.isNotEmpty) {
        await vault.save(endpoint, values.token.trim());
        replacedCredential = true;
      } else if (previousToken == null) {
        throw const HostPackageTransportException('HOST_CREDENTIAL_MISSING');
      }
      final client = _hostPackageClient(endpoint: endpoint, vault: vault);
      final identity = await client.session();
      if (!identity.persistent) {
        throw const HostPackageTransportException(
          'PERSISTENT_HOST_IDENTITY_REQUIRED',
        );
      }
      if (identity.scopes.isEmpty) {
        throw const HostPackageTransportException('HOST_SCOPE_UNAVAILABLE');
      }
      if (!mounted) return;
      final selected = await showDialog<HostScopeGrant>(
        context: context,
        builder: (context) => _HostScopeDialog(
          tenantId: identity.tenantId,
          scopes: identity.scopes,
          initialCompanyId: _hostProfile?.companyId,
          initialBranchId: _hostProfile?.branchId,
        ),
      );
      if (selected == null) {
        if (replacedCredential) {
          await _restoreCredential(vault, endpoint, previousToken);
        }
        return;
      }
      final profile = HostConnectionProfile(
        endpoint: endpoint.toString(),
        tenantId: identity.tenantId,
        companyId: selected.companyId,
        branchId: selected.branchId,
        actorId: identity.actorId,
        deviceId: identity.deviceId,
      );
      await widget.store.saveHostProfile(profile);
      profileSaved = true;
      final oldEndpoint = _hostProfile?.endpoint;
      if (oldEndpoint != null && oldEndpoint != endpoint.toString()) {
        await vault.delete(Uri.parse(oldEndpoint));
      }
      await _load();
      _message('Authenticated Host scope saved for this device.');
    } catch (error) {
      if (!profileSaved && replacedCredential && endpoint != null) {
        try {
          await _restoreCredential(vault, endpoint, previousToken);
        } catch (_) {
          /* Keep the primary Host error visible. */
        }
      }
      if (mounted) _message(error.toString());
    }
  }

  Future<void> _restoreCredential(
    HostCredentialVault vault,
    Uri endpoint,
    String? previousToken,
  ) async {
    if (previousToken == null) {
      await vault.delete(endpoint);
    } else {
      await vault.save(endpoint, previousToken);
    }
  }

  Future<void> _disconnectHost() async {
    final profile = _hostProfile;
    if (profile == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const VentioText('native.ui.disconnect_this_device_from_host'),
        content: const VentioText(
          'native.ui.this_removes_the_saved_host_scope_and_this_endpoint_s_device_credential',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const VentioText('native.ui.cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const VentioText('native.ui.disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final vault = widget.credentialVault;
    if (vault != null) {
      await vault.delete(Uri.parse(profile.endpoint));
    }
    await widget.store.clearHostProfile();
    if (mounted) setState(() => _hostIdentity = null);
    await _load();
    _message('Host disconnected. Local work was preserved.');
  }

  Future<void> _syncHost() async {
    final profile = _hostProfile;
    final vault = widget.credentialVault;
    if (profile == null || vault == null) {
      _message('Configure an authenticated Host connection first.');
      return;
    }
    try {
      final resolved = await _syncPendingFromHost();
      if (mounted) _message('Host resolved $resolved queued command(s).');
    } on HostSyncFailureException catch (failure) {
      if (mounted) {
        _message(
          context.ventioText(
            'native.ui.sync_failed_message',
            params: {
              'code': failure.code,
              'correlationId': failure.correlationId,
            },
          ),
        );
      }
    }
  }

  Future<int> _syncPendingFromHost() async {
    final profile = _hostProfile;
    final vault = widget.credentialVault;
    if (profile == null || vault == null) {
      throw HostSyncFailureException(
        code: 'HOST_CREDENTIAL_MISSING',
        correlationId: newLocalCorrelationId(),
        retryable: false,
      );
    }
    try {
      final identity = await _requireHostSyncIdentity(
        _hostPackageClient(endpoint: Uri.parse(profile.endpoint), vault: vault),
        profile,
      );
      final resolved = await HostSyncService(
        queue: widget.queue,
        identity: identity,
        transport: HttpHostCommandTransport(
          endpoint: Uri.parse(profile.endpoint),
          credentials: vault,
        ),
      ).syncPending();
      await reconcileQueuedRecords(widget.store, widget.queue);
      await _load();
      return resolved;
    } catch (error) {
      try {
        await reconcileQueuedRecords(widget.store, widget.queue);
      } catch (_) {
        // Queue recovery remains visible through the dedicated recovery warning.
      }
      throw await _recordHostSyncFailure(
        error,
        source: widget.diagnosticEventSource,
      );
    }
  }

  Future<void> _openSynchronization() async {
    final profile = _hostProfile;
    final vault = widget.credentialVault;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => SynchronizationPage(
          queue: widget.queue,
          onRetryPending: profile != null && vault != null
              ? () async {
                  await _syncPendingFromHost();
                }
              : null,
        ),
      ),
    );
  }

  Future<void> _installApprovedFromHost() async {
    final profile = _hostProfile;
    final vault = widget.credentialVault;
    if (profile == null || vault == null) {
      _message('Configure an authenticated Host connection first.');
      return;
    }
    final client = _hostPackageClient(
      endpoint: Uri.parse(profile.endpoint),
      vault: vault,
    );
    final requested = await showDialog<HostApprovedPackageSummary>(
      context: context,
      builder: (context) => _HostApprovedPackageDialog(
        client: client,
        companyId: profile.companyId,
        branchId: profile.branchId,
      ),
    );
    if (requested == null) return;
    try {
      final bundle = await client.readApproved(
        moduleId: requested.moduleId,
        version: requested.version,
        companyId: profile.companyId,
        branchId: profile.branchId,
        expectedPackageSha256: requested.packageSha256,
      );
      if (!mounted) return;
      final install = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const VentioText('native.ui.install_host_approved_extension'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.extensionMetadataText(
                    bundle.manifest.displayNameKey,
                    bundle.manifest.displayName,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText('${bundle.moduleId} · ${bundle.version}'),
                const SizedBox(height: 12),
                Text(
                  context.ventioText(
                    'native.ui.doctypes_summary',
                    params: {
                      'names': bundle.docTypes
                          .map((type) => type.name)
                          .join(', '),
                    },
                  ),
                ),
                const SizedBox(height: 12),
                _LocalOnlyNotice(
                  title: context.ventioText('native.ui.host_approved_package'),
                  body: context.ventioText(
                    'native.ui.the_host_approved_this_metadata_package_installing_saves_it_on_this_devi',
                  ),
                  icon: Icons.verified_user_outlined,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const VentioText('native.ui.cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const VentioText('native.ui.install_on_this_device'),
            ),
          ],
        ),
      );
      if (install != true) return;
      await widget.store.installBundle(bundle);
      await _load();
      if (!mounted) return;
      _message('Host-approved extension installed as a local draft.');
      await _openExtension(bundle.moduleId);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _openExtension(String moduleId) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => ExtensionDetailsPage(
          store: widget.store,
          queue: widget.queue,
          moduleId: moduleId,
          scope: widget.scope,
          hostProfile: _hostProfile,
          credentialVault: widget.credentialVault,
          hostPackageClientFactory: widget.hostPackageClientFactory,
        ),
      ),
    );
    await _load();
  }

  Future<void> _openMaintenanceProof() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => MaintenanceRequestPage(
          queue: widget.queue,
          transport: const DeterministicTransportFixture(),
        ),
      ),
    );
  }

  void _message(String value) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  HostExtensionPackageClient _hostPackageClient({
    required Uri endpoint,
    required HostCredentialVault vault,
  }) =>
      widget.hostPackageClientFactory?.call(
        endpoint: endpoint,
        credentials: vault,
      ) ??
      HostExtensionPackageClient(endpoint: endpoint, credentials: vault);

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      appBar: AppBar(
        title: const VentioText('native.ui.ventio_extension_builder'),
        actions: [
          if (width < 600)
            PopupMenuButton<_StudioMenuAction>(
              tooltip: context.ventioText('native.ui.workspace_actions'),
              onSelected: (action) {
                switch (action) {
                  case _StudioMenuAction.connect:
                    _configureHost();
                  case _StudioMenuAction.sync:
                    _syncHost();
                  case _StudioMenuAction.manageUsers:
                    _openUserManagement();
                  case _StudioMenuAction.manageDevices:
                    _openDeviceManagement();
                  case _StudioMenuAction.hostOverview:
                    _openHostOverview();
                  case _StudioMenuAction.pairClient:
                    _openClientPairing();
                  case _StudioMenuAction.localDiagnostics:
                    _openLocalDiagnostics();
                  case _StudioMenuAction.synchronization:
                    _openSynchronization();
                  case _StudioMenuAction.installFromHost:
                    _installApprovedFromHost();
                  case _StudioMenuAction.installPackage:
                    _installBundle();
                  case _StudioMenuAction.offlineProof:
                    _openMaintenanceProof();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _StudioMenuAction.connect,
                  child: Text(
                    _hostProfile == null ? 'Connect Host' : 'Host settings',
                  ),
                ),
                PopupMenuItem(
                  value: _StudioMenuAction.localDiagnostics,
                  child: Text(_localDiagnosticsLabel(context)),
                ),
                if (widget.credentialVault != null)
                  const PopupMenuItem(
                    value: _StudioMenuAction.pairClient,
                    child: VentioText('native.ui.enroll_client'),
                  ),
                const PopupMenuItem(
                  value: _StudioMenuAction.synchronization,
                  child: VentioText('native.ui.synchronization'),
                ),
                if (_canManageUsers)
                  const PopupMenuItem(
                    value: _StudioMenuAction.manageUsers,
                    child: VentioText('native.ui.users_permissions'),
                  ),
                if (_canManageDevices || _canManagePairings)
                  const PopupMenuItem(
                    value: _StudioMenuAction.manageDevices,
                    child: VentioText('native.ui.host_devices'),
                  ),
                if (_canReadHostStatus)
                  const PopupMenuItem(
                    value: _StudioMenuAction.hostOverview,
                    child: VentioText('native.ui.host_overview'),
                  ),
                PopupMenuItem(
                  value: _StudioMenuAction.installFromHost,
                  enabled: _hostProfile != null,
                  child: const VentioText('native.ui.install_from_host'),
                ),
                PopupMenuItem(
                  value: _StudioMenuAction.sync,
                  enabled: _hostProfile != null,
                  child: const VentioText('native.ui.sync_pending_records'),
                ),
                const PopupMenuItem(
                  value: _StudioMenuAction.installPackage,
                  child: VentioText('native.ui.install_package'),
                ),
                const PopupMenuItem(
                  value: _StudioMenuAction.offlineProof,
                  child: VentioText('native.ui.offline_queue_proof'),
                ),
              ],
            )
          else if (width < 1200) ...[
            if (widget.credentialVault != null)
              IconButton(
                tooltip: context.ventioText('native.ui.enroll_client'),
                onPressed: _openClientPairing,
                icon: const Icon(Icons.phonelink_setup_outlined),
              ),
            IconButton(
              tooltip: _localDiagnosticsLabel(context),
              onPressed: _openLocalDiagnostics,
              icon: const Icon(Icons.health_and_safety_outlined),
            ),
            if (_canReadHostStatus)
              IconButton(
                tooltip: context.ventioText('native.ui.host_overview'),
                onPressed: _openHostOverview,
                icon: const Icon(Icons.monitor_heart_outlined),
              ),
            IconButton(
              tooltip: context.ventioText('native.ui.synchronization'),
              onPressed: _openSynchronization,
              icon: const Icon(Icons.sync_alt_outlined),
            ),
            IconButton(
              tooltip: context.ventioText('native.ui.sync_pending_records'),
              onPressed: _hostProfile == null ? null : _syncHost,
              icon: const Icon(Icons.sync),
            ),
            IconButton(
              tooltip: context.ventioText(
                'native.ui.install_host_approved_extension',
              ),
              onPressed: _hostProfile == null ? null : _installApprovedFromHost,
              icon: const Icon(Icons.cloud_download_outlined),
            ),
            IconButton(
              tooltip: _hostProfile == null ? 'Connect Host' : 'Host settings',
              onPressed: _configureHost,
              icon: const Icon(Icons.cloud_outlined),
            ),
            IconButton(
              tooltip: context.ventioText(
                'native.ui.install_extension_package',
              ),
              onPressed: _installBundle,
              icon: const Icon(Icons.file_download_outlined),
            ),
            IconButton(
              tooltip: context.ventioText('native.ui.offline_queue_proof'),
              onPressed: _openMaintenanceProof,
              icon: const Icon(Icons.cloud_off_outlined),
            ),
          ] else ...[
            if (widget.credentialVault != null)
              TextButton.icon(
                onPressed: _openClientPairing,
                icon: const Icon(Icons.phonelink_setup_outlined),
                label: const VentioText('native.ui.enroll_client'),
              ),
            TextButton.icon(
              onPressed: _openLocalDiagnostics,
              icon: const Icon(Icons.health_and_safety_outlined),
              label: Text(_localDiagnosticsLabel(context)),
            ),
            if (_canReadHostStatus)
              TextButton.icon(
                onPressed: _openHostOverview,
                icon: const Icon(Icons.monitor_heart_outlined),
                label: const VentioText('native.ui.host_overview'),
              ),
            TextButton.icon(
              onPressed: _openSynchronization,
              icon: const Icon(Icons.sync_alt_outlined),
              label: const VentioText('native.ui.synchronization'),
            ),
            TextButton.icon(
              onPressed: _hostProfile == null ? null : _syncHost,
              icon: const Icon(Icons.sync),
              label: const VentioText('native.ui.sync_pending'),
            ),
            TextButton.icon(
              onPressed: _hostProfile == null ? null : _installApprovedFromHost,
              icon: const Icon(Icons.cloud_download_outlined),
              label: const VentioText('native.ui.install_from_host'),
            ),
            TextButton.icon(
              onPressed: _configureHost,
              icon: const Icon(Icons.cloud_outlined),
              label: Text(_hostProfile == null ? 'Connect Host' : 'Host'),
            ),
            TextButton.icon(
              onPressed: _installBundle,
              icon: const Icon(Icons.file_download_outlined),
              label: const VentioText('native.ui.install_package'),
            ),
            TextButton.icon(
              onPressed: _openMaintenanceProof,
              icon: const Icon(Icons.cloud_off_outlined),
              label: const VentioText('native.ui.offline_queue_proof'),
            ),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                _LocalOnlyNotice(
                  title: _hostProfile == null
                      ? 'Device workspace'
                      : 'Host connected · ${_hostProfile!.tenantId}',
                  body: _hostProfile == null
                      ? 'Extension definitions and preview records are stored on this device. Connect to an authenticated Host to submit packages for review or install approved packages.'
                      : 'Selected scope: ${_hostProfile!.companyId} / ${_hostProfile!.branchId}. Local drafts and records stay provisional; only Host-approved packages can be installed from the registry.',
                  icon: _hostProfile == null
                      ? Icons.phonelink_setup_outlined
                      : Icons.cloud_done_outlined,
                ),
                if (widget.credentialVault != null) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('client-pairing-open'),
                      onPressed: _openClientPairing,
                      icon: const Icon(Icons.phonelink_setup_outlined),
                      label: const VentioText('native.ui.enroll_client'),
                    ),
                  ),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    onPressed: _openLocalDiagnostics,
                    icon: const Icon(Icons.health_and_safety_outlined),
                    label: Text(_localDiagnosticsLabel(context)),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    onPressed: _openSynchronization,
                    icon: const Icon(Icons.sync_alt_outlined),
                    label: const VentioText('native.ui.synchronization'),
                  ),
                ),
                const SizedBox(height: 8),
                if (_queueRecoveryWarning != null) ...[
                  const SizedBox(height: 12),
                  _StateCard(
                    icon: Icons.warning_amber_outlined,
                    title: context.ventioText(
                      'native.ui.a_saved_record_could_not_enter_the_host_queue',
                    ),
                    body: _queueRecoveryWarning!,
                    action: TextButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const VentioText('native.ui.retry_queue_recovery'),
                    ),
                  ),
                ],
                if (_hostProfile != null) ...[
                  if (_canManageUsers) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        onPressed: _openUserManagement,
                        icon: const Icon(Icons.people_alt_outlined),
                        label: const VentioText('native.ui.users_permissions'),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_canManageRoles) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        onPressed: _openRoleAdministration,
                        icon: const Icon(Icons.manage_accounts_outlined),
                        label: const VentioText(
                          'native.ui.manage_roles_access',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_canManageDevices || _canManagePairings) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        onPressed: _openDeviceManagement,
                        icon: const Icon(Icons.devices_other_outlined),
                        label: const VentioText('native.ui.host_devices'),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: _disconnectHost,
                      icon: const Icon(Icons.link_off_outlined),
                      label: const VentioText('native.ui.disconnect_host'),
                    ),
                  ),
                ],
                if (_canReadHostStatus)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      onPressed: _openHostOverview,
                      icon: const Icon(Icons.monitor_heart_outlined),
                      label: const VentioText('native.ui.host_overview'),
                    ),
                  ),
                const SizedBox(height: 24),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 620;
                    final heading = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        VentioText(
                          'native.ui.build_an_extension',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 6),
                        const VentioText(
                          'native.ui.define_reusable_records_fields_relationships_and_screens_without_adding',
                        ),
                      ],
                    );
                    final create = FilledButton.icon(
                      onPressed: _createExtension,
                      icon: const Icon(Icons.add),
                      label: const VentioText('native.ui.new_extension'),
                    );
                    if (compact) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [heading, const SizedBox(height: 16), create],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: heading),
                        const SizedBox(width: 16),
                        create,
                      ],
                    );
                  },
                ),
                const SizedBox(height: 24),
                if (_loading)
                  const Center(child: CircularProgressIndicator())
                else if (_loadError != null)
                  _StateCard(
                    icon: Icons.error_outline,
                    title: context.ventioText(
                      'native.ui.extensions_could_not_be_loaded',
                    ),
                    body: _loadError!,
                    action: TextButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const VentioText('native.ui.try_again'),
                    ),
                  )
                else if (_extensions.isEmpty)
                  _StateCard(
                    icon: Icons.extension_outlined,
                    title: context.ventioText(
                      'native.ui.start_with_an_extension',
                    ),
                    body: context.ventioText(
                      'native.ui.create_a_local_draft_add_one_or_more_doctypes_then_preview_the_screens_g',
                    ),
                    action: FilledButton.icon(
                      onPressed: _createExtension,
                      icon: const Icon(Icons.add),
                      label: const VentioText(
                        'native.ui.create_your_first_extension',
                      ),
                    ),
                  )
                else ...[
                  VentioText(
                    'native.ui.your_extensions',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  for (final extension in _extensions)
                    _ExtensionCard(
                      extension: extension,
                      onTap: () => _openExtension(extension.moduleId),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HostConnectionValues {
  const _HostConnectionValues(this.endpoint, this.token);

  final String endpoint;
  final String token;
}

class _HostConnectionDialog extends StatefulWidget {
  const _HostConnectionDialog({this.profile});

  final HostConnectionProfile? profile;

  @override
  State<_HostConnectionDialog> createState() => _HostConnectionDialogState();
}

class _HostConnectionDialogState extends State<_HostConnectionDialog> {
  late final TextEditingController _endpoint = TextEditingController(
    text: widget.profile?.endpoint ?? '',
  );
  final TextEditingController _token = TextEditingController();

  @override
  void dispose() {
    _endpoint.dispose();
    _token.dispose();
    super.dispose();
  }

  void _save() {
    try {
      HostCredentialVault.normalizeEndpoint(Uri.parse(_endpoint.text.trim()));
      Navigator.pop(
        context,
        _HostConnectionValues(_endpoint.text.trim(), _token.text.trim()),
      );
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: VentioText(
            'native.ui.enter_an_https_host_origin_or_http_for_a_same_device_loopback_host',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const VentioText('native.ui.connect_to_host'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _endpoint,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: context.ventioText('native.ui.host_origin'),
              hintText: 'https://ventio-host.example.com:8443',
              helperText: context.ventioText(
                'native.ui.remote_hosts_require_https',
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: widget.profile == null
                  ? 'Host credential'
                  : 'Replace Host credential (optional)',
              helperText: widget.profile == null
                  ? 'Stored in this device’s secure credential vault.'
                  : 'Leave blank to reuse the credential stored for this endpoint.',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const VentioText('native.ui.cancel'),
      ),
      FilledButton(
        onPressed: _save,
        child: const VentioText('native.ui.verify_host'),
      ),
    ],
  );
}

class _HostScopeDialog extends StatefulWidget {
  const _HostScopeDialog({
    required this.tenantId,
    required this.scopes,
    this.initialCompanyId,
    this.initialBranchId,
  });

  final String tenantId;
  final List<HostScopeGrant> scopes;
  final String? initialCompanyId;
  final String? initialBranchId;

  @override
  State<_HostScopeDialog> createState() => _HostScopeDialogState();
}

class _HostScopeDialogState extends State<_HostScopeDialog> {
  HostScopeGrant? _selected;

  @override
  void initState() {
    super.initState();
    for (final scope in widget.scopes) {
      if (scope.companyId == widget.initialCompanyId &&
          scope.branchId == widget.initialBranchId) {
        _selected = scope;
        break;
      }
    }
    _selected ??= widget.scopes.first;
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: const VentioText('native.ui.choose_host_scope'),
      content: SizedBox(
        width: screen.width < 640 ? null : 560,
        height: screen.height * 0.45,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.ventioText(
                'native.ui.tenant_summary',
                params: {'tenantId': widget.tenantId},
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  for (final scope in widget.scopes)
                    ListTile(
                      onTap: () => setState(() => _selected = scope),
                      leading: Icon(
                        _selected == scope
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text('${scope.companyId} / ${scope.branchId}'),
                      subtitle: Text(scope.permissions.join(' · ')),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const VentioText('native.ui.cancel'),
        ),
        FilledButton(
          onPressed: _selected == null
              ? null
              : () => Navigator.pop(context, _selected),
          child: const VentioText('native.ui.use_this_scope'),
        ),
      ],
    );
  }
}

class _HostApprovedPackageDialog extends StatefulWidget {
  const _HostApprovedPackageDialog({
    required this.client,
    required this.companyId,
    required this.branchId,
  });

  final HostExtensionPackageClient client;
  final String companyId;
  final String branchId;

  @override
  State<_HostApprovedPackageDialog> createState() =>
      _HostApprovedPackageDialogState();
}

class _HostApprovedPackageDialogState
    extends State<_HostApprovedPackageDialog> {
  static const _pageSize = 30;
  final _packages = <HostApprovedPackageSummary>[];
  bool _loading = false;
  bool _hasMore = true;
  String? _afterModuleId;
  String? _afterVersion;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPage(reset: true);
  }

  Future<void> _loadPage({bool reset = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _packages.clear();
        _afterModuleId = null;
        _afterVersion = null;
        _hasMore = true;
      }
    });
    try {
      final page = await widget.client.listApproved(
        companyId: widget.companyId,
        branchId: widget.branchId,
        limit: _pageSize,
        afterModuleId: _afterModuleId,
        afterVersion: _afterVersion,
      );
      if (!mounted) return;
      setState(() {
        _packages.addAll(page.packages);
        _hasMore = page.hasMore;
        final cursor = page.nextCursor;
        _afterModuleId = cursor?.moduleId;
        _afterVersion = cursor?.version;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: SizedBox(
        width: (size.width - 32).clamp(0.0, 640.0),
        height: (size.height - 32).clamp(0.0, 620.0),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        VentioText(
                          'native.ui.approved_extensions',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${widget.companyId} / ${widget.branchId}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: context.ventioText(
                      'native.ui.refresh_approved_extensions',
                    ),
                    onPressed: _loading ? null : () => _loadPage(reset: true),
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: context.ventioText('native.ui.close'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const Divider(),
              if (_error != null)
                MaterialBanner(
                  content: Text(_error!),
                  actions: [
                    TextButton(
                      onPressed: _loading ? null : () => _loadPage(),
                      child: const VentioText('native.ui.retry'),
                    ),
                  ],
                ),
              Expanded(
                child: _packages.isEmpty && !_loading && _error == null
                    ? const Center(
                        child: VentioText(
                          'native.ui.no_approved_extensions_are_available_for_this_host_scope',
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.separated(
                        itemCount: _packages.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final package = _packages[index];
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            leading: const CircleAvatar(
                              child: Icon(Icons.extension_outlined),
                            ),
                            title: Text(
                              context.extensionMetadataText(
                                _extensionMessageKey(package.moduleId, 'name'),
                                package.displayName,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${package.moduleId} · ${package.version}',
                                ),
                                if (package.description?.isNotEmpty == true)
                                  Text(
                                    context.extensionMetadataText(
                                      _extensionMessageKey(
                                        package.moduleId,
                                        'description',
                                      ),
                                      package.description!,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                              ],
                            ),
                            isThreeLine:
                                package.description?.isNotEmpty == true,
                            trailing: const Icon(Icons.download_outlined),
                            onTap: () => Navigator.pop(context, package),
                          );
                        },
                      ),
              ),
              if (_loading) const LinearProgressIndicator(),
              if (!_loading && _hasMore)
                Align(
                  alignment: Alignment.center,
                  child: TextButton.icon(
                    onPressed: () => _loadPage(),
                    icon: const Icon(Icons.expand_more),
                    label: const VentioText('native.ui.load_more'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExtensionBundleImportDialog extends StatefulWidget {
  const _ExtensionBundleImportDialog();

  @override
  State<_ExtensionBundleImportDialog> createState() =>
      _ExtensionBundleImportDialogState();
}

class _ExtensionBundleImportDialogState
    extends State<_ExtensionBundleImportDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const VentioText('native.ui.install_extension_package'),
    content: SizedBox(
      width: 680,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const VentioText(
            'native.ui.paste_a_ventio_declarative_package_it_can_contain_schemas_and_ui_metadat',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            minLines: 8,
            maxLines: 14,
            maxLength: ExtensionBundle.maxEncodedBytes,
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(
              labelText: context.ventioText('native.ui.package_json'),
              hintText: '{"manifest": ...}',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () async {
                final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
                if (mounted) _controller.text = clipboard?.text ?? '';
              },
              icon: const Icon(Icons.content_paste),
              label: const VentioText('native.ui.paste_from_clipboard'),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const VentioText('native.ui.cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text.trim()),
        child: const VentioText('native.ui.validate_package'),
      ),
    ],
  );
}

Future<HostSyncIdentity> _requireHostSyncIdentity(
  HostExtensionPackageClient client,
  HostConnectionProfile profile,
) async {
  final identity = await client.session();
  final selectedScopeIsGranted = identity.scopes.any(
    (scope) =>
        scope.companyId == profile.companyId &&
        scope.branchId == profile.branchId,
  );
  if (!identity.persistent ||
      identity.tenantId != profile.tenantId ||
      identity.actorId != profile.actorId ||
      identity.deviceId != profile.deviceId ||
      !selectedScopeIsGranted) {
    throw const HostPackageTransportException('HOST_PROFILE_IDENTITY_CHANGED');
  }
  return HostSyncIdentity(
    tenantId: profile.tenantId,
    companyId: profile.companyId,
    branchId: profile.branchId,
    actorId: profile.actorId!,
    deviceId: profile.deviceId!,
  );
}

class ExtensionDetailsPage extends StatefulWidget {
  const ExtensionDetailsPage({
    required this.store,
    this.queue,
    required this.moduleId,
    required this.scope,
    this.hostProfile,
    this.credentialVault,
    this.hostPackageClientFactory,
    this.readableFields,
    this.writableFields,
    this.creatableFields,
    super.key,
  });

  final LocalExtensionStore store;
  final LocalCommandQueue? queue;
  final String moduleId;
  final RecordScope scope;
  final HostConnectionProfile? hostProfile;
  final HostCredentialVault? credentialVault;
  final HostExtensionPackageClientFactory? hostPackageClientFactory;
  final Set<String>? readableFields;
  final Set<String>? writableFields;
  final Set<String>? creatableFields;

  @override
  State<ExtensionDetailsPage> createState() => _ExtensionDetailsPageState();
}

class _ExtensionDetailsPageState extends State<ExtensionDetailsPage> {
  LocalExtension? _extension;
  List<Map<String, dynamic>> _docTypes = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait<Object?>([
        widget.store.getExtension(widget.moduleId),
        widget.store.listDocTypes(widget.moduleId),
      ]);
      if (!mounted) return;
      setState(() {
        _extension = values[0] as LocalExtension?;
        _docTypes =
            List<Map<String, dynamic>>.of(
              values[1] as List<Map<String, dynamic>>,
            )..sort((left, right) {
              final leftUi = left['ui'];
              final rightUi = right['ui'];
              final leftOrder = leftUi is Map && leftUi['pageOrder'] is int
                  ? leftUi['pageOrder'] as int
                  : 0;
              final rightOrder = rightUi is Map && rightUi['pageOrder'] is int
                  ? rightUi['pageOrder'] as int
                  : 0;
              final byOrder = leftOrder.compareTo(rightOrder);
              if (byOrder != 0) return byOrder;
              return (left['name'] as String).compareTo(
                right['name'] as String,
              );
            });
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _editExtension() async {
    final extension = _extension;
    if (extension == null) return;
    final availableExtensions = await widget.store.listExtensions();
    if (!mounted) return;
    final values = await showDialog<_ExtensionFormValues>(
      context: context,
      builder: (context) => _ExtensionFormDialog(
        extension: extension,
        availableExtensions: availableExtensions,
      ),
    );
    if (values == null) return;
    await _run(() async {
      await widget.store.updateExtensionDetails(
        moduleId: extension.moduleId,
        displayName: values.displayName,
        description: values.description,
        version: values.version,
        dependencies: values.dependencies,
      );
    });
  }

  Future<void> _addDocType([Map<String, dynamic>? existing]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => DocTypeBuilderPage(
          store: widget.store,
          moduleId: widget.moduleId,
          existing: existing,
        ),
      ),
    );
    if (saved == true) await _load();
  }

  Future<void> _addReport() async {
    if (_docTypes.isEmpty) return;
    final metadata = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) =>
          _ReportBuilderDialog(moduleId: widget.moduleId, docTypes: _docTypes),
    );
    if (metadata == null) return;
    await _run(() async {
      await widget.store.saveReportDefinition(
        moduleId: widget.moduleId,
        metadata: metadata,
      );
    });
  }

  Future<void> _addPrintFormat() async {
    if (_docTypes.isEmpty) return;
    final metadata = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _PrintFormatBuilderDialog(
        moduleId: widget.moduleId,
        docTypes: _docTypes,
      ),
    );
    if (metadata == null) return;
    await _run(() async {
      await widget.store.savePrintFormatDefinition(
        moduleId: widget.moduleId,
        metadata: metadata,
      );
    });
  }

  Future<void> _openPreview(
    Map<String, dynamic> metadata, {
    bool previewOnly = true,
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => DynamicDocTypePage(
          store: widget.store,
          queue: widget.queue,
          moduleId: widget.moduleId,
          metadata: metadata,
          scope: widget.scope,
          moduleVersion: _extension?.version,
          hostProfile: widget.hostProfile,
          credentialVault: widget.credentialVault,
          hostPackageClientFactory: widget.hostPackageClientFactory,
          previewOnly: previewOnly,
        ),
      ),
    );
  }

  Future<void> _exportBundle() async {
    try {
      final bundle = await widget.store.exportBundle(widget.moduleId);
      final source = const JsonEncoder.withIndent(
        '  ',
      ).convert(bundle.toJson());
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const VentioText('native.ui.declarative_extension_package'),
          content: SizedBox(
            width: 720,
            height: MediaQuery.sizeOf(context).height * 0.6,
            child: SelectableText(source),
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: source));
                if (context.mounted) {
                  Navigator.pop(context);
                  _message('Package JSON copied to the clipboard.');
                }
              },
              icon: const Icon(Icons.copy_outlined),
              label: const VentioText('native.ui.copy_package_json'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const VentioText('native.ui.close'),
            ),
          ],
        ),
      );
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _submitPackageForReview() async {
    final profile = widget.hostProfile;
    final vault = widget.credentialVault;
    if (profile == null || vault == null) {
      _message('Configure an authenticated Host connection first.');
      return;
    }
    late final ExtensionBundle bundle;
    try {
      bundle = await widget.store.exportBundle(widget.moduleId);
    } catch (error) {
      _message(error.toString());
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const VentioText('native.ui.submit_extension_for_host_review'),
        content: SelectableText(
          context.ventioText(
            'native.ui.extension_review_submission',
            params: {
              'displayName': context.extensionMetadataText(
                _extensionMessageKey(bundle.moduleId, 'name'),
                bundle.manifest.displayName,
              ),
              'moduleId': bundle.moduleId,
              'version': bundle.version,
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const VentioText('native.ui.cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.cloud_upload_outlined),
            label: const VentioText('native.ui.submit_candidate'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      final status =
          await _hostPackageClient(
            endpoint: Uri.parse(profile.endpoint),
            vault: vault,
          ).submit(
            bundle: bundle,
            companyId: profile.companyId,
            branchId: profile.branchId,
          );
      if (mounted) {
        _message(
          status == HostPackageSubmissionStatus.submitted
              ? 'Host stored the candidate. It is not shared until an operator approves it.'
              : 'Host confirms this exact release is already approved.',
        );
      }
    } catch (error) {
      if (mounted) _message(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeState() async {
    final extension = _extension;
    if (extension == null) return;
    await _run(() async {
      if (extension.state == ExtensionState.active) {
        await widget.store.disable(widget.moduleId);
      } else {
        await widget.store.activate(widget.moduleId);
      }
    });
  }

  Future<void> _remove() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const VentioText('native.ui.remove_this_local_extension'),
        content: const VentioText(
          'native.ui.removal_requires_no_data_or_pending_commands',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const VentioText('native.ui.cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const VentioText('native.ui.remove'),
          ),
        ],
      ),
    );
    if (approved != true) return;
    try {
      final hasUnresolvedCommands =
          await widget.queue?.hasUnresolvedCommandsForModule(widget.moduleId) ??
          false;
      if (!mounted) return;
      if (hasUnresolvedCommands) {
        _message(
          context.ventioText('native.ui.remove_blocked_pending_commands'),
        );
        return;
      }
      await widget.store.remove(widget.moduleId);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } catch (error) {
      _message(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String value) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  HostExtensionPackageClient _hostPackageClient({
    required Uri endpoint,
    required HostCredentialVault vault,
  }) =>
      widget.hostPackageClientFactory?.call(
        endpoint: endpoint,
        credentials: vault,
      ) ??
      HostExtensionPackageClient(endpoint: endpoint, credentials: vault);

  @override
  Widget build(BuildContext context) {
    final extension = _extension;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          extension == null
              ? context.ventioText('native.ui.extension')
              : context.extensionMetadataText(
                  _extensionMessageKey(extension.moduleId, 'name'),
                  extension.displayName,
                ),
        ),
        actions: [
          IconButton(
            tooltip: context.ventioText(
              'native.ui.submit_package_for_host_review',
            ),
            onPressed:
                extension == null ||
                    _docTypes.isEmpty ||
                    _busy ||
                    widget.hostProfile == null ||
                    widget.credentialVault == null
                ? null
                : _submitPackageForReview,
            icon: const Icon(Icons.cloud_upload_outlined),
          ),
          IconButton(
            tooltip: context.ventioText('native.ui.export_declarative_package'),
            onPressed: extension == null || _docTypes.isEmpty || _busy
                ? null
                : _exportBundle,
            icon: const Icon(Icons.data_object_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : extension == null
          ? const Center(
              child: VentioText('native.ui.this_extension_was_removed'),
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1080),
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    _LocalOnlyNotice(
                      title: context.ventioText(
                        'native.ui.device_local_extension_copy',
                      ),
                      body: context.ventioText(
                        'native.ui.local_activation_controls_this_device_only_submit_this_declarative_packa',
                      ),
                      icon: Icons.lock_clock_outlined,
                    ),
                    const SizedBox(height: 20),
                    _extensionHeader(extension),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: VentioText(
                            'native.ui.doctypes',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: _busy ? null : () => _addDocType(),
                          icon: const Icon(Icons.add),
                          label: const VentioText('native.ui.add_doctype'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_docTypes.isEmpty)
                      _StateCard(
                        icon: Icons.schema_outlined,
                        title: context.ventioText('native.ui.no_doctypes_yet'),
                        body: context.ventioText(
                          'native.ui.a_doctype_defines_the_fields_relationships_validation_and_permissions_fo',
                        ),
                      )
                    else
                      for (final metadata in _docTypes)
                        _DocTypeCard(
                          metadata: metadata,
                          active: extension.state == ExtensionState.active,
                          onEdit: () => _addDocType(metadata),
                          onPreview: () => _openPreview(metadata),
                          onOpen: () =>
                              _openPreview(metadata, previewOnly: false),
                        ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: VentioText(
                            'native.ui.reports',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: _busy || _docTypes.isEmpty
                              ? null
                              : _addReport,
                          icon: const Icon(Icons.add),
                          label: const VentioText('native.ui.add_report'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (extension.reportDefinitions.isEmpty)
                      _StateCard(
                        icon: Icons.summarize_outlined,
                        title: context.ventioText('native.ui.no_reports_yet'),
                        body: context.ventioText(
                          'native.ui.reports_are_saved_as_bounded_package_metadata_and_host_permissions_are_rechecked',
                        ),
                      )
                    else
                      for (final report in extension.reportDefinitions)
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.summarize_outlined),
                            title: Text(
                              context.extensionMetadataText(
                                report['labelKey'] as String,
                                report['label'] as String,
                              ),
                            ),
                            subtitle: Text(
                              '${report['id']} · ${report['docType']}',
                            ),
                          ),
                        ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: VentioText(
                            'native.ui.print_formats',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: _busy || _docTypes.isEmpty
                              ? null
                              : _addPrintFormat,
                          icon: const Icon(Icons.print_outlined),
                          label: const VentioText('native.ui.add_print_format'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (extension.printFormatDefinitions.isEmpty)
                      _StateCard(
                        icon: Icons.print_disabled_outlined,
                        title: context.ventioText(
                          'native.ui.no_print_formats_yet',
                        ),
                        body: context.ventioText(
                          'native.ui.print_formats_use_authorized_record_fields',
                        ),
                      )
                    else
                      for (final format in extension.printFormatDefinitions)
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.print_outlined),
                            title: Text(
                              context.extensionMetadataText(
                                format['labelKey'] as String,
                                format['label'] as String,
                              ),
                            ),
                            subtitle: Text(
                              '${format['id']} · ${format['docType']} · ${format['pageSize']} · ${format['orientation']}',
                            ),
                          ),
                        ),
                    const SizedBox(height: 20),
                    _permissionsCard(_docTypes),
                    const SizedBox(height: 20),
                    _lifecycleCard(extension),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _extensionHeader(LocalExtension extension) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  context.extensionMetadataText(
                    _extensionMessageKey(extension.moduleId, 'name'),
                    extension.displayName,
                  ),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                _StatusPill(label: extension.state.databaseValue),
                _StatusPill(label: context.ventioText('native.ui.local_only')),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              extension.description.isEmpty
                  ? context.ventioText('native.ui.no_description')
                  : context.extensionMetadataText(
                      _extensionMessageKey(extension.moduleId, 'description'),
                      extension.description,
                    ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _MetadataText(
                  label: context.ventioText('native.ui.module_id'),
                  value: extension.moduleId,
                ),
                _MetadataText(
                  label: context.ventioText('native.ui.version'),
                  value: extension.version,
                ),
                _MetadataText(
                  label: context.ventioText('native.ui.dependencies'),
                  value: extension.dependencies.isEmpty
                      ? 'None'
                      : extension.dependencies.entries
                            .map((entry) => _dependencyVersionRange(entry))
                            .join(', '),
                ),
                _MetadataText(
                  label: context.ventioText('native.ui.updated'),
                  value: extension.updatedAtUtc
                      .toLocal()
                      .toString()
                      .split('.')
                      .first,
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _busy ? null : _editExtension,
                icon: const Icon(Icons.edit_outlined),
                label: const VentioText('native.ui.edit_extension_details'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _permissionsCard(List<Map<String, dynamic>> definitions) {
    final permissions = <String>{};
    for (final metadata in definitions) {
      final raw = metadata['permissions'];
      if (raw is Map) permissions.addAll(raw.values.whereType<String>());
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            VentioText(
              'native.ui.permissions_and_operations',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const VentioText(
              'native.ui.the_extension_declares_read_create_and_update_permission_keys_it_cannot',
            ),
            const SizedBox(height: 12),
            if (permissions.isEmpty)
              const VentioText(
                'native.ui.add_a_doctype_to_define_permission_keys',
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final permission in permissions)
                    Chip(
                      avatar: const Icon(Icons.key_outlined, size: 16),
                      label: Text(permission),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _lifecycleCard(LocalExtension extension) {
    final active = extension.state == ExtensionState.active;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 12,
          children: [
            SizedBox(
              width: 540,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  VentioText(
                    'native.ui.device_lifecycle',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    active
                        ? 'Pages are active on this device. Disabling keeps local definitions and records.'
                        : 'Activate this local draft to use its generated forms and records on this device.',
                  ),
                ],
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _remove,
                  icon: const Icon(Icons.delete_outline),
                  label: const VentioText('native.ui.remove'),
                ),
                FilledButton.icon(
                  onPressed: _busy ? null : _changeState,
                  icon: Icon(
                    active ? Icons.pause_circle_outline : Icons.play_arrow,
                  ),
                  label: Text(
                    active ? 'Disable on device' : 'Activate on device',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class DocTypeBuilderPage extends StatefulWidget {
  const DocTypeBuilderPage({
    required this.store,
    required this.moduleId,
    this.existing,
    super.key,
  });

  final LocalExtensionStore store;
  final String moduleId;
  final Map<String, dynamic>? existing;

  @override
  State<DocTypeBuilderPage> createState() => _DocTypeBuilderPageState();
}

class _DocTypeBuilderPageState extends State<DocTypeBuilderPage> {
  final _nameController = TextEditingController();
  final _labelController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _pageTitleController = TextEditingController();
  final _pageOrderController = TextEditingController();
  final _seriesIdController = TextEditingController();
  final _seriesPrefixController = TextEditingController();
  final _seriesPaddingController = TextEditingController(text: '6');
  String? _seriesField;
  bool _namingEnabled = false;
  bool _governedLifecycleEnabled = false;
  String _pageIcon = 'list';
  bool _pageTitleCustomized = false;
  final _formKey = GlobalKey<FormState>();
  final List<Map<String, dynamic>> _fields = [];
  final List<String> _listColumns = [];
  final List<String> _formFields = [];
  final List<String> _detailFields = [];
  final List<String> _operations = [];
  final List<Map<String, dynamic>> _migrationSteps = [];
  final List<Map<String, dynamic>> _priorMigrations = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final metadata = widget.existing;
    if (metadata != null) {
      _nameController.text = metadata['name'] as String;
      _labelController.text = metadata['label'] as String;
      _descriptionController.text = (metadata['description'] as String?) ?? '';
      final ui = metadata['ui'];
      _pageTitleController.text = ui is Map && ui['pageTitle'] is String
          ? ui['pageTitle'] as String
          : metadata['label'] as String;
      _pageTitleCustomized =
          _pageTitleController.text != (metadata['label'] as String);
      _pageOrderController.text = ui is Map && ui['pageOrder'] is int
          ? (ui['pageOrder'] as int).toString()
          : '0';
      _pageIcon = ui is Map && _generatedPageIcons.containsKey(ui['pageIcon'])
          ? ui['pageIcon'] as String
          : 'list';
      final rawNaming = metadata['naming'];
      if (rawNaming is Map) {
        _namingEnabled = true;
        _seriesIdController.text = rawNaming['seriesId'] as String? ?? '';
        _seriesPrefixController.text = rawNaming['prefix'] as String? ?? '';
        _seriesPaddingController.text = (rawNaming['padding'] as int? ?? 6)
            .toString();
        _seriesField = rawNaming['field'] as String?;
      }
      final rawBusinessOperations = metadata['businessOperations'];
      _governedLifecycleEnabled =
          rawBusinessOperations is List &&
          rawBusinessOperations.any((operation) {
            if (operation is! Map || operation['effects'] is! List) {
              return false;
            }
            return (operation['effects'] as List).any(
              (effect) =>
                  effect is Map &&
                  (effect['type'] == 'document.transition' ||
                      effect['type'] == 'document.amend'),
            );
          });
      final rawMigrations = metadata['migrations'];
      if (rawMigrations is List) {
        _priorMigrations.addAll(
          rawMigrations.map(
            (migration) => Map<String, dynamic>.from(migration as Map),
          ),
        );
      }
      final rawOperations = metadata['operations'];
      _operations.addAll(
        rawOperations is List
            ? rawOperations.whereType<String>().where(
                const {'read', 'create', 'update'}.contains,
              )
            : const ['read', 'create', 'update'],
      );
      _fields.addAll(
        (metadata['fields'] as List).map(
          (field) => Map<String, dynamic>.from(field as Map),
        ),
      );
      final names = _fields.map((field) => field['name']! as String).toList();
      final rawListColumns = ui is Map ? ui['listColumns'] : null;
      final rawFormFields = ui is Map ? ui['formFields'] : null;
      final rawDetailFields = ui is Map ? ui['detailFields'] : null;
      _listColumns.addAll(
        rawListColumns is List
            ? rawListColumns.whereType<String>().where(names.contains)
            : names.take(4),
      );
      _formFields.addAll(
        rawFormFields is List
            ? rawFormFields.whereType<String>().where(names.contains)
            : names,
      );
      _detailFields.addAll(
        rawDetailFields is List
            ? rawDetailFields.whereType<String>().where(names.contains)
            : names,
      );
      for (final field in _fields.where((item) => item['required'] == true)) {
        final name = field['name']! as String;
        if (!_formFields.contains(name)) _formFields.add(name);
      }
    } else {
      _pageOrderController.text = '0';
      _operations.addAll(const ['read', 'create', 'update']);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _labelController.dispose();
    _descriptionController.dispose();
    _pageTitleController.dispose();
    _pageOrderController.dispose();
    _seriesIdController.dispose();
    _seriesPrefixController.dispose();
    _seriesPaddingController.dispose();
    super.dispose();
  }

  Future<void> _addField([Map<String, dynamic>? existing]) async {
    final docTypeName = _nameController.text.trim();
    final docTypeNameError = _docTypeIdentifierError(docTypeName);
    if (docTypeNameError != null) {
      _message('Enter a valid DocType ID before adding fields.');
      return;
    }
    final docTypes = await widget.store.listDocTypes(widget.moduleId);
    final targets = docTypes
        .map((item) => item['name']! as String)
        .where((name) => name != widget.existing?['name'])
        .toList();
    if (!mounted) return;
    final field = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _FieldEditorDialog(
        moduleId: widget.moduleId,
        docTypeName: docTypeName,
        relationTargets: targets,
        availableFields: _fields
            .map((field) => Map<String, dynamic>.from(field))
            .toList(),
        existing: existing,
      ),
    );
    if (field == null) return;
    setState(() {
      if (existing == null) {
        _fields.add(field);
        final name = field['name']! as String;
        _formFields.add(name);
        _detailFields.add(name);
        if (_listColumns.length < 4) _listColumns.add(name);
      } else {
        final index = _fields.indexOf(existing);
        if (index >= 0) _fields[index] = field;
      }
    });
  }

  Future<void> _removeField(Map<String, dynamic> field) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const VentioText('native.ui.remove_field_from_this_draft'),
        content: Text(
          context.ventioText(
            'native.ui.remove_field_confirmation',
            params: {'fieldId': field['name']},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const VentioText('native.ui.keep_field'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const VentioText('native.ui.remove_field'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      setState(() {
        _fields.remove(field);
        final name = field['name']! as String;
        _listColumns.remove(name);
        _formFields.remove(name);
        _detailFields.remove(name);
      });
    }
  }

  Future<void> _addMigrationStep({required bool rename}) async {
    final currentFields = _fields
        .map((field) => field['name']! as String)
        .toList(growable: false);
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) =>
          _MigrationStepDialog(rename: rename, fields: currentFields),
    );
    if (result != null) setState(() => _migrationSteps.add(result));
  }

  void _toggleLayoutField(List<String> selected, String name, bool checked) {
    setState(() {
      if (checked && !selected.contains(name)) {
        selected.add(name);
      } else if (!checked) {
        selected.remove(name);
      }
    });
  }

  void _moveLayoutField(List<String> selected, int index, int delta) {
    final destination = index + delta;
    if (destination < 0 || destination >= selected.length) return;
    setState(() {
      final field = selected.removeAt(index);
      selected.insert(destination, field);
    });
  }

  List<Map<String, dynamic>> get _namingFieldCandidates => _fields
      .where(
        (field) =>
            field['type'] == 'text' &&
            field['readOnly'] == true &&
            field['required'] != true &&
            field['default'] == null &&
            (field['maxLength'] == null || (field['maxLength'] as int) >= 42),
      )
      .toList(growable: false);

  Widget _layoutCard({
    required String title,
    required String description,
    required List<String> selected,
    required bool requiredFieldsOnly,
  }) {
    final selectedRequired = _fields
        .where((field) => field['required'] == true)
        .map((field) => field['name']! as String)
        .toSet();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(description),
            if (_fields.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: VentioText(
                  'native.ui.add_fields_to_configure_this_layout',
                ),
              ),
            for (final field in _fields)
              Builder(
                builder: (context) {
                  final name = field['name']! as String;
                  final index = selected.indexOf(name);
                  final isRequired = selectedRequired.contains(name);
                  return CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: index >= 0,
                    title: Text(field['label']! as String),
                    subtitle: Text('$name · ${field['type']}'),
                    secondary: index < 0
                        ? null
                        : Wrap(
                            spacing: 0,
                            children: [
                              IconButton(
                                tooltip: context.ventioText(
                                  'native.ui.move_field_up',
                                  params: {'label': field['label']},
                                ),
                                onPressed: index == 0
                                    ? null
                                    : () =>
                                          _moveLayoutField(selected, index, -1),
                                icon: const Icon(Icons.arrow_upward),
                              ),
                              IconButton(
                                tooltip: context.ventioText(
                                  'native.ui.move_field_down',
                                  params: {'label': field['label']},
                                ),
                                onPressed: index == selected.length - 1
                                    ? null
                                    : () =>
                                          _moveLayoutField(selected, index, 1),
                                icon: const Icon(Icons.arrow_downward),
                              ),
                            ],
                          ),
                    onChanged: requiredFieldsOnly && isRequired
                        ? null
                        : (checked) => _toggleLayoutField(
                            selected,
                            name,
                            checked ?? false,
                          ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_fields.isEmpty) {
      _message('Add at least one field to the DocType.');
      return;
    }
    if (_listColumns.isEmpty) {
      _message('Choose at least one list column.');
      return;
    }
    if (_formFields.isEmpty) {
      _message('Choose at least one generated form field.');
      return;
    }
    if (_detailFields.isEmpty) {
      _message('Choose at least one detail page field.');
      return;
    }
    final name = _nameController.text.trim();
    final label = _labelController.text.trim();
    final pageTitle = _pageTitleController.text.trim();
    final pageOrder = int.parse(_pageOrderController.text.trim());
    final previousVersion = widget.existing?['schemaVersion'] as int?;
    final fields = List<Map<String, dynamic>>.from(_fields);
    final namespace = _messageNamespace(widget.moduleId);
    final labelKey =
        widget.existing?['labelKey'] as String? ??
        '$namespace.doctype.${name.toLowerCase()}.label';
    final permissions = <String, String>{
      for (final operation in _operations)
        operation: permissionKey(widget.moduleId, name, operation),
    };
    if (_governedLifecycleEnabled) {
      final amendedFromIndex = fields.indexWhere(
        (field) => field['name'] == 'amendedFrom',
      );
      if (amendedFromIndex == -1) {
        fields.add({
          'name': 'amendedFrom',
          'type': 'reference',
          'label': 'Amended From',
          'labelKey': '$namespace.${name.toLowerCase()}.amended_from',
          'referenceTo': name,
          'required': false,
          'readOnly': true,
        });
        if (!_detailFields.contains('amendedFrom')) {
          _detailFields.add('amendedFrom');
        }
      } else {
        final existingLink = fields[amendedFromIndex];
        if (existingLink['type'] != 'reference' ||
            existingLink['referenceTo'] != name ||
            existingLink['required'] == true ||
            existingLink['readOnly'] != true) {
          _message('native.ui.amendment_field_conflict');
          return;
        }
      }
    }
    final priorBusinessOperations =
        (widget.existing?['businessOperations'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .where(
              (operation) => !const {
                'document.submit',
                'document.cancel',
                'document.amend',
              }.contains(operation['id']),
            )
            .toList(growable: true);
    final businessOperations = <Map<String, dynamic>>[
      ...priorBusinessOperations,
      if (_governedLifecycleEnabled)
        {
          'id': 'document.amend',
          'version': 1,
          'permission': permissionKey(widget.moduleId, name, 'amend'),
          'inputs': <String, dynamic>{},
          'outputs': <String, dynamic>{
            'amendedRecordId': {'type': 'text', 'required': true},
          },
          'effects': [
            {
              'type': 'document.amend',
              'linkField': 'amendedFrom',
              'output': 'amendedRecordId',
            },
          ],
        },
      if (_governedLifecycleEnabled)
        {
          'id': 'document.submit',
          'version': 1,
          'permission': permissionKey(widget.moduleId, name, 'submit'),
          'inputs': <String, dynamic>{},
          'outputs': <String, dynamic>{
            'status': {'type': 'integer', 'required': true},
            if (_namingEnabled)
              'officialNumber': {'type': 'text', 'required': true},
          },
          'effects': [
            if (_namingEnabled)
              {
                'type': 'document.allocate_number',
                'field': _seriesField,
                'output': 'officialNumber',
              },
            {'type': 'document.transition', 'targetStatus': 1},
          ],
        },
      if (_governedLifecycleEnabled)
        {
          'id': 'document.cancel',
          'version': 1,
          'permission': permissionKey(widget.moduleId, name, 'cancel'),
          'inputs': <String, dynamic>{},
          'outputs': <String, dynamic>{
            'status': {'type': 'integer', 'required': true},
          },
          'effects': [
            {'type': 'document.transition', 'targetStatus': 2},
          ],
        },
    ];
    final metadata = <String, dynamic>{
      'name': name,
      'moduleId': widget.moduleId,
      'schemaVersion': (previousVersion ?? 0) + 1,
      'kind': 'operational',
      'fields': fields,
      'operations': List<String>.of(_operations),
      'permissions': permissions,
      if (businessOperations.isNotEmpty)
        'businessOperations': businessOperations,
      'ui': {
        'listColumns': List<String>.of(_listColumns),
        'formFields': List<String>.of(_formFields),
        'detailFields': List<String>.of(_detailFields),
        'pageTitle': pageTitle,
        'pageTitleKey': '$namespace.${name.toLowerCase()}.page_title',
        'pageIcon': _pageIcon,
        'pageOrder': pageOrder,
      },
      'label': label,
      'labelKey': labelKey,
      'description': _descriptionController.text.trim(),
      'descriptionKey': '$namespace.${name.toLowerCase()}.description',
    };
    if (_namingEnabled) {
      final field = _seriesField;
      if (field == null) {
        _message(context.ventioText('native.ui.choose_a_valid_number_field'));
        return;
      }
      metadata['naming'] = {
        'seriesId': _seriesIdController.text.trim(),
        'field': field,
        'prefix': _seriesPrefixController.text.trim(),
        'padding': int.tryParse(_seriesPaddingController.text.trim()),
      };
    }
    if (previousVersion != null) {
      metadata['migrations'] = [
        ..._priorMigrations,
        {
          'fromVersion': previousVersion,
          'toVersion': previousVersion + 1,
          'steps': List<Map<String, dynamic>>.of(_migrationSteps),
        },
      ];
    }
    setState(() => _saving = true);
    try {
      DocTypeDefinition.fromJson(metadata);
      await widget.store.saveDocType(metadata);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      _message(error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String value) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'Edit DocType' : 'New DocType')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                _LocalOnlyNotice(
                  title: context.ventioText('native.ui.schema_designer'),
                  body: context.ventioText(
                    'native.ui.doctype_definitions_are_validated_metadata_they_cannot_contain_sql_scrip',
                  ),
                  icon: Icons.schema_outlined,
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _nameController,
                  readOnly: editing,
                  decoration: InputDecoration(
                    labelText: context.ventioText('native.ui.doctype_id'),
                    hintText: context.ventioText('native.ui.asset'),
                    helperText: context.ventioText(
                      'native.ui.stable_identifier_use_letters_numbers_and_underscores',
                    ),
                    border: OutlineInputBorder(),
                  ),
                  validator: _docTypeIdentifierError,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _labelController,
                  decoration: InputDecoration(
                    labelText: context.ventioText('native.ui.display_name'),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) {
                    if (!_pageTitleCustomized) {
                      _pageTitleController.text = value;
                    }
                  },
                  validator: (value) =>
                      _requiredText(value, 'Enter a display name.'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descriptionController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: context.ventioText('native.ui.description'),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        VentioText(
                          'native.ui.generated_page_settings',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        const VentioText(
                          'native.ui.each_doctype_creates_a_records_page_these_settings_control_its_navigatio',
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _pageTitleController,
                          maxLength: 120,
                          decoration: InputDecoration(
                            labelText: context.ventioText(
                              'native.ui.page_title',
                            ),
                            helperText: context.ventioText(
                              'native.ui.shown_in_extension_navigation_and_on_the_records_page',
                            ),
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (value) {
                            _pageTitleCustomized =
                                value.trim() != _labelController.text.trim();
                          },
                          validator: (value) {
                            final trimmed = value?.trim() ?? '';
                            if (trimmed.isEmpty) {
                              return context.ventioText(
                                'native.ui.enter_page_title',
                              );
                            }
                            if (trimmed.length > 120) {
                              return context.ventioText(
                                'native.ui.use_120_characters_or_fewer',
                              );
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _pageOrderController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: InputDecoration(
                            labelText: context.ventioText(
                              'native.ui.navigation_order',
                            ),
                            helperText: context.ventioText(
                              'native.ui.lower_values_appear_first_values_from_0_to_10000_are_supported',
                            ),
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) {
                            final order = int.tryParse(value?.trim() ?? '');
                            if (order == null || order > 10000) {
                              return context.ventioText(
                                'native.ui.enter_navigation_order',
                              );
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: _pageIcon,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: context.ventioText(
                              'native.ui.navigation_icon',
                            ),
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final entry in _generatedPageIcons.entries)
                              DropdownMenuItem(
                                value: entry.key,
                                child: Row(
                                  children: [
                                    Icon(entry.value),
                                    const SizedBox(width: 10),
                                    Text(entry.key),
                                  ],
                                ),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _pageIcon = value);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const VentioText(
                            'native.ui.enable_governed_document_lifecycle',
                          ),
                          value: _governedLifecycleEnabled,
                          onChanged: (enabled) => setState(
                            () => _governedLifecycleEnabled = enabled,
                          ),
                        ),
                        const VentioText(
                          'native.ui.governed_document_lifecycle_help',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.ventioText(
                          'native.ui.fields_count',
                          params: {'count': _fields.length},
                        ),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => _addField(),
                      icon: const Icon(Icons.add),
                      label: const VentioText('native.ui.add_field'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_fields.isEmpty)
                  _StateCard(
                    icon: Icons.view_list_outlined,
                    title: context.ventioText('native.ui.add_the_first_field'),
                    body: context.ventioText(
                      'native.ui.fields_define_what_the_generated_form_validates_and_stores',
                    ),
                  )
                else
                  for (final field in _fields)
                    _FieldCard(
                      field: field,
                      onEdit: () => _addField(field),
                      onDelete: () => _removeField(field),
                    ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const VentioText(
                            'native.ui.enable_document_numbering',
                          ),
                          value: _namingEnabled,
                          onChanged: (enabled) =>
                              setState(() => _namingEnabled = enabled ?? false),
                        ),
                        const VentioText(
                          'native.ui.document_numbers_are_provisional_offline_and_assigned_by_the_host_on_submit',
                        ),
                        if (_namingEnabled) ...[
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _seriesIdController,
                            decoration: InputDecoration(
                              labelText: context.ventioText(
                                'native.ui.numbering_series_id',
                              ),
                              helperText: context.ventioText(
                                'native.ui.stable_series_id_lowercase_letters_numbers_hyphens_or_underscores',
                              ),
                            ),
                            validator: (value) {
                              if (!_namingEnabled) return null;
                              return RegExp(
                                    r'^[a-z][a-z0-9_-]{0,63}$',
                                  ).hasMatch(value?.trim() ?? '')
                                  ? null
                                  : context.ventioText(
                                      'native.ui.enter_a_valid_numbering_series_id',
                                    );
                            },
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            initialValue:
                                _seriesField != null &&
                                    _namingFieldCandidates.any(
                                      (field) => field['name'] == _seriesField,
                                    )
                                ? _seriesField
                                : null,
                            decoration: InputDecoration(
                              labelText: context.ventioText(
                                'native.ui.official_number_field',
                              ),
                              helperText: context.ventioText(
                                'native.ui.choose_an_optional_read_only_text_field_with_room_for_a_provisional_name',
                              ),
                            ),
                            items: [
                              for (final field in _namingFieldCandidates)
                                DropdownMenuItem<String>(
                                  value: field['name']! as String,
                                  child: Text(field['label']! as String),
                                ),
                            ],
                            onChanged: (field) =>
                                setState(() => _seriesField = field),
                            validator: (value) =>
                                !_namingEnabled ||
                                    (value != null &&
                                        _namingFieldCandidates.any(
                                          (field) => field['name'] == value,
                                        ))
                                ? null
                                : context.ventioText(
                                    'native.ui.choose_a_valid_number_field',
                                  ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _seriesPrefixController,
                            maxLength: 24,
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[A-Z0-9._/-]'),
                              ),
                            ],
                            decoration: InputDecoration(
                              labelText: context.ventioText(
                                'native.ui.number_prefix',
                              ),
                            ),
                            validator: (value) =>
                                !_namingEnabled ||
                                    RegExp(
                                      r'^[A-Z0-9._/-]{0,24}$',
                                    ).hasMatch(value?.trim() ?? '')
                                ? null
                                : context.ventioText(
                                    'native.ui.enter_a_literal_number_prefix',
                                  ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _seriesPaddingController,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: InputDecoration(
                              labelText: context.ventioText(
                                'native.ui.number_zero_padding',
                              ),
                              helperText: context.ventioText(
                                'native.ui.choose_a_width_between_1_and_12',
                              ),
                            ),
                            validator: (value) {
                              if (!_namingEnabled) return null;
                              final padding = int.tryParse(value?.trim() ?? '');
                              return padding != null &&
                                      padding >= 1 &&
                                      padding <= 12
                                  ? null
                                  : context.ventioText(
                                      'native.ui.choose_a_width_between_1_and_12',
                                    );
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _layoutCard(
                  title: context.ventioText('native.ui.list_page_columns'),
                  description: context.ventioText(
                    'native.ui.choose_visible_columns_and_their_order_in_generated_lists',
                  ),
                  selected: _listColumns,
                  requiredFieldsOnly: false,
                ),
                const SizedBox(height: 12),
                _layoutCard(
                  title: context.ventioText('native.ui.generated_form_fields'),
                  description: context.ventioText(
                    'native.ui.choose_and_order_fields_shown_on_create_and_edit_forms_required_fields_s',
                  ),
                  selected: _formFields,
                  requiredFieldsOnly: true,
                ),
                const SizedBox(height: 12),
                _layoutCard(
                  title: context.ventioText('native.ui.details_page_fields'),
                  description: context.ventioText(
                    'native.ui.choose_and_order_fields_shown_when_a_saved_record_is_opened_this_affects',
                  ),
                  selected: _detailFields,
                  requiredFieldsOnly: false,
                ),
                const SizedBox(height: 12),
                if (editing) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          VentioText(
                            'native.ui.data_migration',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          const VentioText(
                            'native.ui.supported_operations_preserve_data_rename_a_field_or_populate_a_constant',
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () =>
                                    _addMigrationStep(rename: true),
                                icon: const Icon(
                                  Icons.drive_file_rename_outline,
                                ),
                                label: const VentioText(
                                  'native.ui.add_field_rename',
                                ),
                              ),
                              OutlinedButton.icon(
                                onPressed: () =>
                                    _addMigrationStep(rename: false),
                                icon: const Icon(Icons.data_object),
                                label: const VentioText(
                                  'native.ui.add_default',
                                ),
                              ),
                            ],
                          ),
                          if (_migrationSteps.isEmpty)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: VentioText(
                                'native.ui.no_data_transformations_safe_optional_additions_and_widened_constraints',
                              ),
                            ),
                          for (final step in _migrationSteps)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.transform_outlined),
                              title: Text(
                                step['op'] == 'renameField'
                                    ? 'Rename ${step['from']} → ${step['to']}'
                                    : 'Default ${step['field']} to ${jsonEncode(step['value'])}',
                              ),
                              trailing: IconButton(
                                tooltip: context.ventioText(
                                  'native.ui.remove_migration_step',
                                ),
                                onPressed: () => setState(
                                  () => _migrationSteps.remove(step),
                                ),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        VentioText(
                          'native.ui.declared_record_operations',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        const VentioText(
                          'native.ui.choose_which_local_record_operations_this_doctype_supports_permission_ke',
                        ),
                        for (final operation in const [
                          'read',
                          'create',
                          'update',
                        ])
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(operation),
                            value: _operations.contains(operation),
                            onChanged: (checked) => setState(() {
                              if (checked == true &&
                                  !_operations.contains(operation)) {
                                _operations.add(operation);
                              } else if (checked == false) {
                                _operations.remove(operation);
                              }
                            }),
                          ),
                        if (_operations.isEmpty)
                          const VentioText(
                            'native.ui.no_record_operations_are_enabled_for_this_doctype',
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(_saving ? 'Saving…' : 'Save DocType'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MigrationStepDialog extends StatefulWidget {
  const _MigrationStepDialog({required this.rename, required this.fields});

  final bool rename;
  final List<String> fields;

  @override
  State<_MigrationStepDialog> createState() => _MigrationStepDialogState();
}

class _MigrationStepDialogState extends State<_MigrationStepDialog> {
  final _fromController = TextEditingController();
  final _toController = TextEditingController();
  final _fieldController = TextEditingController();
  final _valueController = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.fields.isNotEmpty) _fieldController.text = widget.fields.first;
  }

  @override
  void dispose() {
    _fromController.dispose();
    _toController.dispose();
    _fieldController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final step = widget.rename
          ? <String, dynamic>{
              'op': 'renameField',
              'from': _fromController.text.trim(),
              'to': _toController.text.trim(),
            }
          : <String, dynamic>{
              'op': 'setDefault',
              'field': _fieldController.text,
              'value': jsonDecode(_valueController.text),
            };
      DocTypeMigrationStep.fromJson(step);
      Navigator.pop(context, step);
    } catch (error) {
      setState(() => _error = 'Invalid migration step: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final contentWidth = (MediaQuery.sizeOf(context).width - 72)
        .clamp(220.0, 420.0)
        .toDouble();
    return AlertDialog(
      title: Text(
        widget.rename ? 'Rename a saved field' : 'Set a default value',
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: contentWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.rename) ...[
                TextField(
                  controller: _fromController,
                  decoration: InputDecoration(
                    labelText: context.ventioText(
                      'native.ui.existing_field_id',
                    ),
                    helperText: context.ventioText(
                      'native.ui.the_old_value_is_retained_under_the_new_id',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _toController,
                  decoration: InputDecoration(
                    labelText: context.ventioText('native.ui.new_field_id'),
                    helperText: context.ventioText(
                      'native.ui.it_must_exist_in_the_new_schema',
                    ),
                  ),
                ),
              ] else ...[
                if (widget.fields.isEmpty)
                  const VentioText(
                    'native.ui.add_a_field_to_the_new_schema_first',
                  )
                else
                  DropdownButtonFormField<String>(
                    initialValue: widget.fields.first,
                    decoration: InputDecoration(
                      labelText: context.ventioText('native.ui.target_field'),
                    ),
                    items: [
                      for (final name in widget.fields)
                        DropdownMenuItem(value: name, child: Text(name)),
                    ],
                    onChanged: (value) => _fieldController.text = value ?? '',
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: _valueController,
                  decoration: InputDecoration(
                    labelText: context.ventioText(
                      'native.ui.json_scalar_value',
                    ),
                    hintText: '"Unknown", 0, or false',
                    helperText: context.ventioText(
                      'native.ui.applied_only_when_the_saved_value_is_missing_or_null',
                    ),
                  ),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const VentioText('native.ui.cancel'),
        ),
        FilledButton(
          onPressed: !widget.rename && widget.fields.isEmpty ? null : _submit,
          child: const VentioText('native.ui.add_step'),
        ),
      ],
    );
  }
}

class _FieldEditorDialog extends StatefulWidget {
  const _FieldEditorDialog({
    required this.moduleId,
    required this.docTypeName,
    required this.relationTargets,
    this.availableFields = const [],
    this.childField = false,
    this.existing,
  });

  final String moduleId;
  final String docTypeName;
  final List<String> relationTargets;
  final List<Map<String, dynamic>> availableFields;
  final bool childField;
  final Map<String, dynamic>? existing;

  @override
  State<_FieldEditorDialog> createState() => _FieldEditorDialogState();
}

class _FieldEditorDialogState extends State<_FieldEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _label;
  late final TextEditingController _minLength;
  late final TextEditingController _maxLength;
  late final TextEditingController _minValue;
  late final TextEditingController _maxValue;
  late final TextEditingController _precision;
  late final TextEditingController _defaultValue;
  late final TextEditingController _description;
  late final TextEditingController _enumValues;
  late final TextEditingController _readPermission;
  late final TextEditingController _writePermission;
  String _type = 'text';
  String? _referenceTo;
  Map<String, dynamic>? _childDocType;
  bool _required = false;
  bool _readOnly = false;
  String? _calculationType;
  String? _calculationLeft;
  String? _calculationRight;
  String? _calculationRows;
  String? _calculationValue;

  @override
  void initState() {
    super.initState();
    final field = widget.existing;
    _name = TextEditingController(text: field?['name'] as String? ?? '');
    _label = TextEditingController(text: field?['label'] as String? ?? '');
    _minLength = TextEditingController(
      text: field?['minLength']?.toString() ?? '',
    );
    _maxLength = TextEditingController(
      text:
          field?['maxLength']?.toString() ??
          (field?['type'] == 'long_text' ? '2000' : '160'),
    );
    _minValue = TextEditingController(
      text: field?['minValue']?.toString() ?? '',
    );
    _maxValue = TextEditingController(
      text: field?['maxValue']?.toString() ?? '',
    );
    _precision = TextEditingController(
      text: field?['precision']?.toString() ?? '',
    );
    _defaultValue = TextEditingController(
      text: field?['default']?.toString() ?? '',
    );
    _description = TextEditingController(
      text: field?['description'] as String? ?? '',
    );
    _enumValues = TextEditingController(
      text: ((field?['enumValues'] as List?) ?? const []).join(', '),
    );
    _readPermission = TextEditingController(
      text: field?['readPermission'] as String? ?? '',
    );
    _writePermission = TextEditingController(
      text: field?['writePermission'] as String? ?? '',
    );
    _type = field?['type'] as String? ?? 'text';
    _referenceTo = field?['referenceTo'] as String?;
    _childDocType = field?['childDocType'] is Map
        ? Map<String, dynamic>.from(field!['childDocType'] as Map)
        : null;
    _required = field?['required'] as bool? ?? false;
    _readOnly = field?['readOnly'] as bool? ?? false;
    final calculation = field?['calculation'];
    if (calculation is Map) {
      _calculationType = calculation['type'] as String?;
      _calculationLeft = calculation['leftField'] as String?;
      _calculationRight = calculation['rightField'] as String?;
      _calculationRows = calculation['rowsField'] as String?;
      _calculationValue = calculation['valueField'] as String?;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _label.dispose();
    _minLength.dispose();
    _maxLength.dispose();
    _minValue.dispose();
    _maxValue.dispose();
    _precision.dispose();
    _defaultValue.dispose();
    _description.dispose();
    _enumValues.dispose();
    _readPermission.dispose();
    _writePermission.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final fieldName = _name.text.trim();
    final label = _label.text.trim();
    final fieldNamespace =
        '${_messageNamespace(widget.moduleId)}.'
        '${widget.docTypeName.toLowerCase()}.field.${fieldName.toLowerCase()}';
    final metadata = <String, dynamic>{
      'name': fieldName,
      'type': _type,
      'required': _required,
      'label': label,
      'labelKey': '$fieldNamespace.label',
    };
    if (_type == 'text' || _type == 'long_text') {
      metadata['maxLength'] = int.parse(_maxLength.text);
      final minimumLength = int.tryParse(_minLength.text.trim());
      if (minimumLength != null) metadata['minLength'] = minimumLength;
    }
    if (_type == 'integer' || _type == 'decimal') {
      final minimum = _parseBound(_minValue.text);
      final maximum = _parseBound(_maxValue.text);
      if (minimum != null) metadata['minValue'] = minimum;
      if (maximum != null) metadata['maxValue'] = maximum;
    }
    if (_type == 'decimal' && _precision.text.trim().isNotEmpty) {
      metadata['precision'] = int.parse(_precision.text.trim());
    }
    if (_type == 'decimal' && _calculationType != null) {
      metadata['calculation'] = switch (_calculationType) {
        'multiply' => {
          'type': 'multiply',
          'leftField': _calculationLeft,
          'rightField': _calculationRight,
        },
        'sum' => {
          'type': 'sum',
          'rowsField': _calculationRows,
          'valueField': _calculationValue,
        },
        _ => throw StateError('Unsupported calculation selection.'),
      };
      metadata['required'] = true;
      if (!widget.childField) metadata['readOnly'] = true;
    }
    final rawDefault = _calculationType == null ? _defaultValue.text : '';
    if (rawDefault.isNotEmpty) {
      metadata['default'] = switch (_type) {
        'integer' => int.parse(rawDefault.trim()),
        'decimal' => num.parse(rawDefault.trim()),
        'boolean' => rawDefault.trim() == 'true',
        _ => rawDefault,
      };
    }
    metadata['readOnly'] =
        _readOnly || (_calculationType == 'sum' && !widget.childField);
    final description = _description.text.trim();
    if (description.isNotEmpty) {
      metadata['description'] = description;
      metadata['descriptionKey'] = '$fieldNamespace.description';
    }
    if (_type == 'reference') metadata['referenceTo'] = _referenceTo;
    if (_type == 'table' && _childDocType != null) {
      metadata['childDocType'] = _childDocType;
    }
    final readPermission = _readPermission.text.trim();
    final writePermission = _writePermission.text.trim();
    if (readPermission.isNotEmpty) metadata['readPermission'] = readPermission;
    if (writePermission.isNotEmpty) {
      metadata['writePermission'] = writePermission;
    }
    if (_type == 'enum') {
      final values = _enumValues.text
          .split(',')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
      metadata['enumValues'] = values;
      metadata['enumLabels'] = {
        for (final value in values)
          value: {
            'label': value,
            'labelKey': '$fieldNamespace.enum.${value.toLowerCase()}',
          },
      };
    }
    Navigator.pop(context, metadata);
  }

  Future<void> _configureChildDocType() async {
    final child = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _ChildDocTypeEditorDialog(
        moduleId: widget.moduleId,
        parentDocTypeName: widget.docTypeName,
        relationTargets: widget.relationTargets,
        existing: _childDocType,
      ),
    );
    if (child != null && mounted) setState(() => _childDocType = child);
  }

  num? _parseBound(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return null;
    return _type == 'integer' ? int.tryParse(raw) : num.tryParse(raw);
  }

  String? _boundError(String? value, {required bool minimum}) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return null;
    final parsed = _parseBound(raw);
    if (parsed == null || !parsed.isFinite) {
      return _type == 'integer'
          ? context.ventioText('native.ui.enter_whole_number')
          : context.ventioText('native.ui.enter_finite_number');
    }
    final other = _parseBound(minimum ? _maxValue.text : _minValue.text);
    if (other != null && (minimum ? parsed > other : parsed < other)) {
      return minimum
          ? context.ventioText('native.ui.minimum_must_not_exceed_maximum')
          : context.ventioText('native.ui.maximum_must_not_be_below_minimum');
    }
    return null;
  }

  String? _lengthError(String? value, {required bool minimum}) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty && minimum) return null;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 1 || parsed > 65535) {
      return context.ventioText('native.ui.enter_length_bound');
    }
    final other = int.tryParse(
      (minimum ? _maxLength.text : _minLength.text).trim(),
    );
    if (other != null && (minimum ? parsed > other : parsed < other)) {
      return minimum
          ? context.ventioText(
              'native.ui.minimum_length_must_not_exceed_maximum',
            )
          : context.ventioText(
              'native.ui.maximum_length_must_not_be_below_minimum',
            );
    }
    return null;
  }

  String? _precisionError(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return null;
    final parsed = int.tryParse(raw);
    return parsed != null && parsed >= 0 && parsed <= 9
        ? null
        : context.ventioText('native.ui.precision_error');
  }

  String? _defaultError(String? value) {
    final raw = value ?? '';
    if (raw.isEmpty) return null;
    dynamic parsed;
    switch (_type) {
      case 'integer':
        parsed = int.tryParse(raw.trim());
        break;
      case 'decimal':
        parsed = num.tryParse(raw.trim());
        if (parsed is num && !parsed.isFinite) parsed = null;
        break;
      case 'boolean':
        if (raw.trim() != 'true' && raw.trim() != 'false') {
          parsed = null;
        } else {
          parsed = raw.trim() == 'true';
        }
        break;
      case 'enum':
        final values = _enumValues.text
            .split(',')
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty);
        if (!values.contains(raw)) {
          parsed = null;
        } else {
          parsed = raw;
        }
        break;
      case 'date':
        parsed = _validIsoDate(raw) ? raw : null;
        break;
      case 'datetime':
        parsed =
            RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(raw) &&
                DateTime.tryParse(raw) != null
            ? raw
            : null;
        break;
      default:
        parsed = raw;
    }
    if (parsed == null) {
      return context.ventioText('native.ui.invalid_field_default');
    }
    if (_type == 'text' || _type == 'long_text') {
      final minimum = int.tryParse(_minLength.text.trim());
      final maximum = int.tryParse(_maxLength.text.trim());
      if ((minimum != null && (parsed as String).runes.length < minimum) ||
          (maximum != null && (parsed as String).runes.length > maximum)) {
        return context.ventioText('native.ui.invalid_field_default');
      }
    }
    if (_type == 'decimal') {
      final precision = int.tryParse(_precision.text.trim());
      if (precision != null && _fractionalDigits(parsed) > precision) {
        return context.ventioText('native.ui.invalid_field_default');
      }
    }
    if (parsed is num) {
      final minimum = _parseBound(_minValue.text);
      final maximum = _parseBound(_maxValue.text);
      if ((minimum != null && parsed < minimum) ||
          (maximum != null && parsed > maximum)) {
        return context.ventioText('native.ui.invalid_field_default');
      }
    }
    return null;
  }

  int _fractionalDigits(num value) {
    final parts = value.abs().toString().toLowerCase().split('e');
    final mantissa = parts.first;
    final exponent = parts.length == 2 ? int.tryParse(parts.last) ?? 0 : 0;
    final fraction = mantissa.split('.').skip(1).firstOrNull ?? '';
    return fraction.replaceFirst(RegExp(r'0+$'), '').length - exponent;
  }

  bool _validIsoDate(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
    final parsed = DateTime.tryParse(value);
    return parsed != null && parsed.toIso8601String().startsWith(value);
  }

  String? _permissionError(String? value) {
    final permission = value?.trim() ?? '';
    if (permission.isEmpty) return null;
    final prefix = permissionKey(
      widget.moduleId,
      widget.docTypeName,
      'read',
    ).replaceFirst(RegExp(r'\.read$'), '.');
    if (!permission.startsWith(prefix) ||
        permission.length > 200 ||
        !RegExp(r'^[a-z][a-z0-9_.-]*$').hasMatch(permission)) {
      return 'Use a permission key under $prefix';
    }
    return null;
  }

  List<Map<String, dynamic>> get _numericCalculationFields => widget
      .availableFields
      .where(
        (field) =>
            field['name'] != _name.text.trim() &&
            {'integer', 'decimal'}.contains(field['type']) &&
            field['calculation'] == null,
      )
      .toList(growable: false);

  List<Map<String, dynamic>> get _calculationTables => widget.availableFields
      .where(
        (field) =>
            field['name'] != _name.text.trim() &&
            field['type'] == 'table' &&
            field['childDocType'] is Map,
      )
      .toList(growable: false);

  List<Map<String, dynamic>> get _calculationValues {
    final table = _calculationTables.where(
      (field) => field['name'] == _calculationRows,
    );
    if (table.isEmpty) return const [];
    final child = table.single['childDocType'] as Map;
    final fields = child['fields'];
    if (fields is! List) return const [];
    return fields
        .whereType<Map>()
        .map((field) => Map<String, dynamic>.from(field))
        .where((field) => {'integer', 'decimal'}.contains(field['type']))
        .toList(growable: false);
  }

  Widget _calculationEditor(BuildContext context) {
    final canMultiply =
        widget.childField && _numericCalculationFields.length >= 2;
    final canSum = !widget.childField && _calculationTables.isNotEmpty;
    final selectedType = switch (_calculationType) {
      'multiply' when canMultiply => 'multiply',
      'sum' when canSum => 'sum',
      _ => null,
    };
    return Column(
      children: [
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(
          initialValue: selectedType,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: context.ventioText('native.ui.calculation'),
          ),
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: VentioText('native.ui.no_calculation'),
            ),
            if (canMultiply)
              DropdownMenuItem<String?>(
                value: 'multiply',
                child: VentioText('native.ui.multiply_fields'),
              ),
            if (canSum)
              DropdownMenuItem<String?>(
                value: 'sum',
                child: VentioText('native.ui.sum_child_rows'),
              ),
          ],
          onChanged: (value) => setState(() {
            _calculationType = value;
            if (value == null) {
              _calculationLeft = null;
              _calculationRight = null;
              _calculationRows = null;
              _calculationValue = null;
            } else {
              _defaultValue.clear();
            }
          }),
          validator: (value) =>
              value == 'multiply' &&
                      (_calculationLeft == null || _calculationRight == null) ||
                  value == 'sum' &&
                      (_calculationRows == null || _calculationValue == null)
              ? context.ventioText('native.ui.complete_calculation')
              : null,
        ),
        if (selectedType == 'multiply') ...[
          const SizedBox(height: 8),
          for (final pair in [
            ('left', 'native.ui.calculation_left_field', _calculationLeft),
            ('right', 'native.ui.calculation_right_field', _calculationRight),
          ])
            DropdownButtonFormField<String?>(
              key: ValueKey<String>('calculation-${pair.$1}'),
              initialValue:
                  _numericCalculationFields.any(
                    (field) => field['name'] == pair.$3,
                  )
                  ? pair.$3
                  : null,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: context.ventioText(pair.$2),
              ),
              items: [
                for (final field in _numericCalculationFields)
                  DropdownMenuItem<String?>(
                    value: field['name'] as String,
                    child: Text(field['name'] as String),
                  ),
              ],
              onChanged: (value) => setState(() {
                if (pair.$1 == 'left') _calculationLeft = value;
                if (pair.$1 == 'right') _calculationRight = value;
              }),
            ),
        ],
        if (selectedType == 'sum') ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            initialValue:
                _calculationTables.any(
                  (field) => field['name'] == _calculationRows,
                )
                ? _calculationRows
                : null,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: context.ventioText('native.ui.calculation_table'),
            ),
            items: [
              for (final field in _calculationTables)
                DropdownMenuItem<String?>(
                  value: field['name'] as String,
                  child: Text(field['name'] as String),
                ),
            ],
            onChanged: (value) => setState(() {
              _calculationRows = value;
              _calculationValue = null;
            }),
          ),
          if (_calculationValues.isNotEmpty) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              initialValue:
                  _calculationValues.any(
                    (field) => field['name'] == _calculationValue,
                  )
                  ? _calculationValue
                  : null,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: context.ventioText('native.ui.calculation_value'),
              ),
              items: [
                for (final field in _calculationValues)
                  DropdownMenuItem<String?>(
                    value: field['name'] as String,
                    child: Text(field['name'] as String),
                  ),
              ],
              onChanged: (value) => setState(() => _calculationValue = value),
            ),
          ],
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add field' : 'Edit field'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  decoration: InputDecoration(
                    labelText: context.ventioText('native.ui.field_id'),
                    hintText: 'serialNumber',
                  ),
                  validator: (value) => _identifierError(
                    value,
                    RegExp(r'^[a-z][A-Za-z0-9_]*$'),
                    'Use lower camel case, such as serialNumber.',
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _label,
                  decoration: InputDecoration(
                    labelText: context.ventioText('native.ui.label'),
                  ),
                  validator: (value) =>
                      _requiredText(value, 'Enter a field label.'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _description,
                  maxLength: 500,
                  decoration: InputDecoration(
                    labelText: context.ventioText(
                      'native.ui.field_description',
                    ),
                  ),
                  validator: (value) => (value?.length ?? 0) > 500
                      ? context.ventioText('native.ui.description_too_long')
                      : null,
                ),
                if (!widget.childField)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: VentioText('native.ui.read_only'),
                    value: _readOnly,
                    onChanged: (value) =>
                        setState(() => _readOnly = value ?? false),
                  ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _type,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: context.ventioText('native.ui.data_type'),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'text',
                      child: VentioText('native.ui.text'),
                    ),
                    DropdownMenuItem(
                      value: 'long_text',
                      child: VentioText('native.ui.long_text'),
                    ),
                    if (!widget.childField)
                      const DropdownMenuItem(
                        value: 'table',
                        child: VentioText('native.ui.child_table'),
                      ),
                    DropdownMenuItem(
                      value: 'integer',
                      child: VentioText('native.ui.whole_number'),
                    ),
                    DropdownMenuItem(
                      value: 'decimal',
                      child: VentioText('native.ui.decimal'),
                    ),
                    DropdownMenuItem(
                      value: 'boolean',
                      child: VentioText('native.ui.yes_no'),
                    ),
                    DropdownMenuItem(
                      value: 'date',
                      child: VentioText('native.ui.date'),
                    ),
                    DropdownMenuItem(
                      value: 'datetime',
                      child: VentioText('native.ui.date_and_time'),
                    ),
                    DropdownMenuItem(
                      value: 'enum',
                      child: VentioText('native.ui.choice_list'),
                    ),
                    DropdownMenuItem(
                      value: 'reference',
                      child: VentioText('native.ui.relationship'),
                    ),
                  ],
                  onChanged: (value) => setState(() {
                    if (value == 'long_text' &&
                        _maxLength.text.trim() == '160') {
                      _maxLength.text = '2000';
                    } else if (value == 'text' &&
                        _maxLength.text.trim() == '2000') {
                      _maxLength.text = '160';
                    }
                    _type = value ?? 'text';
                  }),
                ),
                if (widget.childField)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      context.ventioText(
                        'native.ui.child_field_uses_parent_table_access',
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (_type == 'table') ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _configureChildDocType,
                    icon: const Icon(Icons.table_rows_outlined),
                    label: Text(
                      _childDocType == null
                          ? context.ventioText(
                              'native.ui.configure_child_doctype',
                            )
                          : context.ventioText(
                              'native.ui.edit_child_doctype',
                              params: {'name': _childDocType!['name']},
                            ),
                    ),
                  ),
                ],
                if (_type == 'text' || _type == 'long_text') ...[
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _minLength,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: context.ventioText('native.ui.minimum_length'),
                      hintText: context.ventioText('native.ui.optional'),
                    ),
                    validator: (value) => _lengthError(value, minimum: true),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _maxLength,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: context.ventioText('native.ui.maximum_length'),
                    ),
                    validator: (value) => _lengthError(value, minimum: false),
                  ),
                ],
                if (_type == 'integer' || _type == 'decimal') ...[
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _minValue,
                    keyboardType: _type == 'integer'
                        ? TextInputType.number
                        : const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: context.ventioText('native.ui.minimum_value'),
                      hintText: context.ventioText('native.ui.optional'),
                    ),
                    validator: (value) => _boundError(value, minimum: true),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _maxValue,
                    keyboardType: _type == 'integer'
                        ? TextInputType.number
                        : const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: context.ventioText('native.ui.maximum_value'),
                      hintText: context.ventioText('native.ui.optional'),
                    ),
                    validator: (value) => _boundError(value, minimum: false),
                  ),
                  if (_type == 'decimal') ...[
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _precision,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: context.ventioText('native.ui.precision'),
                        hintText: context.ventioText('native.ui.optional'),
                      ),
                      validator: _precisionError,
                    ),
                    if (widget.availableFields.isNotEmpty)
                      _calculationEditor(context),
                  ],
                ],
                if (!['table', 'reference'].contains(_type)) ...[
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _defaultValue,
                    decoration: InputDecoration(
                      labelText: context.ventioText('native.ui.field_default'),
                      hintText: context.ventioText('native.ui.optional'),
                    ),
                    validator: _defaultError,
                  ),
                ],
                if (_type == 'enum') ...[
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _enumValues,
                    minLines: 2,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: context.ventioText('native.ui.choice_values'),
                      hintText: 'new, active, retired',
                      helperText: context.ventioText(
                        'native.ui.separate_stable_values_with_commas',
                      ),
                    ),
                    validator: (value) {
                      final values = (value ?? '')
                          .split(',')
                          .map((item) => item.trim())
                          .where((item) => item.isNotEmpty)
                          .toList();
                      if (values.isEmpty) {
                        return context.ventioText(
                          'native.ui.add_at_least_one_choice',
                        );
                      }
                      if (values.toSet().length != values.length) {
                        return context.ventioText(
                          'native.ui.choice_values_must_be_unique',
                        );
                      }
                      if (values.any((item) => !_enumValue.hasMatch(item))) {
                        return context.ventioText(
                          'native.ui.use_lowercase_stable_choice_ids',
                        );
                      }
                      return null;
                    },
                  ),
                ],
                if (_type == 'reference') ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: _referenceTo,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: context.ventioText(
                        'native.ui.related_doctype',
                      ),
                    ),
                    items: [
                      for (final target in widget.relationTargets)
                        DropdownMenuItem(value: target, child: Text(target)),
                    ],
                    onChanged: (value) => setState(() => _referenceTo = value),
                    validator: (value) => value == null
                        ? context.ventioText('native.ui.select_a_doctype')
                        : null,
                  ),
                ],
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const VentioText('native.ui.required_field'),
                  value: _required,
                  onChanged: (value) => setState(() => _required = value),
                ),
                const SizedBox(height: 8),
                if (!widget.childField)
                  TextFormField(
                    controller: _readPermission,
                    decoration: InputDecoration(
                      labelText: context.ventioText(
                        'native.ui.read_permission_optional',
                      ),
                      helperText: context.ventioText(
                        'native.ui.adds_a_host_grant_required_to_receive_this_field',
                      ),
                    ),
                    validator: _permissionError,
                  ),
                const SizedBox(height: 8),
                if (!widget.childField)
                  TextFormField(
                    controller: _writePermission,
                    decoration: InputDecoration(
                      labelText: context.ventioText(
                        'native.ui.write_permission_optional',
                      ),
                      helperText: context.ventioText(
                        'native.ui.adds_a_host_grant_required_to_create_or_change_this_field',
                      ),
                    ),
                    validator: _permissionError,
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const VentioText('native.ui.cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const VentioText('native.ui.save_field'),
        ),
      ],
    );
  }
}

class _ChildDocTypeEditorDialog extends StatefulWidget {
  const _ChildDocTypeEditorDialog({
    required this.moduleId,
    required this.parentDocTypeName,
    required this.relationTargets,
    this.existing,
  });

  final String moduleId;
  final String parentDocTypeName;
  final List<String> relationTargets;
  final Map<String, dynamic>? existing;

  @override
  State<_ChildDocTypeEditorDialog> createState() =>
      _ChildDocTypeEditorDialogState();
}

class _ChildDocTypeEditorDialogState extends State<_ChildDocTypeEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _label;
  final List<Map<String, dynamic>> _fields = [];

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?['name'] as String? ?? '');
    _label = TextEditingController(text: existing?['label'] as String? ?? '');
    final rawFields = existing?['fields'];
    if (rawFields is List) {
      _fields.addAll(
        rawFields.map((field) => Map<String, dynamic>.from(field as Map)),
      );
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _editField([Map<String, dynamic>? existing]) async {
    final childName = _name.text.trim();
    if (!RegExp(r'^[A-Z][A-Za-z0-9_]{0,79}$').hasMatch(childName)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: VentioText('native.ui.enter_child_doctype_name_first'),
        ),
      );
      return;
    }
    if (existing == null && _fields.length >= 50) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: VentioText('native.ui.child_doctype_field_limit')),
      );
      return;
    }
    final field = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _FieldEditorDialog(
        moduleId: widget.moduleId,
        docTypeName: childName,
        relationTargets: widget.relationTargets,
        availableFields: _fields
            .map((field) => Map<String, dynamic>.from(field))
            .toList(),
        childField: true,
        existing: existing,
      ),
    );
    if (field == null || !mounted) return;
    field
      ..remove('readPermission')
      ..remove('writePermission')
      ..remove('readOnly');
    try {
      FieldDefinition.fromJson(field, childField: true);
      final duplicate = _fields.any(
        (item) => item['name'] == field['name'] && !identical(item, existing),
      );
      if (duplicate) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: VentioText('native.ui.child_field_ids_unique')),
        );
        return;
      }
      setState(() {
        if (existing == null) {
          _fields.add(field);
        } else {
          final index = _fields.indexOf(existing);
          if (index >= 0) _fields[index] = field;
        }
      });
    } on ContractError {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: VentioText('native.ui.invalid_child_field_schema')),
      );
    }
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    if (_fields.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: VentioText('native.ui.add_child_doctype_field')),
      );
      return;
    }
    final name = _name.text.trim();
    final namespace =
        '${_messageNamespace(widget.moduleId)}.'
        '${widget.parentDocTypeName.toLowerCase()}.child.${name.toLowerCase()}';
    final child = <String, dynamic>{
      'name': name,
      'label': _label.text.trim(),
      'labelKey': '$namespace.label',
      'fields': List<Map<String, dynamic>>.of(_fields),
    };
    try {
      ChildDocTypeDefinition.fromJson(child);
    } on ContractError {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: VentioText('native.ui.invalid_child_doctype')),
      );
      return;
    }
    Navigator.pop(context, child);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const VentioText('native.ui.child_doctype'),
    content: SizedBox(
      width: 560,
      child: Form(
        key: _formKey,
        child: ListView(
          shrinkWrap: true,
          children: [
            TextFormField(
              controller: _name,
              decoration: InputDecoration(
                labelText: context.ventioText('native.ui.child_doctype_id'),
              ),
              validator: (value) {
                final raw = value?.trim() ?? '';
                if (!RegExp(r'^[A-Z][A-Za-z0-9_]{0,79}$').hasMatch(raw)) {
                  return context.ventioText(
                    'native.ui.invalid_child_doctype_id',
                  );
                }
                return null;
              },
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _label,
              decoration: InputDecoration(
                labelText: context.ventioText('native.ui.child_doctype_label'),
              ),
              validator: (value) => (value?.trim().isNotEmpty ?? false)
                  ? null
                  : context.ventioText('native.ui.enter_child_doctype_label'),
            ),
            const SizedBox(height: 12),
            Text(
              context.ventioText(
                'native.ui.child_fields_inherit_parent_table_access',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final field in _fields)
              ListTile(
                title: Text(field['label'] as String),
                subtitle: Text(
                  '${field['name']} · ${field['type']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (action) {
                    if (action == 'edit') _editField(field);
                    if (action == 'remove') {
                      setState(() => _fields.remove(field));
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: VentioText('native.ui.edit_field'),
                    ),
                    PopupMenuItem(
                      value: 'remove',
                      child: VentioText('native.ui.remove_field'),
                    ),
                  ],
                ),
              ),
            OutlinedButton.icon(
              onPressed: () => _editField(),
              icon: const Icon(Icons.add),
              label: const VentioText('native.ui.add_child_field'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const VentioText('native.ui.cancel'),
      ),
      FilledButton(
        onPressed: _save,
        child: const VentioText('native.ui.save_child_doctype'),
      ),
    ],
  );
}

class DynamicDocTypePage extends StatefulWidget {
  const DynamicDocTypePage({
    required this.store,
    this.queue,
    required this.moduleId,
    required this.metadata,
    required this.scope,
    this.moduleVersion,
    this.hostProfile,
    this.credentialVault,
    this.hostPackageClientFactory,
    this.previewOnly = false,
    super.key,
  });

  final LocalExtensionStore store;
  final LocalCommandQueue? queue;
  final String moduleId;
  final Map<String, dynamic> metadata;
  final RecordScope scope;
  final String? moduleVersion;
  final HostConnectionProfile? hostProfile;
  final HostCredentialVault? credentialVault;
  final HostExtensionPackageClientFactory? hostPackageClientFactory;
  final bool previewOnly;

  @override
  State<DynamicDocTypePage> createState() => _DynamicDocTypePageState();
}

class _DynamicDocTypePageState extends State<DynamicDocTypePage> {
  final _searchController = TextEditingController();
  final _filterController = TextEditingController();
  List<LocalExtensionRecord> _records = const [];
  bool _loading = false;
  String? _error;
  String? _filterField;
  String? _sortField;
  bool _ascending = true;
  int _loadGeneration = 0;
  int _hostOffset = 0;
  String? _hostCursor;
  bool _hostHasMore = false;
  bool _hostQuerySucceeded = false;
  bool _hostAccessDenied = false;
  String? _hostWarning;
  Set<String>? _hostReadableFields;
  Set<String>? _hostWritableFields;
  Set<String>? _hostCreatableFields;

  DocTypeDefinition get _definition =>
      DocTypeDefinition.fromJson(widget.metadata);

  RecordScope get _recordScope {
    final profile = widget.hostProfile;
    return profile == null
        ? widget.scope
        : RecordScope(
            organizationId: profile.tenantId,
            companyId: profile.companyId,
            branchId: profile.branchId,
          );
  }

  @override
  void initState() {
    super.initState();
    final defaultSortFields = _definition.fields
        .where((field) => field.readPermission == null)
        .toList(growable: false);
    _sortField = defaultSortFields.isEmpty
        ? null
        : defaultSortFields.first.name;
    if (!widget.previewOnly && _definition.operations.contains('read')) {
      _loadRecords();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _loadRecords() async {
    if (!_definition.operations.contains('read')) return;
    final generation = ++_loadGeneration;
    _hostOffset = 0;
    _hostCursor = null;
    _hostHasMore = false;
    setState(() {
      _loading = true;
      _error = null;
      _hostWarning = null;
      _hostQuerySucceeded = false;
    });
    try {
      final profile = widget.hostProfile;
      _hostAccessDenied =
          profile != null &&
          profile.actorId != null &&
          profile.deviceId != null &&
          await widget.store.hasHostRecordReadDenial(
            profile: profile,
            moduleId: widget.moduleId,
          );
      final cachedFieldPermissions = profile == null
          ? null
          : await widget.store.getHostFieldPermissions(
              profile: profile,
              moduleId: widget.moduleId,
              docTypeName: _definition.name,
            );
      _hostReadableFields = cachedFieldPermissions?.readableFields;
      _hostWritableFields = cachedFieldPermissions?.writableFields;
      _hostCreatableFields = cachedFieldPermissions?.creatableFields;
      if (widget.queue != null) {
        await reconcileQueuedRecords(widget.store, widget.queue!);
      }
      try {
        await _queryHostRecords(offset: 0, generation: generation);
      } catch (error) {
        _hostWarning = error.toString();
        await _rememberHostRecordReadDenial(error, generation: generation);
      }
      final records = await widget.store.listRecords(
        moduleId: widget.moduleId,
        docTypeName: _definition.name,
        scope: _recordScope,
        search: _searchController.text,
        filterField: _filterField,
        filterContains: _filterController.text,
        sortField: _sortField,
        ascending: _ascending,
        limit: 1000,
        readableFields: _hostReadableFields,
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _records = _hostAccessDenied ? const [] : records;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _loadMoreHostRecords() async {
    if (_loading || !_hostHasMore) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _hostWarning = null;
    });
    try {
      await _queryHostRecords(
        cursor: _hostCursor,
        offset: _hostCursor == null ? _hostOffset : 0,
        generation: generation,
      );
      final records = await widget.store.listRecords(
        moduleId: widget.moduleId,
        docTypeName: _definition.name,
        scope: _recordScope,
        search: _searchController.text,
        filterField: _filterField,
        filterContains: _filterController.text,
        sortField: _sortField,
        ascending: _ascending,
        limit: 1000,
        readableFields: _hostReadableFields,
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _records = records;
        _loading = false;
      });
    } catch (error) {
      await _rememberHostRecordReadDenial(error, generation: generation);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        if (_hostAccessDenied) _records = const [];
        _loading = false;
        _hostWarning = error.toString();
      });
    }
  }

  Future<void> _rememberHostRecordReadDenial(
    Object error, {
    required int generation,
  }) async {
    if (!mounted ||
        generation != _loadGeneration ||
        !_isHostRecordReadDenial(error)) {
      return;
    }
    _hostAccessDenied = true;
    final profile = widget.hostProfile;
    if (profile == null ||
        profile.actorId == null ||
        profile.deviceId == null) {
      return;
    }
    try {
      await widget.store.markHostRecordReadDenied(
        profile: profile,
        moduleId: widget.moduleId,
        reasonCode: (error as HostPackageTransportException).code,
      );
    } catch (storageError) {
      _hostWarning =
          '${error.toString()} (the local denial marker could not be saved: $storageError)';
    }
  }

  Future<void> _queryHostRecords({
    int offset = 0,
    String? cursor,
    required int generation,
  }) async {
    final profile = widget.hostProfile;
    final vault = widget.credentialVault;
    final version = widget.moduleVersion;
    if (widget.previewOnly || profile == null) {
      return;
    }
    if (vault == null || version == null) {
      throw const HostPackageTransportException(
        'HOST_CONFIGURATION_INCOMPLETE',
      );
    }
    final client =
        widget.hostPackageClientFactory?.call(
          endpoint: Uri.parse(profile.endpoint),
          credentials: vault,
        ) ??
        HostExtensionPackageClient(
          endpoint: Uri.parse(profile.endpoint),
          credentials: vault,
        );
    final localBundle = await widget.store.exportBundle(widget.moduleId);
    final localDigest = sha256
        .convert(utf8.encode(canonicalJson(localBundle.toJson())))
        .toString();
    final page = await client.queryRecords(
      companyId: profile.companyId,
      branchId: profile.branchId,
      moduleId: widget.moduleId,
      version: version,
      docType: _definition.name,
      search: _searchController.text,
      filterField: _filterField,
      filterContains: _filterController.text,
      sortField: _sortField,
      descending: !_ascending,
      cursor: cursor,
      offset: offset,
      limit: 50,
    );
    if (page.packageSha256 != localDigest) {
      throw const HostPackageTransportException(
        'LOCAL_PACKAGE_DIFFERS_FROM_HOST_APPROVED_RELEASE',
      );
    }
    if (_definition.fields.any(
          (field) =>
              field.readPermission != null || field.writePermission != null,
        ) &&
        (page.readableFields == null ||
            page.writableFields == null ||
            page.creatableFields == null)) {
      throw const HostPackageTransportException(
        'HOST_FIELD_PERMISSIONS_MISSING',
      );
    }
    _hostReadableFields = page.readableFields;
    _hostWritableFields = page.writableFields;
    _hostCreatableFields = page.creatableFields;
    final readableFields = page.readableFields;
    if (_filterField != null &&
        readableFields != null &&
        !readableFields.contains(_filterField)) {
      _filterField = null;
    }
    if (_sortField != null &&
        readableFields != null &&
        !readableFields.contains(_sortField)) {
      _sortField = readableFields.isEmpty
          ? null
          : (_definition.fields
                .where((field) => readableFields.contains(field.name))
                .toList(growable: false)
                .first
                .name);
    }
    if (readableFields != null && page.writableFields != null) {
      final creatableFields = page.creatableFields;
      if (creatableFields == null) {
        throw const HostPackageTransportException(
          'HOST_FIELD_PERMISSIONS_MISSING',
        );
      }
      await widget.store.applyHostFieldPermissions(
        moduleId: widget.moduleId,
        docTypeName: _definition.name,
        scope: _recordScope,
        readableFields: readableFields,
        writableFields: page.writableFields!,
        creatableFields: creatableFields,
        profile: profile,
      );
    }
    for (final record in page.records) {
      if (!mounted || generation != _loadGeneration) return;
      await widget.store.applyHostRecord(
        moduleId: widget.moduleId,
        docTypeName: _definition.name,
        scope: _recordScope,
        recordId: record.recordId,
        revision: record.revision,
        values: record.values,
        updatedAtUtc: DateTime.parse(record.updatedAtUtc),
        readableFields: page.readableFields,
        writableFields: page.writableFields,
        creatableFields: page.creatableFields,
      );
    }
    if (!mounted || generation != _loadGeneration) return;
    if (profile.actorId != null && profile.deviceId != null) {
      await widget.store.clearHostRecordReadDenial(
        profile: profile,
        moduleId: widget.moduleId,
      );
    }
    _hostAccessDenied = false;
    _hostWarning = null;
    _hostHasMore = page.hasMore;
    _hostOffset = offset + page.records.length;
    _hostCursor = page.nextCursor;
    _hostQuerySucceeded = true;
  }

  Future<void> _syncPendingCommands() async {
    final profile = widget.hostProfile;
    final vault = widget.credentialVault;
    final queue = widget.queue;
    if (profile == null || vault == null || queue == null) return;
    try {
      final client =
          widget.hostPackageClientFactory?.call(
            endpoint: Uri.parse(profile.endpoint),
            credentials: vault,
          ) ??
          HostExtensionPackageClient(
            endpoint: Uri.parse(profile.endpoint),
            credentials: vault,
          );
      final identity = await _requireHostSyncIdentity(client, profile);
      final count = await HostSyncService(
        queue: queue,
        identity: identity,
        transport: HttpHostCommandTransport(
          endpoint: Uri.parse(profile.endpoint),
          credentials: vault,
        ),
      ).syncPending();
      await reconcileQueuedRecords(widget.store, queue);
      await _loadRecords();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: VentioText(
              'native.ui.host_resolved_commands',
              params: {'count': count},
            ),
          ),
        );
      }
    } catch (error) {
      await reconcileQueuedRecords(widget.store, queue);
      final failure = await _recordHostSyncFailure(error);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.ventioText(
                'native.ui.sync_failed_message',
                params: {
                  'code': failure.code,
                  'correlationId': failure.correlationId,
                },
              ),
            ),
          ),
        );
      }
      await _loadRecords();
    }
  }

  List<LocalExtensionRecord> get _visibleRecords => _records;

  bool _canReadField(FieldDefinition field) =>
      _hostReadableFields?.contains(field.name) ?? field.readPermission == null;

  bool _canCreateField(FieldDefinition field) =>
      _hostCreatableFields?.contains(field.name) ??
      (field.writePermission == null && field.readPermission == null);

  Future<void> _openForm([LocalExtensionRecord? record]) async {
    if (widget.previewOnly) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (context) => DynamicRecordFormPage(
            store: widget.store,
            moduleId: widget.moduleId,
            definition: _definition,
            scope: _recordScope,
            readableFields: _hostReadableFields,
            writableFields: _hostWritableFields,
            creatableFields: _hostCreatableFields,
            previewOnly: true,
          ),
        ),
      );
      return;
    }
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => DynamicRecordFormPage(
          store: widget.store,
          queue: widget.queue,
          moduleId: widget.moduleId,
          definition: _definition,
          scope: _recordScope,
          moduleVersion: widget.moduleVersion,
          hostProfile: widget.hostProfile,
          credentialVault: widget.credentialVault,
          hostPackageClientFactory: widget.hostPackageClientFactory,
          record: record,
          readableFields: _hostReadableFields,
          writableFields: _hostWritableFields,
          creatableFields: _hostCreatableFields,
        ),
      ),
    );
    if (changed == true) await _loadRecords();
  }

  Future<void> _openDetails(LocalExtensionRecord record) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => DynamicRecordDetailsPage(
          store: widget.store,
          queue: widget.queue,
          moduleId: widget.moduleId,
          definition: _definition,
          scope: _recordScope,
          moduleVersion: widget.moduleVersion,
          hostProfile: widget.hostProfile,
          credentialVault: widget.credentialVault,
          hostPackageClientFactory: widget.hostPackageClientFactory,
          readableFields: _hostReadableFields,
          writableFields: _hostWritableFields,
          creatableFields: _hostCreatableFields,
          record: record,
        ),
      ),
    );
    if (changed == true) await _loadRecords();
  }

  @override
  Widget build(BuildContext context) {
    final metadata = widget.metadata;
    final title = context.extensionMetadataText(
      _definition.pageTitleKey,
      _definition.pageTitle,
    );
    final canRead = _definition.operations.contains('read');
    final canCreate =
        _definition.operations.contains('create') &&
        _definition.fields
            .where((field) => field.required && field.calculation == null)
            .every(_canCreateField);
    final readableFields = _definition.fields
        .where(_canReadField)
        .toList(growable: false);
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (widget.hostProfile != null)
            IconButton(
              tooltip: context.ventioText(
                'native.ui.sync_pending_commands_with_host',
              ),
              onPressed:
                  widget.credentialVault == null ||
                      widget.queue == null ||
                      _loading
                  ? null
                  : _syncPendingCommands,
              icon: const Icon(Icons.sync),
            ),
          IconButton(
            tooltip: context.ventioText('native.ui.refresh_records'),
            onPressed: _loading ? null : _loadRecords,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: widget.previewOnly || canCreate
          ? FloatingActionButton.extended(
              onPressed: () => _openForm(),
              icon: Icon(
                widget.previewOnly ? Icons.preview_outlined : Icons.add,
              ),
              label: VentioText(
                widget.previewOnly
                    ? 'native.ui.preview_form'
                    : 'native.ui.new_record',
              ),
            )
          : null,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 96),
            children: [
              _LocalOnlyNotice(
                title: _hostAccessDenied
                    ? context.ventioText(
                        'native.ui.host_authorization_required',
                      )
                    : widget.previewOnly
                    ? context.ventioText('native.ui.metadata_preview')
                    : widget.hostProfile == null
                    ? context.ventioText('native.ui.provisional_local_records')
                    : _hostQuerySucceeded
                    ? context.ventioText('native.ui.host_authoritative_records')
                    : context.ventioText(
                        'native.ui.local_records_host_unavailable',
                      ),
                body: _hostAccessDenied
                    ? context.ventioText(
                        'native.ui.host_denied_list_query_body',
                      )
                    : widget.previewOnly
                    ? context.ventioText(
                        'native.ui.list_preview_activation_body',
                      )
                    : widget.hostProfile == null
                    ? context.ventioText(
                        'native.ui.local_records_need_host_connection',
                      )
                    : _hostQuerySucceeded
                    ? context.ventioText(
                        'native.ui.host_records_list_verified_scope',
                      )
                    : context.ventioText(
                        'native.ui.local_records_host_scope_unavailable',
                      ),
                icon: _hostAccessDenied
                    ? Icons.lock_outline
                    : widget.previewOnly
                    ? Icons.visibility_outlined
                    : _hostQuerySucceeded
                    ? Icons.verified_user_outlined
                    : Icons.storage_outlined,
              ),
              if (_hostWarning != null) ...[
                const SizedBox(height: 10),
                _StateCard(
                  icon: Icons.cloud_off_outlined,
                  title: context.ventioText(
                    'native.ui.host_records_were_not_refreshed',
                  ),
                  body: context.ventioText(
                    'native.ui.host_record_refresh_failed_body',
                  ),
                  action: TextButton.icon(
                    onPressed: _loadRecords,
                    icon: const Icon(Icons.refresh),
                    label: const VentioText('native.ui.retry_host_query'),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              if (metadata['description'] case final String description
                  when description.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(description),
              ],
              const SizedBox(height: 12),
              if (!widget.previewOnly && canRead && !_hostAccessDenied) ...[
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    labelText: context.ventioText('native.ui.search_records'),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      onPressed: () {
                        _searchController.clear();
                        _loadRecords();
                      },
                      icon: const Icon(Icons.clear),
                    ),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => _loadRecords(),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String?>(
                        initialValue: _filterField,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: context.ventioText(
                            'native.ui.filter_field',
                          ),
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: VentioText('native.ui.no_filter'),
                          ),
                          for (final field in readableFields)
                            DropdownMenuItem<String?>(
                              value: field.name,
                              child: Text(
                                context.extensionMetadataText(
                                  field.labelKey,
                                  field.label,
                                ),
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          setState(() => _filterField = value);
                          _loadRecords();
                        },
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: TextField(
                        controller: _filterController,
                        enabled: _filterField != null,
                        decoration: InputDecoration(
                          labelText: context.ventioText('native.ui.contains'),
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => _loadRecords(),
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String?>(
                        initialValue: _sortField,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: context.ventioText('native.ui.sort_by'),
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: VentioText('native.ui.last_updated'),
                          ),
                          for (final field in readableFields)
                            DropdownMenuItem<String?>(
                              value: field.name,
                              child: Text(
                                context.extensionMetadataText(
                                  field.labelKey,
                                  field.label,
                                ),
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          setState(() => _sortField = value);
                          _loadRecords();
                        },
                      ),
                    ),
                    IconButton(
                      tooltip: context.ventioText(
                        _ascending
                            ? 'native.ui.ascending'
                            : 'native.ui.descending',
                      ),
                      onPressed: () {
                        setState(() => _ascending = !_ascending);
                        _loadRecords();
                      },
                      icon: Icon(
                        _ascending ? Icons.arrow_upward : Icons.arrow_downward,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
              ],
              if (widget.previewOnly)
                _StateCard(
                  icon: Icons.view_list_outlined,
                  title: context.ventioText('native.ui.generated_list_view'),
                  body: context.ventioText(
                    'native.ui.generated_list_preview_summary',
                    params: {
                      'count': _definition.listColumns.length,
                      'columns': _definition.listColumns.length == 1
                          ? 'column'
                          : 'columns',
                    },
                  ),
                  action: OutlinedButton.icon(
                    onPressed: () => _openForm(),
                    icon: const Icon(Icons.open_in_new),
                    label: const VentioText('native.ui.open_generated_form'),
                  ),
                )
              else if (!canRead)
                _StateCard(
                  icon: Icons.lock_outline,
                  title: context.ventioText(
                    'native.ui.read_operation_is_not_declared',
                  ),
                  body: context.ventioText(
                    'native.ui.this_doctype_does_not_permit_listing_or_opening_records_on_this_device',
                  ),
                )
              else if (_loading)
                const Center(child: CircularProgressIndicator())
              else if (_hostAccessDenied)
                _StateCard(
                  icon: Icons.lock_outline,
                  title: context.ventioText(
                    'native.ui.host_denied_record_access',
                  ),
                  body: context.ventioText(
                    'native.ui.cached_records_hidden_until_authorized',
                  ),
                )
              else if (_error != null)
                _StateCard(
                  icon: Icons.error_outline,
                  title: context.ventioText(
                    'native.ui.records_could_not_be_loaded',
                  ),
                  body: context.ventioText(
                    'native.ui.record_list_load_failed_body',
                  ),
                  action: TextButton.icon(
                    onPressed: _loadRecords,
                    icon: const Icon(Icons.refresh),
                    label: const VentioText('native.ui.try_again'),
                  ),
                )
              else if (_visibleRecords.isEmpty)
                _StateCard(
                  icon: Icons.inbox_outlined,
                  title: context.ventioText('native.ui.no_matching_records'),
                  body: context.ventioText(
                    'native.ui.create_a_record_on_this_device_or_change_your_search_and_filters',
                  ),
                )
              else
                for (final record in _visibleRecords)
                  _RecordCard(
                    record: record,
                    columns: _listColumns,
                    onTap: () => _openDetails(record),
                  ),
              if (!widget.previewOnly && _hostHasMore && !_loading)
                Center(
                  child: OutlinedButton.icon(
                    onPressed: _loadMoreHostRecords,
                    icon: const Icon(Icons.expand_more),
                    label: const VentioText('native.ui.load_more_host_records'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<FieldDefinition> get _listColumns {
    final byName = {for (final field in _definition.fields) field.name: field};
    return _definition.listColumns
        .map((name) => byName[name]!)
        .where(_canReadField)
        .toList(growable: false);
  }
}

class DynamicRecordFormPage extends StatefulWidget {
  const DynamicRecordFormPage({
    required this.store,
    this.queue,
    required this.moduleId,
    required this.definition,
    required this.scope,
    this.moduleVersion,
    this.hostProfile,
    this.credentialVault,
    this.hostPackageClientFactory,
    this.record,
    this.initialValues,
    this.readableFields,
    this.writableFields,
    this.creatableFields,
    this.previewOnly = false,
    super.key,
  });

  final LocalExtensionStore store;
  final LocalCommandQueue? queue;
  final String moduleId;
  final DocTypeDefinition definition;
  final RecordScope scope;
  final String? moduleVersion;
  final HostConnectionProfile? hostProfile;
  final HostCredentialVault? credentialVault;
  final HostExtensionPackageClientFactory? hostPackageClientFactory;
  final LocalExtensionRecord? record;
  final Map<String, dynamic>? initialValues;
  final Set<String>? readableFields;
  final Set<String>? writableFields;
  final Set<String>? creatableFields;
  final bool previewOnly;

  @override
  State<DynamicRecordFormPage> createState() => _DynamicRecordFormPageState();
}

class _DynamicRecordFormPageState extends State<DynamicRecordFormPage> {
  final _formKey = GlobalKey<FormState>();
  String? _newRecordId;
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, bool> _booleans = {};
  final Map<String, String?> _selections = {};
  final Map<String, List<LocalExtensionRecord>> _references = {};
  final Map<String, List<Map<String, dynamic>>> _childRows = {};
  final Map<String, List<Object>> _childRowKeys = {};
  bool _loadingReferences = false;
  bool _saving = false;

  Set<String> get _effectiveReadableFields =>
      widget.readableFields ??
      widget.definition.fields
          .where((field) => field.readPermission == null)
          .map((field) => field.name)
          .toSet();

  Set<String> get _effectiveWritableFields =>
      widget.writableFields ??
      widget.definition.fields
          .where((field) => field.writePermission == null)
          .map((field) => field.name)
          .toSet();

  Set<String> get _effectiveCreatableFields =>
      widget.creatableFields ??
      widget.definition.fields
          .where(
            (field) =>
                field.writePermission == null && field.readPermission == null,
          )
          .map((field) => field.name)
          .toSet();

  bool _isEditable(FieldDefinition field) => widget.record == null
      ? !field.readOnly && _effectiveCreatableFields.contains(field.name)
      : !field.readOnly && _effectiveWritableFields.contains(field.name);

  bool get _canSaveOperation {
    final editing = widget.record != null;
    if (!widget.definition.operations.contains(editing ? 'update' : 'create')) {
      return false;
    }
    if (editing) return _formFields.any(_isEditable);
    final requiredFields = widget.definition.fields.where(
      (field) =>
          field.required &&
          field.defaultValue == null &&
          field.calculation == null,
    );
    return requiredFields.every(
      (field) => _effectiveCreatableFields.contains(field.name),
    );
  }

  List<FieldDefinition> get _formFields {
    final byName = {
      for (final field in widget.definition.fields) field.name: field,
    };
    return widget.definition.formFields
        .map((name) => byName[name]!)
        .where(
          (field) =>
              widget.previewOnly ||
              (widget.record == null
                  ? _effectiveCreatableFields.contains(field.name) ||
                        (field.readOnly &&
                            _effectiveReadableFields.contains(field.name))
                  : _effectiveReadableFields.contains(field.name) ||
                        _effectiveWritableFields.contains(field.name)),
        )
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    if (widget.record == null && widget.definition.namingSeries != null) {
      _newRecordId = createCommandId();
    }
    for (final field in _formFields) {
      final initialValues = widget.initialValues;
      final canRead =
          widget.previewOnly || _effectiveReadableFields.contains(field.name);
      final value = !canRead
          ? null
          : initialValues != null && initialValues.containsKey(field.name)
          ? initialValues[field.name]
          : widget.record?.values[field.name] ?? field.defaultValue;
      final displayValue =
          value == null &&
              !widget.previewOnly &&
              widget.record == null &&
              widget.definition.namingSeries?.field == field.name
          ? widget.definition.namingSeries!.provisionalName(_newRecordId!)
          : value;
      if (field.type == 'boolean') {
        _booleans[field.name] = displayValue as bool? ?? false;
      } else if (field.type == 'enum' || field.type == 'reference') {
        _selections[field.name] = displayValue as String?;
      } else if (field.type == 'table' && field.childDocType != null) {
        final child = field.childDocType!;
        final sourceRows = displayValue is List
            ? displayValue.whereType<Map>().toList()
            : [];
        _childRows[field.name] = [
          for (final row in sourceRows)
            {
              for (final childField in child.fields)
                if (row.containsKey(childField.name))
                  childField.name: row[childField.name],
            },
        ];
        _childRowKeys[field.name] = List<Object>.generate(
          sourceRows.length,
          (_) => Object(),
        );
      } else if (field.type == 'table') {
        _controllers[field.name] = TextEditingController(
          text: displayValue == null ? '[]' : jsonEncode(displayValue),
        );
      } else {
        _controllers[field.name] = TextEditingController(
          text: displayValue?.toString() ?? '',
        );
      }
    }
    _loadReferences();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadReferences() async {
    final references = <({String key, String docType})>[];
    for (final field in _formFields) {
      if (field.type == 'reference') {
        references.add((key: field.name, docType: field.referenceTo!));
      }
      if (field.type == 'table') {
        for (final childField
            in field.childDocType?.fields ?? const <FieldDefinition>[]) {
          if (childField.type == 'reference') {
            references.add((
              key: '${field.name}.${childField.name}',
              docType: childField.referenceTo!,
            ));
          }
        }
      }
    }
    if (references.isEmpty) return;
    setState(() => _loadingReferences = true);
    try {
      for (final reference in references) {
        _references[reference.key] = await widget.store.listRecords(
          moduleId: widget.moduleId,
          docTypeName: reference.docType,
          scope: widget.scope,
          limit: 500,
        );
      }
    } catch (_) {
      // A reference list can be empty in a preview; saving still validates it.
    } finally {
      if (mounted) setState(() => _loadingReferences = false);
    }
  }

  Map<String, dynamic> _values() {
    final values = <String, dynamic>{};
    for (final field in _formFields) {
      if (!_isEditable(field)) continue;
      if (field.type == 'table' && field.childDocType != null) {
        values[field.name] = [
          for (final row in _childRows[field.name] ?? const [])
            Map<String, dynamic>.of(row),
        ];
        continue;
      }
      if (field.type == 'boolean') {
        values[field.name] = _booleans[field.name] ?? false;
      } else if (field.type == 'enum' || field.type == 'reference') {
        values[field.name] = _selections[field.name];
      } else {
        final raw = _controllers[field.name]!.text.trim();
        if (raw.isEmpty) {
          values[field.name] = null;
        } else if (field.type == 'table') {
          try {
            values[field.name] = jsonDecode(raw);
          } on FormatException {
            values[field.name] = raw;
          }
        } else if (field.type == 'integer') {
          values[field.name] = int.tryParse(raw);
        } else if (field.type == 'decimal') {
          values[field.name] = num.tryParse(raw);
        } else {
          values[field.name] = raw;
        }
      }
    }
    return values;
  }

  Future<void> _save() async {
    if (widget.previewOnly) return;
    final operation = widget.record == null ? 'create' : 'update';
    if (!widget.definition.operations.contains(operation)) {
      _message('native.ui.form_operation_not_declared');
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    final values = widget.definition.calculateValues(_values());
    final issues = widget.definition.validatePayload(
      values,
      partial: widget.record != null,
    );
    if (issues.isNotEmpty) {
      _message('native.ui.correct_form_errors_before_saving');
      return;
    }
    setState(() => _saving = true);
    try {
      late final LocalExtensionRecord saved;
      if (widget.record == null) {
        final recordId = _newRecordId ?? createCommandId();
        saved = await widget.store.createRecord(
          moduleId: widget.moduleId,
          docTypeName: widget.definition.name,
          scope: widget.scope,
          values: values,
          recordId: recordId,
          readableFields: _effectiveReadableFields,
          writableFields: _effectiveWritableFields,
          creatableFields: _effectiveCreatableFields,
        );
      } else {
        saved = await widget.store.updateRecord(
          moduleId: widget.moduleId,
          docTypeName: widget.definition.name,
          recordId: widget.record!.recordId,
          scope: widget.scope,
          expectedRevision: widget.record!.revision,
          values: values,
          readableFields: _effectiveReadableFields,
          writableFields: _effectiveWritableFields,
          creatableFields: _effectiveCreatableFields,
        );
      }
      try {
        await _queueDynamicRecordCommand(
          queue: widget.queue,
          store: widget.store,
          profile: widget.hostProfile,
          record: saved,
          moduleVersion: widget.moduleVersion,
          definition: widget.definition,
          values: values,
        );
      } catch (_) {
        _message('native.ui.saved_record_needs_queue_recovery');
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      _message('native.ui.form_save_failed');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String key) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: VentioText(key)));
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.record != null;
    final canSave = _canSaveOperation;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          editing
              ? context.ventioText(
                  'native.ui.edit_document',
                  params: {
                    'label': context.extensionMetadataText(
                      widget.definition.labelKey,
                      widget.definition.label,
                    ),
                  },
                )
              : context.ventioText(
                  'native.ui.new_document',
                  params: {
                    'label': context.extensionMetadataText(
                      widget.definition.labelKey,
                      widget.definition.label,
                    ),
                  },
                ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                _LocalOnlyNotice(
                  title: widget.previewOnly
                      ? context.ventioText('native.ui.preview_form')
                      : widget.record?.authorityState == 'HOST_ACCEPTED'
                      ? context.ventioText('native.ui.host_record_local_edits')
                      : context.ventioText(
                          'native.ui.provisional_device_record',
                        ),
                  body: widget.previewOnly
                      ? context.ventioText('native.ui.form_preview_cannot_save')
                      : widget.record?.authorityState == 'HOST_ACCEPTED'
                      ? context.ventioText(
                          'native.ui.host_record_revision_notice',
                          params: {
                            'revision':
                                widget.record!.hostRevision ??
                                widget.record!.revision,
                          },
                        )
                      : context.ventioText(
                          'native.ui.provisional_record_notice',
                        ),
                  icon: widget.previewOnly
                      ? Icons.preview_outlined
                      : Icons.save_outlined,
                ),
                const SizedBox(height: 20),
                for (final field in _formFields) ...[
                  _fieldInput(field, editable: _isEditable(field)),
                  const SizedBox(height: 14),
                ],
                if (_loadingReferences) const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _saving || widget.previewOnly || !canSave
                        ? null
                        : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(
                      widget.previewOnly
                          ? context.ventioText('native.ui.preview_only')
                          : !canSave
                          ? context.ventioText(
                              'native.ui.operation_not_declared',
                            )
                          : _saving
                          ? context.ventioText('native.ui.saving')
                          : editing
                          ? context.ventioText('native.ui.save_changes')
                          : context.ventioText('native.ui.save_on_device'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _childReferenceKey(
    FieldDefinition tableField,
    FieldDefinition field,
  ) => '${tableField.name}.${field.name}';

  void _addChildRow(FieldDefinition tableField) {
    final child = tableField.childDocType!;
    final rows = _childRows[tableField.name] ??= [];
    if (rows.length >= 500) return;
    setState(() {
      rows.add({
        for (final field in child.fields)
          if (field.defaultValue != null) field.name: field.defaultValue,
      });
      (_childRowKeys[tableField.name] ??= []).add(Object());
      _refreshCalculatedValues();
    });
  }

  void _moveChildRow(FieldDefinition tableField, int index, int delta) {
    final rows = _childRows[tableField.name]!;
    final destination = index + delta;
    if (destination < 0 || destination >= rows.length) return;
    setState(() {
      final row = rows.removeAt(index);
      rows.insert(destination, row);
      final keys = _childRowKeys[tableField.name]!;
      keys.insert(destination, keys.removeAt(index));
      _refreshCalculatedValues();
    });
  }

  void _removeChildRow(FieldDefinition tableField, int index) {
    setState(() {
      _childRows[tableField.name]!.removeAt(index);
      _childRowKeys[tableField.name]!.removeAt(index);
      _refreshCalculatedValues();
    });
  }

  void _setChildValue(
    FieldDefinition tableField,
    int rowIndex,
    FieldDefinition childField,
    dynamic value,
  ) {
    _childRows[tableField.name]![rowIndex][childField.name] = value;
    _refreshCalculatedValues();
  }

  void _refreshCalculatedValues() {
    for (final tableField in widget.definition.fields.where(
      (field) => field.childDocType != null,
    )) {
      final calculatedFields = tableField.childDocType!.fields
          .where((field) => field.calculation != null)
          .toList(growable: false);
      if (calculatedFields.isEmpty) continue;
      try {
        final calculated = widget.definition.calculateValues({
          tableField.name: _childRows[tableField.name] ?? const [],
        });
        _childRows[tableField.name] = (calculated[tableField.name] as List)
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
      } on ContractError {
        for (final row in _childRows[tableField.name] ?? const []) {
          for (final field in calculatedFields) {
            row.remove(field.name);
          }
        }
      }
    }
    try {
      final calculated = widget.definition.calculateValues(_values());
      for (final field in widget.definition.fields.where(
        (item) => item.calculation != null,
      )) {
        final controller = _controllers[field.name];
        final value = calculated[field.name];
        if (controller != null &&
            value != null &&
            controller.text != '$value') {
          controller.text = '$value';
        }
      }
    } on ContractError {
      for (final field in widget.definition.fields.where(
        (item) => item.calculation != null,
      )) {
        _controllers[field.name]?.clear();
      }
    }
  }

  dynamic _parseChildValue(FieldDefinition field, String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    return switch (field.type) {
      'integer' => int.tryParse(value) ?? value,
      'decimal' => num.tryParse(value) ?? value,
      _ => value,
    };
  }

  String? _validateChildValue(FieldDefinition field, dynamic value) {
    if (field.calculation != null) return null;
    if (value == null || (value is String && value.trim().isEmpty)) {
      if (!field.required) return null;
      return context.ventioText(
        'native.ui.enter_field',
        params: {
          'label': context
              .extensionMetadataText(field.labelKey, field.label)
              .toLowerCase(),
        },
      );
    }
    if (field.validate(value) != null) {
      return context.ventioText(
        'native.ui.child_row_field_invalid',
        params: {
          'label': context.extensionMetadataText(field.labelKey, field.label),
        },
      );
    }
    return null;
  }

  Widget _childRowsGrid(FieldDefinition tableField, {required bool editable}) {
    final child = tableField.childDocType!;
    final rows = _childRows[tableField.name] ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                context.extensionMetadataText(child.labelKey, child.label),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Text(
              context.ventioText(
                'native.ui.child_row_count',
                params: {'count': rows.length},
              ),
            ),
            if (editable && !widget.previewOnly)
              IconButton(
                tooltip: context.ventioText('native.ui.add_child_row'),
                onPressed: rows.length >= 500
                    ? null
                    : () => _addChildRow(tableField),
                icon: const Icon(Icons.add),
              ),
          ],
        ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(context.ventioText('native.ui.no_child_rows')),
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                DataColumn(
                  label: Text(context.ventioText('native.ui.row_number')),
                ),
                for (final field in child.fields)
                  DataColumn(
                    label: Text(
                      context.extensionMetadataText(
                        field.labelKey,
                        field.label,
                      ),
                    ),
                  ),
                if (editable && !widget.previewOnly)
                  DataColumn(
                    label: Text(context.ventioText('native.ui.row_actions')),
                  ),
              ],
              rows: [
                for (var rowIndex = 0; rowIndex < rows.length; rowIndex++)
                  DataRow(
                    key: ValueKey<Object>(
                      _childRowKeys[tableField.name]![rowIndex],
                    ),
                    cells: [
                      DataCell(Text('${rowIndex + 1}')),
                      for (final childField in child.fields)
                        DataCell(
                          SizedBox(
                            width: 176,
                            child: _childCell(
                              tableField,
                              childField,
                              rowIndex,
                              editable: editable && !widget.previewOnly,
                            ),
                          ),
                        ),
                      if (editable && !widget.previewOnly)
                        DataCell(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: context.ventioText(
                                  'native.ui.move_row_up',
                                ),
                                onPressed: rowIndex == 0
                                    ? null
                                    : () => _moveChildRow(
                                        tableField,
                                        rowIndex,
                                        -1,
                                      ),
                                icon: const Icon(Icons.arrow_upward),
                              ),
                              IconButton(
                                tooltip: context.ventioText(
                                  'native.ui.move_row_down',
                                ),
                                onPressed: rowIndex == rows.length - 1
                                    ? null
                                    : () => _moveChildRow(
                                        tableField,
                                        rowIndex,
                                        1,
                                      ),
                                icon: const Icon(Icons.arrow_downward),
                              ),
                              IconButton(
                                tooltip: context.ventioText(
                                  'native.ui.remove_child_row',
                                ),
                                onPressed: () =>
                                    _removeChildRow(tableField, rowIndex),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _childCell(
    FieldDefinition tableField,
    FieldDefinition field,
    int rowIndex, {
    required bool editable,
  }) {
    final value = _childRows[tableField.name]![rowIndex][field.name];
    final rowKey = _childRowKeys[tableField.name]![rowIndex];
    if (field.calculation != null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(value?.toString() ?? '—'),
        ),
      );
    }
    if (field.type == 'boolean') {
      return Checkbox(
        value: value as bool? ?? false,
        onChanged: editable
            ? (next) => setState(
                () => _setChildValue(tableField, rowIndex, field, next),
              )
            : null,
      );
    }
    if (field.type == 'enum' || field.type == 'reference') {
      final records = field.type == 'reference'
          ? _references[_childReferenceKey(tableField, field)] ??
                const <LocalExtensionRecord>[]
          : const <LocalExtensionRecord>[];
      final options = field.type == 'enum'
          ? field.enumValues
          : records.map((record) => record.recordId).toList();
      return DropdownButtonFormField<String?>(
        key: ValueKey<String>(
          '${rowKey.hashCode}:${field.name}:${field.enumValues.join(',')}',
        ),
        initialValue: value as String?,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: context.extensionMetadataText(field.labelKey, field.label),
          border: const OutlineInputBorder(),
        ),
        items: [
          if (!field.required)
            const DropdownMenuItem<String?>(
              value: null,
              child: VentioText('native.ui.not_set'),
            ),
          for (final option in options)
            DropdownMenuItem<String?>(
              value: option,
              child: Text(
                field.type == 'enum'
                    ? _enumLabel(context, field, option)
                    : _recordTitle(
                        records.firstWhere(
                          (record) => record.recordId == option,
                        ),
                      ),
              ),
            ),
          if (value is String && !options.contains(value))
            DropdownMenuItem<String?>(value: value, child: Text(value)),
        ],
        onChanged: editable
            ? (next) => setState(
                () => _setChildValue(tableField, rowIndex, field, next),
              )
            : null,
        validator: (next) => _validateChildValue(field, next),
      );
    }
    final raw = value?.toString() ?? '';
    return TextFormField(
      key: ValueKey<String>('${rowKey.hashCode}:${field.name}:text'),
      initialValue: raw,
      readOnly: !editable,
      keyboardType: switch (field.type) {
        'integer' => TextInputType.number,
        'decimal' => const TextInputType.numberWithOptions(decimal: true),
        _ => TextInputType.text,
      },
      decoration: InputDecoration(
        labelText: context.extensionMetadataText(field.labelKey, field.label),
        border: const OutlineInputBorder(),
      ),
      onChanged: editable
          ? (next) => _setChildValue(
              tableField,
              rowIndex,
              field,
              _parseChildValue(field, next),
            )
          : null,
      validator: (next) =>
          _validateChildValue(field, _parseChildValue(field, next ?? '')),
    );
  }

  Widget _fieldInput(FieldDefinition field, {required bool editable}) {
    if (field.type == 'table' && field.childDocType != null) {
      return _childRowsGrid(field, editable: editable);
    }
    if (field.type == 'boolean') {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(context.extensionMetadataText(field.labelKey, field.label)),
        subtitle: VentioText(
          field.required ? 'native.ui.required' : 'native.ui.optional',
        ),
        value: _booleans[field.name] ?? false,
        onChanged: widget.previewOnly || !editable
            ? null
            : (value) => setState(() => _booleans[field.name] = value),
      );
    }
    if (field.type == 'enum') {
      return DropdownButtonFormField<String?>(
        initialValue: _selections[field.name],
        isExpanded: true,
        decoration: InputDecoration(
          labelText: context.extensionMetadataText(field.labelKey, field.label),
          border: const OutlineInputBorder(),
        ),
        items: [
          if (!field.required)
            const DropdownMenuItem<String?>(
              value: null,
              child: VentioText('native.ui.not_set'),
            ),
          for (final value in field.enumValues)
            DropdownMenuItem<String?>(
              value: value,
              child: Text(_enumLabel(context, field, value)),
            ),
        ],
        onChanged: widget.previewOnly || !editable
            ? null
            : (value) => setState(() => _selections[field.name] = value),
        validator: (value) => field.required && value == null
            ? context.ventioText(
                'native.ui.select_field',
                params: {
                  'label': context
                      .extensionMetadataText(field.labelKey, field.label)
                      .toLowerCase(),
                },
              )
            : null,
      );
    }
    if (field.type == 'reference') {
      final records = _references[field.name] ?? const <LocalExtensionRecord>[];
      return DropdownButtonFormField<String?>(
        initialValue: _selections[field.name],
        isExpanded: true,
        decoration: InputDecoration(
          labelText: context.extensionMetadataText(field.labelKey, field.label),
          helperText: context.ventioText(
            'native.ui.related_reference_scope',
            params: {'doctype': field.referenceTo!},
          ),
          border: const OutlineInputBorder(),
        ),
        items: [
          if (!field.required)
            const DropdownMenuItem<String?>(
              value: null,
              child: VentioText('native.ui.not_set'),
            ),
          for (final record in records)
            DropdownMenuItem<String?>(
              value: record.recordId,
              child: Text(_recordTitle(record)),
            ),
        ],
        onChanged: widget.previewOnly || !editable
            ? null
            : (value) => setState(() => _selections[field.name] = value),
        validator: (value) => field.required && value == null
            ? context.ventioText(
                'native.ui.select_related_record',
                params: {'doctype': field.referenceTo!},
              )
            : null,
      );
    }
    final numericBounds = <String>[
      if (field.minValue != null)
        context.ventioText(
          'native.ui.minimum_value_summary',
          params: {'minimum': field.minValue!},
        ),
      if (field.maxValue != null)
        context.ventioText(
          'native.ui.maximum_value_summary',
          params: {'maximum': field.maxValue!},
        ),
    ];
    final lengthConstraints = <String>[
      if (field.minLength != null)
        context.ventioText(
          'native.ui.minimum_length_summary',
          params: {'minimum': field.minLength!},
        ),
      if (field.maxLength != null)
        context.ventioText(
          'native.ui.maximum_length_summary',
          params: {'maximum': field.maxLength!},
        ),
    ];
    if (field.precision != null) {
      numericBounds.add(
        context.ventioText(
          'native.ui.decimal_precision_summary',
          params: {'precision': field.precision!},
        ),
      );
    }
    return TextFormField(
      controller: _controllers[field.name],
      readOnly: widget.previewOnly || !editable,
      keyboardType: field.type == 'long_text' || field.type == 'table'
          ? TextInputType.multiline
          : switch (field.type) {
              'integer' => TextInputType.number,
              'decimal' => const TextInputType.numberWithOptions(decimal: true),
              _ => TextInputType.text,
            },
      maxLength: field.type == 'text' || field.type == 'long_text'
          ? field.maxLength
          : null,
      maxLines: switch (field.type) {
        'long_text' => 4,
        'table' => 8,
        'text' when (field.maxLength ?? 0) > 500 => 4,
        _ => 1,
      },
      decoration: InputDecoration(
        labelText: context.extensionMetadataText(field.labelKey, field.label),
        helperText: [
          context.ventioText(switch (field.type) {
            'text' => 'native.ui.field_type_text',
            'long_text' => 'native.ui.field_type_long_text',
            'integer' => 'native.ui.field_type_integer',
            'decimal' => 'native.ui.field_type_decimal',
            'date' => 'native.ui.field_type_date',
            'datetime' => 'native.ui.field_type_datetime',
            'boolean' => 'native.ui.field_type_boolean',
            'enum' => 'native.ui.field_type_enum',
            'reference' => 'native.ui.field_type_reference',
            'table' => 'native.ui.field_type_table',
            _ => 'native.ui.field_type_text',
          }),
          context
              .ventioText(
                field.required ? 'native.ui.required' : 'native.ui.optional',
              )
              .toLowerCase(),
          ...lengthConstraints,
          ...numericBounds,
          if (field.description != null)
            context.extensionMetadataText(
              field.descriptionKey!,
              field.description!,
            ),
          if (field.type == 'table')
            context.ventioText('native.ui.table_json_help'),
        ].join(' · '),
        border: const OutlineInputBorder(),
      ),
      validator: (value) {
        final raw = value?.trim() ?? '';
        if (editable && field.required && raw.isEmpty) {
          return context.ventioText(
            'native.ui.enter_field',
            params: {
              'label': context
                  .extensionMetadataText(field.labelKey, field.label)
                  .toLowerCase(),
            },
          );
        }
        if (raw.isEmpty) return null;
        if (field.type == 'text') {
          final issue = field.validate(raw);
          if (issue == 'TOO_SHORT') {
            return context.ventioText(
              'native.ui.too_short',
              params: {'minLength': field.minLength!},
            );
          }
          if (issue == 'TOO_LONG') {
            return context.ventioText(
              'native.ui.too_long',
              params: {'maxLength': field.maxLength!},
            );
          }
        }
        if (field.type == 'long_text') {
          final issue = field.validate(raw);
          if (issue == 'TOO_SHORT') {
            return context.ventioText(
              'native.ui.too_short',
              params: {'minLength': field.minLength!},
            );
          }
          if (issue == 'TOO_LONG') {
            return context.ventioText(
              'native.ui.too_long',
              params: {'maxLength': field.maxLength!},
            );
          }
        }
        if (field.type == 'table') {
          try {
            final decoded = jsonDecode(raw);
            if (field.validate(decoded) != null) {
              return context.ventioText('native.ui.table_json_error');
            }
          } on FormatException {
            return context.ventioText('native.ui.table_json_error');
          }
        }
        if (field.type == 'integer') {
          final parsed = int.tryParse(raw);
          if (parsed == null) {
            return context.ventioText('native.ui.enter_whole_number');
          }
          return _numericValidationMessage(field, parsed);
        }
        if (field.type == 'decimal') {
          final parsed = num.tryParse(raw);
          if (parsed == null) {
            return context.ventioText('native.ui.enter_number');
          }
          final issue = field.validate(parsed);
          if (issue == 'INVALID_DECIMAL') {
            return context.ventioText('native.ui.enter_finite_number');
          }
          if (issue == 'INVALID_PRECISION') {
            return context.ventioText(
              'native.ui.decimal_precision',
              params: {'precision': field.precision!},
            );
          }
          return _numericValidationMessage(field, parsed);
        }
        if (field.type == 'date' && field.validate(raw) != null) {
          return context.ventioText('native.ui.enter_valid_date');
        }
        if (field.type == 'datetime' && field.validate(raw) != null) {
          return context.ventioText('native.ui.enter_valid_datetime');
        }
        return null;
      },
    );
  }

  String? _numericValidationMessage(FieldDefinition field, num value) {
    final issue = field.validate(value);
    if (issue == 'BELOW_MINIMUM') {
      return context.ventioText(
        'native.ui.value_at_least',
        params: {'minimum': field.minValue!},
      );
    }
    if (issue == 'ABOVE_MAXIMUM') {
      return context.ventioText(
        'native.ui.value_at_most',
        params: {'maximum': field.maxValue!},
      );
    }
    return null;
  }
}

Future<void> _queueDynamicRecordCommand({
  required LocalCommandQueue? queue,
  required LocalExtensionStore store,
  required HostConnectionProfile? profile,
  required LocalExtensionRecord record,
  required String? moduleVersion,
  required DocTypeDefinition definition,
  required Map<String, dynamic> values,
}) async {
  if (queue == null || profile == null) return;
  final actorId = profile.actorId;
  final deviceId = profile.deviceId;
  if (actorId == null || deviceId == null || moduleVersion == null) {
    throw StateError('Reconnect to Host to refresh the persistent identity.');
  }
  final hostValues = Map<String, dynamic>.of(values);
  final provisionalNameField = definition.namingSeries?.field;
  if (provisionalNameField != null) {
    hostValues.remove(provisionalNameField);
  }
  final commandId = createCommandId();
  final command = record.hostRevision == null
      ? ExtensionRecordCommand.create(
          commandId: commandId,
          tenantId: profile.tenantId,
          companyId: profile.companyId,
          branchId: profile.branchId,
          recordId: record.recordId,
          actorId: actorId,
          deviceId: deviceId,
          moduleId: record.moduleId,
          moduleVersion: moduleVersion,
          docType: definition.name,
          schemaVersion: definition.schemaVersion,
          values: hostValues,
        )
      : ExtensionRecordCommand.update(
          commandId: commandId,
          tenantId: profile.tenantId,
          companyId: profile.companyId,
          branchId: profile.branchId,
          recordId: record.recordId,
          expectedRevision: record.hostRevision!,
          actorId: actorId,
          deviceId: deviceId,
          moduleId: record.moduleId,
          moduleVersion: moduleVersion,
          docType: definition.name,
          schemaVersion: definition.schemaVersion,
          values: hostValues,
        );
  await queue.enqueue(command.envelope);
  await store.markRecordPending(
    recordId: record.recordId,
    scope: record.scope,
    commandId: commandId,
  );
}

class DynamicRecordDetailsPage extends StatefulWidget {
  const DynamicRecordDetailsPage({
    required this.store,
    this.queue,
    required this.moduleId,
    required this.definition,
    required this.scope,
    this.moduleVersion,
    this.hostProfile,
    this.credentialVault,
    this.hostPackageClientFactory,
    this.readableFields,
    this.writableFields,
    this.creatableFields,
    this.printPdf,
    required this.record,
    super.key,
  });

  final LocalExtensionStore store;
  final LocalCommandQueue? queue;
  final String moduleId;
  final DocTypeDefinition definition;
  final RecordScope scope;
  final String? moduleVersion;
  final HostConnectionProfile? hostProfile;
  final HostCredentialVault? credentialVault;
  final HostExtensionPackageClientFactory? hostPackageClientFactory;
  final Set<String>? readableFields;
  final Set<String>? writableFields;
  final Set<String>? creatableFields;
  final Future<void> Function(String name, List<int> bytes)? printPdf;
  final LocalExtensionRecord record;

  @override
  State<DynamicRecordDetailsPage> createState() =>
      _DynamicRecordDetailsPageState();
}

class _DynamicRecordDetailsPageState extends State<DynamicRecordDetailsPage> {
  late LocalExtensionRecord _record;
  List<PrintFormatDefinition> _printFormats = const [];
  bool _refreshingConflict = false;
  String? _conflictRefreshError;
  bool _printingRecord = false;

  @override
  void initState() {
    super.initState();
    _record = widget.record;
    _loadRecord();
  }

  Future<void> _loadRecord() async {
    final latest = await widget.store.getRecord(
      moduleId: widget.moduleId,
      docTypeName: widget.definition.name,
      recordId: _record.recordId,
      scope: widget.scope,
    );
    if (!mounted || latest == null) return;
    final extension = await widget.store.getExtension(widget.moduleId);
    final typeDefinitions = (await widget.store.listDocTypes(
      widget.moduleId,
    )).map(DocTypeDefinition.fromJson).toList(growable: false);
    final formats =
        extension?.printFormatDefinitions
            .map(
              (raw) => PrintFormatDefinition.fromJson(
                raw,
                moduleId: widget.moduleId,
                docTypes: typeDefinitions,
              ),
            )
            .where((format) => format.docType == widget.definition.name)
            .toList(growable: false) ??
        const <PrintFormatDefinition>[];
    setState(() {
      _record = latest;
      _printFormats = formats;
    });
    if (latest.authorityState == 'CONFLICT' && latest.conflictValues == null) {
      await _refreshConflictSnapshot();
    }
  }

  Future<void> _printRecord() async {
    final profile = widget.hostProfile;
    final vault = widget.credentialVault;
    final moduleVersion = widget.moduleVersion;
    if (_printingRecord ||
        _printFormats.isEmpty ||
        _record.authorityState != 'HOST_ACCEPTED' ||
        _record.pendingCommandId != null ||
        _record.hostRevision == null ||
        _record.isDeleted ||
        profile == null ||
        vault == null ||
        moduleVersion == null) {
      return;
    }
    final selected = _printFormats.length == 1
        ? _printFormats.single
        : await showDialog<PrintFormatDefinition>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const VentioText('native.ui.choose_print_format'),
              children: [
                for (final format in _printFormats)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, format),
                    child: Text(
                      context.extensionMetadataText(
                        format.labelKey,
                        format.label,
                      ),
                    ),
                  ),
              ],
            ),
          );
    if (selected == null || !mounted) return;
    setState(() => _printingRecord = true);
    try {
      final bundle = await widget.store.exportBundle(widget.moduleId);
      if (bundle.version != moduleVersion) {
        throw const HostPackageTransportException(
          'LOCAL_PACKAGE_VERSION_DIFFERS_FROM_HOST_APPROVED_RELEASE',
        );
      }
      final digest = sha256
          .convert(utf8.encode(canonicalJson(bundle.toJson())))
          .toString();
      final client =
          widget.hostPackageClientFactory?.call(
            endpoint: Uri.parse(profile.endpoint),
            credentials: vault,
          ) ??
          HostExtensionPackageClient(
            endpoint: Uri.parse(profile.endpoint),
            credentials: vault,
          );
      final page = await client.queryRecords(
        companyId: profile.companyId,
        branchId: profile.branchId,
        moduleId: widget.moduleId,
        version: moduleVersion,
        docType: widget.definition.name,
        recordId: _record.recordId,
        sortField: null,
        limit: 1,
      );
      final requiredFields = selected.blocks
          .where((block) => block.field != null)
          .map((block) => block.field!)
          .toSet();
      final values = verifiedHostPrintValues(
        page: page,
        recordId: _record.recordId,
        minimumRevision: _record.hostRevision!,
        approvedPackageDigest: digest,
        requiredFields: requiredFields,
        fieldPermissionsDeclared: widget.definition.fields.any(
          (field) =>
              requiredFields.contains(field.name) &&
              field.readPermission != null,
        ),
      );
      final bytes = await buildPrintFormatPdf(
        format: selected,
        docType: widget.definition,
        englishCatalog: bundle.englishCatalog,
        record: values,
        useSystemFonts: widget.printPdf == null,
      );
      final safeRecordId = _record.recordId.replaceAll(
        RegExp(r'[^A-Za-z0-9_-]'),
        '_',
      );
      final name = '${selected.id}-$safeRecordId.pdf';
      if (widget.printPdf case final printPdf?) {
        await printPdf(name, bytes);
      } else {
        await Printing.layoutPdf(
          name: name,
          onLayout: (_) async => Uint8List.fromList(bytes),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: VentioText('native.ui.print_failed')),
        );
      }
    } finally {
      if (mounted) setState(() => _printingRecord = false);
    }
  }

  Future<void> _refreshConflictSnapshot() async {
    final profile = widget.hostProfile;
    final vault = widget.credentialVault;
    final version = widget.moduleVersion;
    if (profile == null || vault == null || version == null) {
      setState(() {
        _conflictRefreshError =
            'Connect to the authenticated Host to fetch its latest record.';
      });
      return;
    }
    setState(() {
      _refreshingConflict = true;
      _conflictRefreshError = null;
    });
    try {
      final client =
          widget.hostPackageClientFactory?.call(
            endpoint: Uri.parse(profile.endpoint),
            credentials: vault,
          ) ??
          HostExtensionPackageClient(
            endpoint: Uri.parse(profile.endpoint),
            credentials: vault,
          );
      final bundle = await widget.store.exportBundle(widget.moduleId);
      final digest = sha256
          .convert(utf8.encode(canonicalJson(bundle.toJson())))
          .toString();
      final page = await client.queryRecords(
        companyId: profile.companyId,
        branchId: profile.branchId,
        moduleId: widget.moduleId,
        version: version,
        docType: widget.definition.name,
        recordId: _record.recordId,
        sortField: null,
        limit: 1,
      );
      if (page.packageSha256 != digest) {
        throw const HostPackageTransportException(
          'LOCAL_PACKAGE_DIFFERS_FROM_HOST_APPROVED_RELEASE',
        );
      }
      if (widget.definition.fields.any(
            (field) =>
                field.readPermission != null || field.writePermission != null,
          ) &&
          (page.readableFields == null ||
              page.writableFields == null ||
              page.creatableFields == null)) {
        throw const HostPackageTransportException(
          'HOST_FIELD_PERMISSIONS_MISSING',
        );
      }
      if (page.records.length != 1 ||
          page.records.single.recordId != _record.recordId) {
        throw const HostPackageTransportException(
          'CONFLICT_RECORD_NOT_AVAILABLE',
        );
      }
      if (page.readableFields != null && page.writableFields != null) {
        await widget.store.applyHostFieldPermissions(
          moduleId: widget.moduleId,
          docTypeName: widget.definition.name,
          scope: widget.scope,
          readableFields: page.readableFields!,
          writableFields: page.writableFields!,
          creatableFields: page.creatableFields!,
          profile: profile,
        );
      }
      final hostRecord = page.records.single;
      final minimumRevision = _record.hostRevision ?? 0;
      if (hostRecord.revision < minimumRevision) {
        throw const HostPackageTransportException(
          'HOST_RETURNED_STALE_CONFLICT_SNAPSHOT',
        );
      }
      await widget.store.applyHostRecord(
        moduleId: widget.moduleId,
        docTypeName: widget.definition.name,
        scope: widget.scope,
        recordId: hostRecord.recordId,
        revision: hostRecord.revision,
        values: hostRecord.values,
        updatedAtUtc: DateTime.parse(hostRecord.updatedAtUtc),
        readableFields: page.readableFields,
        writableFields: page.writableFields,
        creatableFields: page.creatableFields,
      );
      final latest = await widget.store.getRecord(
        moduleId: widget.moduleId,
        docTypeName: widget.definition.name,
        recordId: _record.recordId,
        scope: widget.scope,
      );
      if (mounted && latest != null) setState(() => _record = latest);
    } catch (error) {
      if (mounted) setState(() => _conflictRefreshError = error.toString());
    } finally {
      if (mounted) setState(() => _refreshingConflict = false);
    }
  }

  Future<void> _editRecord({Map<String, dynamic>? initialValues}) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => DynamicRecordFormPage(
          store: widget.store,
          queue: widget.queue,
          moduleId: widget.moduleId,
          definition: widget.definition,
          scope: widget.scope,
          moduleVersion: widget.moduleVersion,
          hostProfile: widget.hostProfile,
          credentialVault: widget.credentialVault,
          hostPackageClientFactory: widget.hostPackageClientFactory,
          readableFields: widget.readableFields,
          writableFields: widget.writableFields,
          creatableFields: widget.creatableFields,
          record: _record,
          initialValues: initialValues,
        ),
      ),
    );
    if (!mounted || changed != true) return;
    await _loadRecord();
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _deleteRecord() async {
    if (_record.pendingCommandId != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const VentioText('native.ui.delete_record'),
        content: const VentioText('native.ui.confirm_delete_record'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const VentioText('native.ui.cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const VentioText('native.ui.delete_record'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      if (_record.hostRevision == null) {
        await widget.store.deleteLocalRecord(
          moduleId: widget.moduleId,
          docTypeName: widget.definition.name,
          recordId: _record.recordId,
          scope: widget.scope,
        );
      } else {
        final profile = widget.hostProfile;
        final queue = widget.queue;
        final version = widget.moduleVersion;
        final actor = profile?.actorId;
        final device = profile?.deviceId;
        if (profile == null ||
            queue == null ||
            version == null ||
            actor == null ||
            device == null) {
          throw const ExtensionStoreException(
            'HOST_COMMAND_QUEUE_UNAVAILABLE',
            'The Host identity and durable command queue are required to delete a shared record.',
          );
        }
        final commandId = createCommandId();
        final command = ExtensionRecordCommand.delete(
          commandId: commandId,
          tenantId: profile.tenantId,
          companyId: profile.companyId,
          branchId: profile.branchId,
          recordId: _record.recordId,
          expectedRevision: _record.hostRevision!,
          actorId: actor,
          deviceId: device,
          moduleId: widget.moduleId,
          moduleVersion: version,
          docType: widget.definition.name,
          schemaVersion: widget.definition.schemaVersion,
        );
        await queue.enqueue(command.envelope);
        await widget.store.markRecordPending(
          recordId: _record.recordId,
          scope: widget.scope,
          commandId: commandId,
          operation: 'delete',
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: VentioText('native.ui.delete_record_failed')),
        );
      }
    }
  }

  Future<void> _executeBusinessOperation(
    BusinessOperationDefinition operation,
  ) async {
    final queue = widget.queue;
    final profile = widget.hostProfile;
    final moduleVersion = widget.moduleVersion;
    final actor = profile?.actorId;
    final device = profile?.deviceId;
    final transitions = operation.effects
        .where((effect) => effect.type == 'document.transition')
        .toList(growable: false);
    final amendments = operation.effects
        .where((effect) => effect.type == 'document.amend')
        .toList(growable: false);
    final isAmendment = amendments.length == 1 && transitions.isEmpty;
    if (queue == null ||
        profile == null ||
        moduleVersion == null ||
        actor == null ||
        device == null ||
        _record.hostRevision == null ||
        _record.pendingCommandId != null ||
        _record.authorityState != 'HOST_ACCEPTED' ||
        (isAmendment
            ? _record.documentStatus != 2
            : transitions.length != 1 ||
                  transitions.single.targetStatus == null)) {
      return;
    }
    if (!isAmendment) {
      final transition = transitions.single;
      if ((transition.targetStatus == 1 && _record.documentStatus != 0) ||
          (transition.targetStatus == 2 && _record.documentStatus != 1)) {
        return;
      }
    }
    if (operation.inputs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: VentioText(
            'native.ui.business_operation_inputs_unavailable',
          ),
        ),
      );
      return;
    }
    final commandId = createCommandId();
    final command = ExtensionBusinessOperationCommand.execute(
      commandId: commandId,
      tenantId: profile.tenantId,
      companyId: profile.companyId,
      branchId: profile.branchId,
      recordId: _record.recordId,
      expectedRevision: _record.hostRevision!,
      actorId: actor,
      deviceId: device,
      moduleId: widget.moduleId,
      moduleVersion: moduleVersion,
      docType: widget.definition.name,
      schemaVersion: widget.definition.schemaVersion,
      operationId: operation.id,
      operationVersion: operation.version,
      inputs: const {},
    );
    try {
      await queue.enqueue(command.envelope);
      if (isAmendment) {
        await widget.store.createAmendmentDraft(
          moduleId: widget.moduleId,
          docTypeName: widget.definition.name,
          sourceRecordId: _record.recordId,
          scope: widget.scope,
          expectedSourceRevision: _record.hostRevision!,
          commandId: commandId,
          linkField: amendments.single.linkField!,
        );
      } else {
        await widget.store.markRecordPending(
          recordId: _record.recordId,
          scope: widget.scope,
          commandId: commandId,
        );
      }
      await _loadRecord();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: VentioText('native.ui.business_operation_queue_failed'),
          ),
        );
      }
    }
  }

  Future<void> _reviewConflict() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => DynamicRecordConflictPage(
          store: widget.store,
          queue: widget.queue,
          moduleId: widget.moduleId,
          definition: widget.definition,
          scope: widget.scope,
          moduleVersion: widget.moduleVersion,
          hostProfile: widget.hostProfile,
          credentialVault: widget.credentialVault,
          hostPackageClientFactory: widget.hostPackageClientFactory,
          readableFields: widget.readableFields,
          writableFields: widget.writableFields,
          creatableFields: widget.creatableFields,
          record: _record,
        ),
      ),
    );
    if (!mounted || changed != true) return;
    await _loadRecord();
    if (_record.authorityState != 'CONFLICT' && mounted) {
      Navigator.pop(context, true);
    }
  }

  List<FieldDefinition> get _detailFields => widget.definition.detailFields
      .map(
        (name) =>
            widget.definition.fields.firstWhere((field) => field.name == name),
      )
      .where(
        (field) =>
            widget.readableFields?.contains(field.name) ??
            field.readPermission == null,
      )
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final record = _record;
    final conflicted = record.authorityState == 'CONFLICT';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          context.ventioText(
            'native.ui.details_for_doctype',
            params: {
              'label': context.extensionMetadataText(
                widget.definition.labelKey,
                widget.definition.label,
              ),
            },
          ),
        ),
        actions: [
          if (_printFormats.isNotEmpty)
            IconButton(
              tooltip: context.ventioText('native.ui.print_record'),
              onPressed:
                  !_printingRecord &&
                      record.authorityState == 'HOST_ACCEPTED' &&
                      record.pendingCommandId == null &&
                      record.hostRevision != null &&
                      !record.isDeleted
                  ? _printRecord
                  : null,
              icon: _printingRecord
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.print_outlined),
            ),
          if (widget.definition.operations.contains('delete'))
            IconButton(
              tooltip: context.ventioText('native.ui.delete_record'),
              onPressed: record.pendingCommandId == null ? _deleteRecord : null,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      floatingActionButton:
          !conflicted &&
              record.documentStatus == 0 &&
              widget.definition.operations.contains('update') &&
              widget.definition.formFields.any((name) {
                final field = widget.definition.fields.firstWhere(
                  (field) => field.name == name,
                );
                return widget.writableFields?.contains(field.name) ??
                    field.writePermission == null;
              })
          ? FloatingActionButton.extended(
              onPressed: _editRecord,
              icon: const Icon(Icons.edit_outlined),
              label: const VentioText('native.ui.edit_record'),
            )
          : null,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              _LocalOnlyNotice(
                title: switch (record.authorityState) {
                  'HOST_ACCEPTED' => 'Host accepted record',
                  'PENDING' => 'Waiting for Host receipt',
                  'CONFLICT' => 'Host revision conflict',
                  'REJECTED' => 'Host rejected this operation',
                  _ => 'Provisional device record',
                },
                body: switch (record.authorityState) {
                  'HOST_ACCEPTED' =>
                    'Host revision ${record.hostRevision ?? record.revision} is authoritative. Local edits remain provisional until accepted.',
                  'PENDING' =>
                    'This record has a durable command in the local queue and is not shared until the Host returns a real receipt.',
                  'CONFLICT' =>
                    'The Host has revision ${record.hostRevision ?? 'unknown'}. Local values are preserved separately until you review the latest Host version.',
                  'REJECTED' =>
                    'The Host denied the queued operation. Local values are preserved on this device.',
                  _ =>
                    'The record is stored locally. A Host receipt is required before it becomes shared data.',
                },
                icon: record.authorityState == 'HOST_ACCEPTED'
                    ? Icons.verified_user_outlined
                    : Icons.info_outline,
              ),
              for (final operation in widget.definition.businessOperations)
                if (operation.effects.any((effect) {
                  if (effect.type == 'document.amend') {
                    return record.documentStatus == 2;
                  }
                  return effect.type == 'document.transition' &&
                      ((effect.targetStatus == 1 &&
                              record.documentStatus == 0) ||
                          (effect.targetStatus == 2 &&
                              record.documentStatus == 1));
                })) ...[
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed:
                        record.authorityState == 'HOST_ACCEPTED' &&
                            record.pendingCommandId == null
                        ? () => _executeBusinessOperation(operation)
                        : null,
                    icon: Icon(
                      operation.effects.any(
                            (effect) =>
                                effect.type == 'document.transition' &&
                                effect.targetStatus == 1,
                          )
                          ? Icons.task_alt
                          : operation.effects.any(
                              (effect) => effect.type == 'document.amend',
                            )
                          ? Icons.copy_outlined
                          : Icons.cancel_outlined,
                    ),
                    label: VentioText(
                      operation.effects.any(
                            (effect) =>
                                effect.type == 'document.transition' &&
                                effect.targetStatus == 1,
                          )
                          ? 'native.ui.submit_document'
                          : operation.effects.any(
                              (effect) => effect.type == 'document.amend',
                            )
                          ? 'native.ui.amend_document'
                          : 'native.ui.cancel_document',
                    ),
                  ),
                ],
              if (conflicted) ...[
                const SizedBox(height: 12),
                if (_conflictRefreshError != null)
                  Text(
                    _conflictRefreshError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (record.conflictValues == null)
                  FilledButton.icon(
                    onPressed: _refreshingConflict
                        ? null
                        : _refreshConflictSnapshot,
                    icon: _refreshingConflict
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync),
                    label: Text(
                      _refreshingConflict
                          ? 'Fetching Host version…'
                          : 'Fetch latest Host version',
                    ),
                  )
                else ...[
                  Text(
                    context.ventioText(
                      'native.ui.host_snapshot_revision',
                      params: {'revision': record.conflictRevision},
                    ),
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  OutlinedButton.icon(
                    onPressed: _refreshingConflict
                        ? null
                        : _refreshConflictSnapshot,
                    icon: const Icon(Icons.refresh),
                    label: const VentioText('native.ui.refresh_host_version'),
                  ),
                  FilledButton.icon(
                    onPressed: _reviewConflict,
                    icon: const Icon(Icons.compare_arrows),
                    label: const VentioText(
                      'native.ui.review_and_resolve_conflict',
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final field in _detailFields) ...[
                        Text(
                          context.extensionMetadataText(
                            field.labelKey,
                            field.label,
                          ),
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 4),
                        SelectableText(
                          _displayValue(
                            context,
                            field,
                            record.values[field.name],
                          ),
                        ),
                        const Divider(height: 24),
                      ],
                      Text(
                        context.ventioText(
                          'native.ui.local_host_revision',
                          params: {
                            'localRevision': record.revision,
                            'hostRevision': record.hostRevision ?? 'none',
                            'syncState': record.syncState,
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DynamicRecordConflictPage extends StatefulWidget {
  const DynamicRecordConflictPage({
    required this.store,
    required this.queue,
    required this.moduleId,
    required this.definition,
    required this.scope,
    required this.record,
    this.moduleVersion,
    this.hostProfile,
    this.credentialVault,
    this.hostPackageClientFactory,
    this.readableFields,
    this.writableFields,
    this.creatableFields,
    super.key,
  });

  final LocalExtensionStore store;
  final LocalCommandQueue? queue;
  final String moduleId;
  final DocTypeDefinition definition;
  final RecordScope scope;
  final LocalExtensionRecord record;
  final String? moduleVersion;
  final HostConnectionProfile? hostProfile;
  final HostCredentialVault? credentialVault;
  final HostExtensionPackageClientFactory? hostPackageClientFactory;
  final Set<String>? readableFields;
  final Set<String>? writableFields;
  final Set<String>? creatableFields;

  @override
  State<DynamicRecordConflictPage> createState() =>
      _DynamicRecordConflictPageState();
}

class _DynamicRecordConflictPageState extends State<DynamicRecordConflictPage> {
  late final Map<String, String> _sources = {
    for (final field in widget.definition.fields) field.name: 'local',
  };
  bool _saving = false;

  Future<void> _useHostVersion() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const VentioText('native.ui.use_host_version'),
        content: const VentioText(
          'native.ui.this_replaces_the_local_provisional_values_with_the_latest_host_values_o',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const VentioText('native.ui.cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const VentioText('native.ui.replace_local_values'),
          ),
        ],
      ),
    );
    if (discard != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await widget.store.resolveConflictWithHostSnapshot(
        recordId: widget.record.recordId,
        scope: widget.scope,
        readableFields: widget.readableFields,
        writableFields: widget.writableFields,
        creatableFields: widget.creatableFields,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _mergeAndEdit() async {
    final hostValues = widget.record.conflictValues;
    if (hostValues == null) return;
    final merged = <String, dynamic>{};
    for (final field in widget.definition.fields.where(
      (field) =>
          widget.readableFields?.contains(field.name) ??
          field.readPermission == null,
    )) {
      final chooseHost = _sources[field.name] == 'host';
      if (chooseHost && hostValues.containsKey(field.name)) {
        merged[field.name] = hostValues[field.name];
      } else if (widget.record.values.containsKey(field.name)) {
        merged[field.name] = widget.record.values[field.name];
      } else if (hostValues.containsKey(field.name)) {
        merged[field.name] = hostValues[field.name];
      }
    }
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => DynamicRecordFormPage(
          store: widget.store,
          queue: widget.queue,
          moduleId: widget.moduleId,
          definition: widget.definition,
          scope: widget.scope,
          moduleVersion: widget.moduleVersion,
          hostProfile: widget.hostProfile,
          credentialVault: widget.credentialVault,
          hostPackageClientFactory: widget.hostPackageClientFactory,
          readableFields: widget.readableFields,
          writableFields: widget.writableFields,
          creatableFields: widget.creatableFields,
          record: widget.record,
          initialValues: merged,
        ),
      ),
    );
    if (mounted && changed == true) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final hostValues = widget.record.conflictValues;
    if (hostValues == null || widget.record.conflictRevision == null) {
      return Scaffold(
        appBar: AppBar(
          title: const VentioText('native.ui.resolve_record_conflict'),
        ),
        body: const Center(
          child: VentioText(
            'native.ui.fetch_the_latest_host_version_before_reviewing_this_conflict',
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const VentioText('native.ui.review_record_conflict'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                context.ventioText(
                  'native.ui.choose_conflict_values',
                  params: {'revision': widget.record.conflictRevision},
                ),
              ),
              const SizedBox(height: 16),
              for (final field in widget.definition.fields.where(
                (field) =>
                    widget.readableFields?.contains(field.name) ??
                    field.readPermission == null,
              ))
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.extensionMetadataText(
                            field.labelKey,
                            field.label,
                          ),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          context.ventioText(
                            'native.ui.local_value',
                            params: {
                              'value': _displayValue(
                                context,
                                field,
                                widget.record.values[field.name],
                              ),
                            },
                          ),
                        ),
                        Text(
                          context.ventioText(
                            'native.ui.host_value',
                            params: {
                              'value': _displayValue(
                                context,
                                field,
                                hostValues[field.name],
                              ),
                            },
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            ChoiceChip(
                              label: const VentioText('native.ui.keep_local'),
                              selected: _sources[field.name] == 'local',
                              onSelected: _saving
                                  ? null
                                  : (_) => setState(
                                      () => _sources[field.name] = 'local',
                                    ),
                            ),
                            ChoiceChip(
                              label: const VentioText('native.ui.use_host'),
                              selected: _sources[field.name] == 'host',
                              onSelected: _saving
                                  ? null
                                  : (_) => setState(
                                      () => _sources[field.name] = 'host',
                                    ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _saving ? null : _useHostVersion,
                icon: const Icon(Icons.download_done),
                label: const VentioText(
                  'native.ui.discard_local_edits_and_use_host_version',
                ),
              ),
              if (widget.definition.operations.contains('update'))
                FilledButton.icon(
                  onPressed: _saving ? null : _mergeAndEdit,
                  icon: const Icon(Icons.merge_type),
                  label: const VentioText(
                    'native.ui.continue_with_selected_values',
                  ),
                )
              else
                const VentioText(
                  'native.ui.this_doctype_does_not_grant_the_update_operation_so_merged_values_cannot',
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExtensionFormValues {
  const _ExtensionFormValues({
    required this.moduleId,
    required this.displayName,
    required this.description,
    required this.version,
    required this.dependencies,
  });

  final String moduleId;
  final String displayName;
  final String description;
  final String version;
  final Map<String, String> dependencies;
}

class _ReportBuilderDialog extends StatefulWidget {
  const _ReportBuilderDialog({required this.moduleId, required this.docTypes});

  final String moduleId;
  final List<Map<String, dynamic>> docTypes;

  @override
  State<_ReportBuilderDialog> createState() => _ReportBuilderDialogState();
}

class _ReportBuilderDialogState extends State<_ReportBuilderDialog> {
  final _formKey = GlobalKey<FormState>();
  final _id = TextEditingController();
  final _label = TextEditingController();
  String? _docType;
  String? _filter;
  String? _group;
  String? _sum;

  @override
  void initState() {
    super.initState();
    _docType = widget.docTypes.first['name'] as String;
  }

  @override
  void dispose() {
    _id.dispose();
    _label.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _fields =>
      ((widget.docTypes.firstWhere((type) => type['name'] == _docType)['fields']
                  as List)
              .cast<Map<String, dynamic>>())
          .where((field) => field['type'] != 'table')
          .toList();

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final id = _id.text.trim();
    final slug = widget.moduleId.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '_',
    );
    final key = 'extension.$slug.report.$id';
    final aggregates = <Map<String, dynamic>>[
      {
        'id': 'row_count',
        'operation': 'count',
        'label': 'Count',
        'labelKey': '$key.row_count',
      },
      if (_sum != null)
        {
          'id': 'sum_total',
          'operation': 'sum',
          'field': _sum,
          'label': 'Total',
          'labelKey': '$key.sum_total',
        },
    ];
    Navigator.pop(context, <String, dynamic>{
      'id': id,
      'docType': _docType,
      'label': _label.text.trim(),
      'labelKey': key,
      if (_filter != null) 'filters': [_filter!],
      if (_group != null) 'groupBy': _group,
      if (_sum != null) 'sortBy': 'sum_total',
      'descending': true,
      'aggregates': aggregates,
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const VentioText('native.ui.create_report'),
    content: SizedBox(
      width: 520,
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _id,
                decoration: InputDecoration(
                  labelText: context.ventioText('native.ui.report_id'),
                ),
                validator: (value) =>
                    RegExp(
                      r'^[a-z][a-z0-9_]{0,63}$',
                    ).hasMatch(value?.trim() ?? '')
                    ? null
                    : context.ventioText('native.ui.enter_valid_report_id'),
              ),
              TextFormField(
                controller: _label,
                decoration: InputDecoration(
                  labelText: context.ventioText('native.ui.report_label'),
                ),
                validator: (value) => (value?.trim().isNotEmpty ?? false)
                    ? null
                    : context.ventioText('native.ui.enter_report_label'),
              ),
              DropdownButtonFormField<String>(
                initialValue: _docType,
                decoration: InputDecoration(
                  labelText: context.ventioText('native.ui.source_doctype'),
                ),
                items: widget.docTypes
                    .map(
                      (type) => DropdownMenuItem(
                        value: type['name'] as String,
                        child: Text(type['label'] as String),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() {
                  _docType = value;
                  _filter = null;
                  _group = null;
                  _sum = null;
                }),
              ),
              _fieldDropdown(
                'native.ui.report_filter_field',
                _filter,
                (value) => _filter = value,
                nullable: true,
              ),
              _fieldDropdown(
                'native.ui.group_by_field',
                _group,
                (value) => _group = value,
                nullable: true,
              ),
              _fieldDropdown(
                'native.ui.sum_numeric_field',
                _sum,
                (value) => _sum = value,
                numericOnly: true,
                nullable: true,
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const VentioText('native.ui.cancel'),
      ),
      FilledButton(
        onPressed: _save,
        child: const VentioText('native.ui.save_report'),
      ),
    ],
  );

  Widget _fieldDropdown(
    String key,
    String? value,
    ValueChanged<String?> update, {
    bool numericOnly = false,
    bool nullable = false,
  }) {
    final fields = _fields
        .where(
          (field) =>
              !numericOnly ||
              const {'integer', 'decimal'}.contains(field['type']),
        )
        .toList();
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(labelText: context.ventioText(key)),
      items: [
        if (nullable)
          DropdownMenuItem<String>(
            value: null,
            child: Text(context.ventioText('native.ui.none')),
          ),
        ...fields.map(
          (field) => DropdownMenuItem(
            value: field['name'] as String,
            child: Text(field['label'] as String),
          ),
        ),
      ],
      onChanged: update,
    );
  }
}

class _PrintFormatBuilderDialog extends StatefulWidget {
  const _PrintFormatBuilderDialog({
    required this.moduleId,
    required this.docTypes,
  });

  final String moduleId;
  final List<Map<String, dynamic>> docTypes;

  @override
  State<_PrintFormatBuilderDialog> createState() =>
      _PrintFormatBuilderDialogState();
}

class _PrintFormatBuilderDialogState extends State<_PrintFormatBuilderDialog> {
  final _formKey = GlobalKey<FormState>();
  final _id = TextEditingController();
  final _label = TextEditingController();
  late String _docType;
  String _pageSize = 'a4';
  String _orientation = 'portrait';
  String? _field;
  String? _table;
  final List<Map<String, dynamic>> _blocks = [];

  Map<String, dynamic> get _selectedType =>
      widget.docTypes.firstWhere((type) => type['name'] == _docType);
  List<Map<String, dynamic>> get _fields =>
      (_selectedType['fields'] as List).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get _scalarFields =>
      _fields.where((field) => field['type'] != 'table').toList();
  List<Map<String, dynamic>> get _tableFields =>
      _fields.where((field) => field['type'] == 'table').toList();

  @override
  void initState() {
    super.initState();
    _docType = widget.docTypes.first['name'] as String;
  }

  @override
  void dispose() {
    _id.dispose();
    _label.dispose();
    super.dispose();
  }

  void _appendField() {
    final field = _field;
    if (field == null || _blocks.length >= PrintFormatDefinition.maxBlocks) {
      return;
    }
    setState(() => _blocks.add({'type': 'field', 'field': field}));
  }

  void _appendTable() {
    final tableName = _table;
    if (tableName == null ||
        _blocks.length >= PrintFormatDefinition.maxBlocks) {
      return;
    }
    final table = _tableFields.firstWhere(
      (field) => field['name'] == tableName,
    );
    final child = table['childDocType'] as Map<String, dynamic>;
    final columns = (child['fields'] as List)
        .cast<Map<String, dynamic>>()
        .where((field) => field['type'] != 'table')
        .take(PrintFormatDefinition.maxColumnsPerTable)
        .map((field) => field['name'] as String)
        .toList();
    if (columns.isEmpty) return;
    setState(
      () => _blocks.add({
        'type': 'table',
        'field': tableName,
        'columns': columns,
      }),
    );
  }

  void _save() {
    if (!_formKey.currentState!.validate() || _blocks.isEmpty) return;
    final id = _id.text.trim();
    final slug = widget.moduleId.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '_',
    );
    Navigator.pop(context, <String, dynamic>{
      'id': id,
      'docType': _docType,
      'label': _label.text.trim(),
      'labelKey': 'extension.$slug.print.$id',
      'pageSize': _pageSize,
      'orientation': _orientation,
      'blocks': _blocks,
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const VentioText('native.ui.create_print_format'),
    content: SizedBox(
      width: 600,
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _id,
                decoration: InputDecoration(
                  labelText: context.ventioText('native.ui.print_format_id'),
                ),
                validator: (value) =>
                    RegExp(
                      r'^[a-z][a-z0-9_]{0,63}$',
                    ).hasMatch(value?.trim() ?? '')
                    ? null
                    : context.ventioText(
                        'native.ui.enter_valid_print_format_id',
                      ),
              ),
              TextFormField(
                controller: _label,
                decoration: InputDecoration(
                  labelText: context.ventioText('native.ui.print_format_label'),
                ),
                validator: (value) => value?.trim().isNotEmpty == true
                    ? null
                    : context.ventioText('native.ui.enter_print_format_label'),
              ),
              DropdownButtonFormField<String>(
                initialValue: _docType,
                decoration: InputDecoration(
                  labelText: context.ventioText('native.ui.source_doctype'),
                ),
                items: widget.docTypes
                    .map(
                      (type) => DropdownMenuItem(
                        value: type['name'] as String,
                        child: Text(type['label'] as String),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() {
                  _docType = value!;
                  _field = null;
                  _table = null;
                }),
              ),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _pageSize,
                      decoration: InputDecoration(
                        labelText: context.ventioText('native.ui.page_size'),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'a4',
                          child: Text(context.ventioText('native.ui.a4')),
                        ),
                        DropdownMenuItem(
                          value: 'letter',
                          child: Text(context.ventioText('native.ui.letter')),
                        ),
                      ],
                      onChanged: (value) => setState(() => _pageSize = value!),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _orientation,
                      decoration: InputDecoration(
                        labelText: context.ventioText('native.ui.orientation'),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'portrait',
                          child: Text(context.ventioText('native.ui.portrait')),
                        ),
                        DropdownMenuItem(
                          value: 'landscape',
                          child: Text(
                            context.ventioText('native.ui.landscape'),
                          ),
                        ),
                      ],
                      onChanged: (value) =>
                          setState(() => _orientation = value!),
                    ),
                  ),
                ],
              ),
              if (_scalarFields.isNotEmpty)
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue:
                            _scalarFields.any(
                              (field) => field['name'] == _field,
                            )
                            ? _field
                            : null,
                        decoration: InputDecoration(
                          labelText: context.ventioText(
                            'native.ui.field_block',
                          ),
                        ),
                        items: _scalarFields
                            .map(
                              (field) => DropdownMenuItem(
                                value: field['name'] as String,
                                child: Text(field['label'] as String),
                              ),
                            )
                            .toList(),
                        onChanged: (value) => setState(() => _field = value),
                      ),
                    ),
                    IconButton(
                      onPressed: _appendField,
                      icon: const Icon(Icons.add),
                      tooltip: context.ventioText('native.ui.add_field_block'),
                    ),
                  ],
                ),
              if (_tableFields.isNotEmpty)
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue:
                            _tableFields.any((field) => field['name'] == _table)
                            ? _table
                            : null,
                        decoration: InputDecoration(
                          labelText: context.ventioText(
                            'native.ui.child_table_block',
                          ),
                        ),
                        items: _tableFields
                            .map(
                              (field) => DropdownMenuItem(
                                value: field['name'] as String,
                                child: Text(field['label'] as String),
                              ),
                            )
                            .toList(),
                        onChanged: (value) => setState(() => _table = value),
                      ),
                    ),
                    IconButton(
                      onPressed: _appendTable,
                      icon: const Icon(Icons.add),
                      tooltip: context.ventioText('native.ui.add_table_block'),
                    ),
                  ],
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _blocks.length >= PrintFormatDefinition.maxBlocks
                      ? null
                      : () =>
                            setState(() => _blocks.add({'type': 'page_break'})),
                  icon: const Icon(Icons.insert_page_break_outlined),
                  label: const VentioText('native.ui.add_page_break'),
                ),
              ),
              for (var index = 0; index < _blocks.length; index++)
                ListTile(
                  dense: true,
                  leading: Icon(
                    _blocks[index]['type'] == 'page_break'
                        ? Icons.insert_page_break_outlined
                        : _blocks[index]['type'] == 'table'
                        ? Icons.table_rows_outlined
                        : Icons.text_fields_outlined,
                  ),
                  title: Text(
                    _blocks[index]['type'] == 'page_break'
                        ? context.ventioText('native.ui.page_break')
                        : '${_blocks[index]['type'] == 'table' ? context.ventioText('native.ui.table') : context.ventioText('native.ui.field')}: ${_blocks[index]['field']}',
                  ),
                  trailing: IconButton(
                    onPressed: () => setState(() => _blocks.removeAt(index)),
                    icon: const Icon(Icons.remove_circle_outline),
                    tooltip: context.ventioText('native.ui.remove_block'),
                  ),
                ),
              if (_blocks.isEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    context.ventioText('native.ui.add_print_content_block'),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const VentioText('native.ui.cancel'),
      ),
      FilledButton(
        onPressed: _save,
        child: const VentioText('native.ui.save_print_format'),
      ),
    ],
  );
}

class _ExtensionFormDialog extends StatefulWidget {
  const _ExtensionFormDialog({
    this.extension,
    this.availableExtensions = const [],
  });

  final LocalExtension? extension;
  final List<LocalExtension> availableExtensions;

  @override
  State<_ExtensionFormDialog> createState() => _ExtensionFormDialogState();
}

class _ExtensionFormDialogState extends State<_ExtensionFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _moduleId;
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _version;
  late final Map<String, String> _dependencies;

  @override
  void initState() {
    super.initState();
    final extension = widget.extension;
    _moduleId = TextEditingController(
      text: extension?.moduleId ?? 'com.example.new_extension',
    );
    _name = TextEditingController(text: extension?.displayName ?? '');
    _description = TextEditingController(text: extension?.description ?? '');
    _version = TextEditingController(text: extension?.version ?? '0.1.0');
    _dependencies = Map.of(extension?.dependencies ?? const {});
  }

  @override
  void dispose() {
    _moduleId.dispose();
    _name.dispose();
    _description.dispose();
    _version.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _ExtensionFormValues(
        moduleId: _moduleId.text.trim(),
        displayName: _name.text.trim(),
        description: _description.text.trim(),
        version: _version.text.trim(),
        dependencies: Map.unmodifiable(_dependencies),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.extension != null;
    return AlertDialog(
      title: Text(editing ? 'Edit extension details' : 'Create extension'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _moduleId,
                  readOnly: editing,
                  decoration: InputDecoration(
                    labelText: context.ventioText('native.ui.module_id'),
                    hintText: context.ventioText(
                      'native.ui.com_example_asset_register',
                    ),
                    helperText: context.ventioText(
                      'native.ui.stable_namespaced_id_it_cannot_be_changed_later',
                    ),
                  ),
                  validator: (value) => _identifierError(
                    value,
                    RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$'),
                    'Use lowercase words separated by dots, such as com.example.assets.',
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _name,
                  decoration: InputDecoration(
                    labelText: context.ventioText('native.ui.display_name'),
                  ),
                  validator: (value) => _requiredText(value, 'Enter a name.'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _description,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: context.ventioText('native.ui.description'),
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _version,
                  decoration: InputDecoration(
                    labelText: context.ventioText('native.ui.version'),
                    helperText: context.ventioText(
                      'native.ui.semantic_version_for_example_0_1_0',
                    ),
                  ),
                  validator: (value) {
                    final raw = value?.trim() ?? '';
                    if (!RegExp(
                      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
                    ).hasMatch(raw)) {
                      return context.ventioText(
                        'native.ui.enter_semantic_version',
                      );
                    }
                    final previous = widget.extension?.version;
                    if (previous != null && compareSemver(raw, previous) < 0) {
                      return context.ventioText(
                        'native.ui.version_cannot_move_backwards',
                      );
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: VentioText(
                    'native.ui.dependencies',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                    child: Text(
                      widget.extension?.state == ExtensionState.active
                          ? 'Disable this extension before changing dependencies.'
                          : 'Dependencies must be installed locally. Version 0.x dependencies accept patch updates only; later versions accept updates within the same major version.',
                    ),
                  ),
                ),
                if (widget.availableExtensions
                    .where(
                      (item) => item.moduleId != widget.extension?.moduleId,
                    )
                    .isEmpty)
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: VentioText(
                      'native.ui.create_another_extension_to_add_a_dependency',
                    ),
                  )
                else
                  for (final dependency in widget.availableExtensions.where(
                    (item) => item.moduleId != widget.extension?.moduleId,
                  ))
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _dependencies.containsKey(dependency.moduleId),
                      title: Text(dependency.displayName),
                      subtitle: Text(
                        '${dependency.moduleId} · ${_dependencyVersionRange(MapEntry(dependency.moduleId, _dependencies[dependency.moduleId] ?? dependency.version))}',
                      ),
                      onChanged:
                          widget.extension?.state == ExtensionState.active
                          ? null
                          : (selected) {
                              setState(() {
                                if (selected == true) {
                                  _dependencies[dependency.moduleId] =
                                      _dependencies[dependency.moduleId] ??
                                      dependency.version;
                                } else {
                                  _dependencies.remove(dependency.moduleId);
                                }
                              });
                            },
                    ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const VentioText('native.ui.cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(editing ? 'Save changes' : 'Create draft'),
        ),
      ],
    );
  }
}

class _ExtensionCard extends StatelessWidget {
  const _ExtensionCard({required this.extension, required this.onTap});

  final LocalExtension extension;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 10,
        ),
        leading: const CircleAvatar(child: Icon(Icons.extension_outlined)),
        title: Text(extension.displayName),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            context.ventioText(
              'native.ui.extension_module_version',
              params: {
                'moduleId': extension.moduleId,
                'version': extension.version,
              },
            ),
          ),
        ),
        trailing: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _StatusPill(label: extension.state.databaseValue),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

class _DocTypeCard extends StatelessWidget {
  const _DocTypeCard({
    required this.metadata,
    required this.active,
    required this.onEdit,
    required this.onPreview,
    required this.onOpen,
  });

  final Map<String, dynamic> metadata;
  final bool active;
  final VoidCallback onEdit;
  final VoidCallback onPreview;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final fields = metadata['fields'] as List;
    final label = metadata['label'] as String;
    final ui = metadata['ui'];
    final pageTitle = ui is Map && ui['pageTitle'] is String
        ? ui['pageTitle'] as String
        : label;
    final pageIcon = ui is Map && ui['pageIcon'] is String
        ? ui['pageIcon'] as String
        : 'list';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(_generatedPageIcon(pageIcon)),
                Text(pageTitle, style: Theme.of(context).textTheme.titleMedium),
                _StatusPill(label: 'SCHEMA ${metadata['schemaVersion']}'),
                Text(
                  context.ventioText(
                    'native.ui.fields_count',
                    params: {'count': fields.length},
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              context.ventioText(
                'native.ui.operational_doctype',
                params: {'label': label},
              ),
            ),
            if (pageTitle != label) ...[
              const SizedBox(height: 2),
              Text(
                context.ventioText(
                  'native.ui.record_label',
                  params: {'label': label},
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in fields.take(6))
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('${item['label']} · ${item['type']}'),
                  ),
                if (fields.length > 6)
                  Chip(
                    label: Text(
                      context.ventioText(
                        'native.ui.more_fields',
                        params: {'count': fields.length - 6},
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: onPreview,
                  icon: const Icon(Icons.preview_outlined),
                  label: const VentioText('native.ui.preview'),
                ),
                if (active)
                  FilledButton.tonalIcon(
                    onPressed: onOpen,
                    icon: const Icon(Icons.open_in_new),
                    label: const VentioText('native.ui.open_records'),
                  ),
                TextButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                  label: const VentioText('native.ui.edit_schema'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FieldCard extends StatelessWidget {
  const _FieldCard({
    required this.field,
    required this.onEdit,
    required this.onDelete,
  });

  final Map<String, dynamic> field;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final detail = field['type'] == 'reference'
        ? context.ventioText(
            'native.ui.related_to',
            params: {'referenceTo': field['referenceTo']},
          )
        : field['type'] == 'enum'
        ? (field['enumValues'] as List).join(', ')
        : field['type'] == 'text'
        ? context.ventioText(
            'native.ui.maximum_characters',
            params: {'maxLength': field['maxLength']},
          )
        : field['type'] as String;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.drag_indicator),
        title: Text('${field['label']} · ${field['name']}'),
        subtitle: Text(
          context.ventioText(
            'native.ui.field_card_summary',
            params: {
              'detail': detail,
              'requiredness': context.ventioText(
                field['required'] == true
                    ? 'native.ui.required'
                    : 'native.ui.optional',
              ),
            },
          ),
        ),
        trailing: Wrap(
          children: [
            IconButton(
              onPressed: onEdit,
              tooltip: context.ventioText('native.ui.edit_field'),
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              onPressed: onDelete,
              tooltip: context.ventioText('native.ui.remove_field'),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordCard extends StatelessWidget {
  const _RecordCard({
    required this.record,
    required this.columns,
    required this.onTap,
  });

  final LocalExtensionRecord record;
  final List<FieldDefinition> columns;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = columns.isEmpty ? null : columns.first;
    final summary = (primary == null ? columns : columns.skip(1)).take(3).map((
      field,
    ) {
      return '${context.extensionMetadataText(field.labelKey, field.label)}: ${_displayValue(context, field, record.values[field.name])}';
    }).toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: onTap,
        leading: const CircleAvatar(child: Icon(Icons.description_outlined)),
        title: Text(
          primary == null
              ? context.ventioText(
                  'native.ui.record_id_fallback',
                  params: {'recordId': record.recordId},
                )
              : _displayValue(context, primary, record.values[primary.name]),
        ),
        subtitle: Text(
          [
            if (summary.isNotEmpty) summary.join(' · '),
            context.ventioText(
              'native.ui.record_revision_local_only',
              params: {'revision': record.revision},
            ),
          ].join(' · '),
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _MetadataText extends StatelessWidget {
  const _MetadataText({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => RichText(
    text: TextSpan(
      style: DefaultTextStyle.of(context).style,
      children: [
        TextSpan(
          text: '$label: ',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        TextSpan(text: value),
      ],
    ),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(label, style: Theme.of(context).textTheme.labelSmall),
  );
}

class _LocalOnlyNotice extends StatelessWidget {
  const _LocalOnlyNotice({
    required this.title,
    required this.body,
    required this.icon,
  });
  final String title;
  final String body;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(body),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 30),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(body),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    ),
  );
}

String _messageNamespace(String moduleId) =>
    'extension.${moduleId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}';

String? _requiredText(String? value, String error) =>
    (value == null || value.trim().isEmpty) ? error : null;

String? _identifierError(String? value, RegExp pattern, String message) {
  final raw = value?.trim() ?? '';
  return pattern.hasMatch(raw) ? null : message;
}

String? _docTypeIdentifierError(String? value) => _identifierError(
  value,
  RegExp(r'^[A-Z][A-Za-z0-9_]*$'),
  'Use an identifier such as Asset or AssetAssignment.',
);

String _enumLabel(BuildContext context, FieldDefinition field, String value) {
  final raw = field.enumValues;
  if (!raw.contains(value)) return value;
  final fallback =
      field.enumLabels[value] ??
      value
          .replaceAll('_', ' ')
          .split(' ')
          .map((part) {
            if (part.isEmpty) return part;
            return '${part[0].toUpperCase()}${part.substring(1)}';
          })
          .join(' ');
  final key =
      field.enumLabelKeys[value] ??
      '${field.labelKey.substring(0, field.labelKey.lastIndexOf('.label'))}.enum.$value';
  return context.extensionMetadataText(key, fallback);
}

String _displayValue(
  BuildContext context,
  FieldDefinition field,
  Object? value,
) {
  if (value == null || value == '') return '—';
  if (field.type == 'enum') return _enumLabel(context, field, value.toString());
  return value.toString();
}

String _recordTitle(LocalExtensionRecord record) {
  final first = record.values.values.firstWhere(
    (value) => value != null && value.toString().isNotEmpty,
    orElse: () => record.recordId,
  );
  return first.toString();
}

bool _isHostRecordReadDenial(Object error) {
  if (error is! HostPackageTransportException) return false;
  if (error.statusCode == 401 ||
      error.statusCode == 403 ||
      error.statusCode == 404) {
    return true;
  }
  return const {
    'EXTENSION_NOT_APPROVED',
    'EXTENSION_REVOKED',
    'UPGRADE_REQUIRED',
    'LOCAL_PACKAGE_DIFFERS_FROM_HOST_APPROVED_RELEASE',
    'HOST_PACKAGE_INTEGRITY_FAILED',
  }.contains(error.code);
}

String _dependencyVersionRange(MapEntry<String, String> dependency) {
  final version = semverParts(dependency.value);
  final upperBound = version[0] == 0
      ? '0.${version[1] + 1}.0'
      : '${version[0] + 1}.0.0';
  return '>=${dependency.value}, <$upperBound';
}

final RegExp _enumValue = RegExp(r'^[a-z][a-z0-9_]*$');
