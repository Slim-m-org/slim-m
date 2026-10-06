// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Message-row actions shared by any screen that renders a message: reaction
/// and poll-vote toggles apply an optimistic local update before the real
/// request, reverting on failure where a clean revert exists; edit and
/// delete let the request fail up to the caller, which has a user-visible
/// error to show. The `can*` gates decide what a caller may even offer,
/// mirroring the server's own author-or-permission checks.
///
/// A send (and its retry) is the third shape: it applies its optimistic row
/// immediately and marks it failed on refusal, with nothing thrown up to a
/// caller at all - that is what lets `SyncController` retry a failed send on
/// reconnect with nobody to report a failure to.
library;

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

import '../api_failure.dart';
import '../permissions.dart';
import 'message_extras.dart';
import 'message_search.dart' show ProviderReader;
import 'providers.dart';
import 'slow_mode_controller.dart';

/// Toggles a reaction: off if [wasActive], on otherwise. Applied
/// optimistically before the request, so a chip responds immediately; a
/// failure reverts it, and the acting connection's own `reactions.changed`
/// broadcast (it receives its own broadcasts too) reconciles the rest
/// either way.
Future<void> setReaction(
  WidgetRef ref,
  String messageId,
  String emoji, {
  required bool wasActive,
}) async {
  final extras = ref.read(messageExtrasProvider.notifier);
  final activate = !wasActive;
  extras.applyLocalReactionToggle(messageId, emoji, activate);
  try {
    final client = ref.read(apiProvider);
    if (activate) {
      await client.addReaction(messageId: messageId, emoji: emoji);
    } else {
      await client.removeReaction(messageId: messageId, emoji: emoji);
    }
  } on api.ApiException {
    extras.applyLocalReactionToggle(messageId, emoji, wasActive);
  }
}

/// Whether the caller has already reacted to [messageId] with [emoji],
/// according to whatever this session currently has cached.
bool hasReacted(WidgetRef ref, String messageId, String emoji) => ref
    .read(messageExtrasProvider.notifier)
    .extrasFor(messageId)
    .reactions
    .any((r) => r.emoji == emoji && r.reacted);

/// Casts (or changes) a vote, applied optimistically for the same reason
/// reactions are: `poll.voted` never reports back who voted, only the
/// refreshed tally, so the voter's own [api.Poll.votedOption] would
/// otherwise never update on their own screen.
///
/// A failed request is swallowed rather than reverted. There is no clean revert
/// for a vote the way there is for a reaction, since the previous choice is
/// already folded into the locally merged tally, so this leans on the next
/// `poll.voted` broadcast or re-fetch to correct the screen.
Future<void> castVote(WidgetRef ref, String messageId, int option) async {
  ref.read(messageExtrasProvider.notifier).applyLocalVote(messageId, option);
  try {
    await ref.read(apiProvider).votePoll(messageId: messageId, option: option);
  } on api.ApiException {
    // Best-effort: the next tally corrects this, and a vote has no clean revert.
  }
}

bool _isAuthor(Message message, String? myUserId) =>
    message.authorId != null && message.authorId == myUserId;

/// Any live message, own included - unlike edit and delete, replying to your
/// own message is completely ordinary. Gated on SEND_MESSAGES, the same bit
/// the server checks on the send this starts: offering it to somebody a
/// timeout or an overwrite has denied would only ever end in the 400 that
/// permission produces.
bool canReplyToMessage(Message message, int myPermissions) =>
    !message.pending &&
    !message.failed &&
    myPermissions.hasPermission(Perm.sendMessages);

/// Gated the same way [canReplyToMessage] is - opening a thread is a way of
/// sending, not a way of managing the channel - plus one more: never inside
/// a thread already. Nesting is refused server-side (see
/// `docs/decisions/0005-threads.md`), so this keeps the menu from offering
/// an action that would only ever come back a 400.
bool canOpenThreadFor(
  Message message,
  int myPermissions, {
  required bool channelIsThread,
}) => !channelIsThread && canReplyToMessage(message, myPermissions);

/// Own message only, matching the server's author check: a member holding
/// MANAGE_MESSAGES can edit someone else's message server-side too, but
/// that is deliberately not offered here (see `channel_screen.dart`).
bool canEditMessage(Message message, String? myUserId) =>
    !message.pending && !message.failed && _isAuthor(message, myUserId);

