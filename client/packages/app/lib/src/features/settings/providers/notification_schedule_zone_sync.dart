// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the saved schedule's time zone equal to this device's, so push judges
/// the hours in the zone the person is actually in after travel or a move.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/app_lifecycle.dart';
import '../../../providers/providers.dart';
import 'device_timezone.dart';
import 'notification_schedule_controller.dart';

const _syncedZoneKey = 'notification_schedule_synced_zone';

/// Re-saves the schedule when this device's own zone changed since it last synced it.
///
/// Comparing with the saved zone instead would make two devices in different zones undo each other.
final notificationScheduleZoneSyncProvider = Provider<void>((ref) {
  var running = false;

  Future<void> sync() async {
    final loaded = ref.read(notificationScheduleProvider);
    final schedule = loaded.valueOrNull;
    if (schedule == null || loaded.isLoading || running) return;
    running = true;
    try {
      final zone = await ref.read(deviceTimezoneProvider.future);
      final prefs = await ref.read(preferencesProvider.future);
      final userId = ref.read(sessionProvider).tokens?.userId ?? '';
      final key = '$_syncedZoneKey.$userId';
      final lastSynced = prefs.getString(key) ?? schedule.timezone;
      if (zone == lastSynced) {
        await prefs.setString(key, zone);
        return;
      }
      await ref
          .read(apiProvider)
          .setNotificationSchedule(
            timezone: zone,
            offHoursMode: schedule.offHoursMode,
            days: schedule.days,
          );
      await prefs.setString(key, zone);
      ref.invalidate(notificationScheduleProvider);
    } on Object catch (error, stack) {
      api.reportFailure(
        api.LogTag.platform,
        'follow the device time zone in the notification schedule',
        error,
        stack,
      );
    } finally {
      running = false;
    }
  }

  ref.listen(
    notificationScheduleProvider,
    (_, next) => unawaited(sync()),
    fireImmediately: true,
  );
  ref.listen(appLifecycleProvider, (_, next) {
    if (next == AppLifecycleState.resumed) unawaited(sync());
  });
});
