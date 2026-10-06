// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Brings what decides who and what can alert this device back in line with
/// the server when the socket connects.
///
/// The block list, the per-channel overrides, the notification schedule and the
/// account preference are each fetched once, and a change made on another
/// device while this one was offline arrives as a frame nobody replays.
/// Without this a failed first fetch (launching offline, a 500) left them
/// empty until the app restarted: blocked authors' messages showed everywhere
/// and muted channels kept chiming.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'blocks_controller.dart';
import 'channel_notification_overrides_controller.dart';
import 'notification_preference_controller.dart';
import 'notification_schedule_controller.dart';

/// Refetches the block list, the channel overrides, the schedule and the
/// account preference.
///
/// On the first connect of a session only what failed or never answered is
/// refetched, since each already fetched once on its own; after a reconnect all
/// are, because what changed meanwhile is exactly what a dropped socket loses.
/// One nothing has built yet is left alone: it will fetch itself when something
/// first reads it.
void refreshAccountNotificationState(Ref ref, {required bool reconnect}) {
  if (ref.exists(blocksProvider)) {
    final blocks = ref.read(blocksProvider);
    if (reconnect || !blocks.settled || blocks.error != null) {
      unawaited(ref.read(blocksProvider.notifier).refresh());
    }
  }
  if (ref.exists(channelNotificationOverridesProvider)) {
    final overrides = ref.read(channelNotificationOverridesProvider);
    if (reconnect || !overrides.settled || overrides.error != null) {
      unawaited(
        ref.read(channelNotificationOverridesProvider.notifier).refresh(),
      );
    }
  }
  if (ref.exists(notificationScheduleProvider) &&
      (reconnect || ref.read(notificationScheduleProvider).hasError)) {
    ref.invalidate(notificationScheduleProvider);
  }
  if (ref.exists(notificationPreferenceProvider) &&
      (reconnect || ref.read(notificationPreferenceProvider).hasError)) {
    ref.invalidate(notificationPreferenceProvider);
  }
}