/// The caller's own most recent editable message in [messages] (oldest
/// first, [MessageStore.watchChannel]'s own order), or null if there isn't
/// one. Backs "Up in an empty composer edits your last message": scanning
/// from the end finds the newest match without sorting by `seq` again.
Message? lastEditableOwnMessage(List<Message> messages, String? myUserId) {
  for (final message in messages.reversed) {
    if (canEditMessage(message, myUserId)) return message;
  }
  return null;
}

/// The caller's own most recent editable message in [channelId], or null -
/// what Up in an empty composer opens for editing. Takes [store] and
/// [myUserId] already resolved rather than a [WidgetRef], so the one await
/// in here is the only one: a caller that reads providers before and after
/// can put its own `mounted` check around them instead of this function
/// guessing whether its `ref` is still good partway through.
Future<Message?> lastOwnMessageInChannel(
  MessageStore store,
  String channelId,
  String? myUserId,
) async {
  final messages = await store.channelSnapshot(channelId);
  return lastEditableOwnMessage(messages, myUserId);
}

/// Own message, or MANAGE_MESSAGES. A pending or failed send was never
/// stored server-side, so it has nothing here to delete; its own
/// retry/discard row covers that case instead.
bool canDeleteMessage(Message message, String? myUserId, int myPermissions) =>
    !message.pending &&
    !message.failed &&
    (_isAuthor(message, myUserId) ||
        myPermissions.hasPermission(Perm.manageMessages));

/// MANAGE_MESSAGES only; there is no author exception for pinning.
bool canManageMessagePin(Message message, int myPermissions) =>
    !message.pending &&
    !message.failed &&
    myPermissions.hasPermission(Perm.manageMessages);

/// MANAGE_MESSAGES only, matching bulk-delete's own server-side gate with no
/// author exception - unlike [canDeleteMessage], which a plain member also
/// satisfies for their own message. That gap matters here specifically:
/// selection mode lets any visible message be added once it starts, so
/// keying the entry point off [canDeleteMessage] would let a plain member
/// open the mode from their own message and then pick someone else's.
bool canStartSelectingMessages(Message message, int myPermissions) =>
    canManageMessagePin(message, myPermissions);

/// Any live message not your own. The server enforces no authorship rule
/// on `/reports`; this is purely a client-side UX gate.
bool canReportMessage(Message message, String? myUserId) =>
    !message.pending && !message.failed && !_isAuthor(message, myUserId);

/// Any live message, own included: forwarding reads [Message.content], it
/// never re-sends the exact stored row, and the destination picker only
/// ever offers a channel or DM the caller can already send to - so unlike
/// [canReplyToMessage] this needs no permission check against the *current*
/// channel at all.
bool canForwardMessage(Message message) => !message.pending && !message.failed;

/// Linking needs a message the server already has, for the same reason
/// forwarding and saving do: the id is the client's, but nothing else can reach
/// the row it names until the send is acknowledged, so a link to a pending
/// message would resolve to nothing for whoever followed it.
///
/// No permission check. A link is a string; following one runs the same
/// authorization the recipient's own channel read already does, and a link to a
/// channel they cannot see simply fails to find the message.
bool canCopyMessageLink(Message message) => !message.pending && !message.failed;

/// Saving needs a message the server already has, for the same reason
/// forwarding does: the id is the client's, but the row it names is not
/// there until the send is acknowledged. No permission beyond being able
/// to read it - keeping something you can see is not a further privilege.
bool canSaveMessage(Message message) => !message.pending && !message.failed;

/// Blocking is keyed by author id, so a message with no live author (its
/// account was deleted and the content anonymized) has nobody left to block.
bool canBlockMessageAuthor(Message message, String? myUserId) =>
    !message.pending &&
    !message.failed &&
    message.authorId != null &&
    !_isAuthor(message, myUserId);

/// Edits a message, then applies the server's returned copy (with its
/// fresh `edited_at`) to the local store and the extras cache the same way
/// a live `message.edited` event would, so the row's own edited marker
/// updates without waiting for that broadcast to loop back.
Future<void> editMessageAction(
  WidgetRef ref,
  Message message,
  String content,
) async {
  final updated = await ref
      .read(apiProvider)
      .editMessage(
        channelId: message.channelId,
        messageId: message.id,
        content: content,
      );
  final store = await ref.read(storeProvider.future);
  await store.applyMessage(updated);
  ref.read(messageExtrasProvider.notifier).applyMessage(updated);
}

