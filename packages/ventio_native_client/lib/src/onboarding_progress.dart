import 'package:flutter/material.dart';

import 'app_localization.dart';

class OnboardingProgress extends StatelessWidget {
  const OnboardingProgress({required this.currentStep, super.key})
    : assert(currentStep >= 0 && currentStep < 3);

  final int currentStep;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    const labels = [
      'native.ui.onboarding_step_role',
      'native.ui.onboarding_step_setup',
      'native.ui.onboarding_step_sign_in',
    ];

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 17,
                    backgroundColor: i <= currentStep
                        ? colors.primary
                        : colors.surfaceContainerHighest,
                    foregroundColor: i <= currentStep
                        ? colors.onPrimary
                        : colors.onSurfaceVariant,
                    child: i < currentStep
                        ? const Icon(Icons.check, size: 18)
                        : Text('${i + 1}'),
                  ),
                  const SizedBox(height: 10),
                  VentioText(
                    labels[i],
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: i == currentStep
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
