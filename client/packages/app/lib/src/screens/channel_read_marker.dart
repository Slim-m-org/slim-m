// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Advancing a channel's read marker: the local write, the server call, and
/// the guard that keeps a busy channel from re-sending a seq it has already
/// recorded.
///
/// Split out of `channel_screen.dart`, which was the only thing that ever
/// held this and had no room left to grow.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../providers/providers.dart';

/// Records what has been read, up to the newest delivered message in a
/// channel ([VisibleTranscript.newestSeq]).
///
/// Pending sends are excluded there: they carry seq 0 until the server
/// acknowledges them, so treating one as "read" would either no-op or, once
/// the real send lands with its assigned seq, immediately look unread again
/// for a message the user already sees on screen. A blocked author's message
/// counts, since it was received rather than never sent.
///
/// The local write and the network call are both monotonic and idempotent
/// (`MessageStore.setReadMarker`, the server's `PUT .../read`), so a redundant
/// call is harmless; the per-channel guard exists only to keep a busy channel
/// from re-sending the same seq on every unrelated rebuild. It is keyed by
/// channel because one instance outlives a channel switch: `ConversationPane`
/// builds `ChannelScreen` with no key, so navigating between channels reuses
/// the same `State`.
///
/// Callers own the scroll gate: this only knows the seq to advance to, never
/// whether the viewport is actually showing it.
class ReadMarker {
  ReadMarker(this._ref);

  final WidgetRef _ref;
  final Map<String, int> _sent = {};

  /// [manuallyUnread] is the hand-mark's current value, not an edge trigger:
  /// the caller has no seq of its own to guard it with, since the server's
  /// `markUnread` deliberately does not move `lastReadSeq` (`seq ==
  /// lastReadSeq` is the ordinary result of marking an already-read channel
  /// unread). Both guards below are bypassed while it is true, so sitting at
  /// the latest message still clears it even though there is no seq to
  /// advance to; they resume once the local write flips it false and the next
  /// build passes that back in.
  void advance(
    String channelId, {
    required int seq,
    required int lastReadSeq,
    required bool manuallyUnread,
  }) {
    if (seq == 0) return;
    if (seq <= lastReadSeq && !manuallyUnread) return;
    if (!manuallyUnread && (_sent[channelId] ?? 0) >= seq) return;
    final previous = _sent[channelId];
    _sent[channelId] = seq;
    unawaited(_write(channelId, seq, previous));
  }

  Future<void> _write(String channelId, int seq, int? previous) async {
    // Read before the first await: the widget can be disposed while this runs.
    final storeFuture = _ref.read(storeProvider.future);
    final client = _ref.read(apiProvider);
    try {
      final store = await storeFuture;
      // Reading clears the manual mark here too, so the dot goes out at once.
      await store.setReadMarker(channelId, seq, manuallyUnread: false);
      await client.markRead(channelId: channelId, seq: seq);
    } on api.ApiException catch (e) {
      // The local marker already advanced; only the server one is behind.
      if (_isTransient(e)) _forget(channelId, seq, previous);
    } on Object {
      _forget(channelId, seq, previous);
    }
  }

  /// A 4xx is a refusal a retry cannot change, so it stays recorded as sent.
  static bool _isTransient(api.ApiException e) =>
      e is api.TransportException ||
      e is api.RateLimitedException ||
      e is api.UnavailableException ||
      e is api.ServerException;

  /// Lets the next [advance] for this seq send again, unless a newer one has since gone out.
  void _forget(String channelId, int seq, int? previous) {
    if (_sent[channelId] != seq) return;
    if (previous == null) {
      _sent.remove(channelId);
    } else {
      _sent[channelId] = previous;
    }
  }
}
