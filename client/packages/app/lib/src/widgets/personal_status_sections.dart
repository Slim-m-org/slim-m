// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The personal settings sections about how this device behaves: push
/// notification status and a link to the voice preferences screen.
///
/// Presence used to live here too. It moved out rather than being duplicated:
/// the rail footer's own status menu already sets both the visibility and the
/// status text, right where a person looks to change them.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart'
    show LocalAlertChannel, isAndroidHost, isLinuxHost;

import '../providers/desktop_message_text_settings.dart';
import '../features/modules/providers/module_sound_settings.dart';
import '../providers/notification_sound_settings.dart';
import '../providers/push_controller.dart';
import '../providers/toasts.dart';
import 'notification_schedule_allow_lists.dart';
import 'notification_schedule_section.dart';
import 'notification_snooze_section.dart';
import 'notification_status_banner.dart';
import 'notification_settings_rows.dart';
import 'settings_section_header.dart';
import 'settings_toggle_row.dart';

/// Whether this device is registered for push, read plainly off the state
/// [PushController] tracks: this is what makes a registration problem
/// diagnosable from the device itself, instead of guessing from server logs.
class NotificationsSection extends ConsumerWidget {
  const NotificationsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(pushControllerProvider);
    final soundsEnabled = ref.watch(messageSoundSettingsProvider);
    final moduleSoundsEnabled = ref.watch(moduleSoundSettingsProvider);
    // The Linux desktop shows its own notifications and never has push, so any push status would be the wrong answer there.
    final localOnly = isLinuxHost;
    final style = notificationBannerStyle(status, localOnly: localOnly);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.s16),
        NotificationStatusBanner(
          label: localOnly ? 'Shown while slim-m is running' : status.label,
          warn: style.warn,
          bell: style.bell,
        ),
        SettingsSectionCard(
          title: 'When to notify',
          children: [
            const NotificationPreferenceRow(),
            if (isLinuxHost) const _DesktopMessageTextRow(),
            if (defaultTargetPlatform == TargetPlatform.iOS)
              const PushContentPreviewRow(),
            const NotificationScheduleSection(),
            const _TestNotificationRow(),
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

/// A button that posts a local notification straight away, so someone can
/// confirm slim-m's notifications reach their OS - most useful on the Linux
/// desktop, where there is no remote push to fall back on and a silent
/// failure is otherwise invisible.
class _TestNotificationRow extends ConsumerWidget {
  const _TestNotificationRow();

  // Only where a local notification actually displays (Android, Linux desktop); a pipe test via the same LocalNotifications.show path a real alert uses.
  static bool get _supported => isAndroidHost || isLinuxHost;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppListRow(
      label: 'Test notification',
      subtitle: 'Check that notifications reach you.',
      trailing: AppButton(
        label: 'Send test',
        size: AppButtonSize.sm,
        variant: AppButtonVariant.secondary,
        onPressed: _supported
            ? () {
                unawaited(
                  ref
                      .read(localNotificationsProvider)
                      .show(
                        'Test notification - if you can see this, slim-m can '
                        'reach your notifications.',
                        channel: LocalAlertChannel.messages,
                      ),
                );
                ref
                    .read(toastsProvider.notifier)
                    .show('Test notification sent.');
              }
            : null,
      ),
    );
  }
}

/// Voice call preferences: microphone, screen share quality, and sounds.
/// A separate screen rather than inline rows, matching how much is on it.
