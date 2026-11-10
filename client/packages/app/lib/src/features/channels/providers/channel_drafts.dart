// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Unsent composer text, saved against the channel it was typed in and restored
/// against whichever channel is open now, whether or not the widget survived.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

/// Holds every channel's unsent composer text, in memory and on disk.
///
/// The map is authoritative once loaded, because a composer opening a channel
/// needs an answer in the same frame; the disk write is fire-and-forget so no
/// keystroke waits on it. A reply target is deliberately not kept, since
/// `ChannelScreen` clears it on a channel switch, and staged attachments never
/// reach disk because the server sweeps an unsent upload after a day.
class ChannelDraftsController {
  ChannelDraftsController(this._ref) {
    _account = _ref.read(sessionProvider).tokens?.userId;
    _sub = _ref.read(sessionProvider).changes.listen(_onSessionChanged);
    unawaited(_restore());
  }

  final Ref _ref;
  final Map<String, String> _drafts = {};
  late final StreamSubscription<api.TokenPair?> _sub;
  String? _account;

  /// Completes once the on-disk drafts have been merged in; a composer that
  /// opened first fills itself from this.
  Future<void> get restored => _restoreDone.future;
  final _restoreDone = Completer<void>();

  /// Fills only channels the map has nothing for, never replacing it wholesale.
  /// Somebody typing during the restore is stating a newer intent than the row
  /// being read, so `putIfAbsent` is the whole of that rule.
  Future<void> _restore() async {
    try {
      final store = await _ref.read(storeProvider.future);
      final saved = await store.drafts();
      for (final entry in saved.entries) {
        _drafts.putIfAbsent(entry.key, () => entry.value);
      }
    } catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.data,
        'Could not restore saved message drafts',
        error,
        stack,
      );
      // Quiet on purpose: see this class's doc on the fire-and-forget write.
    }
    if (!_restoreDone.isCompleted) _restoreDone.complete();
  }

  /// Whatever was last saved for [channelId], or an empty string if there is
  /// nothing to restore.
  String draftFor(String channelId) => _drafts[channelId] ?? '';

  /// Saves [text] as [channelId]'s draft, or forgets it once it is empty: an
  /// empty draft and no draft have to read the same way, or every channel a
  /// member ever opens and leaves empty grows the map forever.
  void save(String channelId, String text) {
    if (text.isEmpty) {
      _drafts.remove(channelId);
    } else {
      _drafts[channelId] = text;
    }
    unawaited(_persist(channelId, text));
  }

  /// Forgets [channelId]'s draft outright, called once its text has been
  /// sent rather than left to [save] with an empty string a rebuild later.
  void clear(String channelId) {
    _drafts.remove(channelId);
    unawaited(_persist(channelId, ''));
  }

  /// Mirrors one channel's draft to disk. Never awaited by a caller; see the
  /// class doc for why a keystroke does not wait on a write.
  Future<void> _persist(String channelId, String text) async {
    try {
      final store = await _ref.read(storeProvider.future);
      await store.saveDraft(
        channelId,
        text,
        now: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.data,
        'Could not save a message draft',
        error,
        stack,
      );
      // See _restore.
    }
  }

  /// Sign-out, or a different account signing in on this process, empties
  /// every draft: the same account-boundary rule `BlocksController` already
  /// follows, because Riverpod's container outlives a sign-out and the next
  /// account on this device must never read the last one's unfinished words.
  /// The rows themselves go with the rest of the local cache in
  /// `MessageStore.clear()`, which sign-out already calls; this drops the map so
  /// the in-memory copy cannot outlive them.
  void _onSessionChanged(api.TokenPair? tokens) {
    if (tokens == null) {
      _account = null;
      _drafts.clear();
      return;
    }
    if (tokens.userId == _account) return;
    // No account to an account is a cold start reading the key store, not a switch.
    final coldStart = _account == null;
    _account = tokens.userId;
    if (!coldStart) _drafts.clear();
  }

  void dispose() => unawaited(_sub.cancel());
}

/// Deliberately not `autoDispose`: a draft has to survive for as long as the
/// session does, independent of whether any particular `ChannelScreen` is
/// currently mounted to read or write one.
final channelDraftsProvider = Provider<ChannelDraftsController>((ref) {
  final controller = ChannelDraftsController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});
