import 'app_localization.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ventio_core/ventio_core.dart';

import 'extension_store.dart';
import 'host_credentials.dart';
import 'host_extension_packages.dart';
import 'host_setup_windows.dart';

final accountSessionInvalidated = ValueNotifier<int>(0);

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
      await widget.signIn.credentials.clearOfflineAccount(
        widget.signIn.endpoint,
      );
      if (mounted) accountSessionInvalidated.value++;
    } on HostPackageTransportException catch (e) {
      if (mounted) setState(() => error = e.code);
    } catch (_) {
      if (mounted) setState(() => error = 'ACCOUNT_UPDATE_UNAVAILABLE');
    } finally {
      current.clear();
      password.clear();
      confirm.clear();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const VentioText('native.ui.account_my_organization_account')),
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
              decoration: InputDecoration(labelText: context.ventioText('native.ui.account_username')),
            ),
            TextField(
              controller: current,
              enabled: !busy,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(labelText: context.ventioText('native.ui.account_current_password')),
            ),
            TextField(
              controller: password,
              enabled: !busy,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: context.ventioText('native.ui.account_new_password_at_least_15_characters'),
              ),
            ),
            TextField(
              controller: confirm,
              enabled: !busy,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: context.ventioText('native.ui.account_confirm_new_password'),
              ),
            ),
            if (error != null) Text(error!),
            FilledButton(
              onPressed: busy ? null : save,
              child: const VentioText('native.ui.account_change_login_and_lock_ventio'),
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

  Future<DateTime> online(String username, String password) async {
    await credentials.preserveEnrollment(endpoint);
    try {
      final account = await client.account('login', {
        'tenantId': profile.tenantId,
        'username': username,
        'password': password,
      }, enrollment: true);
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
      await credentials.save(endpoint, account['token'] as String);
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
      return expiry.toUtc();
    } on HostPackageTransportException catch (error) {
      // A reachable Host denial must never fall back to stale authorization.
      if (error.statusCode != null &&
          error.statusCode! >= 400 &&
          error.statusCode! < 500) {
        await credentials.clearOfflineAccount(endpoint);
      }
      rethrow;
    }
  }

  Future<DateTime> offline(String username, String password) async {
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
  }
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

  Future<void> submit(bool offline) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final expiry = await (offline
          ? widget.signIn.offline(username.text.trim(), password.text)
          : widget.signIn.online(username.text.trim(), password.text));
      if (mounted) widget.onSignedIn(expiry);
    } on HostPackageTransportException catch (e) {
      if (mounted) setState(() => error = e.code);
    } catch (_) {
      if (mounted) setState(() => error = 'SIGN_IN_UNAVAILABLE');
    } finally {
      password.clear();
      if (mounted) setState(() => busy = false);
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
      password.clear();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const VentioText('native.ui.account_organization_sign_in')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            VentioText('native.ui.account_organization', params: {'tenant': widget.signIn.profile.tenantId}),
            const VentioText(
              'native.ui.account_use_this_organization_s_account_on_an_enrolled_host_or_client_offline_access_expires_eight',
            ),
            TextField(
              controller: username,
              enabled: !busy,
              decoration: InputDecoration(labelText: context.ventioText('native.ui.account_username')),
              autofillHints: const [AutofillHints.username],
            ),
            TextField(
              controller: password,
              enabled: !busy,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(labelText: context.ventioText('native.ui.account_password')),
              onSubmitted: (_) => busy ? null : submit(false),
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            FilledButton(
              onPressed: busy ? null : () => submit(false),
              child: const VentioText('native.ui.account_sign_in_through_host'),
            ),
            OutlinedButton(
              onPressed: busy ? null : () => submit(true),
              child: const VentioText('native.ui.account_sign_in_offline'),
            ),
            TextButton(
              onPressed: busy ? null : initialize,
              child: const VentioText('native.ui.account_finish_first_owner_setup'),
            ),
            OutlinedButton(
              onPressed: busy ? null : widget.onEnroll,
              child: const VentioText('native.ui.account_enroll_another_account_or_organization'),
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
              child: const VentioText('native.ui.account_local_host_owner_setup_and_recovery'),
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
