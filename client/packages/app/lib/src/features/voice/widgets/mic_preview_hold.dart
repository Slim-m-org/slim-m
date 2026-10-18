// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The screen side of the microphone preview: it runs while one is mounted.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
        child: child,
      ),
    );
  }
}
