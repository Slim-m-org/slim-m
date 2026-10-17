// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Notifications pane with its schedule on and the Voice pane, at a
/// height tall enough to see every card, which the shared pane matrix cuts off.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/notification_preference_controller.dart';
import 'package:slimm_app/src/features/settings/providers/notification_schedule_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';

import 'ui_snapshot_support.dart';
import 'features/voice/voice_snapshot_fixtures.dart'
    show SnapshotVoiceController;

const _schedule = api.NotificationSchedule(
  timezone: 'UTC',
  days: [
    api.NotificationScheduleDay(weekday: 0, startMinute: 540, endMinute: 1020),
    api.NotificationScheduleDay(weekday: 1, startMinute: 540, endMinute: 1020),
    api.NotificationScheduleDay(weekday: 2, startMinute: 540, endMinute: 1020),
    api.NotificationScheduleDay(weekday: 3, startMinute: 540, endMinute: 1020),
    api.NotificationScheduleDay(weekday: 4, startMinute: 540, endMinute: 1020),
  ],
  offHoursMode: api.OffHoursMode.mentions,
  snoozeUntil: null,
  allowedUserIds: ['user-ada'],
  allowedChannelIds: ['c-design'],
);

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in const ['desktop', 'phone-portrait']) {
    for (final pane in const {
      'notifications': 'Notifications',
      'voice': 'Voice & screen share',
    }.entries) {
      for (final end in const [false, true]) {
        testWidgets('${pane.key} with a schedule at $viewport $end', (
          tester,
        ) async {
          await renderSurface(
            tester,
            '/settings',
            viewport,
            'dark',
            'notify-voice-${pane.key}-$viewport${end ? '-end' : ''}',
            overrides: [
              voiceControllerProvider.overrideWith(
                (ref) => SnapshotVoiceController(ref, const VoiceState()),
              ),
              notificationScheduleProvider.overrideWith(
                (ref) async => _schedule,
              ),
              notificationPreferenceProvider.overrideWith(
                (ref) async => api.NotificationPreference.everything,
              ),
            ],
            afterSettle: (tester) async {
              await tester.tap(find.text(pane.value).first);
              await tester.pump();
              if (end) {
                await tester.ensureVisible(
                  find.text(
                    pane.key == 'voice'
                        ? 'Music while alone'
                        : 'Dock module sounds',
                  ),
                );
                await tester.pump();
              }
            },
          );
        });
      }
    }
  }
}
