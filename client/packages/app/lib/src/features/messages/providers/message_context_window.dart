// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A read-only window of messages around one that is too old to page to,
/// held in memory and never written to the local store.
///
/// The transcript shows it in place of the live window until it is closed, so
/// the store keeps its contiguous history and its read cursors.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart' show Message, ForwardedMessage;

import '../../../providers/providers.dart';
import 'message_extras.dart';

/// Rows asked for around the target: the server clamps to its own maximum.
const int contextWindowRows = 100;

class MessageContextWindow {
  const MessageContextWindow({required this.targetId, required this.messages});

  final String targetId;

  /// Oldest first, the order the store hands the transcript.
  final List<Message> messages;
}

class MessageContextController extends StateNotifier<MessageContextWindow?> {
  MessageContextController(this._ref, this._channelId) : super(null);

  final Ref _ref;
  final String _channelId;

  /// Fetches the page around [messageId] and shows it; the fetch's errors
  /// reach the caller, which words them as a jump refusal.
  Future<void> open(String messageId) async {
    final client = _ref.read(apiProvider);
    final target = await client.getMessage(
      channelId: _channelId,
      messageId: messageId,
    );
    final page = await client.listMessages(
      _channelId,
      around: target.seq,
      limit: contextWindowRows,
    );
    if (!mounted) return;
    _ref.read(messageExtrasProvider.notifier).applyMessages(page);
    final rows = [for (final m in page.reversed) _rowFor(m)];
    if (!rows.any((m) => m.id == messageId)) rows.add(_rowFor(target));
    rows.sort((a, b) => a.seq.compareTo(b.seq));
    state = MessageContextWindow(targetId: messageId, messages: rows);
  }

  void close() => state = null;
}

final messageContextWindowProvider =
    StateNotifierProvider.family<
      MessageContextController,
      MessageContextWindow?,
      String
    >((ref, channelId) => MessageContextController(ref, channelId));

Message _rowFor(api.Message m) => Message(
  id: m.id,
  channelId: m.channelId,
  authorId: m.authorId,
  authorDisplayName: m.authorDisplayName,
  seq: m.seq,
  content: m.content,
  createdAt: m.createdAt,
  editedAt: m.editedAt,
  replyToId: m.replyToId,
  forwarded: m.forwarded == null
      ? null
      : ForwardedMessage(
          messageId: m.forwarded!.messageId,
          channelId: m.forwarded!.channelId,
          authorId: m.forwarded!.authorId,
          authorDisplayName: m.forwarded!.authorDisplayName,
          authorAvatarUpdatedAt: m.forwarded!.authorAvatarUpdatedAt,
          createdAt: m.forwarded!.createdAt,
          content: m.forwarded!.content,
          removed: m.forwarded!.removed,
        ),
  linkPreviewsRemoved: m.linkPreviewsRemoved,
  pending: false,
  failed: false,
);
