// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Picking several messages out of a transcript in order to act on them all
/// at once.
///
/// `POST /channels/{channelId}/messages/bulk-delete` shipped in #675 with no
/// caller, and MOD2's member search shipped the ability to *find* a wave of
/// throwaway accounts with no way to act on what it found. This is the piece
/// that joins the two: a moderator can now select the spam and remove it in
/// one request rather than one dialog per message while the raid continues.
///
/// State is per channel and `autoDispose`, so leaving a channel drops the
/// selection rather than carrying it somewhere it would name messages that
/// are not on screen.
///
/// Selection deliberately holds ids rather than messages. A selected message
/// can be deleted by somebody else, or fall out of the loaded window, while
/// the bar is still open; the server treats an id that is already deleted as
/// a no-op rather than an error, so a stale id costs nothing and the
/// alternative - pruning the set on every transcript rebuild - would make
/// the selection flicker under normal traffic.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';

/// The most ids one bulk-delete request may name.
///
/// Mirrors `MAX_BULK_DELETE_IDS` in `http/messages_bulk.rs`, which rejects a
/// longer list with 400. Enforced here too so the cap is reached as a control
/// that stops responding rather than as a request that fails.
const int maxBulkDeleteIds = 64;

/// What is selected in one channel, and whether selection is on at all.
///
/// [active] is separate from `ids.isEmpty` on purpose: deselecting the last
/// message leaves selection mode running with nothing selected, rather than
/// closing the bar out from under somebody who is still choosing. Only an
/// explicit cancel, or a completed delete, ends the mode.
@immutable
class MessageSelection {
  const MessageSelection({
    this.ids = const {},
    this.active = false,
    this.anchor,
  });

  final Set<String> ids;
  final bool active;

  /// The message last picked by a plain tap: where a shift-tap extends from.
  final String? anchor;

  int get count => ids.length;
  bool contains(String id) => ids.contains(id);

  /// True once no further message may be added. Deselecting still works.
  bool get atCap => ids.length >= maxBulkDeleteIds;
}

class MessageSelectionController extends StateNotifier<MessageSelection> {
  MessageSelectionController() : super(const MessageSelection());

  /// Turns selection on with [id] already picked, which is how the transcript
  /// enters the mode: the message whose menu was used is the first selected.
  void start(String id) =>
      state = MessageSelection(ids: {id}, active: true, anchor: id);

  /// Adds [id], or removes it if it is already selected.
  ///
  /// At the cap this adds nothing, but still removes: a full selection that
  /// could not be undone would strand somebody who picked one message too
  /// many with no way back except cancelling the whole thing.
  void toggle(String id) {
    if (!state.active) return;
    final next = {...state.ids};
    if (!next.remove(id)) {
      if (state.atCap) return;
      next.add(id);
    }
    state = MessageSelection(ids: next, active: true, anchor: id);
  }

  /// A shift-tap: selects every message from the anchor to [id] inclusive,
  /// along [order] (the transcript's ids, oldest first), in either direction.
  ///
  /// Extends rather than replaces, so a selection made elsewhere in the
  /// transcript survives, and the anchor stays put so a second shift-tap
  /// re-extends from the same message - the way a file manager behaves.
  /// Filled from the anchor outward, so hitting the cap leaves a contiguous
  /// run rather than a gap. With no anchor in [order] this is a plain
  /// [toggle].
  void extendTo(String id, List<String> order) {
    if (!state.active) return;
    final anchor = state.anchor;
    final from = anchor == null ? -1 : order.indexOf(anchor);
    final to = order.indexOf(id);
    if (from < 0 || to < 0) return toggle(id);
    final next = {...state.ids};
    final step = to >= from ? 1 : -1;
    for (var i = from; i != to + step; i += step) {
      if (next.length >= maxBulkDeleteIds && !next.contains(order[i])) break;
      next.add(order[i]);
    }
    state = MessageSelection(ids: next, active: true, anchor: anchor);
  }

  /// Ends selection mode and forgets everything picked.
  void clear() => state = const MessageSelection();
}

/// Selection for one channel's transcript, keyed by channel id.
final messageSelectionProvider = StateNotifierProvider.autoDispose
    .family<MessageSelectionController, MessageSelection, String>(
      (ref, channelId) => MessageSelectionController(),
    );

/// A refused bulk delete, kept above the selection bar until dismissed.
///
/// The bar stays up with the selection intact for a retry, so the failure has
/// a place to sit; autoDispose drops it when the mode ends.
final messageBulkDeleteErrorProvider = StateProvider.autoDispose
    .family<String?, String>((ref, channelId) => null);