/// Deletes a message server-side, then drops its local row so it vanishes
/// from this device immediately rather than waiting for the `message.deleted`
/// broadcast [SyncController] applies the same way.
Future<void> deleteMessageAction(WidgetRef ref, Message message) async {
  await ref
      .read(apiProvider)
      .deleteMessage(channelId: message.channelId, messageId: message.id);
  final store = await ref.read(storeProvider.future);
  await store.discard(message.id);
}

/// Deletes several messages in one request, then drops their local rows the
/// same way [deleteMessageAction] drops one.
///
/// One request rather than a loop, which is the whole point of the endpoint:
/// a loop would hold the moderator through N round trips while a raid
/// continues, and would half-succeed in a way neither they nor the audit log
/// could describe afterwards.
///
/// Ids the server did not delete - already gone, or never in this channel -
/// are not an error there, so nothing is reported here either. The local
/// discard is unconditional for the same reason: a row for a message the
/// server says is not there should not survive on this device.
Future<void> bulkDeleteMessagesAction(
  WidgetRef ref, {
  required String channelId,
  required List<String> messageIds,
}) async {
  if (messageIds.isEmpty) return;
  await ref
      .read(apiProvider)
      .bulkDeleteMessages(channelId: channelId, messageIds: messageIds);
  final store = await ref.read(storeProvider.future);
  for (final id in messageIds) {
    await store.discard(id);
  }
}

/// Puts a message on screen before the network has answered, then reconciles
/// with the server's copy.
///
/// The id is the caller's and is reused on retry, so a retry after an
/// uncertain failure can never post twice - the server's own send route is
/// idempotent by (channel, author, id), and this is the one place that
/// invariant is spent. Takes a [ProviderReader] rather than either ref type
/// directly (see that typedef's own doc comment): a screen's manual retry
/// holds a `WidgetRef`, and `SyncController`'s reconnect retry holds a plain
/// `Ref`, and the two share no common supertype in this Riverpod version.
///
/// [onQueued] fires once the local row exists and before the request goes
/// out, which is when a sender wants the transcript scrolled.
Future<void> sendOptimistically(
  ProviderReader read, {
  required String id,
  required String channelId,
  required String authorId,
  required String content,
  List<String> attachmentIds = const [],
  String? replyToId,
  VoidCallback? onQueued,
}) async {
  final store = await read(storeProvider.future);
  await store.addPending(
    id: id,
    channelId: channelId,
    authorId: authorId,
    content: content,
    replyToId: replyToId,
    attachmentIds: attachmentIds,
  );
  onQueued?.call();
  try {
    final sent = await read(apiProvider).sendMessage(
      channelId: channelId,
      id: id,
      content: content,
      attachmentIds: attachmentIds,
      replyToId: replyToId,
    );
    // Lands on the same row, because it carries the same id.
    await store.applyMessage(sent);
    read(messageExtrasProvider.notifier).applyMessage(sent);
    // The device clock, since the countdown ticks on it; the server's `created_at` can sit minutes off a skewed device and pin the countdown.
    read(
      slowModeLastSentProvider.notifier,
    ).recordSent(channelId, DateTime.now());
  } on api.ApiException catch (e) {
    await store.markFailed(
      id,
      reason: describeApiFailure('send the message', e),
    );
  }
}

/// Re-sends a message whose first attempt failed, under its original id.
/// Called both from a message row's own manual retry button and from
/// `SyncController`'s automatic retry on reconnect.
Future<void> retryMessage(ProviderReader read, Message message) async {
  final store = await read(storeProvider.future);
  await sendOptimistically(
    read,
    id: message.id,
    channelId: message.channelId,
    authorId: message.authorId ?? '',
    content: message.content,
    attachmentIds: await store.pendingAttachmentIds(message.id),
    replyToId: message.replyToId,
  );
}

/// Discards a failed send. Nothing reached the server, so nothing to undo.
Future<void> discardMessage(ProviderReader read, Message message) async =>
    (await read(storeProvider.future)).discard(message.id);
