import 'package:flutter/material.dart';

import 'app_localization.dart';
import 'onboarding_progress.dart';

enum _DeviceRole { host, client }

class FirstRunSetupPage extends StatefulWidget {
  const FirstRunSetupPage({
    required this.onSetUpHost,
    required this.onConnectClient,
    this.onOwnerSetup,
    super.key,
  });

  final VoidCallback onSetUpHost;
  final VoidCallback? onOwnerSetup;
  final ValueChanged<BuildContext> onConnectClient;

  @override
  State<FirstRunSetupPage> createState() => _FirstRunSetupPageState();
}

class _FirstRunSetupPageState extends State<FirstRunSetupPage> {
  _DeviceRole? _selectedRole;

  void _continue() {
    switch (_selectedRole) {
      case _DeviceRole.host:
        widget.onSetUpHost();
        break;
      case _DeviceRole.client:
        widget.onConnectClient(context);
        break;
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              colors.surface,
              Color.alphaBlend(
                colors.primary.withValues(alpha: 0.06),
                colors.surface,
              ),
              Color.alphaBlend(
                colors.primary.withValues(alpha: 0.12),
                colors.surface,
              ),
            ],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 720;

              final hostCard = _RoleCard(
                key: const ValueKey('role-host'),
                icon: Icons.dns_outlined,
                titleKey: 'native.ui.first_run_host_title',
                bodyKey: 'native.ui.first_run_host_details',
                selected: _selectedRole == _DeviceRole.host,
                onTap: () => setState(() => _selectedRole = _DeviceRole.host),
              );

              final clientCard = _RoleCard(
                key: const ValueKey('role-client'),
                icon: Icons.laptop_mac_outlined,
                titleKey: 'native.ui.first_run_client_title',
                bodyKey: 'native.ui.first_run_client_details',
                selected: _selectedRole == _DeviceRole.client,
                onTap: () => setState(() => _selectedRole = _DeviceRole.client),
              );

              return SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight > 48
                        ? constraints.maxHeight - 48
                        : 0,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 920),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 24),
                          Image.asset(
                            'assets/branding/ventio_symbol.png',
                            height: 80,
                            fit: BoxFit.contain,
                          ),
                          const SizedBox(height: 12),
                          VentioText(
                            'native.ui.first_run_title',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                              color: colors.primary,
                            ),
                          ),
                          const SizedBox(height: 24),
                          VentioText(
                            'native.ui.first_run_heading',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: wide ? 42 : 30,
                              fontWeight: FontWeight.w700,
                              color: colors.onSurface,
                            ),
                          ),
                          const SizedBox(height: 12),
                          VentioText(
                            'native.ui.first_run_explanation',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 17,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 24),
                          if (wide)
                            IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(child: hostCard),
                                  const SizedBox(width: 24),
                                  Expanded(child: clientCard),
                                ],
                              ),
                            )
                          else
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                hostCard,
                                const SizedBox(height: 16),
                                clientCard,
                              ],
                            ),
                          const SizedBox(height: 20),
                          SizedBox(
                            width: 240,
                            child: FilledButton(
                              key: const ValueKey(
                                'native.ui.first_run_continue',
                              ),
                              onPressed: _selectedRole == null
                                  ? null
                                  : _continue,
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  VentioText('native.ui.first_run_continue'),
                                  SizedBox(width: 12),
                                  Icon(Icons.arrow_forward_rounded),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          const OnboardingProgress(currentStep: 0),
                          if (widget.onOwnerSetup != null) ...[
                            const SizedBox(height: 24),
                            TextButton(
                              onPressed: widget.onOwnerSetup,
                              child: const VentioText(
                                'native.ui.first_run_advanced_recovery',
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.titleKey,
    required this.bodyKey,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String titleKey;
  final String bodyKey;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? colors.primaryContainer : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked,
                    color: selected ? colors.primary : colors.outline,
                  ),
                ),
                const SizedBox(height: 8),
                Icon(icon, size: 56, color: colors.primary),
                const SizedBox(height: 24),
                VentioText(
                  titleKey,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: 12),
                VentioText(
                  bodyKey,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.5,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
