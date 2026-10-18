// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The account list as the UI reads it.
/// See docs/decisions/0068-multiple-servers-in-one-app.md.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account.dart';
import 'account_host.dart';
import 'account_unread.dart';

/// Null in a container with no host (every widget test): the app then shows
/// no switcher and behaves as a single-account install.
final accountHostProvider = Provider<AccountHost?>((ref) => null);

class AccountEntry {
  const AccountEntry({
    required this.account,
    required this.container,
    required this.active,
    required this.signedIn,
    required this.unread,
    required this.inCall,
  });

  final Account account;
  final ProviderContainer container;
  final bool active;
  final bool signedIn;
  final AccountUnread unread;
  final bool inCall;
}

class AccountsSnapshot {
  const AccountsSnapshot({
    this.entries = const [],
    this.callElsewhere,
    this.canCancelAdd = false,
  });

  final List<AccountEntry> entries;

  /// An account other than the one on screen that is in a call.
  final AccountEntry? callElsewhere;
  final bool canCancelAdd;

  /// Everything the other accounts have waiting, for the closed trigger's dot.
  AccountUnread get unreadElsewhere {
    var channels = 0;
    var mentions = 0;
    for (final e in entries) {
      if (e.active) continue;
      channels += e.unread.channels;
      mentions += e.unread.mentions;
    }
    return AccountUnread(channels: channels, mentions: mentions);
  }
}

/// Rebuilds whenever the host reports a change; empty with no host.
final accountsSnapshotProvider = Provider.autoDispose<AccountsSnapshot>((ref) {
  final host = ref.watch(accountHostProvider);
  if (host == null) return const AccountsSnapshot();
  void changed() => ref.invalidateSelf();
  host.addListener(changed);
  ref.onDispose(() => host.removeListener(changed));

  AccountEntry entryOf(AccountRuntime r) => AccountEntry(
    account: r.account!,
    container: r.container,
    active: r == host.active,
    signedIn: r.signedIn,
    unread: r.unread,
    inCall: r.inCall,
  );
  final other = host.callElsewhere;
  return AccountsSnapshot(
    entries: [for (final r in host.accounts) entryOf(r)],
    callElsewhere: other?.account == null ? null : entryOf(other!),
    canCancelAdd: host.canCancelAdd,
  );
});
