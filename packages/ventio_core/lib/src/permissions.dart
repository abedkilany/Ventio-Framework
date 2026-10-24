/// A grant applies only to this company/branch pair. Keeping permission names
/// on the pair prevents one branch's grant from leaking into another branch.
class PrincipalScope {
  PrincipalScope({
    required this.companyId,
    required this.branchId,
    required Set<String> permissions,
  }) : permissions = Set.unmodifiable(permissions);

  final String companyId;
  final String branchId;
  final Set<String> permissions;

  bool matches(String companyId, String branchId) =>
      this.companyId == companyId && this.branchId == branchId;
}

/// Security context is constructed from verified Host authentication.
/// Never trust tenant, permission, device, or actor claims from a client command.
class Principal {
  final String actorId;
  final String deviceId;
  final String tenantId;
  final Set<String> companyIds;
  final Set<String> branchIds;
  final Set<String> permissions;
  final List<PrincipalScope> scopeGrants;

  Principal({
    required this.actorId,
    required this.deviceId,
    required this.tenantId,
    required Set<String> companyIds,
    required Set<String> branchIds,
    required Set<String> permissions,
    Iterable<PrincipalScope>? scopeGrants,
  })  : companyIds = Set.unmodifiable(companyIds),
        branchIds = Set.unmodifiable(branchIds),
        permissions = Set.unmodifiable(permissions),
        scopeGrants = List.unmodifiable(
          scopeGrants ?? _singleScopeGrant(companyIds, branchIds, permissions),
        ) {
    final seen = <(String, String)>{};
    for (final scope in this.scopeGrants) {
      if (!this.companyIds.contains(scope.companyId) ||
          !this.branchIds.contains(scope.branchId) ||
          !this.permissions.containsAll(scope.permissions) ||
          !seen.add((scope.companyId, scope.branchId))) {
        throw ArgumentError('Invalid or duplicate exact scope grant.');
      }
    }
  }

  bool allowsInScope(String permission, String companyId, String branchId) =>
      scopeGrants.any(
        (scope) =>
            scope.matches(companyId, branchId) &&
            scope.permissions.contains(permission),
      );

  bool hasScope(String companyId, String branchId) =>
      scopeGrants.any((scope) => scope.matches(companyId, branchId));

  bool withinScope(
          {required String tenantId,
          required String companyId,
          required String branchId,
          required String actorId,
          required String deviceId}) =>
      tenantId == this.tenantId &&
      actorId == this.actorId &&
      deviceId == this.deviceId &&
      hasScope(companyId, branchId);
}

List<PrincipalScope> _singleScopeGrant(
  Set<String> companyIds,
  Set<String> branchIds,
  Set<String> permissions,
) {
  if (companyIds.isEmpty && branchIds.isEmpty) return const [];
  if (companyIds.length != 1 || branchIds.length != 1) {
    throw ArgumentError(
      'Exact scope grants are required when multiple companies or branches are present.',
    );
  }
  return [
    PrincipalScope(
      companyId: companyIds.single,
      branchId: branchIds.single,
      permissions: permissions,
    ),
  ];
}
