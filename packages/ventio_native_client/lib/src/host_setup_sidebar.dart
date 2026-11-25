import 'package:flutter/material.dart';

import 'app_localization.dart';

class HostSetupSidebar extends StatelessWidget {
  const HostSetupSidebar({required this.currentStep, super.key});

  final int currentStep;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    const titles = [
      'native.ui.host_wizard_organization',
      'native.ui.host_wizard_owner',
      'native.ui.host_wizard_prepare',
    ];

    const descriptions = [
      'native.ui.host_wizard_organization_details',
      'native.ui.host_wizard_owner_details',
      'native.ui.host_wizard_prepare_details',
    ];

    const icons = [
      Icons.business_outlined,
      Icons.person_outline,
      Icons.dns_outlined,
    ];

    return Container(
      width: 260,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(right: BorderSide(color: colors.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Image.asset(
                'assets/branding/ventio_symbol.png',
                width: 64,
                height: 64,
              ),
              const SizedBox(width: 12),
              VentioText(
                'native.ui.host_wizard_brand',
                style: TextStyle(
                  color: colors.primary,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 40),
          const VentioText(
            'native.ui.host_wizard_title',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 28),
          for (var i = 0; i < titles.length; i++) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: i == currentStep
                    ? colors.primary.withValues(alpha: 0.10)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(
                    i < currentStep ? Icons.check_circle_outline : icons[i],
                    color: i <= currentStep
                        ? colors.primary
                        : colors.onSurfaceVariant,
                    size: 26,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        VentioText(
                          titles[i],
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: i == currentStep
                                ? colors.primary
                                : colors.onSurface,
                          ),
                        ),
                        const SizedBox(height: 5),
                        VentioText(
                          descriptions[i],
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}
