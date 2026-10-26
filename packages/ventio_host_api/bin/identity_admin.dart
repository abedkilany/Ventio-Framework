import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:ventio_host_api/ventio_host_api.dart';

/// Trusted local operator CLI. No administrative HTTP endpoint. The sole argv
/// value is a private request-file path; credentials and database URLs stay out
/// of process arguments, stdout and exception logs.
Future<void> main(List<String> args) async {
  pg.Connection? db;
  try {
    if (args.length != 1) throw ArgumentError('Private request file required');
    final request =
        jsonDecode(await PrivateFiles.read(args.single))
            as Map<String, dynamic>;
    final authority = RecoveryAuthority(
      request['authorityFile'] as String,
      readerGroupId: request['witnessReaderGid'] as int?,
      readerSid: request['witnessReaderSid'] as String?,
    );
    final label = request['operatorLabel'] as String;
    db = await pg.Connection.openFromUrl(
      request['administrationDatabaseUrl'] as String,
    );
    final action = request['action'] as String;
    if (action == 'reset-for-reenrollment') {
      await authority.resetForReenrollment(db, label);
    } else {
      final admin = IdentityAdministration(
        connection: db,
        tenantId: request['tenantId'] as String,
        operatorLabel: label,
        authority: authority,
      );
      final extensionAdmin = ExtensionPackageAdministration(
        connection: db,
        tenantId: request['tenantId'] as String,
        operatorLabel: label,
        authority: authority,
      );
      switch (action) {
        case 'create-user':
          await admin.createUser(request['actorId'] as String);
        case 'register-branch':
          await admin.registerBranch(
            request['companyId'] as String,
            request['branchId'] as String,
          );
        case 'register-device':
          await admin.registerDevice(
            request['actorId'] as String,
            request['deviceId'] as String,
          );
        case 'grant':
          await admin.grant(
            request['actorId'] as String,
            request['companyId'] as String,
            request['branchId'] as String,
            request['permission'] as String,
          );
        case 'revoke-grant':
          await admin.revokeGrant(
            request['actorId'] as String,
            request['companyId'] as String,
            request['branchId'] as String,
            request['permission'] as String,
          );
        case 'create-role':
          await admin.createRole(
            request['roleId'] as String,
            request['displayName'] as String,
          );
        case 'rename-role':
          await admin.renameRole(
            request['roleId'] as String,
            request['displayName'] as String,
          );
        case 'delete-role':
          await admin.deleteRole(request['roleId'] as String);
        case 'grant-role-permission':
          await admin.grantRolePermission(
            request['roleId'] as String,
            request['permission'] as String,
          );
        case 'revoke-role-permission':
          await admin.revokeRolePermission(
            request['roleId'] as String,
            request['permission'] as String,
          );
        case 'assign-role':
          await admin.assignRole(
            actorId: request['actorId'] as String,
            roleId: request['roleId'] as String,
            companyId: request['companyId'] as String,
            branchId: request['branchId'] as String,
          );
        case 'revoke-role-assignment':
          await admin.revokeRoleAssignment(
            actorId: request['actorId'] as String,
            roleId: request['roleId'] as String,
            companyId: request['companyId'] as String,
            branchId: request['branchId'] as String,
          );
        case 'revoke-device':
          await admin.revokeDevice(request['deviceId'] as String);
        case 'revoke-credential':
          await admin.revokeCredential(request['credentialId'] as String);
        case 'disable-user':
          await admin.disableUser(request['actorId'] as String);
        case 'approve-extension':
          await extensionAdmin.approve(
            moduleId: request['moduleId'] as String,
            version: request['version'] as String,
            packageSha256: request['packageSha256'] as String,
          );
        case 'revoke-extension':
          await extensionAdmin.revoke(
            moduleId: request['moduleId'] as String,
            version: request['version'] as String,
            packageSha256: request['packageSha256'] as String,
            reason: request['reason'] as String,
          );
        case 'provision':
          await admin.provisionToFile(
            actorId: request['actorId'] as String,
            deviceId: request['deviceId'] as String,
            credentialId: request['credentialId'] as String,
            expiresAt: DateTime.parse(request['expiresAt'] as String),
            allowedScopes: (request['allowedScopes'] as List)
                .map((s) => Map<String, Object?>.from(s as Map))
                .toList(),
            outputPath: request['outputPath'] as String,
          );
        case 'rotate':
          final previous =
              jsonDecode(
                    await PrivateFiles.read(
                      request['previousCredentialFile'] as String,
                    ),
                  )
                  as Map<String, dynamic>;
          if (previous['tenantId'] != request['tenantId'] ||
              previous['actorId'] != request['actorId'] ||
              previous['deviceId'] != request['deviceId']) {
            throw StateError('Credential recipient does not match');
          }
          await admin.rotateToFile(
            actorId: request['actorId'] as String,
            deviceId: request['deviceId'] as String,
            previousCredentialId: previous['credentialId'] as String,
            previousToken: previous['token'] as String,
            credentialId: request['credentialId'] as String,
            expiresAt: DateTime.parse(request['expiresAt'] as String),
            outputPath: request['outputPath'] as String,
          );
        default:
          throw ArgumentError('Unsupported operation');
      }
    }
    stdout.writeln('{"status":"completed"}');
  } catch (_) {
    stderr.writeln(
      'Credential administration failed. Access may be quarantined; consult the private recovery runbook.',
    );
    exitCode = 2;
  } finally {
    await db?.close();
  }
}
