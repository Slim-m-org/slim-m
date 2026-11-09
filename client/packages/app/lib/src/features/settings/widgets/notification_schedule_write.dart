// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One write to the caller's notification schedule, refreshed on the
/// container so alert policy hears it even if the pane was left mid-save.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/run_guarded.dart';
import '../providers/notification_schedule_controller.dart';
import '../providers/settings_actions.dart';

/// Runs [write] through [guard], then refreshes the schedule on [container], which the caller took before any await
/// so the message alert policy hears the change even if the pane was left.
Future<void> writeNotificationSchedule(
  ProviderContainer container,
  Guard guard, {
  required String whatFailed,
  required Future<void> Function(SettingsActions actions) write,
}) => guard(
  whatFailed: whatFailed,
  action: () async {
    await write(container.read(settingsActionsProvider));
    container.invalidate(notificationScheduleProvider);
  },
);
