// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Takes a conversation's Android notifications down once it reads as read,
/// here or on another device, the way [appBadgeSyncProvider] does for iOS.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import '../features/accounts/providers/account_providers.dart';
import '../features/accounts/providers/account_unread.dart';
import '../push/android_push_messages.dart';
import '../push/providers/push_channel_providers.dart';
import 'app_badge_sync.dart';

/// The notification ids that no longer have anything to say: each read
/// conversation's own, plus the shared fallback ones once nothing is unread.
/// An empty read set means the local store has not loaded, not that nothing
/// is unread, so it never clears the shared ones.
Set<int> staleNotificationIds({
  required Set<String> readChannelIds,
  required int unreadCount,
}) => {
  for (final id in readChannelIds) previewNotificationId(id),
  if (unreadCount == 0 && readChannelIds.isNotEmpty) ...[
    previewNotificationId(null),
    LocalAlertChannel.messages.notificationId,
    LocalAlertChannel.mentions.notificationId,
  ],
};

/// Mounted once on the app-level container beside [appBadgeSyncProvider].
final notificationReadSyncProvider = Provider<void>((ref) {
  if (!isAndroidHost) return;
  final entries = ref.watch(accountsSnapshotProvider).entries;
  final stale = staleNotificationIds(
    readChannelIds: {
      for (final e in entries)
        ...?e.container.read(readChannelIdsProvider).valueOrNull,
    },
    unreadCount: appBadgeCount(entries.map((e) => e.unread)),
  );
  ref.read(localNotificationsProvider).cancelShown(stale);
});
