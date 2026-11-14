// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Desktop-only: raises an OS notification for an incoming DM call, and takes
/// it down again when the ring ends.
///
/// `incoming_call_overlay.dart` already answers "put a ring in front of
/// everything and take focus" by calling `DesktopWindowPort.show` then
/// `.focus`. That works on X11 and on Windows and reaches nobody on Wayland,
/// which forbids focus stealing by design: a client needs an xdg-activation
/// token from the application that currently has focus, and the browser
/// someone is reading is not going to hand one over. So the in-app overlay is
/// only ever seen by a person already looking at the app - which is the one
/// case where a ring did not need announcing.
///
/// A critical-urgency notification is the mechanism the desktop does honour.
/// The compositor draws it over a fullscreen window and, on KDE, leaves it up
/// rather than timing it out. See [LocalAlertChannel.calls].
///
/// Unlike `desktop_message_notifier.dart` this does **not** skip while the
/// window is focused. A message that arrives on the channel you are reading
/// is already in front of you; a ring is a 30-second prompt (the server's own
/// `spawn_ring_sweep` timeout) that is lost if it is missed, and "focused"
/// only means the app has focus, not that anyone is looking at it.
///
/// A ring also flashes the Windows taskbar button, which Windows does let
/// through even when it will not hand over focus.
///
/// Read by `startAccountServices` for every account's container, beside the
/// message notifier, so a ring in a Space out of view still raises one.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_platform/platform.dart';

import '../../features/members/providers/user_profiles.dart';
import '../../features/voice/providers/dm_call_ring_controller.dart';
import '../../providers/providers.dart';
import '../../push/providers/push_controller.dart';
import 'desktop_message_text_settings.dart';

/// What the notification says; the caller's name is its title while the
/// desktop shows message text, the same switch that names a message's author.
const incomingCallAlertText = 'Incoming call';

/// How long a ring waits for its caller's name before it goes out without one.
const callerNameWait = Duration(seconds: 1);

final desktopCallNotifierProvider = Provider<void>((ref) {
  // Android and iOS raise their own from the call push; only desktop needs this.
  if (!isDesktopHost) return;

  final notifications = ref.read(localNotificationsProvider);
  final taskbar = ref.read(taskbarAttentionProvider);

  ref.listen<IncomingDmCallRing?>(
    dmCallRingControllerProvider.select((s) => s.visibleIncoming),
    (previous, next) {
      // Fire-and-forget: a failed notification must not disturb the call.
      if (next == null) {
        notifications.cancel(LocalAlertChannel.calls);
        taskbar.stop();
        return;
      }
      // Only a genuinely new ring, never one already dealt with.
      if (previous?.ringId == next.ringId) return;
      unawaited(_announce(ref, notifications, next));
      taskbar.flash();
    },
  );
});

Future<void> _announce(
  Ref ref,
  LocalNotifications notifications,
  IncomingDmCallRing ring,
) async {
  final title = await _callerName(ref, ring.callerId);
  final still = ref.read(dmCallRingControllerProvider).visibleIncoming;
  if (still?.ringId != ring.ringId) return;
  await notifications.show(
    incomingCallAlertText,
    channel: LocalAlertChannel.calls,
    title: title,
  );
}

/// Null when message text is hidden, or the name does not arrive in time.
Future<String?> _callerName(Ref ref, String callerId) async {
  try {
    final prefs = await ref.read(preferencesProvider.future);
    if (!(prefs.getBool(desktopMessageTextKey) ?? true)) return null;
    final profile = await ref
        .read(batchProfilesControllerProvider.notifier)
        .profile(callerId)
        .timeout(callerNameWait);
    final name = profile?.displayName.trim();
    return name == null || name.isEmpty ? null : name;
  } on Object catch (error, stack) {
    api.AppLog.swallowed(
      api.LogTag.voice,
      'Could not name a caller; the ring goes out without one',
      error,
      stack,
    );
    return null;
  }
}
