// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// What a [SessionStore] needs when other tabs share its stored token pair.
///
/// Each tab holds its own in-memory pair, so a rotation in one leaves the
/// others on a refresh token the server has already spent.
abstract interface class SessionSync {
  /// Runs [body] while no other tab runs one, so only one tab rotates at a time.
  Future<T> exclusive<T>(Future<T> Function() body);

  /// The pair currently in shared storage, or null once a tab has signed out.
  Future<TokenPair?> readStored();
}

extension SessionStoreTabs on SessionStore {
  /// Takes up the pair another tab stored, or its sign-out.
  ///
  /// Memory only: the other tab already wrote it, and writing it back would
  /// race that tab's next rotation.
  void adopt(TokenPair? tokens, {String reason = 'signed out in another tab'}) {
    _tokens = tokens;
    if (tokens == null) _endings.add(reason);
    _changes.add(tokens);
  }

  /// Re-reads shared storage after another tab wrote to it.
  Future<void> reloadFromStorage() async {
    await adoptStoredRotation(adoptSignOut: true);
  }

  /// Adopts the stored pair when it is not the one held, returning it.
  ///
  /// Null means this tab still holds the newest pair and must rotate itself.
  Future<TokenPair?> adoptStoredRotation({bool adoptSignOut = false}) async {
    final source = sync;
    final held = _tokens;
    if (source == null || held == null) return null;
    await settled;
    final TokenPair? stored;
    try {
      stored = await source.readStored();
    } on Object catch (error, stack) {
      AppLog.swallowed(
          LogTag.net, 'Could not read the shared session', error, stack);
      return null;
    }
    if (!identical(_tokens, held)) return null;
    if (stored == null) {
      if (adoptSignOut) adopt(null);
      return null;
    }
    if (stored.refreshToken == held.refreshToken) return null;
    adopt(stored);
    return stored;
  }
}
