// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call sounds card, shown under Notifications beside the other sounds.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../audio/hold_music_player.dart' show holdMusicAvailableProvider;
import '../../../audio/lounge_tracks.dart';
import '../../settings/widgets/settings_section_header.dart';
import '../../settings/widgets/settings_select_row.dart';
import '../../settings/widgets/settings_toggle_row.dart';
import '../providers/voice_settings_controller.dart';

class CallSoundsCard extends ConsumerWidget {
  const CallSoundsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(voiceSettingsControllerProvider);

    return SettingsSectionCard(
      title: 'Call sounds',
      children: [
        SettingsToggleRow(
          label: 'Join and leave sounds',
          description: 'Off automatically in busy calls.',
          value: settings.joinLeaveSoundsEnabled,
          semanticLabel: 'Play join and leave sounds',
          onChanged: (value) => ref
              .read(voiceSettingsControllerProvider.notifier)
              .setJoinLeaveSoundsEnabled(value),
        ),
        SettingsToggleRow(
          label: 'Incoming call sound',
          value: settings.callRingSoundEnabled,
          semanticLabel: 'Play a sound for an incoming call',
          onChanged: (value) => ref
              .read(voiceSettingsControllerProvider.notifier)
              .setCallRingSoundEnabled(value),
        ),
        if (ref.watch(holdMusicAvailableProvider)) ...[
          SettingsToggleRow(
            label: 'Music while alone',
            value: settings.holdMusicEnabled,
            semanticLabel: 'Play hold music while alone in a call',
            onChanged: (value) => ref
                .read(voiceSettingsControllerProvider.notifier)
                .setHoldMusicEnabled(value),
          ),
          if (settings.holdMusicEnabled)
            SettingsSelectRow<LoungeTrack>(
              sub: true,
              label: 'Music style',
              value: settings.holdMusicTrack,
              sheetTitle: 'Music style',
              choices: [
                for (final track in LoungeTrack.values)
                  SettingsChoice(
                    value: track,
                    label: '${track.style} - ${track.title}',
                  ),
              ],
              onChanged: (track) => ref
                  .read(voiceSettingsControllerProvider.notifier)
                  .setHoldMusicTrack(track),
            ),
        ],
      ],
    );
  }
}
