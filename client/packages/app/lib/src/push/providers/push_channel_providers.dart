// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The native push bridges as providers, so a test can substitute each.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import '../../desktop/desktop_window_shell.dart';
import '../../features/accounts/providers/account_providers.dart';
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

/// The seam onto Android's local-notification channel: creating it, and
/// asking for runtime permission to use it. A provider, for the same reason
/// as the two above - a test can substitute one that reports "denied"
/// without a real Android device or plugin channel behind it.
final localNotificationsProvider = Provider<LocalNotifications>(
  (ref) => LocalNotifications(
    onActivated: (payload) async {
      await ref.read(desktopWindowShellProvider).raise();
      final host = ref.read(accountHostProvider);
      final target = NotificationTarget.decode(payload);
      if (host == null || target == null) return;
      await openChannelOnOwner(host, target.channelId, origin: target.origin);
    },
  ),
);
