// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The emoji picker's recently-used shelf: not a secret, so it lives in
/// [preferencesProvider] rather than the key store, and it does not need to
/// survive a reinstall the way a session does.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const _recentEmojiKey = 'slimm.recent_emoji';
const _maxRecentEmoji = 24;

/// Recently-picked reaction emoji, most recent first. Loaded from
/// [preferencesProvider] on construction and persisted, best-effort, after
/// every [use]; a failed read or write just leaves the shelf as it was.
class RecentEmojiController extends StateNotifier<List<String>> {
  RecentEmojiController(this._ref) : super(const []) {
    unawaited(_load());
  }

  final Ref _ref;

  Future<void> _load() async {
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      final stored = prefs.getStringList(_recentEmojiKey);
      if (stored != null) state = stored;
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.media,
        'Falls back to an empty shelf; the picker still works without one',
        error,
        stack,
      );
    }
  }

  /// Moves [emoji] to the front of the shelf, adding it if it is new.
  Future<void> use(String emoji) async {
    state = [
      emoji,
      ...state.where((e) => e != emoji),
    ].take(_maxRecentEmoji).toList();
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      await prefs.setStringList(_recentEmojiKey, state);
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.media,
        'Best-effort: the shelf still reflects the pick for this session even if it does not survive a restart',
        error,
        stack,
      );
    }
  }
}

final recentEmojiProvider =
    StateNotifierProvider<RecentEmojiController, List<String>>(
      (ref) => RecentEmojiController(ref),
    );
