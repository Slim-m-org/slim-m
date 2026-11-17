// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A read-only window of messages around one that is too old to page to,
/// held in memory and never written to the local store.
///
/// The transcript shows it in place of the live window until it is closed, so
/// the store keeps its contiguous history and its read cursors.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart' show Message;

import '../../../providers/providers.dart';
import 'local_message_of.dart';
import 'message_extras.dart';

/// Rows asked for around the target: the server clamps to its own maximum.
const int contextWindowRows = 100;

class MessageContextWindow {
  const MessageContextWindow({required this.targetId, required this.messages});

  final String targetId;

  /// Oldest first, the order the store hands the transcript.
  final List<Message> messages;
}

class MessageContextController
    extends FamilyNotifier<MessageContextWindow?, String> {
  /// Bumped by every open and close, so a fetch that a close or a newer open overtook never shows.
  int _ticket = 0;

  @override
  MessageContextWindow? build(String channelId) => null;

  /// Fetches the page around [messageId] and shows it; the fetch's errors
  /// reach the caller, which words them as a jump refusal.
  Future<void> open(String messageId) async {
    final ticket = ++_ticket;
    final client = ref.read(apiProvider);
    final target = await client.getMessage(
      channelId: arg,
      messageId: messageId,
    );
    final page = await client.listMessages(
      arg,
      around: target.seq,
      limit: contextWindowRows,
    );
    if (ticket != _ticket) return;
    ref.read(messageExtrasProvider.notifier).applyMessages(page);
    final rows = [for (final m in page.reversed) localMessageOf(m)];
    if (!rows.any((m) => m.id == messageId)) rows.add(localMessageOf(target));
    rows.sort((a, b) => a.seq.compareTo(b.seq));
    state = MessageContextWindow(targetId: messageId, messages: rows);
  }

  void close() {
    _ticket++;
    if (state != null) state = null;
  }
}

final messageContextWindowProvider =
    NotifierProvider.family<
      MessageContextController,
      MessageContextWindow?,
      String
    >(MessageContextController.new);
