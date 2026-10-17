// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reads and writes the account index, and moves a pre-accounts install's
/// single session into it. See docs/decisions/0068-multiple-servers-in-one-app.md.
library;

import 'dart:convert';

import 'package:slimm_platform/platform.dart';

import '../../../providers/providers.dart'
    show serverUrlHandle, sessionTokenHandle;
import 'account.dart';

/// The key-store entry holding the [AccountIndex]. It carries no secrets.
const accountIndexHandle = 'slimm.accounts';

class AccountStore {
  AccountStore(this._keys);

  final KeyStore _keys;

  /// The saved index, or an empty one when nothing usable is stored.
  ///
  /// Never deletes: an unreadable index is left for the next launch to retry.
  Future<AccountIndex> load() async {
    final raw = await _keys.read(accountIndexHandle);
    if (raw == null) return const AccountIndex();
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final accounts = <Account>[
        for (final row in (json['accounts'] as List? ?? const []))
          ?Account.tryFromJson(row),
      ];
      return AccountIndex(
        accounts: accounts,
        activeOrigin: json['active'] as String?,
      );
    } catch (_) {
      return const AccountIndex();
    }
  }

  Future<void> save(AccountIndex index) =>
      _keys.put(accountIndexHandle, jsonEncode(index.toJson()));

  Future<String?> readSession(Account account) =>
      _keys.read(account.sessionHandle);

  Future<void> writeSession(Account account, String tokenJson) =>
      _keys.put(account.sessionHandle, tokenJson);

  Future<void> deleteSession(Account account) =>
      _keys.delete(account.sessionHandle);

  /// Adopts the legacy `server_url` / `session_token_pair` pair as the first
  /// account when no index exists yet; otherwise returns the saved index.
  ///
  /// The legacy handles are removed only after the new entries read back, so
  /// a launch that dies midway runs this again instead of losing the session.
  Future<AccountIndex> loadOrMigrate() async {
    final saved = await load();
    if (saved.accounts.isNotEmpty) return saved;

    final legacyUrl = await _keys.read(serverUrlHandle);
    final server = legacyUrl == null ? null : Uri.tryParse(legacyUrl);
    if (server == null || !server.hasScheme || server.host.isEmpty) {
      return saved;
    }
    final account = Account.forServer(server, dbFile: legacyDatabaseFile);
    final legacySession = await _keys.read(sessionTokenHandle);
    if (legacySession != null) {
      await writeSession(account, legacySession);
    }
    final index = AccountIndex(
      accounts: [account],
      activeOrigin: account.origin,
    );
    await save(index);

    if (await _landed(account, legacySession)) {
      await _keys.delete(sessionTokenHandle);
      await _keys.delete(serverUrlHandle);
    }
    return index;
  }

  /// Whether the new entries read back, so the legacy ones are safe to drop.
  Future<bool> _landed(Account account, String? legacySession) async {
    try {
      if ((await load()).byOrigin(account.origin) == null) return false;
      return legacySession == null ||
          await _keys.read(account.sessionHandle) == legacySession;
    } catch (_) {
      return false;
    }
  }
}
