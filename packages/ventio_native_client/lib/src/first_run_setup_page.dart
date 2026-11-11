import 'package:flutter/material.dart';

import 'app_localization.dart';

class FirstRunSetupPage extends StatelessWidget {
  const FirstRunSetupPage({
    required this.onSetUpHost,
    required this.onConnectClient,
    super.key,
  });

  final VoidCallback onSetUpHost;
  final ValueChanged<BuildContext> onConnectClient;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const VentioText('native.ui.first_run_title')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const SizedBox(height: 28),
              const Icon(Icons.hub_outlined, size: 56),
              const SizedBox(height: 20),
              const VentioText(
                'native.ui.first_run_heading',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const VentioText(
                'native.ui.first_run_explanation',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              _ChoiceCard(
                icon: Icons.dns_outlined,
                titleKey: 'native.ui.first_run_host_title',
                bodyKey: 'native.ui.first_run_host_details',
                actionKey: 'native.ui.first_run_continue',
                onPressed: onSetUpHost,
              ),
              const SizedBox(height: 16),
              _ChoiceCard(
                icon: Icons.devices_outlined,
                titleKey: 'native.ui.first_run_client_title',
                bodyKey: 'native.ui.first_run_client_details',
                actionKey: 'native.ui.first_run_connect',
                onPressed: () => onConnectClient(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.icon,
    required this.titleKey,
    required this.bodyKey,
    required this.actionKey,
    required this.onPressed,
  });

  final IconData icon;
  final String titleKey;
  final String bodyKey;
  final String actionKey;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 12),
                Expanded(child: VentioText(titleKey)),
              ],
            ),
            const SizedBox(height: 12),
            VentioText(bodyKey),
            const SizedBox(height: 16),
            FilledButton(
              key: ValueKey(actionKey),
              onPressed: onPressed,
              child: VentioText(actionKey),
            ),
          ],
        ),
      ),
    );
  }
}
