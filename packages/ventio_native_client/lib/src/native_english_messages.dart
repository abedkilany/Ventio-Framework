// First-party English UI fallbacks. Keys are stable message identifiers.
const ventioNativeEnglishMessages = <String, String>{
  'native.ui.first_run_title': 'Welcome to Ventio',
  'native.ui.first_run_heading': 'Choose how to use this device',
  'native.ui.first_run_explanation':
      'Set up a Host for your organization or connect this device to an existing Host.',
  'native.ui.first_run_host_title': 'Set up this device as Host',
  'native.ui.first_run_host_details':
      'This device will run the shared Host services and store authoritative business data.',
  'native.ui.first_run_continue': 'Continue',
  'native.ui.first_run_client_title': 'Connect this device to an existing Host',
  'native.ui.first_run_client_details':
      'Use the Host address and a one-time pairing code from its administrator. This Client will not install local Host services.',
  'native.ui.first_run_connect': 'Connect',
  'native.app.title': 'Ventio Extension Builder',
  'native.ui.users_permissions': 'Users & permissions',
  'native.ui.host_overview': 'Host overview',
  'native.ui.host_settings': 'Host settings',
  'native.ui.host_administration': 'Host administration',
  'native.ui.no_host_connection_configured': 'No Host connection configured',
  'native.ui.host_settings_connection_missing_details':
      'Configure this device to connect to a Host. Local settings do not change Host-side users or permissions.',
  'native.ui.device_host_connection': 'Host connection on this device',
  'native.ui.host_address': 'Host address',
  'native.ui.tenant': 'Tenant',
  'native.ui.company': 'Company',
  'native.ui.branch': 'Branch',
  'native.ui.host_session_not_verified': 'Host session is not verified',
  'native.ui.host_settings_session_unavailable_details':
      'The saved connection profile is visible, but this screen could not verify a current Host identity. No Host permissions are displayed.',
  'native.ui.selected_host_scope_not_granted':
      'Selected Host scope is not currently granted',
  'native.ui.host_settings_scope_unavailable_details':
      'The Host session does not include the selected company and branch. Reconfigure this device with an authorized scope.',
  'native.ui.verified_host_session': 'Verified Host session',
  'native.ui.actor_identifier': 'Actor ID',
  'native.ui.device_identifier': 'Device ID',
  'native.ui.credential_storage': 'Credential storage',
  'native.ui.secure_device_credential_vault':
      'Protected credential vault on this device',
  'native.ui.permissions_for_selected_scope':
      'Permissions for the selected company and branch',
  'native.ui.no_permissions_for_selected_scope':
      'No permissions are granted for this scope.',
  'native.ui.host_connection_security': 'Connection security',
  'native.ui.lan_host_listener': 'LAN Host listener',
  'native.ui.lan_endpoint': 'HTTPS endpoint',
  'native.ui.lan_ip_endpoints': 'Current private IP endpoints',
  'native.ui.lan_certificate_fingerprint':
      'TLS certificate SHA-256 fingerprint',
  'native.ui.copy_tls_fingerprint': 'Copy TLS fingerprint',
  'native.ui.tls_fingerprint_copied': 'TLS fingerprint copied.',
  'native.ui.lan_public_certificate': 'Public TLS certificate',
  'native.ui.lan_certificate_trust_notice':
      'The certificate is self-signed. A Client must verify and explicitly trust its fingerprint before pairing.',
  'native.ui.host_settings_security_details':
      'Remote Host connections use HTTPS with standard certificate validation. Stored credentials are never displayed here, and the Host checks authorization on each request.',
  'native.ui.host_certificate_trust_title': 'Host certificate trust',
  'native.ui.host_certificate_trust_details':
      'For a Host certificate renewal, confirm the new SHA-256 fingerprint with the Host administrator through a separate authenticated channel. Ventio checks that exact certificate and then validates its hostname and validity before replacing only this endpoint’s saved certificate pin. The Client identity, credential, SQLite data, and pending operations remain unchanged.',
  'native.ui.host_certificate_fingerprint_label':
      'Independently confirmed Host SHA-256 fingerprint',
  'native.ui.host_certificate_trust_action': 'Verify and update Host trust',
  'native.ui.host_certificate_fingerprint_invalid':
      'Enter a valid 64-character SHA-256 fingerprint confirmed through a separate authenticated channel.',
  'native.ui.host_certificate_trust_updated':
      'The Host certificate was verified and this endpoint’s saved trust was updated. Client credentials and pending operations were not changed.',
  'native.ui.host_certificate_trust_failed':
      'Host trust was not changed. Check the independently confirmed fingerprint, HTTPS endpoint name, and certificate validity; the existing pin and Client credentials remain in place.',
  'native.ui.configure_host_connection': 'Configure Host connection',
  'native.ui.change_host_connection': 'Change Host connection',
  'native.ui.host_settings_device_local_notice':
      'These settings apply to this device. They do not grant Host permissions or change server configuration.',
  'native.ui.invalid_saved_host_address': 'Invalid saved Host address',
  'native.ui.enroll_client': 'Enroll this device as a Client',
  'native.ui.client_pairing_heading': 'Connect this Client to a Host',
  'native.ui.client_pairing_explanation':
      'Enter the Host address and the temporary single-use pairing code supplied by a Host administrator. The Host assigns the account and one exact company/branch scope.',
  'native.ui.client_role_is_not_permission':
      'CLIENT identifies this device role only. It grants no user permissions; access is determined by the Host-authenticated user identity.',
  'native.ui.client_pairing_https_only':
      'HTTPS is required. The Host certificate is verified by its SHA-256 fingerprint.',
  'native.ui.client_pairing_fingerprint':
      'Host TLS certificate SHA-256 fingerprint',
  'native.ui.client_pairing_fingerprint_help':
      'Copy the fingerprint from Host Settings. The certificate is checked before the one-time code is sent.',
  'native.ui.client_pairing_code': 'Temporary pairing code',
  'native.ui.client_pairing_single_use':
      'This code can be used once and expires after a short time.',
  'native.ui.client_pairing_enrolling': 'Enrolling Client…',
  'native.ui.client_pairing_success': 'Client enrolled',
  'native.ui.client_pairing_scope':
      'Host scope: company {companyId} · branch {branchId}',
  'native.ui.client_pairing_credential_expiry':
      'Device credential expires {timestamp}',
  'native.ui.client_pairing_success_details':
      'The device credential was stored securely. Sign-in and permissions continue to be checked by the Host.',
  'native.ui.client_pairing_failed_title': 'Enrollment did not complete',
  'native.ui.client_pairing_https_required':
      'Enter a valid HTTPS Host address. Certificate validation cannot be bypassed.',
  'native.ui.client_pairing_fingerprint_required':
      'Enter the Host TLS certificate SHA-256 fingerprint shown in Host Settings.',
  'native.ui.client_pairing_code_invalid':
      'Enter a valid pairing code supplied by the Host administrator.',
  'native.ui.client_pairing_code_expired':
      'The pairing code is invalid, expired, or already used. Ask the Host administrator for a new code.',
  'native.ui.client_pairing_rate_limited':
      'Too many pairing attempts were made. Wait before trying again.',
  'native.ui.client_pairing_device_registered':
      'This device is already registered. Contact the Host administrator if you need to enroll it again.',
  'native.ui.client_pairing_tls_failed':
      'The Host certificate could not be validated. Check the address and trusted certificate.',
  'native.ui.client_pairing_host_unreachable':
      'The Host could not be reached. Check the network and try again with a current pairing code.',
  'native.ui.client_pairing_version_mismatch':
      'This Host does not support the required pairing API version.',
  'native.ui.client_pairing_local_save_failed':
      'The Host accepted enrollment, but this device could not save it securely. Ask the Host administrator for a new pairing code before retrying.',
  'native.ui.client_pairing_failed':
      'The Host could not complete Client enrollment. Share the reference with a Host administrator if the problem continues.',
  'native.ui.done': 'Done',
  'native.ui.refresh_host_readiness': 'Refresh Host readiness',
  'native.ui.host_checks_status_permission':
      'The Host checks host.status.read for this exact branch on every request.',
  'native.ui.host_status_access_required': 'Host status access required',
  'native.ui.host_status_access_required_details':
      'This signed-in identity does not have host.status.read for the selected company and branch.',
  'native.ui.host_overall_state': 'Overall Host state: {state}',
  'native.ui.host_version_checked':
      'Host version {version} · checked {timestamp}',
  'native.ui.host_readiness_reason_code': 'Safe reason code: {code}',
  'native.ui.device_inventory_unavailable':
      'Device inventory is not part of this readiness summary',
  'native.ui.device_inventory_unavailable_details':
      'Open Host devices & pairing to review registered devices when your signed-in identity has the required permission.',
  'native.ui.host_devices': 'Host devices & pairing',
  'native.ui.refresh_devices': 'Refresh devices',
  'native.ui.device_scope_summary': 'Host device administration · exact scope',
  'native.ui.device_access_required':
      'Device administration permission required',
  'native.ui.device_access_required_details':
      'Ask the Host administrator to grant identity.devices.manage or identity.pairing.manage for this exact branch.',
  'native.ui.registered_devices': 'Registered devices',
  'native.ui.no_device_inventory': 'Device inventory has not loaded.',
  'native.ui.no_registered_devices':
      'No registered devices are visible in this branch.',
  'native.ui.generate_pairing_code': 'Generate Client pairing code',
  'native.ui.check_pairing_request_safely':
      'Check previous pairing request safely',
  'native.ui.pairing_replacement_after_expiry':
      'Replacement available after {timestamp}',
  'native.ui.pairing_target_help':
      'Enter the Host user ID that will use this Client. Pairing grants no additional permissions.',
  'native.ui.pairing_select_active_user':
      'Choose an active user in this exact Host branch. Pairing grants no additional permissions.',
  'native.ui.pairing_users_unavailable':
      'The scoped Host user list could not be loaded. Retry before creating a pairing code.',
  'native.ui.pairing_no_active_users':
      'There are no active Host users available in this branch.',
  'native.ui.pairing_target_user_id': 'Host user ID',
  'native.ui.pairing_pending_target': 'Pending pairing target',
  'native.ui.pairing_code_once':
      'Show this single-use code to the Client operator. It is visible only in this screen and expires soon.',
  'native.ui.create_trusted_scoped_pairing': 'Create trusted scoped pairing',
  'native.ui.trusted_scoped_pairing_help':
      'Use this on the Windows Host after the target user already has the requested permissions. Windows will ask a local administrator to approve only this exact branch and permission list.',
  'native.ui.trusted_pairing_review_title':
      'Review new Client permission ceiling',
  'native.ui.trusted_pairing_review_scope':
      'The new Client will be limited to tenant {tenantId}, company {companyId}, branch {branchId}.',
  'native.ui.trusted_pairing_permissions': 'Client permissions',
  'native.ui.trusted_pairing_permissions_help':
      'Enter only the business permissions this Client needs, separated by commas or new lines. Every permission must already be granted to the selected user directly or through a role.',
  'native.ui.trusted_pairing_permissions_invalid':
      'Enter one or more valid business permissions without duplicates.',
  'native.ui.trusted_pairing_uac_review':
      'A Windows administrator approval prompt follows. The Host independently checks current user grants and Recovery Authority before creating a five-minute, single-use pairing code.',
  'native.ui.review_and_continue': 'Review and continue',
  'native.ui.trusted_pairing_permission_ceiling':
      'This Client credential ceiling contains only: {permissions}',
  'native.ui.trusted_pairing_device_note':
      'Enrollment creates a new Client device identity. Existing devices and credentials remain active until you explicitly revoke them.',
  'native.ui.trusted_pairing_operator_permission_denied':
      'The signed-in Host credential must include identity.pairing.manage for this exact branch, and the selected user must already have every requested permission. Ask a Host identity manager to check both grants and this credential ceiling.',
  'native.ui.trusted_pairing_code_unavailable':
      'A trusted pairing may already have been created for this user and branch. Its one-time code cannot be recovered. Wait five minutes before requesting a replacement.',
  'native.ui.trusted_pairing_outcome_unknown':
      'The Host may have created the pairing, but its one-time code was not received. Wait five minutes before requesting another code for this user and branch.',
  'native.ui.permission_denied_user_grant':
      'This Host user does not currently have extension.package.read for this exact branch, either directly or through a role. Grant it first, then create a scoped Client pairing.',
  'native.ui.permission_denied_credential_ceiling':
      'This Host user has extension.package.read, but this Client credential ceiling does not include it. On the Windows Host, create a trusted scoped pairing for extension.package.read and enroll a new Client.',
  'native.ui.permission_denied_credential_scope':
      'This Client credential is not scoped to the requested company and branch. Ask a Host operator to enroll a Client for the correct exact scope.',
  'native.ui.permission_denied_unclassified':
      'The Host could not safely classify this permission denial. Check the user grant, exact branch scope, and Client credential ceiling with a Host operator.',
  'native.ui.copy_pairing_code': 'Copy pairing code',
  'native.ui.copy_device_credential': 'Copy device credential',
  'native.ui.copied_to_clipboard': 'Copied to clipboard.',
  'native.ui.copy_to_clipboard_failed': 'Could not copy to clipboard.',
  'native.ui.pairing_code_expires': 'Expires {timestamp}',
  'native.ui.clear_code': 'Clear code',
  'native.ui.revoke_device_title': 'Revoke this device?',
  'native.ui.revoke_device_confirmation':
      'Revoke device {deviceId}? Its active credentials will stop working immediately.',
  'native.ui.revoke_device': 'Revoke device',
  'native.ui.rotate_credential_title': 'Rotate this device credential?',
  'native.ui.rotate_credential_confirmation':
      'Replace the active credential for {deviceId}? The old credential will stop working immediately. The new secret is shown once.',
  'native.ui.rotate_credential': 'Rotate credential',
  'native.ui.rotated_credential_once':
      'New device credential — copy it now; it will not be shown again.',
  'native.ui.device_credential_rotated_details':
      'Credential for {deviceId} expires {expires}. Provide it securely to that Client and clear this screen after transfer.',
  'native.ui.clear_credential': 'Clear credential',
  'native.ui.device_role_and_state': '{role} · {state}',
  'native.ui.device_registered': 'Registered',
  'native.ui.device_revoked': 'Revoked',
  'native.ui.device_registered_at': 'Registered {timestamp}',
  'native.ui.device_activity_unavailable':
      'Recent authenticated activity is not available; connection state is unknown.',
  'native.ui.device_last_authenticated': 'Last authenticated {timestamp}',
  'native.ui.no_device_credentials':
      'No credential records are visible in this scope.',
  'native.ui.device_credential_state':
      'Credential {id} · {state} · expires {expires}',
  'native.ui.credential_active': 'Active',
  'native.ui.credential_expired': 'Expired',
  'native.ui.credential_revoked': 'Revoked',
  'native.ui.credential_rotated': 'Rotated',
  'native.ui.credential_unknown': 'Unknown',
  'native.ui.device_action_failed': 'Host device operation failed',
  'native.ui.device_error_permission':
      'The Host denied this operation for the selected branch. Check the signed-in user permissions and scope.',
  'native.ui.device_error_network':
      'The Host could not be reached or did not respond in time. Check the network and Host service, then retry.',
  'native.ui.device_error_tls':
      'The Host TLS identity could not be verified. Check the address and trusted certificate; do not bypass validation.',
  'native.ui.device_error_authentication':
      'The saved Host credential is missing or no longer valid. Reconnect or ask an administrator to review device access.',
  'native.ui.device_error_target':
      'The selected Host user is unavailable in this scope. Check the user ID and branch access.',
  'native.ui.device_error_rate_limit':
      'The Host has temporarily limited pairing requests. Wait, then retry.',
  'native.ui.device_error_not_found':
      'The device is no longer available in this branch. Refresh the inventory.',
  'native.ui.device_error_generic':
      'The Host could not complete the operation. Retry and share the correlation reference with an administrator.',
  'native.ui.safe_error_code': 'Error code: {code}',
  'native.ui.host_readiness_failed': 'Could not check Host readiness',
  'native.ui.host_status_denied':
      'The Host denied access to readiness for this scope.',
  'native.ui.host_readiness_failed_details':
      'The Host could not return a valid readiness summary. Retry and share the reference with a Host administrator if the problem continues.',
  'native.ui.host_component_api': 'Authenticated Host API',
  'native.ui.host_component_database': 'PostgreSQL connection',
  'native.ui.host_component_schema': 'Database schema and runtime profile',
  'native.ui.host_component_recovery': 'Recovery Authority',
  'native.ui.host_api_ready_guidance':
      'The Host accepted this authenticated readiness check.',
  'native.ui.host_database_ready_guidance':
      'The Host confirmed its database connection.',
  'native.ui.host_schema_ready_guidance':
      'The Host confirmed its approved schema and runtime profile.',
  'native.ui.host_recovery_ready_guidance':
      'Recovery admission is ready for Host operations.',
  'native.ui.host_component_degraded_guidance':
      'This component reports degraded readiness. Some Host operations may need attention.',
  'native.ui.host_recovery_blocked_guidance':
      'Recovery admission is blocked. Contact a Host administrator before retrying protected operations.',
  'native.ui.host_component_blocked_guidance':
      'This component is blocked. Review the readiness code with a Host administrator.',
  'native.ui.host_component_not_configured':
      'This Host component has not been configured.',
  'native.ui.host_component_unknown':
      'The Host could not determine this component state.',
  'native.ui.host_api_unavailable_guidance':
      'The Host could not confirm API readiness. Check the Host service and retry.',
  'native.ui.host_database_unavailable_guidance':
      'The Host could not confirm the PostgreSQL connection. Check the Host database service and retry.',
  'native.ui.host_schema_unavailable_guidance':
      'The Host could not confirm the approved schema or runtime profile. Ask a Host administrator to review migrations and database setup.',
  'native.ui.host_recovery_unavailable_guidance':
      'The Host could not confirm Recovery Authority readiness. Ask a Host administrator to review recovery configuration.',
  'native.ui.host_users': 'Host users',
  'native.ui.create_user': 'Create user',
  'native.ui.actor_id': 'User ID',
  'native.ui.user_active': 'Active',
  'native.ui.user_disabled_state': 'Disabled',
  'native.ui.user_actions': 'User actions',
  'native.ui.direct_permissions': 'Direct permissions',
  'native.ui.no_direct_permissions': 'No direct permissions',
  'native.ui.role_assignments': 'Role assignments',
  'native.ui.no_role_assignments': 'No role assignments in this scope',
  'native.ui.grant_permission': 'Grant permission',
  'native.ui.revoke_permission': 'Revoke permission',
  'native.ui.disable_user': 'Disable user',
  'native.ui.disable_user_confirmation':
      'Disable user {displayName} in this Host scope? Login will be suspended. Existing permissions and unrevoked credentials are preserved and may become active again if the user is re-enabled.',
  'native.ui.enable_user': 'Enable user',
  'native.ui.enable_user_confirmation':
      'Re-enable user {displayName} in this Host scope? Existing permissions and unrevoked, unexpired credentials will work again. Revoke compromised device credentials separately.',
  'native.ui.refresh_users': 'Refresh users',
  'native.ui.users_scope_summary': 'Host tenant: {tenantId}',
  'native.ui.host_checks_user_management_permission':
      'The Host checks identity.users.manage for this exact branch on every request.',
  'native.ui.user_access_required': 'User-management access required',
  'native.ui.user_access_required_details':
      'This signed-in identity does not have identity.users.manage for the selected company and branch.',
  'native.ui.no_host_users': 'No users are registered in this Host scope.',
  'native.ui.could_not_load_host_users': 'Could not load Host users',
  'native.ui.user_change_not_confirmed': 'User change was not confirmed',
  'native.ui.user_change_confirmed_refresh_failed':
      'The Host confirmed the change. Retry the list refresh to see the latest users.',
  'native.ui.host_user_read_unreachable': 'The Host could not be reached.',
  'native.ui.user_created_without_permissions':
      'User created without direct permissions or role assignments.',
  'native.ui.legacy_identity_reference': 'Legacy identity {number}',
  'native.ui.user_created_with_id': 'User created. Generated ID: {actorId}',
  'native.ui.generated_user_id': 'Generated user ID: {actorId}',
  'native.ui.user_permission_granted':
      'Host granted this user permission. Existing device credentials remain limited to their original ceilings. Use Host devices & pairing to create a trusted scoped pairing for a new Client.',
  'native.ui.user_permission_revoked': 'Permission revoked by Host.',
  'native.ui.user_disabled': 'Host disabled the user.',
  'native.ui.user_enabled': 'Host enabled the user.',
  'native.ui.recent_user_activity': 'Recent administrative activity',
  'native.ui.no_recent_user_activity': 'No recent activity is available.',
  'native.ui.audit_activity_load_failed':
      'Could not load recent administrative activity',
  'native.ui.audit_event_summary':
      'User {subjectId} · Operator {operator} · {timestamp}',
  'native.ui.audit_user_created': 'User created',
  'native.ui.audit_user_disabled': 'User disabled',
  'native.ui.audit_user_enabled': 'User enabled',
  'native.ui.audit_permission_granted': 'Permission granted',
  'native.ui.audit_permission_revoked': 'Permission revoked',
  'native.ui.audit_role_created': 'Role created',
  'native.ui.audit_role_renamed': 'Role renamed',
  'native.ui.audit_role_deleted': 'Role deleted',
  'native.ui.audit_role_permission_granted': 'Role permission granted',
  'native.ui.audit_role_permission_revoked': 'Role permission revoked',
  'native.ui.audit_role_assigned': 'Role assigned',
  'native.ui.audit_role_unassigned': 'Role unassigned',
  'native.ui.audit_other_administration': 'Administrative activity',
  'native.ui.enter_actor_id': 'Enter a user ID.',
  'native.ui.enter_display_name': 'Enter a display name.',
  'native.ui.permission_not_grantable_to_users':
      'Enter a valid non-management permission key. Identity, Host, system, security and recovery permissions cannot be granted here.',
  'native.ui.new_user_is_unprivileged':
      'The new user starts with no permissions or roles.',
  'native.ui.user_management_denied_by_host':
      'The Host denied this user-management request.',
  'native.ui.host_credential_unavailable':
      'A valid Host credential is not available on this device.',
  'native.ui.host_not_reachable':
      'The Host could not be reached. Your account changes were not confirmed.',
  'native.ui.host_tls_validation_failed':
      'The Host TLS certificate could not be validated. Check the Host address and certificate.',
  'native.ui.host_api_version_not_supported':
      'This Host does not support the required management API version.',
  'native.ui.host_user_operation_failed':
      'The Host could not complete the user-management request.',
  'native.ui.correlation_reference': 'Reference: {correlationId}',
  'native.ui.a_doctype_defines_the_fields_relationships_validation_and_permissions_fo':
      'A DocType defines the fields, relationships, validation and permissions for a kind of record.',
  'native.ui.a_saved_record_could_not_enter_the_host_queue':
      'A saved record could not enter the Host queue',
  'native.ui.add_a_doctype_to_define_permission_keys':
      'Add a DocType to define permission keys.',
  'native.ui.add_a_field_to_the_new_schema_first':
      'Add a field to the new schema first.',
  'native.ui.add_default': 'Add default',
  'native.ui.add_doctype': 'Add DocType',
  'native.ui.add_field': 'Add field',
  'native.ui.add_field_rename': 'Add field rename',
  'native.ui.add_fields_to_configure_this_layout':
      'Add fields to configure this layout.',
  'native.ui.add_permission': 'Add permission',
  'native.ui.add_report': 'Add report',
  'native.ui.add_print_format': 'Add print format',
  'native.ui.add_field_block': 'Add field block',
  'native.ui.add_table_block': 'Add table block',
  'native.ui.add_page_break': 'Add page break',
  'native.ui.add_print_content_block': 'Add at least one field or table block.',
  'native.ui.a4': 'A4',
  'native.ui.letter': 'Letter',
  'native.ui.page_size': 'Page size',
  'native.ui.orientation': 'Orientation',
  'native.ui.portrait': 'Portrait',
  'native.ui.landscape': 'Landscape',
  'native.ui.field_block': 'Field to add',
  'native.ui.child_table_block': 'Child table to add',
  'native.ui.page_break': 'Page break',
  'native.ui.table': 'Table',
  'native.ui.field': 'Field',
  'native.ui.remove_block': 'Remove block',
  'native.ui.print_formats': 'Print formats',
  'native.ui.no_print_formats_yet': 'No print formats yet',
  'native.ui.print_formats_use_authorized_record_fields':
      'Print layouts use reviewed fields and only records freshly authorized by the Host.',
  'native.ui.create_print_format': 'Create print format',
  'native.ui.print_format_id': 'Print format ID',
  'native.ui.enter_valid_print_format_id':
      'Enter a lowercase ID using letters, numbers and underscores.',
  'native.ui.print_format_label': 'Print format label',
  'native.ui.enter_print_format_label': 'Enter a print format label.',
  'native.ui.save_print_format': 'Save print format',
  'native.ui.print_record': 'Print record',
  'native.ui.choose_print_format': 'Choose a print format',
  'native.ui.printing_requires_host_accepted_current_record':
      'Printing requires a Host-accepted record with no pending command.',
  'native.ui.print_failed': 'The authorized record could not be printed.',
  'native.ui.print': 'Print',
  'native.ui.add_step': 'Add step',
  'native.ui.add_the_first_field': 'Add the first field',
  'native.ui.adds_a_host_grant_required_to_create_or_change_this_field':
      'Adds a Host grant required to create or change this field.',
  'native.ui.adds_a_host_grant_required_to_receive_this_field':
      'Adds a Host grant required to receive this field.',
  'native.ui.applied_only_when_the_saved_value_is_missing_or_null':
      'Applied only when the saved value is missing or null.',
  'native.ui.approved_extensions': 'Approved extensions',
  'native.ui.ascending': 'Ascending',
  'native.ui.asset': 'Asset',
  'native.ui.assign_role': 'Assign role',
  'native.ui.assign_user': 'Assign user',
  'native.ui.branch_roles': 'Branch roles',
  'native.ui.build_an_extension': 'Build an extension',
  'native.ui.cancel': 'Cancel',
  'native.ui.choice_list': 'Choice list',
  'native.ui.choice_values': 'Choice values',
  'native.ui.choose_and_order_fields_shown_on_create_and_edit_forms_required_fields_s':
      'Choose and order fields shown on create and edit forms. Required fields stay visible.',
  'native.ui.choose_and_order_fields_shown_when_a_saved_record_is_opened_this_affects':
      'Choose and order fields shown when a saved record is opened. This affects presentation only; it does not restrict access to field values.',
  'native.ui.choose_host_scope': 'Choose Host scope',
  'native.ui.cached_records_hidden_until_authorized':
      'Cached rows are hidden until a Host-authorized query succeeds. Local records and pending commands have not been deleted.',
  'native.ui.choose_visible_columns_and_their_order_in_generated_lists':
      'Choose visible columns and their order in generated lists.',
  'native.ui.choose_which_local_record_operations_this_doctype_supports_permission_ke':
      'Choose which local record operations this DocType supports. Permission keys are namespaced to this extension. These declarations do not grant user access; a Host administrator must grant each operation for an exact scope.',
  'native.ui.close': 'Close',
  'native.ui.com_example_asset_register': 'com.example.asset_register',
  'native.ui.connect_to_host': 'Connect to Host',
  'native.ui.contains': 'Contains',
  'native.ui.continue_with_selected_values': 'Continue with selected values',
  'native.ui.copy_package_json': 'Copy package JSON',
  'native.ui.could_not_load_host_roles': 'Could not load Host roles',
  'native.ui.create_a_local_draft_add_one_or_more_doctypes_then_preview_the_screens_g':
      'Create a local draft, add one or more DocTypes, then preview the screens generated from your metadata.',
  'native.ui.create_a_record_on_this_device_or_change_your_search_and_filters':
      'Create a record on this device or change your search and filters.',
  'native.ui.create_another_extension_to_add_a_dependency':
      'Create another extension to add a dependency.',
  'native.ui.create_requests_offline_a_local_save_is_provisional_and_is_not_host_appr':
      'Create requests offline. A local save is provisional and is not Host approval.',
  'native.ui.create_role': 'Create role',
  'native.ui.create_your_first_extension': 'Create your first extension',
  'native.ui.customer_name': 'Customer name',
  'native.ui.data_migration': 'Data migration',
  'native.ui.data_type': 'Data type',
  'native.ui.date': 'Date',
  'native.ui.date_and_time': 'Date and time',
  'native.ui.decimal': 'Decimal',
  'native.ui.declarative_extension_package': 'Declarative extension package',
  'native.ui.declared_record_operations': 'Declared record operations',
  'native.ui.define_reusable_records_fields_relationships_and_screens_without_adding':
      'Define reusable records, fields, relationships and screens without adding a page to the Flutter app.',
  'native.ui.delete': 'Delete',
  'native.ui.delete_role': 'Delete role?',
  'native.ui.delete_role_ac18d11a': 'Delete role',
  'native.ui.dependencies': 'Dependencies',
  'native.ui.description': 'Description',
  'native.ui.details_page_fields': 'Details page fields',
  'native.ui.device_lifecycle': 'Device lifecycle',
  'native.ui.device_local_extension_copy': 'Device-local extension copy',
  'native.ui.device_model': 'Device model',
  'native.ui.discard_local_edits_and_use_host_version':
      'Discard local edits and use Host version',
  'native.ui.disconnect': 'Disconnect',
  'native.ui.disconnect_host': 'Disconnect Host',
  'native.ui.disconnect_this_device_from_host':
      'Disconnect this device from Host?',
  'native.ui.display_name': 'Display name',
  'native.ui.doctype_definitions_are_validated_metadata_they_cannot_contain_sql_scrip':
      'DocType definitions are validated metadata. They cannot contain SQL, scripts or downloaded executable code.',
  'native.ui.doctype_id': 'DocType ID',
  'native.ui.doctypes_summary': 'DocTypes: {names}',
  'native.ui.tenant_summary': 'Tenant: {tenantId}',
  'native.ui.edit_document': 'Edit {label}',
  'native.ui.decimal_precision_summary': 'precision {precision}',
  'native.ui.new_document': 'New {label}',
  'native.ui.enter_number': 'Enter a number.',
  'native.ui.enter_finite_number': 'Enter a finite number.',
  'native.ui.enter_valid_date': 'Enter a valid date in YYYY-MM-DD format.',
  'native.ui.enter_valid_datetime':
      'Enter an ISO date and time with a time-zone offset.',
  'native.ui.enter_whole_number': 'Enter a whole number.',
  'native.ui.select_field': 'Select {label}.',
  'native.ui.enter_field': 'Enter {label}.',
  'native.ui.enter_page_title': 'Enter a page title.',
  'native.ui.use_120_characters_or_fewer': 'Use 120 characters or fewer.',
  'native.ui.enter_navigation_order': 'Enter an order from 0 to 10000.',
  'native.ui.minimum_must_not_exceed_maximum':
      'Minimum must not exceed the maximum.',
  'native.ui.maximum_must_not_be_below_minimum':
      'Maximum must not be below the minimum.',
  'native.ui.enter_length_bound': 'Enter a number from 1 to 65,535.',
  'native.ui.minimum_length_must_not_exceed_maximum':
      'Minimum length must not exceed the maximum.',
  'native.ui.maximum_length_must_not_be_below_minimum':
      'Maximum length must not be below the minimum.',
  'native.ui.add_at_least_one_choice': 'Add at least one choice.',
  'native.ui.choice_values_must_be_unique': 'Choice values must be unique.',
  'native.ui.use_lowercase_stable_choice_ids':
      'Use lowercase stable IDs, such as in_use.',
  'native.ui.enter_semantic_version': 'Enter a semantic version such as 0.1.1.',
  'native.ui.version_cannot_move_backwards': 'Version cannot move backwards.',
  'native.ui.related_reference_scope':
      'Related {doctype} in the current local scope',
  'native.ui.related_to': 'Related to {referenceTo}',
  'native.ui.maximum_characters': 'Maximum {maxLength} characters',
  'native.ui.field_card_summary': '{detail} · {requiredness}',
  'native.ui.select_related_record': 'Select a related {doctype} record.',
  'native.ui.too_short': 'Enter at least {minLength} characters.',
  'native.ui.too_long': 'Enter no more than {maxLength} characters.',
  'native.ui.rename_role_title': 'Rename {roleId}',
  'native.ui.no_description': 'No description.',
  'native.ui.operational_doctype': '{label} · operational DocType',
  'native.ui.required': 'Required',
  'native.ui.fields_count': 'Fields ({count})',
  'native.ui.saving': 'Saving…',
  'native.ui.save_locally': 'Save locally',
  'native.ui.remove_role_from_actor': 'Remove role from {actorId}',
  'native.ui.scope_identifiers': '{companyId} / {branchId}',
  'native.ui.host_snapshot_revision': 'Host snapshot revision {revision}',
  'native.ui.host_request_failed': 'Host request failed.',
  'native.ui.role_permission_denied':
      'This credential needs a direct identity.roles.manage grant for this branch.',
  'native.ui.persistent_identity_required':
      'Connect a persistent Host identity.',
  'native.ui.role_already_exists': 'A role with that ID already exists.',
  'native.ui.role_not_found': 'The role no longer exists on Host.',
  'native.ui.role_has_assignments':
      'Remove all branch assignments before deleting this role.',
  'native.ui.role_change_rejected':
      'Host rejected the change. Check the role and user IDs, then try again.',
  'native.ui.invalid_role_change': 'Host rejected the role details.',
  'native.ui.host_unreachable':
      'Host is unreachable. Try again when connected.',
  'native.ui.host_request_timeout':
      'Host did not respond before the request deadline.',
  'native.ui.device_error_pairing_unknown':
      'The Host may have created the pairing, but the one-time code was not received. Retry only with the same request reference. If Host already accepted it, the code cannot be recovered.',
  'native.ui.device_error_pairing_code_unavailable':
      'This pairing request was already accepted. Its one-time code cannot be recovered; wait at least five minutes from this response before issuing a replacement.',
  'native.ui.device_error_pairing_database':
      'The Host database could not be reached before pairing began. Check Host readiness and retry with the same request reference.',
  'native.ui.device_error_pairing_api_unsupported':
      'This Host does not support the safe pairing request protocol. Update the Host before generating Client pairing codes.',
  'native.ui.device_error_local_pairing_state':
      'Ventio could not safely save the pending pairing reference on this device. No pairing request was sent.',
  'native.ui.device_error_recovery_authority':
      'Recovery Authority could not safely admit this request. Check Host readiness before trying again.',
  'native.ui.device_error_recovery_authority_busy':
      'Recovery Authority is processing another protected operation. Retry with the same request reference.',
  'native.ui.diagnostics.pairing_request': 'Client pairing request status',
  'native.ui.host_request_failed_with_code': 'Host request failed ({code}).',
  'native.ui.host_package_request_failed':
      'The Host could not load its approved package registry. Check Host readiness and ask a Host operator to review the safe error code {code}.',
  'native.ui.extension_review_submission':
      '{displayName}\n{moduleId} · {version}\n\nThis sends declarative metadata to the selected Host. It remains a candidate until a trusted Host operator reviews and approves it.',
  'native.ui.remove_field_confirmation':
      'Removing {fieldId} may be rejected if the saved schema already uses it. Existing records are preserved.',
  'native.ui.move_field_up': 'Move {label} up',
  'native.ui.move_field_down': 'Move {label} down',
  'native.ui.extension_module_version': '{moduleId} · v{version}',
  'native.ui.long_text': 'Long text',
  'native.ui.child_table': 'Child table',
  'native.ui.child_doctype': 'Child DocType',
  'native.ui.child_doctype_id': 'Child DocType ID',
  'native.ui.child_doctype_label': 'Child DocType label',
  'native.ui.add_child_field': 'Add child field',
  'native.ui.save_child_doctype': 'Save child DocType',
  'native.ui.configure_child_doctype': 'Configure child DocType',
  'native.ui.edit_child_doctype': 'Edit child DocType · {name}',
  'native.ui.child_field_uses_parent_table_access':
      'This field inherits the parent table field’s permissions and scope.',
  'native.ui.child_fields_inherit_parent_table_access':
      'Child fields inherit the parent table field’s permissions and scope. Nested tables are not supported.',
  'native.ui.enter_child_doctype_name_first':
      'Enter a valid child DocType ID before adding fields.',
  'native.ui.child_doctype_field_limit':
      'A child DocType can contain at most 50 fields.',
  'native.ui.child_field_ids_unique': 'Child field IDs must be unique.',
  'native.ui.invalid_child_field_schema':
      'The child field definition is invalid. Check its type and constraints.',
  'native.ui.add_child_doctype_field':
      'Add at least one field to the child DocType.',
  'native.ui.invalid_child_doctype':
      'The child DocType definition is invalid. Review its fields.',
  'native.ui.invalid_child_doctype_id':
      'Use a stable ID starting with a capital letter.',
  'native.ui.enter_child_doctype_label': 'Enter a child DocType label.',
  'native.ui.select_a_doctype': 'Select a DocType.',
  'native.ui.table_json_help':
      'Enter a JSON array of flat row objects (up to 500 rows).',
  'native.ui.table_json_error':
      'Enter a valid JSON array of non-empty row objects, with no nested values and no more than 500 rows.',
  'native.ui.add_child_row': 'Add row',
  'native.ui.child_row_count': '{count} rows',
  'native.ui.no_child_rows': 'No rows yet.',
  'native.ui.row_number': '#',
  'native.ui.row_actions': 'Row actions',
  'native.ui.move_row_up': 'Move row up',
  'native.ui.move_row_down': 'Move row down',
  'native.ui.remove_child_row': 'Remove row',
  'native.ui.child_row_field_invalid': 'Check the value for {label}.',
  'native.ui.field_description': 'Field description',
  'native.ui.description_too_long':
      'Keep the description under 500 characters.',
  'native.ui.read_only': 'Read only',
  'native.ui.field_default': 'Default value',
  'native.ui.precision': 'Decimal places',
  'native.ui.precision_error': 'Enter a number from 0 to 9.',
  'native.ui.calculation': 'Calculated value',
  'native.ui.no_calculation': 'No calculation',
  'native.ui.multiply_fields': 'Multiply two row fields',
  'native.ui.sum_child_rows': 'Sum a child row field',
  'native.ui.calculation_left_field': 'First number field',
  'native.ui.calculation_right_field': 'Second number field',
  'native.ui.calculation_table': 'Child table',
  'native.ui.calculation_value': 'Child number field to sum',
  'native.ui.complete_calculation': 'Complete the calculation fields.',
  'native.ui.invalid_field_default':
      'Enter a default that matches this field type and its constraints.',
  'native.ui.decimal_precision':
      'Enter a value with no more than {precision} decimal places.',
  'native.ui.removal_requires_no_data_or_pending_commands':
      'Removal requires no local records or unresolved Host commands. Other extensions must not depend on this module.',
  'native.ui.remove_blocked_pending_commands':
      'Resolve this extension’s queued Host commands before removing it.',
  'native.ui.command_id': 'Command {commandId}',
  'native.ui.saved_count': '{count} saved',
  'native.ui.host_resolved_commands':
      'Host resolved {count} queued command(s).',
  'native.ui.host_sync_stopped':
      'Host synchronization failed. Pending work remains saved locally.',
  'native.ui.sync_failed_message':
      'Host synchronization failed ({code}). Pending operations remain saved locally. Reference: {correlationId}',
  'native.ui.synchronization': 'Synchronization',
  'native.ui.refresh_sync_status': 'Refresh synchronization status',
  'native.ui.sync_queue_unavailable':
      'The local synchronization queue could not be read. Retry to check it again.',
  'native.ui.sync_attempt_failed':
      'The sync attempt did not complete. Pending operations remain saved locally; check the connection and retry.',
  'native.ui.sync_status_unavailable': 'Synchronization status unavailable',
  'native.ui.sync_queue_empty': 'No queued operations',
  'native.ui.sync_queue_empty_details':
      'New offline operations will appear here and remain saved until the Host responds.',
  'native.ui.sync_recent_limit': 'Showing the latest 1,000 operations.',
  'native.ui.sync_overview_title': 'Synchronization status',
  'native.ui.retry_pending_sync': 'Retry pending',
  'native.ui.sync_offline_explanation':
      'No authenticated Host connection is configured. Local operations remain saved on this device.',
  'native.ui.sync_host_retry_explanation':
      'Only a stored Host receipt counts as confirmed. Retry sends the same durable command IDs.',
  'native.ui.sync_pending_count': 'Pending: {count}',
  'native.ui.sync_retry_count': 'Retry later: {count}',
  'native.ui.sync_confirmed_count': 'Host confirmed: {count}',
  'native.ui.sync_rejected_count': 'Rejected: {count}',
  'native.ui.sync_conflict_count': 'Conflicts: {count}',
  'native.ui.sync_no_host_attempt': 'No Host synchronization attempt recorded.',
  'native.ui.sync_latest_attempt': 'Latest attempt: {timestamp}',
  'native.ui.sync_operation': 'Queued operation',
  'native.ui.sync_status_line': '{status} · {attempts} attempt(s)',
  'native.ui.sync_command_reference': 'Command reference: {commandId}',
  'native.ui.sync_created_at': 'Created: {timestamp}',
  'native.ui.sync_updated_at': 'Updated: {timestamp}',
  'native.ui.sync_attempted_at': 'Last attempt: {timestamp}',
  'native.ui.sync_host_reason': 'Host reason code: {code}',
  'native.ui.sync_host_reason_guidance':
      'Review this Host result and correct the operation before retrying.',
  'native.ui.sync_fixture_not_confirmation':
      'A local test response is saved. It is not a Host confirmation.',
  'native.ui.sync_confirmed': 'Confirmed by Host',
  'native.ui.sync_pending_status': 'Pending on this device',
  'native.ui.sync_unconfirmed_status': 'Waiting for a Host receipt',
  'native.ui.sync_rejected': 'Rejected by Host',
  'native.ui.sync_conflict': 'Conflict reported by Host',
  'native.ui.sync_retry_later': 'Host requested retry later',
  'native.ui.sync_failure_code': 'Safe error code: {code}',
  'native.ui.sync_failure_reference': 'Reference: {correlationId}',
  'native.diagnostics.host_sync_failed': 'Host synchronization failed',
  'native.diagnostics.host_setup_failed': 'Host setup failed',
  'native.ui.local_host_revision':
      'Local revision {localRevision} · Host revision {hostRevision} · {syncState}',
  'native.ui.local_value': 'Local · {value}',
  'native.ui.host_value': 'Host · {value}',
  'native.ui.more_fields': '+{count} more',
  'native.ui.record_label': 'Record label: {label}',
  'native.ui.saved_attempts':
      'Saved on this device · {count} fixture/transport attempts',
  'native.ui.fixture_status':
      'Fixture response: {status}. This is simulated and is not Host confirmation.',
  'native.ui.delete_role_confirmation':
      'Delete {roleName}? Host only allows deletion after all branch assignments have been removed.',
  'native.ui.host_tenant_summary': 'Host · {tenantId}',
  'native.ui.role_access_summary':
      '{roleId} · {permissionCount} permissions · {userCount} users in this branch',
  'native.ui.details_for_doctype': '{label} details',
  'native.ui.delete_record': 'Delete record',
  'native.ui.confirm_delete_record':
      'This record will be removed from lists. Shared records are sent to the Host for safe deletion.',
  'native.ui.delete_record_failed':
      'The record could not be queued for deletion. Try again after resolving pending changes.',
  'native.ui.choose_conflict_values':
      'Choose which value to keep for each field. Saving the merge creates a new command against Host revision {revision}; the Host will validate it again.',
  'native.ui.extension': 'Extension',
  'native.ui.doctypes': 'DocTypes',
  'native.ui.each_doctype_creates_a_records_page_these_settings_control_its_navigatio':
      'Each DocType creates a records page. These settings control its navigation label, icon and order; access still follows the DocType permissions.',
  'native.ui.edit_extension_details': 'Edit extension details',
  'native.ui.edit_field': 'Edit field',
  'native.ui.edit_record': 'Edit record',
  'native.ui.edit_schema': 'Edit schema',
  'native.ui.enter_an_https_host_origin_or_http_for_a_same_device_loopback_host':
      'Enter an HTTPS Host origin, or HTTP for a same-device loopback Host.',
  'native.ui.existing_field_id': 'Existing field ID',
  'native.ui.existing_user_id': 'Existing user ID',
  'native.ui.export_declarative_package': 'Export declarative package',
  'native.ui.extensions_could_not_be_loaded': 'Extensions could not be loaded',
  'native.ui.fetch_the_latest_host_version_before_reviewing_this_conflict':
      'Fetch the latest Host version before reviewing this conflict.',
  'native.ui.field_id': 'Field ID',
  'native.ui.fields_define_what_the_generated_form_validates_and_stores':
      'Fields define what the generated form validates and stores.',
  'native.ui.filter_field': 'Filter field',
  'native.ui.generated_form_fields': 'Generated form fields',
  'native.ui.generated_list_view': 'Generated list view',
  'native.ui.generated_list_preview_summary':
      'The list shows {count} configured {columns} and will support search and local filters when activated.',
  'native.ui.host_authorization_required': 'Host authorization required',
  'native.ui.host_authoritative_records': 'Host-authoritative records',
  'native.ui.host_denied_list_query_body':
      'The Host denied this record query. Cached records remain stored locally but are hidden until an authorized Host query succeeds.',
  'native.ui.host_records_list_verified_scope':
      'The Host-approved package and exact company/branch scope were verified. Accepted records are cached locally; new changes remain provisional until a Host receipt arrives.',
  'native.ui.host_record_refresh_failed_body':
      'The Host query did not complete. Retry to refresh records; cached records remain subject to Host authorization.',
  'native.ui.host_record_local_edits':
      'Host record · Local changes are provisional',
  'native.ui.host_record_revision_notice':
      'The Host accepted revision {revision}. Saving changes creates a pending command and requires a new Host receipt.',
  'native.ui.generated_page_settings': 'Generated page settings',
  'native.ui.host_approved_package': 'Host-approved package',
  'native.ui.host_denied_record_access': 'Host denied record access',
  'native.ui.host_origin': 'Host origin',
  'native.ui.host_records_were_not_refreshed':
      'Host records were not refreshed',
  'native.ui.host_validates_this_exact_branch_scope_on_every_change':
      'Host validates this exact branch scope on every change',
  'native.ui.install_extension_package': 'Install extension package',
  'native.ui.install_from_host': 'Install from Host',
  'native.ui.install_host_approved_extension':
      'Install Host-approved extension',
  'native.ui.install_on_this_device': 'Install on this device',
  'native.ui.install_package': 'Install package',
  'native.ui.installing_this_package_saves_a_local_draft_on_this_device_it_does_not_a':
      'Installing this package saves a local draft on this device. It does not approve or publish it through Host.',
  'native.ui.it_must_exist_in_the_new_schema':
      'It must exist in the new schema.',
  'native.ui.json_scalar_value': 'JSON scalar value',
  'native.ui.keep_field': 'Keep field',
  'native.ui.keep_local': 'Keep local',
  'native.ui.label': 'Label',
  'native.ui.last_updated': 'Last updated',
  'native.ui.list_page_columns': 'List page columns',
  'native.ui.load_more': 'Load more',
  'native.ui.load_more_host_records': 'Load more Host records',
  'native.ui.local_activation_controls_this_device_only_submit_this_declarative_packa':
      'Local activation controls this device only. Submit this declarative package for Host review before sharing its definition with other devices. Record commands stay provisional until Host receipts confirm acceptance.',
  'native.ui.local_command_queue': 'Local command queue',
  'native.ui.local_installation_only': 'Local installation only',
  'native.ui.local_only': 'LOCAL ONLY',
  'native.ui.local_only_demonstration': 'Local-only demonstration',
  'native.ui.local_records_host_scope_unavailable':
      'The selected Host scope remains authoritative. The list below contains locally saved provisional records; connect or retry before treating them as shared data.',
  'native.ui.local_records_host_unavailable':
      'Local records · Host unavailable',
  'native.ui.local_records_need_host_connection':
      'Records stay on this device as provisional work until an authenticated Host connection is configured.',
  'native.ui.list_preview_activation_body':
      'This screen is rendered from the DocType definition. Saving is disabled until the extension is activated on this device.',
  'native.ui.metadata_preview': 'Metadata preview',
  'native.ui.lower_values_appear_first_values_from_0_to_10000_are_supported':
      'Lower values appear first. Values from 0 to 10000 are supported.',
  'native.ui.maintenance_requests': 'Maintenance Requests',
  'native.ui.manage_roles_access': 'Manage roles & access',
  'native.ui.maximum_length': 'Maximum length',
  'native.ui.maximum_value': 'Maximum value',
  'native.ui.maximum_value_summary': 'max {maximum}',
  'native.ui.maximum_length_summary': 'max length {maximum}',
  'native.ui.minimum_length': 'Minimum length',
  'native.ui.minimum_value': 'Minimum value',
  'native.ui.minimum_value_summary': 'min {minimum}',
  'native.ui.minimum_length_summary': 'min length {minimum}',
  'native.ui.module_id': 'Module ID',
  'native.ui.navigation_icon': 'Navigation icon',
  'native.ui.navigation_order': 'Navigation order',
  'native.ui.new_extension': 'New extension',
  'native.ui.new_record': 'New record',
  'native.ui.new_field_id': 'New field ID',
  'native.ui.new_request': 'New request',
  'native.ui.no_approved_extensions_are_available_for_this_host_scope':
      'No approved extensions are available for this Host scope.',
  'native.ui.no_data_transformations_safe_optional_additions_and_widened_constraints':
      'No data transformations. Safe optional additions and widened constraints need no step.',
  'native.ui.no_doctypes_yet': 'No DocTypes yet',
  'native.ui.no_filter': 'No filter',
  'native.ui.no_host_connection_is_configured_the_fixture_below_is_simulated_and_cann':
      'No Host connection is configured. The fixture below is simulated and cannot confirm shared state.',
  'native.ui.no_matching_records': 'No matching records',
  'native.ui.no_record_operations_are_enabled_for_this_doctype':
      'No record operations are enabled for this DocType.',
  'native.ui.no_requests_yet': 'No requests yet',
  'native.ui.no_roles_are_defined_yet_create_a_role_add_namespaced_permissions_then_a':
      'No roles are defined yet. Create a role, add namespaced permissions, then assign it to an existing user in this branch.',
  'native.ui.no_users_are_assigned_in_this_branch':
      'No users are assigned in this branch.',
  'native.ui.not_set': 'Not set',
  'native.ui.offline_first_proof': 'Offline-first proof',
  'native.ui.offline_queue_proof': 'Offline queue proof',
  'native.ui.open_generated_form': 'Open generated form',
  'native.ui.open_records': 'Open records',
  'native.ui.optional': 'Optional',
  'native.ui.operation_not_declared': 'Operation not declared',
  'native.ui.package_json': 'Package JSON',
  'native.ui.page_title': 'Page title',
  'native.ui.paste_a_ventio_declarative_package_it_can_contain_schemas_and_ui_metadat':
      'Paste a Ventio declarative package. It can contain schemas and UI metadata only; scripts, SQL and executable capabilities are rejected.',
  'native.ui.paste_from_clipboard': 'Paste from clipboard',
  'native.ui.permission_key': 'Permission key',
  'native.ui.permissions': 'Permissions',
  'native.ui.permissions_and_operations': 'Permissions and operations',
  'native.ui.preview': 'Preview',
  'native.ui.preview_form': 'Preview form',
  'native.ui.preview_only': 'Preview only',
  'native.ui.provisional_device_record': 'Provisional device record',
  'native.ui.provisional_record_notice':
      'This record is stored locally. The Host has not accepted it yet; a Host receipt is required before it becomes shared data.',
  'native.ui.form_preview_cannot_save':
      'Values are for preview and cannot be saved.',
  'native.ui.form_operation_not_declared':
      'This DocType does not declare the required create or update operation.',
  'native.ui.correct_form_errors_before_saving':
      'Correct the highlighted form errors before saving.',
  'native.ui.form_save_failed': 'The record could not be saved. Try again.',
  'native.ui.saved_record_needs_queue_recovery':
      'The record was saved locally, but its Host command needs recovery.',
  'native.ui.problem_description': 'Problem description',
  'native.ui.provisional_local_records': 'Provisional local records',
  'native.ui.read_operation_is_not_declared': 'Read operation is not declared',
  'native.ui.record_id_fallback': 'Record {recordId}',
  'native.ui.record_list_load_failed_body':
      'The records could not be loaded from this device. Try again.',
  'native.ui.record_revision': 'Revision {revision}',
  'native.ui.record_revision_host_confirmed':
      'Revision {revision} · confirmed by Host',
  'native.ui.record_revision_local_only': 'Revision {revision} · local only',
  'native.ui.read_permission_optional': 'Read permission (optional)',
  'native.ui.records_could_not_be_loaded': 'Records could not be loaded',
  'native.ui.refresh_approved_extensions': 'Refresh approved extensions',
  'native.ui.refresh_host_version': 'Refresh Host version',
  'native.ui.refresh_records': 'Refresh records',
  'native.ui.refresh_roles': 'Refresh roles',
  'native.ui.related_doctype': 'Related DocType',
  'native.ui.relationship': 'Relationship',
  'native.ui.remote_hosts_require_https': 'Remote Hosts require HTTPS.',
  'native.ui.removal_is_allowed_only_when_the_extension_has_no_local_records_this_act':
      'Removal is allowed only when the extension has no local records. This action cannot publish or revoke a shared Host extension.',
  'native.ui.remove': 'Remove',
  'native.ui.remove_field': 'Remove field',
  'native.ui.remove_field_from_this_draft': 'Remove field from this draft?',
  'native.ui.remove_migration_step': 'Remove migration step',
  'native.ui.remove_this_local_extension': 'Remove this local extension?',
  'native.ui.rename': 'Rename',
  'native.ui.replace_local_values': 'Replace local values',
  'native.ui.required_field': 'Required field',
  'native.ui.resolve_record_conflict': 'Resolve record conflict',
  'native.ui.retry': 'Retry',
  'native.ui.retry_host_query': 'Retry Host query',
  'native.ui.retry_queue_recovery': 'Retry queue recovery',
  'native.ui.review_and_resolve_conflict': 'Review and resolve conflict',
  'native.ui.review_extension_package': 'Review extension package',
  'native.ui.review_record_conflict': 'Review record conflict',
  'native.ui.role_actions': 'Role actions',
  'native.ui.role_id': 'Role ID',
  'native.ui.roles_access': 'Roles & access',
  'native.ui.roles_group_permissions_for_this_tenant_host_checks_every_affected_branc':
      'Roles group permissions for this tenant. Host checks every affected branch before changing a shared role. The role management permission itself can only be granted directly by a trusted Host operator.',
  'native.ui.run_local_fixture': 'Run local fixture',
  'native.ui.save': 'Save',
  'native.ui.save_changes': 'Save changes',
  'native.ui.save_on_device': 'Save on device',
  'native.ui.save_field': 'Save field',
  'native.ui.saved_requests_will_remain_in_this_device_s_local_queue_after_the_app_re':
      'Saved requests will remain in this device’s local queue after the app restarts.',
  'native.ui.schema_designer': 'Schema designer',
  'native.ui.search_records': 'Search records',
  'native.ui.semantic_version_for_example_0_1_0':
      'Semantic version, for example 0.1.0.',
  'native.ui.separate_stable_values_with_commas':
      'Separate stable values with commas.',
  'native.ui.shown_in_extension_navigation_and_on_the_records_page':
      'Shown in extension navigation and on the records page.',
  'native.ui.sort_by': 'Sort by',
  'native.ui.descending': 'Descending',
  'native.ui.create_report': 'Create report',
  'native.ui.enter_report_label': 'Enter a report label.',
  'native.ui.enter_valid_report_id':
      'Use lowercase letters, numbers and underscores; start with a letter.',
  'native.ui.group_by_field': 'Group by field',
  'native.ui.no_reports_yet': 'No reports yet',
  'native.ui.none': 'None',
  'native.ui.report_filter_field': 'Filter field',
  'native.ui.report_id': 'Report ID',
  'native.ui.report_label': 'Report label',
  'native.ui.reports': 'Reports',
  'native.ui.reports_are_saved_as_bounded_package_metadata_and_host_permissions_are_rechecked':
      'Reports are saved as bounded package metadata. Host permissions are checked again for each query.',
  'native.ui.save_report': 'Save report',
  'native.ui.source_doctype': 'Source DocType',
  'native.ui.sum_numeric_field': 'Sum numeric field',
  'native.ui.stable_identifier_use_letters_numbers_and_underscores':
      'Stable identifier. Use letters, numbers and underscores.',
  'native.ui.stable_namespaced_id_it_cannot_be_changed_later':
      'Stable namespaced ID; it cannot be changed later.',
  'native.ui.start_with_an_extension': 'Start with an extension',
  'native.ui.submit_candidate': 'Submit candidate',
  'native.ui.submit_extension_for_host_review':
      'Submit extension for Host review?',
  'native.ui.submit_package_for_host_review': 'Submit package for Host review',
  'native.ui.supported_operations_preserve_data_rename_a_field_or_populate_a_constant':
      'Supported operations preserve data: rename a field, or populate a constant scalar where a field is missing or null. Type conversion and field deletion are not supported.',
  'native.ui.sync_pending': 'Sync pending',
  'native.ui.sync_pending_commands_with_host':
      'Sync pending commands with Host',
  'native.ui.sync_pending_records': 'Sync pending records',
  'native.ui.target_field': 'Target field',
  'native.ui.text': 'Text',
  'native.ui.field_type_text': 'Text',
  'native.ui.field_type_long_text': 'Long text',
  'native.ui.field_type_integer': 'Whole number',
  'native.ui.field_type_decimal': 'Decimal',
  'native.ui.field_type_date': 'Date',
  'native.ui.field_type_datetime': 'Date and time',
  'native.ui.field_type_boolean': 'Yes or no',
  'native.ui.field_type_enum': 'Choice',
  'native.ui.field_type_reference': 'Record reference',
  'native.ui.field_type_table': 'Table data',
  'native.ui.the_extension_declares_read_create_and_update_permission_keys_it_cannot':
      'The extension declares read, create and update permission keys. It cannot grant them to users or add trusted Host capabilities. A Host administrator must approve and grant each exact scope.',
  'native.ui.the_host_approved_this_metadata_package_installing_saves_it_on_this_devi':
      'The Host approved this metadata package. Installing saves it on this device as a draft; activate it after reviewing its fields and dependencies.',
  'native.ui.the_old_value_is_retained_under_the_new_id':
      'The old value is retained under the new ID.',
  'native.ui.this_doctype_does_not_grant_the_update_operation_so_merged_values_cannot':
      'This DocType does not grant the update operation, so merged values cannot be submitted.',
  'native.ui.this_doctype_does_not_permit_listing_or_opening_records_on_this_device':
      'This DocType does not permit listing or opening records on this device.',
  'native.ui.this_extension_was_removed': 'This extension was removed.',
  'native.ui.this_removes_the_saved_host_scope_and_this_endpoint_s_device_credential':
      'This removes the saved Host scope and this endpoint’s device credential. Local drafts and records stay on this device.',
  'native.ui.this_replaces_the_local_provisional_values_with_the_latest_host_values_o':
      'This replaces the local provisional values with the latest Host values on this device. The Host record is not changed.',
  'native.ui.try_again': 'Try again',
  'native.ui.updated': 'Updated',
  'native.ui.use_host': 'Use Host',
  'native.ui.use_host_version': 'Use Host version?',
  'native.ui.use_this_scope': 'Use this scope',
  'native.ui.users_in_this_branch': 'Users in this branch',
  'native.ui.validate_package': 'Validate package',
  'native.ui.ventio_extension_builder': 'Ventio · Extension Builder',
  'native.ui.ventio_framework': 'Ventio Framework',
  'native.ui.verify_host': 'Verify Host',
  'native.ui.version': 'Version',
  'native.ui.value_at_least': 'Enter a value of at least {minimum}.',
  'native.ui.value_at_most': 'Enter a value no greater than {maximum}.',
  'native.ui.use_lowercase_namespaced_permission_key':
      'Use a lower-case namespaced permission key.',
  'native.ui.role_management_requires_trusted_operator':
      'Role management must be granted directly by a trusted operator.',
  'native.ui.whole_number': 'Whole number',
  'native.ui.workspace_actions': 'Workspace actions',
  'native.ui.write_permission_optional': 'Write permission (optional)',
  'native.ui.yes_no': 'Yes / no',
  'native.ui.your_extensions': 'Your extensions',
  'native.ui.enable_document_numbering': 'Enable document numbering',
  'native.ui.enable_governed_document_lifecycle':
      'Enable governed document lifecycle',
  'native.ui.governed_document_lifecycle_help':
      'The Host applies Submit, Cancel and Amend atomically. If numbering is enabled, it assigns the official number during Submit.',
  'native.ui.submit_document': 'Submit document',
  'native.ui.cancel_document': 'Cancel document',
  'native.ui.amend_document': 'Amend document',
  'native.ui.amendment_field_conflict':
      'The amended-from field must be an optional read-only reference to this DocType.',
  'native.ui.business_operation_inputs_unavailable':
      'This operation requires inputs that are not supported by this form yet.',
  'native.ui.business_operation_queue_failed':
      'The operation could not be saved to the durable Host queue.',
  'native.ui.document_numbers_are_provisional_offline_and_assigned_by_the_host_on_submit':
      'Names shown offline are provisional. The Host assigns the official number when the document is submitted.',
  'native.ui.numbering_series_id': 'Numbering series ID',
  'native.ui.stable_series_id_lowercase_letters_numbers_hyphens_or_underscores':
      'Use a stable ID with lowercase letters, numbers, hyphens or underscores.',
  'native.ui.enter_a_valid_numbering_series_id':
      'Enter a valid numbering series ID.',
  'native.ui.official_number_field': 'Official number field',
  'native.ui.choose_an_optional_read_only_text_field_with_room_for_a_provisional_name':
      'Choose an optional, read-only text field with room for a provisional name.',
  'native.ui.choose_a_valid_number_field':
      'Choose a valid read-only text field for the number.',
  'native.ui.number_prefix': 'Number prefix',
  'native.ui.enter_a_literal_number_prefix':
      'Use a literal prefix with uppercase letters, numbers, dots, slashes or hyphens.',
  'native.ui.number_zero_padding': 'Number zero-padding width',
  'native.ui.choose_a_width_between_1_and_12': 'Choose a width from 1 to 12.',
  'native.ui.host_setup_menu': 'Host setup',
  'native.ui.host_setup_title': 'Host setup',
  'native.ui.host_setup_admin_required': 'Request Windows setup approval',
  'native.ui.host_setup_admin_explanation':
      'Completing Host setup requires Windows Administrator approval. Continue to authorize only the protected setup component; Ventio itself stays at normal user privileges.',
  'native.ui.host_setup_continue_as_admin':
      'Continue with Administrator access',
  'native.ui.host_setup_windows_only':
      'Host setup is available on a Windows Host installation.',
  'native.ui.host_setup_postgres': 'PostgreSQL service',
  'native.ui.host_setup_service': 'Ventio Host service',
  'native.ui.host_setup_not_installed': 'Not installed',
  'native.ui.host_setup_stopped': 'Stopped',
  'native.ui.host_setup_start_pending': 'Starting',
  'native.ui.host_setup_stop_pending': 'Stopping',
  'native.ui.host_setup_running': 'Running',
  'native.ui.host_setup_unknown': 'Status unavailable',
  'native.ui.host_setup_progress_title': 'Setup progress',
  'native.ui.host_setup_scope_title': 'Initial Host scope',
  'native.ui.host_setup_scope_explanation':
      'Enter the tenant, company and branch identifiers for this Host. The Host grants the first administrator access only to this exact scope.',
  'native.ui.host_setup_tenant_id': 'Tenant ID',
  'native.ui.host_setup_company_id': 'Company ID',
  'native.ui.host_setup_branch_id': 'Branch ID',
  'native.ui.host_setup_first_admin': 'Create the first Host administrator',
  'native.ui.host_setup_store_credential':
      'Store the administrator credential securely',
  'native.ui.host_setup_readiness': 'Verify Host readiness',
  'native.ui.host_setup_credential_privacy':
      'Ventio runs as your normal Windows user. Windows requests Administrator approval only for the protected Host provisioning component. The first administrator credential is stored in Windows secure storage and is never shown.',
  'native.ui.host_setup_diagnostic_reference':
      'Diagnostic reference: {referenceId}',
  'native.ui.host_setup_diagnostic_not_saved':
      'This report could not be saved on this device, but you can still copy the safe summary.',
  'native.ui.host_setup_copy_diagnostics': 'Copy sanitized setup report',
  'native.ui.host_setup_diagnostic_copy_success':
      'Sanitized Host setup report copied.',
  'native.ui.host_setup_diagnostic_copy_failed':
      'The sanitized Host setup report could not be copied.',
  'native.ui.host_setup_start': 'Set up Host',
  'native.ui.host_setup_postgres_port_in_use':
      'Another process is using the local PostgreSQL port (54329). Free the port, then retry Host setup.',
  'native.ui.host_setup_retry': 'Retry Host setup',
  'native.ui.host_setup_check_readiness': 'Check Host readiness',
  'native.ui.host_setup_open_workspace': 'Open Ventio workspace',
  'native.ui.host_setup_complete':
      'Host is ready. The initial administrator credential and exact Host scope are stored securely on this device.',
  'native.ui.host_setup_status_unavailable':
      'Windows could not confirm the required service status. Check the Host installation and try again.',
  'native.ui.host_setup_first_admin_request_invalid':
      'The protected Host setup request could not be validated. Existing setup data was preserved.',
  'native.ui.host_setup_first_admin_database_failed':
      'The Host service could not connect to its PostgreSQL database while creating the first administrator. Existing setup data was preserved; review protected diagnostics before retrying.',
  'native.ui.host_setup_first_admin_recovery_failed':
      'The protected Recovery Authority could not complete first-administrator setup. Existing setup data was preserved; do not reset or remove the Host data.',
  'native.ui.host_setup_first_admin_identity_failed':
      'The Host could not commit the first administrator to its identity database. Existing setup data was preserved; review protected diagnostics before retrying.',
  'native.ui.host_setup_first_admin_helper_timeout':
      'The first-administrator helper exceeded its time limit. Existing setup data was preserved; review protected diagnostics before retrying.',
  'native.ui.host_setup_first_admin_result_invalid':
      'The first-administrator setup returned an invalid result. No credential was accepted, and existing setup data was preserved.',
  'native.ui.host_setup_first_admin_helper_failed':
      'The trusted first-administrator helper failed without a safe diagnostic code. Existing setup data was preserved.',
  'native.ui.host_setup_elevation_failed':
      'Windows did not start the protected Host setup component. Confirm the machine-wide Ventio installation and try again.',
  'native.ui.host_setup_broker_start_timeout':
      'Windows accepted the Host setup request, but Ventio did not receive a protected progress record. Keep the setup data intact and review diagnostics before retrying.',
  'native.ui.host_setup_scope_invalid':
      'Enter a tenant, company and branch ID using letters, numbers, periods, underscores, colons or hyphens. Each value must be 256 characters or fewer.',
  'native.ui.host_setup_failed_generic':
      'Host setup did not complete. Review the service status and retry. No credential was displayed.',
  'native.ui.host_setup_install_role_missing':
      'Host services are not installed. Run the unified Ventio installer and select the Host installation role.',
  'native.ui.host_setup_service_control_denied':
      'Windows denied access to the Host services. Continue with Administrator access and retry.',
  'native.ui.host_setup_service_start_failed':
      'A Ventio Host service stopped before it became ready. Review Host diagnostics and retry.',
  'native.ui.host_setup_service_timeout':
      'A Ventio Host service did not start before the timeout. Review Host diagnostics and retry.',
  'native.ui.host_setup_lan_network_required':
      'Host LAN HTTPS requires a Private or authenticated Domain network. Public networks stay closed. Connect this PC to a trusted network and retry.',
  'native.ui.host_setup_lan_firewall_failed':
      'Windows Firewall or organization policy did not accept the scoped Host HTTPS rule. Do not disable the firewall or allow the Public profile; ask an administrator to review the active network policy.',
  'native.ui.host_setup_existing_profile':
      'A different Host scope is already configured on this device. Disconnect that Host before setting up this one.',
  'native.ui.host_setup_credential_save_failed':
      'The administrator credential could not be saved securely. The protected setup result was preserved so setup can resume safely.',
  'native.ui.host_setup_response_invalid':
      'The local setup broker returned an invalid response. The credential was not accepted.',
  'native.ui.host_setup_credential_unavailable':
      'The protected first administrator result is unavailable to this Windows account. Keep the setup data intact and contact the Host administrator.',
  'native.ui.host_setup_broker_unavailable':
      'The protected local setup component is unavailable. Confirm that Ventio is installed machine-wide, then try again.',
  'native.ui.host_setup_acknowledgement_failed':
      'Ventio could not confirm that the protected setup result was saved. The setup data was preserved.',
  'native.ui.host_setup_readiness_timeout':
      'The Host services started, but the Host API did not become ready in time. The saved credential is retained for a safe retry.',
  'native.ui.host_setup_elevation_cancelled':
      'Host setup needs Administrator approval to register and start Windows services. No Host data was changed.',
  'native.ui.host_setup_application_elevated':
      'Ventio is running as Administrator. Close it and launch Ventio normally before starting Host setup.',
  'native.ui.host_setup_operation_timeout':
      'Host setup is still running or its progress record is unavailable. Keep this window open and check again before retrying.',
  'native.ui.host_setup_pending_mismatch':
      'A pending Host setup belongs to another Windows account or scope. Its data was preserved and was not resumed.',
  'native.ui.host_setup_existing_installation':
      'Ventio Host services or data already exist on this computer. Setup stopped to protect them; use the reviewed recovery workflow.',
  'native.ui.host_setup_migration_ledger_invalid':
      'The Host database migration ledger does not match the bundled migrations. Keep the Host data intact and review the diagnostic report before retrying.',
  'native.ui.host_setup_service_identity_conflict':
      'A Windows service using a Ventio service name does not match this installation. Setup stopped without changing it. Have an administrator review the existing service before continuing.',
  'native.ui.host_setup_already_running':
      'Another Host setup operation is still active. Leave its data unchanged and check its progress again before retrying.',
  'native.ui.host_setup_interrupted_requires_recovery':
      'The previous Host setup stopped or its progress record is stale. Ventio will not restart provisioning automatically because partial database changes may exist. Preserve the Host data and use the reviewed recovery process.',
  'native.ui.host_setup_payload_verification_failed':
      'Ventio could not verify the protected Host setup files. Setup did not continue. Repair the machine-wide Ventio installation before trying again.',
  'native.ui.host_setup_state_unavailable':
      'Ventio could not read or save the local setup checkpoint. No existing Host data was changed.',
  'native.ui.host_setup_identity_unavailable':
      'Ventio could not verify the current Windows account needed to protect the setup result.',
  'native.ui.host_setup_requester_identity_mismatch':
      'Windows started setup under a different account from the one that requested it. Setup stopped without returning credentials.',
  'native.ui.check_credential_update_title': 'Host credential update',
  'native.ui.check_credential_update_details':
      'Check for a Host-approved permission update. Ventio keeps this device identity, Host profile, SQLite records, and pending commands.',
  'native.ui.check_credential_update': 'Check for update',
  'native.ui.reissue_credential_title': 'Update this Client credential ceiling',
  'native.ui.reissue_credential_confirmation':
      'This keeps the current permissions and adds extension.package.read for this existing device. Confirm the exact identity and complete resulting permission ceiling, then approve the trusted Windows operation. Device: {deviceId}. Tenant: {tenantId}. User: {actorId}. Company: {companyId}. Branch: {branchId}. Resulting permissions: {permissions}.',
  'native.ui.authorize_credential_update': 'Review and continue',
  'native.ui.reissue_credential': 'Update permission ceiling',
  'native.ui.reconcile_credential_update': 'Reconcile update',
  'native.ui.credential_reissue_operator_state':
      'Trusted credential update: {state}',
  'native.ui.credential_reissue_device': 'Device: {deviceId}',
  'native.ui.credential_reissue_scope':
      'Tenant: {tenantId} · User: {actorId} · Company: {companyId} · Branch: {branchId}',
  'native.ui.credential_reissue_permissions':
      'Complete permission ceiling: {permissions}',
  'native.ui.credential_reissue_expires': 'Transition expires: {timestamp}',
  'native.ui.credential_reissue_reference':
      'Operation reference: {operationId}',
  'native.ui.credential_reissue_uac_cancelled':
      'Windows Administrator approval was cancelled. No new credential was issued. The operation reference is retained for safe reconciliation.',
  'native.ui.credential_reissue_none':
      'There is no pending Host credential update for this Client.',
  'native.ui.credential_reissue_applied':
      'The replacement credential was acknowledged and saved securely. This Client identity and its local data remain unchanged.',
  'native.ui.credential_reissue_staged':
      'The replacement credential is safely staged. Retry the update check to finish Host acknowledgment.',
  'native.ui.credential_reissue_expired':
      'The pending credential update expired before completion. The existing credential remains active; an operator can authorize a new request.',
  'native.ui.credential_reissue_rejected':
      'The Host rejected the pending update because its device, user, or current permission grants changed. Review the current scope and grants before requesting again.',
  'native.ui.credential_reissue_permission_denied':
      'The Host did not find the required current operator authority or target-user permission grant. Grant the business permission at this exact company and branch, then retry.',
  'native.ui.credential_reissue_reconcile_first':
      'A previous credential update for this device still needs reconciliation. Resume that exact operation before starting another update.',
  'native.ui.credential_reissue_unknown':
      'The Host may have prepared this credential update, but Ventio could not confirm the result. Keep the device and local data intact, then retry with the same operation reference.',
  'native.ui.credential_reissue_failed':
      'The trusted credential update did not complete. Keep the existing device and local data intact and review the safe operation reference.',
  'native.ui.render_failure_title': 'Ventio could not display this screen.',
  'native.ui.render_failure_details':
      'Open Local diagnostics from the workspace and copy the sanitized export.',
  'native.ui.return_to_workspace': 'Return to workspace',
  'native.ui.review_extension_candidates': 'Review extension candidates',
  'native.ui.host_error_code': 'Host error code: {code}',
  'native.ui.host_setup_intro_title':
      'Set up this installation as a Ventio Host',
  'native.ui.host_setup_intro_details':
      'This guided setup provisions PostgreSQL, applies Host migrations, registers the Windows services, creates the first Host administrator through the trusted local service, stores its credential securely, and verifies readiness. Windows requests Administrator approval only for the protected setup component.',
  'native.ui.approve_extension_candidate_title': 'Approve extension candidate?',
  'native.ui.approve_extension_candidate_confirmation':
      '{moduleId} {version} will become an approved Host release for this scope.',
  'native.ui.extension_candidate_result': 'Candidate {result}.',
  'native.ui.reject_extension_candidate_title': 'Reject extension candidate',
  'native.ui.approve': 'Approve',
  'native.ui.reject': 'Reject',
  'native.ui.reason': 'Reason',
  'native.ui.extension_rejection_reason_help':
      'The reason is stored in the Host audit record.',
  'native.ui.extension_candidate_review': 'Extension candidate review',
  'native.ui.refresh_candidates': 'Refresh candidates',
  'native.ui.extension_review_explanation':
      'Review declarative extension metadata and its digest before deciding. Ventio does not execute arbitrary package code. Decisions are recorded by the Host and become available to Clients only after approval.',
  'native.ui.extension_review_failed':
      'Review could not be completed. Reference: {reference}',
  'native.ui.no_pending_candidates': 'No pending candidates.',
  'native.ui.submitted_by': 'Submitted by {actorId}',
  'native.ui.submitted_at': 'Submitted {timestamp}',
  'native.ui.package_sha256': 'Package SHA-256',
  'native.ui.extension_name': 'Name: {name}',
  'native.ui.document_types': 'Document types: {types}',
  'native.ui.minimum_platform_api': 'Minimum platform API: {version}',
  'native.ui.extension_self_review_blocked':
      'You submitted this candidate. A different authorized administrator must review it.',
  'native.ui.disable_on_device': 'Disable on device',
  'native.ui.activate_on_device': 'Activate on device',
};
