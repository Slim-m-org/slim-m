// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the iPhone icon badge equal to the channels the rail shows as unread.
///
/// The notification service extension raises the badge when a push arrives
/// while the app is away; this corrects it whenever the app sees read state
/// change, on this device or another one it syncs from.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import '../features/accounts/providers/account_providers.dart';
import '../features/accounts/providers/account_unread.dart';

final appBadgeChannelProvider = Provider<AppBadgeChannel>(
  (ref) => AppBadgeChannel(),
);

/// What the icon should show: unread channels across every signed-in account.
int appBadgeCount(Iterable<AccountUnread> accounts) =>
    accounts.fold(0, (sum, unread) => sum + unread.channels);

/// Mounted once on the app-level container; the host snapshot rebuilds it on
/// every unread change.
final appBadgeSyncProvider = Provider<void>((ref) {
  final entries = ref.watch(accountsSnapshotProvider).entries;
  final read = <String>{
    for (final e in entries)
      ...?e.container.read(readChannelIdsProvider).valueOrNull,
  };
  ref
      .read(appBadgeChannelProvider)
      .sync(
        count: appBadgeCount(entries.map((e) => e.unread)),
        readChannelIds: read,
      );
});
