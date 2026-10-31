// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The message writes the message widgets make that carry no local optimistic state of their own.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/providers.dart';

class MessageApiActions {
  const MessageApiActions(this._api);

  final SlimmApi _api;

  Future<void> submitInteractionForm({
    required String channelId,
    required String interactionId,
    required String id,
    required Map<String, String> fields,
  }) => _api.submitInteractionForm(
    channelId: channelId,
    interactionId: interactionId,
    id: id,
    fields: fields,
  );

  Future<Message> sendMessage({
    required String channelId,
    required String id,
    required String content,
    List<String> attachmentIds = const [],
    List<String> spoilerAttachmentIds = const [],
    String? replyToId,
    bool mentionReply = true,
    String? forwardedFromId,
  }) => _api.sendMessage(
    channelId: channelId,
    id: id,
    content: content,
    attachmentIds: attachmentIds,
    spoilerAttachmentIds: spoilerAttachmentIds,
    replyToId: replyToId,
    mentionReply: mentionReply,
    forwardedFromId: forwardedFromId,
  );

  Future<ReadState> markUnread(String channelId) => _api.markUnread(channelId);

  Future<void> unsaveMessage(String messageId) => _api.unsaveMessage(messageId);

  Future<List<ChannelReadState>> markChannelsRead(List<String> channelIds) =>
      _api.markChannelsRead(channelIds);
}

final messageApiActionsProvider = Provider(
  (ref) => MessageApiActions(ref.watch(apiProvider)),
);
