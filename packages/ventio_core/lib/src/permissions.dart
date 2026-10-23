/// Security context is constructed from verified Host authentication.
/// Never trust tenant, permission, device, or actor claims from a client command.
class Principal {
  final String actorId;
  final String deviceId;
  final String tenantId;
  final Set<String> companyIds;
  final Set<String> branchIds;
  final Set<String> permissions;

  Principal(
      {required this.actorId,
      required this.deviceId,
      required this.tenantId,
      required Set<String> companyIds,
      required Set<String> branchIds,
      required Set<String> permissions})
      : companyIds = Set.unmodifiable(companyIds),
        branchIds = Set.unmodifiable(branchIds),
        permissions = Set.unmodifiable(permissions);

  bool allows(String permission) => permissions.contains(permission);

  bool withinScope(
          {required String tenantId,
          required String companyId,
          required String branchId,
          required String actorId,
          required String deviceId}) =>
      tenantId == this.tenantId &&
      actorId == this.actorId &&
      deviceId == this.deviceId &&
      companyIds.contains(companyId) &&
      branchIds.contains(branchId);
}
