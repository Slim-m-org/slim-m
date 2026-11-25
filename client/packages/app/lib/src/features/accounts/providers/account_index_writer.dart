// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Writes the account index so a second browser tab's changes are never overwritten.
library;

import 'dart:async';

import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_platform/platform.dart' show CrossTab;

import 'account.dart';
import 'account_store.dart';

class AccountIndexWriter {
  AccountIndexWriter(this._store, this._crossTab);

  final AccountStore _store;

  /// Null where one process is the whole session.
  final CrossTab? _crossTab;

  /// Set when the launch read of the index failed, so the stored list is not yet known.
  bool unread = false;

  Future<void> _last = Future.value();

  /// Applies [change] to the index stored now, not to this tab's copy of it.
  ///
  /// [known] is what this tab holds: it is added to a stored list that is unread or empty, never replaces one.
  Future<void> save(
    AccountIndex Function(AccountIndex stored) change, {
    required AccountIndex known,
  }) {
    final run = _last.then((_) => _write(change, known));
    _last = run;
    return run;
  }

  Future<void> _write(
    AccountIndex Function(AccountIndex) change,
    AccountIndex known,
  ) async {
    try {
      Future<void> body() async {
        final stored = await _store.loadOrMigrate();
        final base = unread || stored.accounts.isEmpty
            ? _withKnown(stored, known)
            : stored;
        await _store.save(change(base));
        unread = false;
      }

      final tabs = _crossTab;
      await (tabs == null ? body() : tabs.exclusive(accountIndexLock, body));
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.auth,
        'Could not save the account list; each sign-in is saved on its own',
        error,
        stack,
      );
    }
  }

  AccountIndex _withKnown(AccountIndex stored, AccountIndex known) {
    var merged = AccountIndex(
      accounts: stored.accounts,
      activeOrigin: known.activeOrigin ?? stored.activeOrigin,
    );
    for (final account in known.accounts) {
      if (merged.byOrigin(account.origin) == null) {
        merged = merged.withAccount(account);
      }
    }
    return merged;
  }
}
