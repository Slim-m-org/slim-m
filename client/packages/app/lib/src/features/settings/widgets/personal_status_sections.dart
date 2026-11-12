// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The personal settings sections about how this device behaves: push
/// notification status and a link to the voice preferences screen.
///
/// Presence used to live here too. It moved out rather than being duplicated:
/// the rail footer's own status menu already sets both the visibility and the
/// status text, right where a person looks to change them.
library;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart' show isDesktopHost, isLinuxHost;

import '../../../desktop/providers/desktop_message_text_settings.dart';
import '../../modules/providers/module_sound_settings.dart';
import '../providers/notification_sound_settings.dart';
import '../../../providers/app_badge_sync.dart';
import '../../../push/providers/push_controller.dart';
import '../../voice/widgets/call_sounds_card.dart';
import 'notification_schedule_allow_lists.dart';
import '../providers/ui_sound_settings.dart';
import 'notification_schedule_section.dart';
import 'notification_snooze_section.dart';
import 'notification_status_banner.dart';
import 'notification_settings_rows.dart';
import 'settings_section_header.dart';
import 'settings_toggle_row.dart';

/// Only the platforms with a haptic engine get a haptics switch.
bool get isPhoneHaptics =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

/// The Notifications pane; a push registration problem shows as a warning at
/// the top and is silent while push works.
class NotificationsSection extends ConsumerWidget {
  const NotificationsSection({super.key, this.hasPushChannel});

  /// Null asks the host; a desktop shows its own notifications and has no push to report on.
  final bool? hasPushChannel;

  static const bannerKey = Key('notification-push-warning');
  static const badgesOffKey = Key('notification-badges-off');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(pushControllerProvider);
    final soundsEnabled = ref.watch(messageSoundSettingsProvider);
    final moduleSoundsEnabled = ref.watch(moduleSoundSettingsProvider);
    final uiSoundsEnabled = ref.watch(uiSoundSettingsProvider);
    final hapticsEnabled = ref.watch(hapticsSettingsProvider);
    final style = notificationBannerStyle(status);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if ((hasPushChannel ?? !isDesktopHost) && style.warn) ...[
          const SizedBox(height: AppSpacing.s16),
          NotificationStatusBanner(
            key: bannerKey,
            label: status.label,
            warn: style.warn,
            bell: style.bell,
          ),
        ],
        SettingsSectionCard(
          title: 'When to notify',
          children: [
            const NotificationPreferenceRow(),
            if (ref.watch(badgesAllowedProvider).valueOrNull == false)
              const AppListRow(
                key: badgesOffKey,
                label: 'Badges are off',
                subtitle: 'Turn on Badges for slim-m in iOS Settings.',
              ),
            if (isLinuxHost) const _DesktopMessageTextRow(),
            if (pushPreviewPlatforms.contains(defaultTargetPlatform))
              const PushContentPreviewRow(),
            const NotificationScheduleSection(),
          ],
        ),
        const NotificationAlwaysLetThroughSection(),
        const NotificationSnoozeSection(),
        SettingsSectionCard(
          title: 'Sounds',
          children: [
            SettingsToggleRow(
              label: 'Message, mention and error sounds',
              value: soundsEnabled,
              onChanged: (value) => ref
                  .read(messageSoundSettingsProvider.notifier)
                  .setEnabled(value),
              semanticLabel: 'Play a sound for messages, mentions and errors',
            ),
            SettingsToggleRow(
              label: 'Interface sounds',
              description: 'Soft cues for sending, joining and muting.',
              value: uiSoundsEnabled,
              onChanged: (value) =>
                  ref.read(uiSoundSettingsProvider.notifier).setEnabled(value),
              semanticLabel: 'Play soft sounds for sending, joining and muting',
            ),
            if (isPhoneHaptics)
              SettingsToggleRow(
                label: 'Haptics',
                description: 'Vibrate for taps, holds and alerts.',
                value: hapticsEnabled,
                onChanged: (value) => ref
                    .read(hapticsSettingsProvider.notifier)
                    .setEnabled(value),
                semanticLabel: 'Vibrate for taps, holds and alerts',
              ),
            SettingsToggleRow(
              label: 'Dock module sounds',
              description: 'Lets modules play short sounds.',
              value: moduleSoundsEnabled,
              onChanged: (value) => ref
                  .read(moduleSoundSettingsProvider.notifier)
                  .setEnabled(value),
              semanticLabel: 'Let modules play sound effects',
            ),
          ],
        ),
        const CallSoundsCard(),
      ],
    );
  }
}

/// The desktop's own choice of whether a notification shows the message.
class _DesktopMessageTextRow extends ConsumerWidget {
  const _DesktopMessageTextRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsToggleRow(
      label: 'Show message text',
      value: ref.watch(desktopMessageTextProvider),
      semanticLabel: 'Show message text in notifications',
      onChanged: (value) =>
          ref.read(desktopMessageTextProvider.notifier).setEnabled(value),
    );
  }
}

/// Voice call preferences: microphone, screen share quality, and sounds.
/// A separate screen rather than inline rows, matching how much is on it.
