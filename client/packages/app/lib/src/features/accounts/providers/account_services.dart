// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What one container runs for its whole life, shown or not.
/// See docs/decisions/0068-multiple-servers-in-one-app.md.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/desktop_message_notifier.dart';
import '../../../providers/direct_route_controller.dart';
import '../../../providers/providers.dart';
import '../../../providers/push_controller.dart';
import '../../../providers/retention_sweep.dart';
import '../../../providers/sync_controller.dart';
import '../../channels/providers/channel_notification_overrides_controller.dart';
import '../../members/providers/activity_publisher.dart';
import '../../members/providers/blocks_controller.dart';
import '../../settings/providers/notification_schedule_controller.dart';
import '../../settings/providers/notification_sound_controller.dart';
import '../../voice/providers/hold_music_controller.dart';
import '../../voice/providers/voice_controller.dart';
import '../../../providers/admin_providers.dart';

/// Brings up sync, push, notifications and the session-lifetime watchers the
/// home shell holds while it is mounted, so an account out of view keeps
/// receiving, counting unread and notifying.
void startAccountServices(ProviderContainer container) {
  container.read(syncControllerProvider);
  container.read(pushControllerProvider);
  container.read(directRouteProvider);
  container.read(desktopMessageNotifierProvider);
  container.listen(blocksProvider, (_, _) {});
  container.listen(channelNotificationOverridesProvider, (_, _) {});
  container.listen(roleChangeWatcherProvider, (_, _) {});
  container.listen(notificationSoundControllerProvider, (_, _) {});
  container.listen(holdMusicControllerProvider, (_, _) {});
  container.listen(activityPublisherProvider, (_, _) {});
  container.listen(notificationScheduleProvider, (_, _) {});
  container.listen(retentionSweepControllerProvider, (_, _) {});
}

/// Reads a provider; both a [WidgetRef] and a [ProviderContainer] offer it.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// Push is unregistered before the session goes, or this device keeps waking
/// for an account that is no longer signed in on it.
///
/// A live call is left first for the same reason: nothing else would stop it
/// POSTing a heartbeat, on a cleared session, for the rest of the process's life.
Future<void> signOutVia(ProviderReader read) async {
  await read(voiceControllerProvider.notifier).leave();
  await read(syncControllerProvider.notifier).stop();
  await read(pushControllerProvider.notifier).unregister();
  try {
    await read(apiProvider).logout();
  } on api.ApiException {
    // The session may already be gone; clear locally either way.
    read(sessionProvider).clear();
  }
}
