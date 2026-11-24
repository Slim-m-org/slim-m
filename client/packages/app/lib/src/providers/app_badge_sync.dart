// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the iPhone icon badge, the Windows taskbar button's overlay and a
/// browser tab's title count equal to the channels the rail shows as unread.
///
/// The notification service extension raises the badge when a push arrives
/// while the app is away; this corrects it whenever the app sees read state
/// change, on this device or another one it syncs from.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import '../features/accounts/providers/account_providers.dart';
import '../features/accounts/providers/account_unread.dart';
import '../push/providers/push_channel_providers.dart';

final appBadgeChannelProvider = Provider<AppBadgeChannel>(
  (ref) => AppBadgeChannel(),
);

/// The browser tab's title and favicon, inert outside a browser.
final browserAttentionProvider = Provider<BrowserAttention>(
  (ref) => BrowserAttention(),
);

/// False when iOS Settings has Badges off for this app, so badge writes do nothing.
final badgesAllowedProvider = FutureProvider.autoDispose<bool>(
  (ref) => ref.watch(appBadgeChannelProvider).badgesAllowed(),
);

/// What the icon should show: unread channels across every signed-in account.
int appBadgeCount(Iterable<AccountUnread> accounts) =>
    accounts.fold(0, (sum, unread) => sum + unread.channels);

/// Kept mounted by [ActiveAccountMount]; runs on every unread change, also
/// while a minimised window draws no frames.
final appBadgeSyncProvider = Provider<void>((ref) {
  onAccountsChanged(ref, (accounts) {
    final read = <String>{
      for (final a in accounts)
        ...?a.container.read(readChannelIdsProvider).valueOrNull,
    };
    final count = appBadgeCount(accounts.map((a) => a.unread));
    ref.read(appBadgeChannelProvider).sync(count: count, readChannelIds: read);
    ref.read(taskbarAttentionProvider).setBadge(count);
    ref.read(browserAttentionProvider).setUnread(count);
  });
});
