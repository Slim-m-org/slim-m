// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Desktop-only: posts an OS notification when a message arrives while the
/// window is not in the foreground.
///
/// The desktop has no remote push - nothing wakes a closed app the way FCM or
/// APNs wakes a phone - so the only notifications it can show are for messages
/// that arrive over the live socket while the app is running. This turns those
/// into `org.freedesktop.Notifications` alerts through
/// [LocalNotifications.show]; on Android and iOS the platform push already
/// does this, so this stays inert there.
///
/// Only when the window is not focused. A focused desktop app shows its own
/// unread state in the rail, and a second OS banner on top of the channel you
/// are already reading is noise, not news. Own messages are skipped for the
/// reason their name gives.
///
/// The channel's own override runs through [channelEarnsASound], the gate the
/// chime already uses and the rule the server's
/// `narrow_for_notification_preference` enforces for push. This path used to
/// read only the mute half of it, so a channel narrowed to mentions kept
/// raising a banner for every ordinary message while the chime beside it
/// stayed silent.
///
/// Also gated by the notification schedule (`notification_schedule_rules.dart`),
/// the same policy `notification_sound_controller.dart` already applies to
/// the chime - the owner's own instruction was that both foreground paths
/// honour it, not only the one with a sound attached.
///
/// Read once from bootstrap, beside the sync and push controllers, so the
/// subscription lives for the whole signed-in session.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_platform/platform.dart';

import 'live_events.dart';
import 'message_alert_policy.dart';
import 'push_controller.dart';

final desktopMessageNotifierProvider = Provider<void>((ref) {
  // Android and iOS notify from platform push; only the desktop needs this.
  if (!isDesktopHost) return;

  final notifier = _DesktopMessageNotifier(ref);
  final sub = ref.read(liveEventsProvider).listen(notifier.onServerEvent);
  ref.onDispose(sub.cancel);
});

class _DesktopMessageNotifier {
  _DesktopMessageNotifier(this._ref);

  final Ref _ref;

  void onServerEvent(api.ServerEvent event) {
    if (event case api.MessageCreated(:final message)) {
      unawaited(_onMessageCreated(message));
    }
  }

  Future<void> _onMessageCreated(api.Message message) async {
    // Skip while focused: a foreground app shows unread in the rail already.
    final foreground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (foreground) return;

    final alert = await _ref.read(messageAlertPolicyProvider).evaluate(message);
    if (alert == null) return;

    final author = message.authorDisplayName;
    final text = author == null || author.isEmpty
        ? 'New message'
        : 'New message from $author';
    final notifications = _ref.read(localNotificationsProvider);
    // The per-kind OS control only reaches a banner filed under the kind it is; see LocalAlertChannel.
    final alertChannel = alert.mentionsSelf
        ? LocalAlertChannel.mentions
        : LocalAlertChannel.messages;
    // Fire-and-forget: a failed notification must never break event handling.
    unawaited(notifications.show(text, channel: alertChannel));
  }
}
