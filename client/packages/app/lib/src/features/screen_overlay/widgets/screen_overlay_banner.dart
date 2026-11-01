// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The always-visible notice, with its one-click off, that viewers can draw on
/// the screen being shared (decision 0096, privacy).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/screen_overlay_controller.dart';

class ScreenOverlayBanner extends ConsumerWidget {
  const ScreenOverlayBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(screenOverlayControllerProvider.select((s) => s.active))) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s12),
      child: AppCallout(
        tone: AppCalloutTone.accent,
        icon: AppIcons.pen,
        child: Row(
          children: [
            const Expanded(child: Text('Viewers can draw on your screen.')),
            const SizedBox(width: AppSpacing.s12),
            AppButton(
              label: 'Turn off',
              size: AppButtonSize.sm,
              onPressed: () =>
                  ref.read(screenOverlayControllerProvider.notifier).turnOff(),
            ),
          ],
        ),
      ),
    );
  }
}
