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
/// Read once from bootstrap, beside the message notifier, so the subscription
/// lives for the whole signed-in session.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import 'dm_call_ring_controller.dart';
import 'push_controller.dart';

/// What the notification says. Content-free on purpose, matching every other
/// notification this app raises: the envelope carries no caller name today,
/// and inventing one here would be the only place in the app that pretended
/// to know.
const incomingCallAlertText = 'Incoming call';

final desktopCallNotifierProvider = Provider<void>((ref) {
  // Android and iOS raise their own from the call push; only desktop needs this.
  if (!isDesktopHost) return;

  final notifications = ref.read(localNotificationsProvider);

  ref.listen<IncomingDmCallRing?>(
    dmCallRingControllerProvider.select((s) => s.visibleIncoming),
    (previous, next) {
      // Fire-and-forget: a failed notification must not disturb the call.
      if (next == null) {
        notifications.cancel(LocalAlertChannel.calls);
        return;
      }
      // Only a genuinely new ring, never one already dealt with.
      if (previous?.ringId == next.ringId) return;
      notifications.show(
        incomingCallAlertText,
        channel: LocalAlertChannel.calls,
      );
    },
  );
});
