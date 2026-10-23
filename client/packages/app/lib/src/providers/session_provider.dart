// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_platform/platform.dart';

import '../features/accounts/providers/account_slot.dart';
import 'providers.dart';

/// The session, shared by everything that talks to the server so a refresh in
/// one place is seen everywhere.
///
/// Every change is written straight to the key store: a login or a refresh
/// persists the new pair (with the server it belongs to), and a sign-out or a
/// rejected refresh deletes it. [restoreSession] does the other half, reading
/// it back on the next launch.
///
/// Writes are chained, not fired in parallel, inside [SessionStore] itself: a
/// burst of rapid session changes (a restore immediately followed by a
/// refresh) must land on disk in the order they happened, or a slow write can
/// finish after a faster later one and leave a stale value as the persisted
/// state. [SessionStore.settled] is what lets a rotation wait for its own
/// write to land before anything relies on it being durable.
final sessionProvider = Provider<SessionStore>((ref) {
  final keyStore = ref.read(keyStoreProvider);
  final slot = ref.read(accountSlotProvider);
  final tabs = ref.read(crossTabProvider);
  // An account's session is filed under its own handle; its server lives in the index.
  String handle() => slot == null
      ? sessionTokenHandle
      : slot.accountFor(ref.read(serverUrlProvider)).sessionHandle;
  final store = SessionStore(
    sync: TabSessionSync(tabs, () async {
      final stored = await keyStore.read(handle());
      if (stored == null) return null;
      return TokenPair.fromJson(jsonDecode(stored) as Map<String, dynamic>);
    }),
    onChange: (tokens) async {
      final serverUrl = tokens == null ? null : ref.read(serverUrlProvider);
      final sessionHandle = handle();
      try {
        await _persistSession(
          keyStore,
          sessionHandle,
          tokens,
          slot == null ? serverUrl : null,
        );
      } catch (error, stack) {
        reportFailure(LogTag.auth, 'save the sign-in', error, stack);

        /// The server rotates refresh tokens with reuse detection: a write that
        /// failed here may have left a stale, already-spent token on disk, and
        /// replaying that on the next launch reads as reuse and revokes the
        /// whole family. Dropping the stored session outright degrades to a
        /// fresh sign-in instead of that false replay.
        if (tokens != null) {
          await keyStore
              .delete(sessionHandle)
              .catchError(
                ignoreError(
                  LogTag.auth,
                  'Could not delete an old saved sign-in',
                ),
              );
        }
      }
    },
  );
  final following = tabs.storageChanges.listen(
    (_) => unawaited(store.reloadFromStorage()),
  );
  ref.onDispose(following.cancel);
  ref.onDispose(store.dispose);
  return store;
});

Future<void> _persistSession(
  KeyStore keyStore,
  String handle,
  TokenPair? tokens,
  Uri? serverUrl,
) async {
  if (tokens == null) {
    await keyStore.delete(handle);
    return;
  }
  await keyStore.put(handle, jsonEncode(tokens.toJson()));
  if (serverUrl != null) {
    await keyStore.put(serverUrlHandle, serverUrl.toString());
  }
}

/// Browser tabs of one profile; a no-op everywhere else.
final crossTabProvider = Provider<CrossTab>((ref) => CrossTab());

/// Lets a [SessionStore] rotate under the tabs' shared lock and re-read storage.
class TabSessionSync implements SessionSync {
  TabSessionSync(this._tabs, this._read);

  static const lockName = 'slimm-session-refresh';

  final CrossTab _tabs;
  final Future<TokenPair?> Function() _read;

  @override
  Future<T> exclusive<T>(Future<T> Function() body) =>
      _tabs.exclusive(lockName, body);

  @override
  Future<TokenPair?> readStored() => _read();
}
