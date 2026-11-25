import 'command_id.dart';
import 'package:ventio_core/ventio_core.dart';

import 'host_setup.dart';
import 'host_extension_packages.dart';

class HostOrganizationInitializer {
  const HostOrganizationInitializer(this.client);

  final HostExtensionPackageClient client;

  Future<void> apply({
    required HostSetupScope scope,
    required String organizationName,
    required String companyName,
    required String branchName,
  }) async {
    final targets = [
      (
        kind: 'organization',
        id: scope.tenantId,
        parent: null,
        name: organizationName,
      ),
      (kind: 'company', id: scope.companyId, parent: null, name: companyName),
      (
        kind: 'branch',
        id: scope.branchId,
        parent: scope.companyId,
        name: branchName,
      ),
    ];

    for (final target in targets) {
      final name = target.name.trim();

      if (name.isEmpty || name.length > 120) {
        throw ArgumentError('Invalid organization display name.');
      }
    }

    for (final target in targets) {
      final snapshot = await client.platformRequest('organization/list', {
        'companyId': scope.companyId,
        'branchId': scope.branchId,
      });

      final entities = requireList(
        snapshot,
        'entities',
      ).map((raw) => requireMap(raw, 'entity'));

      final matches = entities
          .where(
            (entity) =>
                entity['kind'] == target.kind &&
                entity['id'] == target.id &&
                entity['parentId'] == target.parent,
          )
          .toList();

      if (matches.length != 1) {
        throw const HostSetupException('HOST_ORGANIZATION_SCOPE_UNAVAILABLE');
      }

      final entity = matches.single;

      if (entity['archived'] != false) {
        throw const HostSetupException('HOST_ORGANIZATION_SCOPE_UNAVAILABLE');
      }

      if (entity['displayName'] == target.name.trim()) {
        continue;
      }

      if (entity['displayName'] != target.id) {
        throw const HostSetupException('HOST_ORGANIZATION_NAME_CONFLICT');
      }

      final change = <String, dynamic>{
        'kind': target.kind,
        'id': target.id,
        'parentId': target.parent,
        'displayName': target.name.trim(),
        'archived': false,
        'expectedRevision': requireInt(entity, 'revision'),
        'requestId': createCommandId(),
      };

      validateOrganizationChange(change);

      final result = await client.platformRequest('organization/change', {
        'companyId': scope.companyId,
        'branchId': scope.branchId,
        'change': change,
      });

      if (result['status'] != 'SAVED') {
        throw const HostSetupException(
          'HOST_ORGANIZATION_INITIALIZATION_FAILED',
        );
      }
    }

    final verified = await client.platformRequest('organization/list', {
      'companyId': scope.companyId,
      'branchId': scope.branchId,
    });

    final entities = requireList(
      verified,
      'entities',
    ).map((raw) => requireMap(raw, 'entity')).toList();

    for (final target in targets) {
      final matches = entities
          .where(
            (entity) =>
                entity['kind'] == target.kind &&
                entity['id'] == target.id &&
                entity['parentId'] == target.parent,
          )
          .toList();

      if (matches.length != 1 ||
          matches.single['archived'] != false ||
          matches.single['displayName'] != target.name.trim()) {
        throw const HostSetupException('HOST_ORGANIZATION_VERIFICATION_FAILED');
      }
    }
  }
}
