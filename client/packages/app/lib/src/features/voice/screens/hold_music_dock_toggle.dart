// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dock's "music while alone" button, drawn only while you are the sole
/// participant. It flips the same persisted setting as Voice settings.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../audio/lounge_tracks.dart';
import '../providers/hold_music_actions.dart';
import '../providers/voice_settings_controller.dart';
import '../../../widgets/control_options_menu.dart';
import '../../../widgets/control_swatch_row.dart' show ControlOptionEntry;
import '../widgets/call_dock_button.dart';

class HoldMusicDockToggle extends ConsumerWidget {
  const HoldMusicDockToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.holdMusicEnabled),
    );
    final track = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.holdMusicTrack),
    );
    final showCaret = !AppTouchTargets.of(context);
    return ControlOptionsMenu(
      active: on,
      optionsLabel: 'Music options',
      showCaret: showCaret,
      opensAbove: true,
      options: [
        const ControlOptionHeading('Style'),
        for (final style in LoungeTrack.values)
          ControlOption(
            label: style.style,
            selected: style == track,
            onSelected: () => pickHoldMusicTrack(ref, style),
          ),
        ControlOption(
          label: 'Next track',
          icon: AppIcons.callSkipNext,
          onSelected: () => pickHoldMusicTrack(ref, track.next),
        ),
      ],
      child: CallDockButton(
        icon: AppIcons.music,
        tooltip: on ? 'Pause music (${track.style})' : 'Play music while alone',
        active: on,
        holdOpensOptions: !showCaret,
        onPressed: () => toggleHoldMusic(ref),
      ),
    );
  }
}

/// The music controls as menu rows, for a dock too narrow to give the button its own slot.
List<ControlOptionEntry> holdMusicMenuOptions(WidgetRef ref) {
  final state = ref.watch(voiceSettingsControllerProvider);
  final on = state.holdMusicEnabled;
  final track = state.holdMusicTrack;
  return [
    const ControlOptionHeading('Music while alone'),
    ControlOption(
      label: on ? 'Pause music' : 'Play music',
      icon: AppIcons.music,
      onSelected: () => toggleHoldMusic(ref),
    ),
    for (final style in LoungeTrack.values)
      ControlOption(
        label: style.style,
        selected: style == track,
        onSelected: () => pickHoldMusicTrack(ref, style),
      ),
    ControlOption(
      label: 'Next track',
      icon: AppIcons.callSkipNext,
      onSelected: () => pickHoldMusicTrack(ref, track.next),
    ),
  ];
}
