// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether push envelopes carry a message preview, as the member sees and
/// changes it.
///
/// The truth is the account's choice on the server (`GET /push/preview`), so a
/// reinstall or a new device shows the same answer without anyone toggling
/// anything. The local `SharedPreferences` key holds only an explicit choice
/// the server has not yet accepted; registration sends `include_content` only
/// while one is pending, so a device that never toggled can never overwrite a
/// choice made on another. That pending choice is stored per account, and the
/// controller follows the session, so a different account signing in on the
/// same process neither shows nor sends the previous one's.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import 'providers.dart';

/// The `SharedPreferences` key one account's pending choice is stored under.
String pushIncludeContentKeyFor(String userId) =>
    'slimm.notifications.push_include_content.$userId';

/// State is the effective value, or null while the server has not answered.
class PushContentPreviewController extends StateNotifier<bool?> {
  PushContentPreviewController(this._ref) : super(null) {
    _account = _ref.read(sessionProvider).tokens?.userId;
    _sub = _ref.read(sessionProvider).changes.listen(_onSessionChanged);
    unawaited(refresh());
  }

  final Ref _ref;
  late final StreamSubscription<TokenPair?> _sub;
  bool _chosen = false;

  /// Whose choice is held, so a token rotation is told apart from a different
  /// account signing in.
  String? _account;

  /// Bumped by every account change, so an answer for the previous account is
  /// dropped instead of shown to the next.
  int _generation = 0;

  void _onSessionChanged(TokenPair? tokens) {
    final userId = tokens?.userId;
    if (userId == _account) return;
    _account = userId;
    _generation++;
    _chosen = false;
    state = null;
    if (userId != null) unawaited(refresh());
  }

  /// Reads the account's effective value; a failure leaves it unknown rather
  /// than guessing, and a pending explicit choice is shown meanwhile.
  Future<void> refresh() async {
    final generation = _generation;
    bool stale() => !mounted || generation != _generation;
    final pending = await pendingChoice();
    if (stale()) return;
    if (pending != null && !_chosen) state = pending;
    try {
      final served = await _ref.read(apiProvider).pushPreview();
      if (!stale() && !_chosen) state = served;
    } catch (_) {
      // state keeps the pending choice, or stays unknown.
    }
  }

  /// The explicit choice the server has not confirmed yet, or null. Never
  /// throws: it is on every registration's path, and a failed read is retried
  /// by the next caller because the cached provider error is invalidated.
  Future<bool?> pendingChoice() async {
    final account = _account;
    if (account == null) return null;
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      return prefs.getBool(pushIncludeContentKeyFor(account));
    } catch (_) {
      _ref.invalidate(preferencesProvider);
      return null;
    }
  }

  /// Drops the pending choice once the server holds it.
  Future<void> markSent() => _clearPending(_account);

  Future<void> _clearPending(String? account) async {
    if (account == null) return;
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      await prefs.remove(pushIncludeContentKeyFor(account));
    } catch (_) {
      _ref.invalidate(preferencesProvider);
    }
  }

  /// Saves the member's explicit choice to the account. If the server cannot
  /// be reached the choice is kept as pending and sent with the next
  /// registration.
  Future<void> setEnabled(bool enabled) async {
    final account = _account;
    _chosen = true;
    state = enabled;
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      if (account != null) {
        await prefs.setBool(pushIncludeContentKeyFor(account), enabled);
      }
    } catch (_) {
      _ref.invalidate(preferencesProvider);
    }
    try {
      await _ref.read(apiProvider).setPushPreview(enabled);
      await _clearPending(account);
    } catch (_) {
      // Left pending on purpose; see above.
    }
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

final pushContentPreviewSettingsProvider =
    StateNotifierProvider<PushContentPreviewController, bool?>(
      (ref) => PushContentPreviewController(ref),
    );
