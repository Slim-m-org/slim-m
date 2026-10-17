// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Applying the message op stream: how an edit or a delete made while this
/// client was offline finally reaches it.
///
/// A sibling of `sync_controller.dart` rather than part of it, for the line
/// budget.
///
/// The rules here are conventions with no type behind them, and each is a
/// one-word mistake with no symptom until much later, so each has its own
/// test: an op is applied before its cursor moves, an unknown kind resets
/// rather than being skipped, and a live op is applied only when it is exactly
/// the next one.
library;

import 'package:slimm_api/api.dart';
import 'package:slimm_data/data.dart';

/// What applying a page of ops asks the caller to do next.
enum OpsOutcome {
  /// Everything in the page was understood and applied.
  applied,

  /// The page held a kind this client cannot interpret, so it cannot know what
  /// the op did. Skipping it would advance the cursor past a change that was
  /// never made locally, leaving a stale copy nothing would ever correct, so
  /// the caller resets the channel instead.
  needsReset,
}

/// Applies a page of ops in order and advances the op cursor to the last one
/// actually applied.
///
/// The cursor moves per op rather than once at the end, so an interruption
/// leaves the client asking for exactly what it has not yet seen rather than
/// replaying a page it half-applied. Replaying is harmless (an edit and a
/// delete are both idempotent by message id) but asking again for what is
/// already applied is not free.
Future<OpsOutcome> applyOps(
  MessageStore store,
  String channelId,
  List<MessageOp> ops,
) async {
  for (final op in ops) {
    switch (op) {
      case MessageEditOp(
        :final content,
        :final editedAt,
        :final forwardedRemoved,
      ):
        // Gone or collapsed; a later op is what the client acts on instead.
        if (content != null) {
          await store.applyEdit(op.messageId, content, editedAt);
        }
        if (forwardedRemoved) await store.removeForwardSnapshot(op.messageId);
      case MessageDeleteOp():
        await store.discard(op.messageId);
      case MessageUnknownOp():
        return OpsOutcome.needsReset;
    }
    await store.setOpCursor(channelId, op.seq);
  }
  return OpsOutcome.applied;
}

// The live-op adjacency rule (liveOpDecision, LiveOpOutcome) moved to op_adjacency.dart so the canvas op stream shares the one copy (CD3).
