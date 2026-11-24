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

/// Filed per account so the next one on this device never sees the last one's picks.
String recentEmojiStorageKey(String userId) => '$_recentEmojiKey.$userId';

/// Recently-picked reaction emoji, most recent first. Loaded from
/// [preferencesProvider] on construction and persisted, best-effort, after
/// every [use]; a failed read or write just leaves the shelf as it was.
class RecentEmojiController extends StateNotifier<List<String>> {
  RecentEmojiController(this._ref) : super(const []) {
    final userId = _ref.read(sessionProvider).tokens?.userId;
    _key = userId == null ? null : recentEmojiStorageKey(userId);
    unawaited(_load());
  }

  final Ref _ref;
  late final String? _key;

  Future<void> _load() async {
    final key = _key;
    if (key == null) return;
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      final stored = prefs.getStringList(key);
      if (stored == null || !mounted) return;
      state = [
        ...state,
        ...stored.where((e) => !state.contains(e)),
      ].take(_maxRecentEmoji).toList();
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.media,
        'Could not read recent emoji; starting with none',
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
    final key = _key;
    if (key == null) return;
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      await prefs.setStringList(key, state);
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.media,
        'Could not save recent emoji; kept for this session only',
        error,
        stack,
      );
    }
  }
}

final recentEmojiProvider =
    StateNotifierProvider<RecentEmojiController, List<String>>((ref) {
      ref.watch(sessionProvider);
      return RecentEmojiController(ref);
    });
