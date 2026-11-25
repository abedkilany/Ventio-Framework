import 'command_id.dart';
import 'host_setup.dart';

HostSetupScope generateHostSetupScope() => HostSetupScope(
  tenantId: 'org_${createCommandId()}',
  companyId: 'cmp_${createCommandId()}',
  branchId: 'br_${createCommandId()}',
);
