// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The picker's mute button and volume slider for clips heard on this device.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/soundboard_settings.dart';

class SoundboardVolumeRow extends ConsumerWidget {
  const SoundboardVolumeRow({super.key});

  static const muteKey = Key('soundboard-mute');
  static const sliderKey = Key('soundboard-volume');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(soundboardSoundsProvider);
    final volume = ref.watch(soundboardVolumeProvider);
    return AppMenuControl(
      child: Row(
        spacing: AppSpacing.s8,
        children: [
          AppIconButton(
            key: muteKey,
            icon: on ? AppIcons.speaker : AppIcons.speakerOff,
            semanticLabel: on ? 'Mute soundboard' : 'Unmute soundboard',
            tooltip: on ? 'Mute soundboard' : 'Unmute soundboard',
            size: AppIconButtonSize.sm,
            onPressed: () =>
                ref.read(soundboardSoundsProvider.notifier).setEnabled(!on),
          ),
          Expanded(
            child: AppSlider(
              key: sliderKey,
              value: volume * 100,
              semanticLabel: 'Soundboard volume',
              valueLabel: (v) => '${v.round()}%',
              onChanged: on
                  ? (v) => ref
                        .read(soundboardVolumeProvider.notifier)
                        .setVolume(v / 100)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
