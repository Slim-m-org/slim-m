// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The caller's own notification schedule: a real `GET` backs this, not a
/// local echo, the same reasoning [notificationPreferenceProvider] already
/// documents. Kept alive for the whole signed-in session, not only while the
/// settings screen is mounted - `home_shell.dart` force-watches it the same
/// way it already does [channelNotificationOverridesProvider], because both
/// `notification_sound_controller.dart` and `desktop_message_notifier.dart`
/// need the current schedule for every live message, not only while
/// Settings happens to be open.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

/// `null` means never configured - see
/// `store/notification_schedule.rs`'s own doc comment for why that is
/// distinct from a schedule with every weekday empty.
final notificationScheduleProvider =
    FutureProvider.autoDispose<api.NotificationSchedule?>(
      (ref) => ref.watch(apiProvider).notificationSchedule(),
    );
