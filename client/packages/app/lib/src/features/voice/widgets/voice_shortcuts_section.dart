// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Desktop settings "Keybinds": the push-to-talk key, and the call keybinds
/// (mute, deafen, camera, share, leave, call overlay), off until switched on,
/// then each remappable or clearable, with a reset to the defaults.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../screen_overlay/providers/screen_overlay_controller.dart';
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
    final keybinds = ref.watch(shortcutOverridesProvider);
    final voice = ref.read(voiceSettingsControllerProvider.notifier);
    final remap = ref.read(shortcutOverridesProvider.notifier);
    // Absent, never disabled, where this desktop cannot host the overlay window.
    final overlayHosted = ref.watch(screenOverlaySupportedProvider);
    final changed =
        keybinds.overrides.isNotEmpty ||
        settings.pushToTalkKey != kDefaultPushToTalkKey;

    return SettingsSectionCard(
      title: 'Keybinds',
      children: [
        SettingsRowGroup(
          children: [
            SettingsToggleRow(
              label: 'Hold a key to talk',
              description: 'Your mic indicator stays on in calls.',
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
            SettingsToggleRow(
              label: 'Call keybinds',
              description: 'Mute, deafen and more from the keyboard.',
              value: keybinds.enabled,
              semanticLabel: 'Call keybinds',
              onChanged: remap.setEnabled,
            ),
            if (keybinds.enabled)
              for (final action in remappableActions)
                if (action != AppAction.toggleCallOverlay || overlayHosted)
                  _ChordRow(
                    action: action,
                    pushToTalkKey: settings.pushToTalkKey,
                    onChanged: (chord) => remap.set(action, chord),
                    onClear: () => remap.clear(action),
                  ),
            if (keybinds.enabled || settings.pushToTalkEnabled)
              const GlobalHotkeyStatusLine(),
            if (changed && (keybinds.enabled || settings.pushToTalkEnabled))
              Padding(
                padding: const EdgeInsets.all(AppSpacing.s16),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: AppButton(
                    label: 'Reset keybinds',
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

String _shortName(AppAction action) => switch (action) {
  AppAction.toggleMuteCall => 'Mute',
  AppAction.toggleDeafenCall => 'Deafen',
  AppAction.toggleCameraCall => 'Camera',
  AppAction.toggleShareCall => 'Share',
  AppAction.leaveCall => 'Leave',
  AppAction.toggleCallOverlay => 'Call overlay',
  AppAction.markCallMoment => 'Mark the moment',
  _ => action.label,
};

class _ChordRow extends StatelessWidget {
  const _ChordRow({
    required this.action,
    required this.pushToTalkKey,
    required this.onChanged,
    required this.onClear,
  });

  final AppAction action;
  final LogicalKeyboardKey pushToTalkKey;
  final ValueChanged<SingleActivator> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final current = activatorFor(action);
    final name = _shortName(action);
    return KeyCaptureRow(
      title: '$name shortcut',
      keyCap: current is SingleActivator ? chordLabel(current) : 'None',
      semanticName: '$name shortcut',
      clearable: true,
      onClear: current == null ? null : onClear,
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
