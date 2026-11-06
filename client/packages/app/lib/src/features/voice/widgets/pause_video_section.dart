// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop-only switch for pausing video while slim-m is in the background,
/// a row in the Video quality card rather than a card of its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/video_pause.dart';
import '../providers/voice_settings_controller.dart';
import '../../settings/widgets/settings_toggle_row.dart';

class PauseVideoRow extends ConsumerWidget {
  const PauseVideoRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(pauseOnUnfocusedAppliesProvider)) {
      return const SizedBox.shrink();
    }
    final enabled = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.pauseVideoWhenMinimised),
    );
    return SettingsToggleRow(
      label: 'Pause video in the background',
      description:
          "Stops your own previews when unfocused, others' video when minimised.",
      value: enabled,
      semanticLabel: 'Pause video while slim-m is in the background',
      onChanged: (value) => ref
          .read(voiceSettingsControllerProvider.notifier)
          .setPauseVideoWhenMinimised(value),
    );
  }
}
