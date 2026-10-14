// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dock's "music while alone" button, drawn only while you are the sole
/// participant. It flips the same persisted setting as Voice settings.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/hold_music_controller.dart';
import '../providers/voice_settings_controller.dart';
import 'call_dock_button.dart';

class HoldMusicDockToggle extends ConsumerWidget {
  const HoldMusicDockToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.holdMusicEnabled),
    );
    return CallDockButton(
      icon: AppIcons.music,
      tooltip: on
          ? 'Music while alone: on. Turn off'
          : 'Play music while alone',
      active: on,
      onPressed: () {
        unawaited(
          ref
              .read(voiceSettingsControllerProvider.notifier)
              .setHoldMusicEnabled(!on),
        );
        if (!on) ref.read(holdMusicControllerProvider).startNow();
      },
    );
  }
}
