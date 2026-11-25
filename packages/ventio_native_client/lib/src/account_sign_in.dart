import 'app_localization.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ventio_core/ventio_core.dart';

import 'extension_store.dart';
import 'host_credentials.dart';
import 'host_extension_packages.dart';
import 'host_setup_windows.dart';

final accountSessionInvalidated = ValueNotifier<int>(0);

Future<void> invalidateLocalAccountSession(
  HostCredentialVault vault,
  Uri endpoint,
) async {
  try {
    await vault.runSessionMutation(() async {
      vault.invalidateSessionGeneration();
      await vault.markLogoutPending(endpoint);
      await vault.clearOfflineAccount(endpoint);
    });
  } finally {
    accountSessionInvalidated.value++;
  }
}

class AccountLoginSettingsPage extends StatefulWidget {
  const AccountLoginSettingsPage({required this.signIn, super.key});
  final AccountSignIn signIn;
  @override
  State<AccountLoginSettingsPage> createState() =>
      _AccountLoginSettingsPageState();
}

class _AccountLoginSettingsPageState extends State<AccountLoginSettingsPage> {
  final username = TextEditingController(),
      current = TextEditingController(),
      password = TextEditingController(),
      confirm = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    username.dispose();
    current.dispose();
    password.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!AccountPassword.validUsername(username.text.trim()) ||
        !AccountPassword.validPassword(password.text) ||
        password.text != confirm.text) {
      setState(() => error = 'Check username and password confirmation.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.signIn.client.account('manage', {
        'action': 'SET_LOGIN',
        'username': username.text.trim(),
        'currentPassword': current.text,
        'password': password.text,
      });
      await invalidateLocalAccountSession(
        widget.signIn.credentials,
        widget.signIn.endpoint,
      );
    } on HostPackageTransportException catch (e) {
      if (mounted) setState(() => error = e.code);
    } catch (_) {
      if (mounted) setState(() => error = 'ACCOUNT_UPDATE_UNAVAILABLE');
    } finally {
      if (mounted) {
        current.clear();
        password.clear();
        confirm.clear();
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const VentioText('native.ui.account_my_organization_account'),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const VentioText(
              'native.ui.account_changing_your_login_requires_the_online_host_enter_your_chosen_username_and_current_passwo',
            ),
            TextField(
              controller: username,
              enabled: !busy,
              decoration: InputDecoration(
                labelText: context.ventioText('native.ui.account_username'),
              ),
            ),
            TextField(
              controller: current,
              enabled: !busy,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: context.ventioText(
                  'native.ui.account_current_password',
                ),
              ),
            ),
            TextField(
              controller: password,
              enabled: !busy,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: context.ventioText(
                  'native.ui.account_new_password_at_least_15_characters',
                ),
              ),
            ),
            TextField(
              controller: confirm,
              enabled: !busy,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: context.ventioText(
                  'native.ui.account_confirm_new_password',
                ),
              ),
            ),
            if (error != null) Text(error!),
            FilledButton(
              onPressed: busy ? null : save,
              child: const VentioText(
                'native.ui.account_change_login_and_lock_ventio',
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class AccountSignIn {
  AccountSignIn({
    required this.credentials,
    required this.profile,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final HostCredentialVault credentials;
  final HostConnectionProfile profile;
  final DateTime Function() clock;
  Uri get endpoint => Uri.parse(profile.endpoint);
  HostExtensionPackageClient get client =>
      HostExtensionPackageClient(endpoint: endpoint, credentials: credentials);

  /// Prefer the Host; only transport unavailability permits offline fallback.
  Future<DateTime> signIn(String username, String password) async {
    int? attemptedGeneration;
    try {
      return await online(
        username,
        password,
        onAttempt: (generation) => attemptedGeneration = generation,
      );
    } on HostPackageTransportException catch (error) {
      if (error.statusCode != null ||
          !const {
            'HOST_UNREACHABLE',
            'HOST_REQUEST_TIMEOUT',
          }.contains(error.code)) {
        rethrow;
      }
      if (attemptedGeneration == null) rethrow;
      return offline(
        username,
        password,
        expectedGeneration: attemptedGeneration,
      );
    }
  }

  Future<DateTime> online(
    String username,
    String password, {
    void Function(int)? onAttempt,
  }) async {
    if (await credentials.isLogoutPending(endpoint)) {
      throw const HostPackageTransportException('SESSION_CLEANUP_PENDING');
    }
    final (generation, enrollmentToken) = await credentials.runSessionMutation(
      () async {
        if (await credentials.isLogoutPending(endpoint)) {
          throw const HostPackageTransportException('SESSION_CLEANUP_PENDING');
        }

        await credentials.preserveEnrollment(endpoint);
        final enrollment = await credentials.readEnrollment(endpoint);
        if (enrollment == null) {
          throw const HostPackageTransportException('HOST_CREDENTIAL_MISSING');
        }
        credentials.invalidateSessionGeneration();
        return (credentials.sessionGeneration, enrollment);
      },
    );
    onAttempt?.call(generation);
    try {
      final account = await client.account('login', {
        'tenantId': profile.tenantId,
        'username': username,
        'password': password,
      }, tokenOverride: enrollmentToken);
      final expiry = DateTime.tryParse(account['expiresAt'] as String? ?? '');
      final now = clock().toUtc();
      if (account['tenantId'] != profile.tenantId ||
          account['actorId'] != profile.actorId ||
          account['deviceId'] != profile.deviceId ||
          expiry == null ||
          !expiry.isAfter(now) ||
          expiry.isAfter(now.add(const Duration(hours: 8, minutes: 1))) ||
          account['token'] is! String) {
        throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
      }
      final verifier = await AccountPassword.hash(password);
      return await credentials.runSessionMutation(() async {
        final issuedToken = account['token'] as String;

        if (credentials.sessionGeneration != generation ||
            await credentials.isLogoutPending(endpoint) ||
            await credentials.readEnrollment(endpoint) != enrollmentToken ||
            !expiry.isAfter(clock().toUtc())) {
          await credentials.queueSessionRevocation(endpoint, issuedToken);

          throw const HostPackageTransportException('SESSION_UNAVAILABLE');
        }

        if (!RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(issuedToken) ||
            issuedToken == enrollmentToken) {
          throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
        }

        // Keep sign-in blocked across a restart until both writes complete.
        final previousToken = await credentials.read(endpoint);
        await credentials.markLogoutPending(endpoint);
        try {
          if (previousToken != null &&
              previousToken != enrollmentToken &&
              previousToken != issuedToken) {
            await credentials.queueSessionRevocation(endpoint, previousToken);
          }
          await credentials.save(endpoint, issuedToken);
          await credentials.writeOfflineAccount(endpoint, {
            'tenantId': profile.tenantId,
            'actorId': profile.actorId,
            'deviceId': profile.deviceId,
            'username': username.toLowerCase(),
            'verifier': verifier,
            'expiresAt': expiry.toUtc().toIso8601String(),
            'lastSeen': now.toIso8601String(),
            'identity': account['identity'],
            'failures': 0,
          });
          await credentials.clearLogoutPending(endpoint);
        } catch (_) {
          credentials.invalidateSessionGeneration();
          // If cleanup fails, leave the durable marker for startup recovery.
          await credentials.queueSessionRevocation(endpoint, issuedToken);
          await credentials.clearAccountSession(endpoint);
          await credentials.clearLogoutPending(endpoint);
          rethrow;
        }
        return expiry.toUtc();
      });
    } on HostPackageTransportException catch (error) {
      // A reachable Host denial must never fall back to stale authorization.
      if (error.statusCode != null &&
          error.statusCode! >= 400 &&
          error.statusCode! < 500) {
        await credentials.runSessionMutation(() async {
          if (credentials.sessionGeneration == generation) {
            await credentials.clearOfflineAccount(endpoint);
          }
        });
      }
      rethrow;
    }
  }

  Future<void> logout() async {
    await credentials.runSessionMutation(() async {
      credentials.invalidateSessionGeneration();
      await credentials.markLogoutPending(endpoint);

      final token = await credentials.read(endpoint);
      final enrollment = await credentials.readEnrollment(endpoint);

      if (token != null && token != enrollment) {
        await credentials.queueSessionRevocation(endpoint, token);
      }

      await credentials.clearAccountSession(endpoint);
      await credentials.clearLogoutPending(endpoint);
    });

    await flushPendingSessionRevocations();
  }

  Future<void> flushPendingSessionRevocations() =>
      credentials.runSessionRevocationFlush(() async {
        final pending = await credentials.readPendingSessionRevocations(
          endpoint,
        );

        for (final token in pending) {
          try {
            await client.revokeAccountSession(token);
          } on HostPackageTransportException {
            continue;
          }

          await credentials.removePendingSessionRevocation(endpoint, token);
        }
      });

  Future<DateTime> refreshSession() async {
    final generation = credentials.sessionGeneration;
    if (await credentials.isLogoutPending(endpoint)) {
      throw const HostPackageTransportException('SESSION_CLEANUP_PENDING');
    }
    final token = await credentials.read(endpoint);
    final cache = await credentials.readOfflineAccount(endpoint);

    if (token == null ||
        cache == null ||
        cache['tenantId'] != profile.tenantId ||
        cache['actorId'] != profile.actorId ||
        cache['deviceId'] != profile.deviceId) {
      throw const HostPackageTransportException('SESSION_UNAVAILABLE');
    }

    final account = await client.refreshAccountSession(token);

    final now = clock().toUtc();
    final expiry = DateTime.tryParse(
      account['expiresAt'] as String? ?? '',
    )?.toUtc();

    if (account['tenantId'] != profile.tenantId ||
        account['actorId'] != profile.actorId ||
        account['deviceId'] != profile.deviceId ||
        account['identity'] is! Map ||
        expiry == null ||
        !expiry.isAfter(now) ||
        expiry.isAfter(now.add(const Duration(hours: 8, minutes: 1)))) {
      throw const HostPackageTransportException('HOST_INVALID_RESPONSE');
    }

    return credentials.runSessionMutation(() async {
      if (credentials.sessionGeneration != generation ||
          await credentials.isLogoutPending(endpoint) ||
          await credentials.read(endpoint) != token) {
        throw const HostPackageTransportException('SESSION_UNAVAILABLE');
      }

      final current = await credentials.readOfflineAccount(endpoint);

      if (current == null ||
          current['tenantId'] != profile.tenantId ||
          current['actorId'] != profile.actorId ||
          current['deviceId'] != profile.deviceId ||
          current['verifier'] != cache['verifier'] ||
          current['username'] != cache['username']) {
        throw const HostPackageTransportException('SESSION_UNAVAILABLE');
      }

      await credentials.writeOfflineAccount(endpoint, {
        ...current,
        'expiresAt': expiry.toIso8601String(),
        'lastSeen': now.toIso8601String(),
        'identity': account['identity'],
      });

      return expiry;
    });
  }

  Future<DateTime> offline(
    String username,
    String password, {
    int? expectedGeneration,
  }) => credentials.runSessionMutation(() async {
    if (expectedGeneration != null &&
        credentials.sessionGeneration != expectedGeneration) {
      throw const HostPackageTransportException('SESSION_UNAVAILABLE');
    }
    if (await credentials.isLogoutPending(endpoint)) {
      throw const HostPackageTransportException('SESSION_CLEANUP_PENDING');
    }
    final cache = await credentials.readOfflineAccount(endpoint);
    final now = clock().toUtc();
    final expiry = DateTime.tryParse(cache?['expiresAt'] as String? ?? '');
    final last = DateTime.tryParse(cache?['lastSeen'] as String? ?? '');
    if (cache == null ||
        cache['tenantId'] != profile.tenantId ||
        cache['actorId'] != profile.actorId ||
        cache['deviceId'] != profile.deviceId ||
        cache['username'] != username.toLowerCase() ||
        expiry == null ||
        last == null ||
        now.isBefore(last) ||
        !expiry.isAfter(now) ||
        expiry.difference(last) > const Duration(hours: 8, minutes: 1) ||
        cache['verifier'] is! String ||
        (cache['failures'] as int? ?? 0) >= 5) {
      throw const HostPackageTransportException('OFFLINE_SIGN_IN_UNAVAILABLE');
    }
    cache['lastSeen'] = now.toIso8601String();
    cache['failures'] = (cache['failures'] as int? ?? 0) + 1;
    await credentials.writeOfflineAccount(endpoint, cache);
    if (!await AccountPassword.verify(password, cache['verifier'] as String)) {
      throw const HostPackageTransportException('SIGN_IN_DENIED');
    }
    cache['failures'] = 0;
    await credentials.writeOfflineAccount(endpoint, cache);
    return expiry;
  });
}

class AccountSignInPage extends StatefulWidget {
  const AccountSignInPage({
    required this.signIn,
    required this.onSignedIn,
    this.onEnroll,
    super.key,
  });
  final AccountSignIn signIn;
  final ValueChanged<DateTime> onSignedIn;
  final VoidCallback? onEnroll;
  @override
  State<AccountSignInPage> createState() => _AccountSignInPageState();
}

class _AccountSignInPageState extends State<AccountSignInPage> {
  final username = TextEditingController(), password = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    username.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final expiry = await widget.signIn.signIn(
        username.text.trim(),
        password.text,
      );
      if (mounted) widget.onSignedIn(expiry);
    } on HostPackageTransportException catch (e) {
      if (mounted) setState(() => error = e.code);
    } catch (_) {
      if (mounted) setState(() => error = 'SIGN_IN_UNAVAILABLE');
    } finally {
      if (mounted) {
        password.clear();
        setState(() => busy = false);
      }
    }
  }

  Future<void> initialize() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final self = await widget.signIn.client.account('manage', {
        'action': 'SELF',
      });
      if (self['isOwner'] != true || self['needsPassword'] != true) {
        throw const HostPackageTransportException(
          'LOCAL_OWNER_MIGRATION_REQUIRED',
        );
      }
      await widget.signIn.credentials.preserveEnrollment(
        widget.signIn.endpoint,
      );
      await widget.signIn.client.account('manage', {
        'action': 'SET_LOGIN',
        'username': username.text.trim(),
        'password': password.text,
      });
      final expiry = await widget.signIn.online(
        username.text.trim(),
        password.text,
      );
      if (mounted) widget.onSignedIn(expiry);
    } on HostPackageTransportException catch (e) {
      if (mounted) setState(() => error = e.code);
    } catch (_) {
      if (mounted) setState(() => error = 'ACCOUNT_SETUP_UNAVAILABLE');
    } finally {
      if (mounted) {
        password.clear();
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const VentioText('native.ui.account_organization_sign_in'),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            VentioText(
              'native.ui.account_organization',
              params: {'tenant': widget.signIn.profile.tenantId},
            ),
            const VentioText(
              'native.ui.account_use_this_organization_s_account_on_an_enrolled_host_or_client_offline_access_expires_eight',
            ),
            TextField(
              controller: username,
              enabled: !busy,
              decoration: InputDecoration(
                labelText: context.ventioText('native.ui.account_username'),
              ),
              autofillHints: const [AutofillHints.username],
            ),
            TextField(
              controller: password,
              enabled: !busy,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: context.ventioText('native.ui.account_password'),
              ),
              onSubmitted: (_) => busy ? null : submit(),
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            FilledButton(
              onPressed: busy ? null : () => submit(),
              child: const VentioText('native.ui.account_sign_in_through_host'),
            ),
            TextButton(
              onPressed: busy ? null : initialize,
              child: const VentioText(
                'native.ui.account_finish_first_owner_setup',
              ),
            ),
            OutlinedButton(
              onPressed: busy ? null : widget.onEnroll,
              child: const VentioText(
                'native.ui.account_enroll_another_account_or_organization',
              ),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      try {
                        await launchOwnerRecovery();
                      } catch (_) {
                        if (mounted) {
                          setState(
                            () => error = 'LOCAL_OWNER_SETUP_UNAVAILABLE',
                          );
                        }
                      }
                    },
              child: const VentioText(
                'native.ui.account_local_host_owner_setup_and_recovery',
              ),
            ),
            const VentioText(
              'native.ui.account_existing_installation_without_an_owner_use_ventio_organization_owner_setup_and_recovery_on',
            ),
            if (busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    ),
  );
}
