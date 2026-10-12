// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop-only switch for pausing incoming video when the window loses focus.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/video_pause.dart';
import '../providers/voice_settings_controller.dart';
import 'settings_section_header.dart';
import 'settings_toggle_row.dart';

class PauseVideoSection extends ConsumerWidget {
  const PauseVideoSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(pauseOnUnfocusedAppliesProvider)) {
      return const SizedBox.shrink();
    }
    final enabled = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.pauseVideoWhenUnfocused),
    );
    return SettingsSectionCard(
      title: 'Video',
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsToggleRow(
          label: 'Pause video when unfocused',
          description: 'Stops incoming video while another window is in front.',
          value: enabled,
          semanticLabel: 'Pause video when slim-m is not focused',
          onChanged: (value) => ref
              .read(voiceSettingsControllerProvider.notifier)
              .setPauseVideoWhenUnfocused(value),
        ),
      ],
    );
  }
}
