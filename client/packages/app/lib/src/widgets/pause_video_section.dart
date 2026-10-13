// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop-only switch for pausing incoming video when the window loses focus,
/// a row in the Video quality card rather than a card of its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/video_pause.dart';
import '../providers/voice_settings_controller.dart';
import 'settings_toggle_row.dart';

class PauseVideoRow extends ConsumerWidget {
  const PauseVideoRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(pauseOnUnfocusedAppliesProvider)) {
      return const SizedBox.shrink();
    }
    final enabled = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.pauseVideoWhenUnfocused),
    );
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s8),
      child: SettingsToggleRow(
        label: 'Pause video when unfocused',
        description: 'Stops incoming video while another window is in front.',
        value: enabled,
        semanticLabel: 'Pause video when slim-m is not focused',
        onChanged: (value) => ref
            .read(voiceSettingsControllerProvider.notifier)
            .setPauseVideoWhenUnfocused(value),
      ),
    );
  }
}
