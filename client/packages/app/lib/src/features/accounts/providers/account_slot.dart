// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What one container knows about the account it serves.
/// See docs/decisions/0068-multiple-servers-in-one-app.md.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account.dart';

/// Files [server] as an account and returns it; supplied by the host.
typedef ChooseServer = Account Function(AccountSlot slot, Uri server);

/// Overridden per container by the host; null in a container with no host,
/// which then keeps the single-account handles and database file.
final accountSlotProvider = Provider<AccountSlot?>((ref) => null);

/// Whether this container is the one on screen. False keeps it headless, so
/// the desktop notifier speaks for it even while the window is focused.
final accountActiveProvider = StateProvider<bool>((ref) => true);

class AccountSlot {
  AccountSlot({this.account, required ChooseServer chooseServer})
    : _chooseServer = chooseServer;

  /// Null until a server is chosen, which is the state of an add flow.
  Account? account;

  /// Set when the stored session could not be read, so activation retries.
  bool restoreFailed = false;

  final ChooseServer _chooseServer;

  /// The account for [server], creating it on first use.
  Account accountFor(Uri server) {
    final current = account;
    if (current != null && current.origin == originOf(server)) return current;
    return account = _chooseServer(this, server);
  }

  String get databaseFile => account?.dbFile ?? legacyDatabaseFile;
}
