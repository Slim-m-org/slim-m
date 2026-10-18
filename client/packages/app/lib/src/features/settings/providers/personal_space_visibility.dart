// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the caller has removed their own personal space row from the
/// rail's Direct messages section.
///
/// A view preference only, the same shape `blocksProvider` documents for its
/// own filter: the channel this hides, and every message already in it, is
/// untouched server-side. Hiding it is reversible by searching the caller's
/// own display name (`command_palette_items.dart`'s `channelMatchesQuery`),
/// which reveals it and shows it again on selection.
///
/// Persisted per account rather than kept in memory only, so "remove from
/// list" survives a relaunch the way removing anything else from a list
/// would be expected to. The local `SharedPreferences` store is one file for
/// the whole device, not one per account, so the key is namespaced by user
/// id: an unkeyed flag would either hide the next signed-in account's own
/// notes or, on their first launch, silently un-hide the previous account's.
/// `blocksProvider`'s own doc comment names the same trap for the block
/// list; the fix there is not persisting past a session at all, but a view
/// preference meant to survive a relaunch has nothing else to key on.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

/// The `SharedPreferences` key one account's hidden flag is stored under.
String personalSpaceHiddenKey(String userId) =>
    'slimm.personal_space_hidden.$userId';

class PersonalSpaceVisibilityController extends StateNotifier<bool> {
  PersonalSpaceVisibilityController(this._ref) : super(false) {
    _account = _ref.read(sessionProvider).tokens?.userId;
    _sub = _ref.read(sessionProvider).changes.listen(_onSessionChanged);
    unawaited(_load());
  }

  final Ref _ref;
  late final StreamSubscription<api.TokenPair?> _sub;

  /// Whose flag is held, so a session change that is only a token rotation
  /// (the stream also fires on those) is told apart from a different account
  /// signing in on the same running process.
  String? _account;

  /// Bumped by every account change and every explicit [hide]/[show], so a
  /// load that answers after either has already happened is dropped rather
  /// than stomping a deliberate call with the stale value it started
  /// reading before that call was ever made.
  int _generation = 0;

  void _onSessionChanged(api.TokenPair? tokens) {
    final userId = tokens?.userId;
    if (userId == _account) return;
    _account = userId;
    _generation++;
    // Neither a signed-out nor a brand-new account has anything hidden yet.
    state = false;
    if (userId != null) unawaited(_load());
  }

  Future<void> _load() async {
    final generation = _generation;
    final userId = _account;
    if (userId == null) return;
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      if (!mounted || generation != _generation) return;
      state = prefs.getBool(personalSpaceHiddenKey(userId)) ?? false;
    } catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.ui,
        'Could not read the saved visibility; showing it',
        error,
        stack,
      );
    }
  }

  /// Removes the personal space row from the rail; reversed by [show].
  Future<void> hide() => _set(true);

  /// Restores the row. Called when a search result for the hidden channel
  /// is actually selected, so finding it again is also how it comes back.
  Future<void> show() => _set(false);

  Future<void> _set(bool hidden) async {
    final userId = _account;
    if (userId == null) return;
    _generation++;
    state = hidden;
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      await prefs.setBool(personalSpaceHiddenKey(userId), hidden);
    } catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.ui,
        'Could not save the visibility; applied for this session only',
        error,
        stack,
      );
    }
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

/// Deliberately not `autoDispose`: the rail's Direct messages section reads
/// this on every build, and tearing it down whenever that section briefly
/// unmounts (a modal covering the shell) would re-run the async load and
/// flash the row visible again behind the modal.
final personalSpaceVisibilityProvider =
    StateNotifierProvider<PersonalSpaceVisibilityController, bool>(
      (ref) => PersonalSpaceVisibilityController(ref),
    );
