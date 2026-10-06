// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a message row can ask its caller to do, as one value so a new action
/// is added here once rather than threaded through every widget between the
/// transcript and the part that fires it.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart' as api;

class MessageRowCallbacks {
  const MessageRowCallbacks({
    required this.onRetry,
    required this.onDiscard,
    required this.onPickReaction,
    required this.onReactionTap,
    required this.onVote,
    required this.onSubmitEdit,
    required this.onCancelEdit,
    this.onEditFailed,
    this.onViewEditHistory,
    this.onReplyTap,
  });

  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  /// Recovers a failed message's text for editing (error grammar 01: failed
  /// content is never thrown away). Null hides the Edit action.
  final VoidCallback? onEditFailed;

  /// Called with the token the add-reaction picker chose (a codepoint, or a
  /// `:shortcode:` for one of the deployment's own), from the hover toolbar's
  /// button or from the long-press menu's own sheet, which is the only one of
  /// the two a finger can reach.
  final ValueChanged<String> onPickReaction;

  /// Toggles the caller's own reaction for an existing chip: on if
  /// [api.ReactionSummary.reacted] was false, off if it was true.
  final ValueChanged<api.ReactionSummary> onReactionTap;

  /// Casts (or changes) the caller's vote when the message carries a poll.
  /// Always required, like every other callback here, even though it is only
  /// ever invoked when there is a poll to vote on.
  final ValueChanged<int> onVote;

  /// Called with the trimmed new content when an inline edit is saved.
  final ValueChanged<String> onSubmitEdit;

  /// Called to leave edit mode without saving, however that happened
  /// (Escape, the Cancel button, or submitting empty text).
  final VoidCallback onCancelEdit;

  /// Opens this message's edit history. Null leaves the "edited" marker
  /// inert - a view-only surface, or a message with nothing to show.
  final VoidCallback? onViewEditHistory;

  /// Jumps to the parent named by `Message.replyToId`. Only ever called when
  /// that id is non-null, so it is safe to leave null when the message is not
  /// a reply.
  final VoidCallback? onReplyTap;
}
