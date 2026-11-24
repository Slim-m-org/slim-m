// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The native push bridges as providers, so a test can substitute each.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import '../../desktop/desktop_window_shell.dart';
import '../../features/accounts/providers/account_host.dart';
import '../../features/accounts/providers/notification_target.dart';
import 'notification_tap_router.dart' show openChannelOnOwner;

/// The native bridge for this device's APNs token. A provider, rather than a
/// field [PushController] constructs itself, so a test can substitute one
/// that does not depend on the test runner actually being iOS.
final apnsTokenChannelProvider = Provider<ApnsTokenChannel>(
  (ref) => ApnsTokenChannel(),
);

/// The bridge for this device's FCM registration token, Android's
/// counterpart to [apnsTokenChannelProvider]. A provider for the same
/// reason: a test can substitute one that does not depend on the test
/// runner actually being Android.
final fcmTokenChannelProvider = Provider<FcmTokenChannel>(
  (ref) => FcmTokenChannel(),
);

/// The Windows taskbar button; inert on every other host.
final taskbarAttentionProvider = Provider<TaskbarAttention>(
  (ref) => TaskbarAttention(),
);

/// The seam onto Android's local-notification channel: creating it, and
/// asking for runtime permission to use it. A provider, for the same reason
/// as the two above - a test can substitute one that reports "denied"
/// without a real Android device or plugin channel behind it.
///
/// Account containers are given one shared instance by `createAccountHost`,
/// since the plugin's click callback is process-wide and must not belong to
/// a container that can be disposed.
final localNotificationsProvider = Provider<LocalNotifications>(
  (ref) => LocalNotifications(),
);

/// What a click on a local notification does: raise the window, then open the
/// channel on the account that owns it.
Future<void> openNotificationTarget(
  DesktopWindowShell shell,
  AccountHost host,
  String? payload,
) async {
  await shell.raise();
  final target = NotificationTarget.decode(payload);
  if (target == null) return;
  await openChannelOnOwner(host, target.channelId, origin: target.origin);
}
