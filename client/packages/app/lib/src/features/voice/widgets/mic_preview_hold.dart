// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The screen side of the microphone preview: it runs while one is mounted.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/visible_hold.dart';
import '../providers/mic_preview.dart';
import 'level_display_hold.dart';

/// Keeps the preview capture open while it is mounted and its route is shown,
/// and counts as a displayed meter for the in-call level polling.
class MicPreviewHold extends ConsumerWidget {
  const MicPreviewHold({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(micPreviewProvider.notifier);
    return LevelDisplayHold(
      child: VisibleHold(
        acquire: () {
          if (controller.mounted) controller.acquire();
        },
        release: () {
          if (controller.mounted) controller.release();
        },
        child: _TapToTest(child: child),
      ),
    );
  }
}

/// On a phone the meter stays still until the tap, so the pane never opens the
/// microphone by itself.
class _TapToTest extends ConsumerWidget {
  const _TapToTest({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final needsTap = ref.watch(micPreviewNeedsTapProvider);
    final armed = ref.watch(micPreviewArmedProvider);
    if (!needsTap) return child;
    final controller = ref.read(micPreviewProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        child,
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s16,
            0,
            AppSpacing.s16,
            AppSpacing.s16,
          ),
          child: armed
              ? AppButton(
                  key: micTestStopKey,
                  label: 'Stop test',
                  icon: AppIcons.micOff,
                  variant: AppButtonVariant.secondary,
                  onPressed: controller.stop,
                )
              : AppButton(
                  key: micTestButtonKey,
                  label: 'Test microphone',
                  icon: AppIcons.mic,
                  onPressed: controller.arm,
                ),
        ),
      ],
    );
  }
}

const micTestButtonKey = ValueKey('mic-test-button');
const micTestStopKey = ValueKey('mic-test-stop');
