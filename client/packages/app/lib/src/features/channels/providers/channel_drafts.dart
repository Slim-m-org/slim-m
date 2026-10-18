// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Unsent composer text, held per channel for as long as the session lasts.
///
/// `ChannelScreen` reuses its own `State` across a channel switch in the
/// common case (see `channel_read_marker.dart`'s doc comment), which is why a
/// draft looked like it should already survive one and did not: nothing ever
/// told the shared `TextEditingController` which channel its text belonged
/// to, so switching channels either carried the words into the wrong one or,
/// wherever `ConversationPane` happens to tear the screen down instead (a
/// detour through voice, a DM call, or the canvas), lost them outright.
///
/// This is the fix: text is saved against the channel it was typed in and
/// restored against whichever channel is open now, independent of whether
/// the widget underneath survived.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

/// Holds every channel's unsent composer text, in memory and on disk.
///
/// The in-memory map is the whole read path: a composer opening a channel needs
/// an answer in the same frame, not a future, so the map is authoritative once
/// loaded and the database only ever catches up behind it.
///
/// It was in-memory only until a restart was shown to be the same event as a
/// switch, from the person's side. On a phone the OS killing a backgrounded app
/// is indistinguishable from a restart to whoever just lost what they typed, and
/// unlike a switch it happens without anyone choosing it. The original scoping
/// call - "the report was about switching channels, never about restarting the
/// app" - was honest about its report and wrong about the loss.
///
/// The write is deliberately fire-and-forget. A draft is worth saving, and it is
/// not worth making a keystroke wait on a disk to find out whether it was: a
/// failed write costs the words a crash would have cost anyway, and blocking the
/// composer would cost every keystroke.
///
/// A reply-in-progress is deliberately not held here, and that is a decision,
/// not an oversight: `ChannelScreen` clears the reply target on a channel
/// switch (see its own `didUpdateWidget` doc comment, "a reply is scoped to
/// the conversation it was started in"). Staged attachments live beside this
/// in `attachmentStagingProvider`, per channel for the session but never on
/// disk, since the server sweeps an unsent upload after a day.
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
        'restore failed, ignored',
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
        'persist failed, ignored',
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
