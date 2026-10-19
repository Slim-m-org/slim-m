// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Voice settings "Shortcuts": the push-to-talk key and the mute and deafen
/// chords, each remappable, with a reset to the defaults. Desktop only.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../settings/widgets/settings_hairline.dart';
import '../../settings/widgets/settings_section_header.dart';
import '../../settings/widgets/settings_toggle_row.dart';
import '../providers/shortcut_overrides.dart';
import '../providers/voice_settings_controller.dart';
import 'global_hotkey_rows.dart';
import 'key_capture_row.dart';
import 'push_to_talk_key_row.dart';

class VoiceShortcutsSection extends ConsumerWidget {
  const VoiceShortcutsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isDesktopHost) return const SizedBox.shrink();
    final settings = ref.watch(voiceSettingsControllerProvider);
    final overrides = ref.watch(shortcutOverridesProvider);
    final voice = ref.read(voiceSettingsControllerProvider.notifier);
    final remap = ref.read(shortcutOverridesProvider.notifier);
    final changed =
        overrides.isNotEmpty || settings.pushToTalkKey != kDefaultPushToTalkKey;

    return SettingsSectionCard(
      title: 'Shortcuts',
      children: [
        SettingsRowGroup(
          children: [
            SettingsToggleRow(
              label: 'Hold a key to talk',
              description:
                  'Hold the key to talk; your mic stays on between presses.',
              value: settings.pushToTalkEnabled,
              semanticLabel: 'Push-to-talk',
              onChanged: voice.setPushToTalkEnabled,
            ),
            if (settings.pushToTalkEnabled)
              PushToTalkKeyRow(
                current: settings.pushToTalkKey,
                conflictFor: pushToTalkConflict,
                onChanged: voice.setPushToTalkKey,
              ),
            for (final action in remappableActions)
              _ChordRow(
                action: action,
                pushToTalkKey: settings.pushToTalkKey,
                onChanged: (chord) => remap.set(action, chord),
              ),
            const GlobalHotkeyStatusLine(),
            if (changed)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.s16),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: AppButton(
                    label: 'Reset shortcuts',
                    size: AppButtonSize.sm,
                    variant: AppButtonVariant.secondary,
                    onPressed: () {
                      remap.reset();
                      voice.setPushToTalkKey(kDefaultPushToTalkKey);
                    },
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _ChordRow extends StatelessWidget {
  const _ChordRow({
    required this.action,
    required this.pushToTalkKey,
    required this.onChanged,
  });

  final AppAction action;
  final LogicalKeyboardKey pushToTalkKey;
  final ValueChanged<SingleActivator> onChanged;

  @override
  Widget build(BuildContext context) {
    final current = activatorFor(action);
    final name = action == AppAction.toggleMuteCall ? 'Mute' : 'Deafen';
    return KeyCaptureRow(
      title: '$name shortcut',
      keyCap: current is SingleActivator ? chordLabel(current) : 'None',
      semanticName: '$name shortcut',
      onCapture: (captured) {
        final chord = captured.activator;
        final broken = shortcutRuleViolation(chord);
        if (broken != null) return broken;
        final conflict = shortcutConflict(
          chord: chord,
          action: action,
          pushToTalkKey: pushToTalkKey,
        );
        if (conflict != null) return 'Already used for $conflict.';
        onChanged(chord);
        return null;
      },
    );
  }
}
