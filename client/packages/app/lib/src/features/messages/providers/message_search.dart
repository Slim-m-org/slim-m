// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Running a message search: the command palette's one entry point, which
/// builds the request from a parsed query, drops blocked authors, and tells
/// a 403 apart from any other failure.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../members/providers/blocks_controller.dart';
import 'message_search_query.dart';
import 'message_search_request.dart';
import '../../../providers/providers.dart';

/// What running a message search came back with.
///
/// [MessageSearchForbidden] is not transient: the same query fails again
/// until the caller's permissions change, unlike [MessageSearchFailed], which
/// is worth a retry.
sealed class MessageSearchResult {
  const MessageSearchResult();
}

/// Hits with any blocked author already dropped.
class MessageSearchHits extends MessageSearchResult {
  const MessageSearchHits(this.messages);
  final List<api.Message> messages;
}

/// The caller may not search this channel at all.
class MessageSearchForbidden extends MessageSearchResult {
  const MessageSearchForbidden();
}

/// Some other failure; worth a retry.
class MessageSearchFailed extends MessageSearchResult {
  const MessageSearchFailed();
}

/// The one method this needs off `Ref`/`WidgetRef`: reading a provider once.
/// The two share no common supertype in this Riverpod version, but their
/// `read` methods have identical signatures.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// Searches what [parsed] asks for, dropping any hit from a blocked author.
/// An `in:` picked from a list goes through that channel's own route, so a
/// DM or a thread is searched exactly; anything else searches every channel
/// the caller can view. [beforeId] is the last hit of the previous page.
///
/// A query the server would refuse for naming nothing comes back
/// [MessageSearchFailed] without a request.
Future<MessageSearchResult> searchMessages(
  ProviderReader read,
  ParsedSearchQuery parsed, {
  int? limit,
  String? beforeId,
}) async {
  final request = messageSearchRequest(parsed);
  if (request.isEmpty) return const MessageSearchFailed();
  // Read before the await: a caller closed meanwhile (the palette) no longer owns its ref.
  final blocks = read(blocksProvider);
  final client = read(apiProvider);
  try {
    final hits = await switch (request.channelId) {
      final channelId? => client.searchMessages(
        channelId,
        q: request.q,
        limit: limit,
        from: request.from,
        has: request.has,
        mentions: request.mentions,
        pinned: request.pinned,
        afterDate: request.afterDate,
        beforeDate: request.beforeDate,
        beforeId: beforeId,
      ),
      null => client.searchAllMessages(
        q: request.q,
        limit: limit,
        from: request.from,
        inChannel: request.inChannel,
        has: request.has,
        mentions: request.mentions,
        pinned: request.pinned,
        afterDate: request.afterDate,
        beforeDate: request.beforeDate,
        beforeId: beforeId,
      ),
    };
    return MessageSearchHits(
      hits
          .where((message) => !blocks.contains(message.authorId))
          .toList(growable: false),
    );
  } on api.ForbiddenException catch (error, stack) {
    api.AppLog.swallowed(
      api.LogTag.ui,
      'The server could not search; showing no results',
      error,
      stack,
    );
    return const MessageSearchForbidden();
  } on api.ApiException catch (error, stack) {
    api.reportFailure(api.LogTag.ui, 'search messages', error, stack);
    return const MessageSearchFailed();
  }
}

/// What a voice message said, when a search hit matched through its transcript;
/// null for any other hit, so the caller shows the file's name instead.
String? matchedVoiceTranscript(api.Message message) {
  final id = message.matchedAttachmentId;
  if (id == null) return null;
  for (final attachment in message.attachments) {
    final transcript = attachment.transcript;
    if (attachment.id == id &&
        attachment.voice != null &&
        transcript != null &&
        transcript.status == api.VoiceTranscriptStatus.ready &&
        transcript.text.isNotEmpty) {
      return transcript.text;
    }
  }
  return null;
}

/// The file a search hit matched through, or null when the message's own text
/// matched. Falls back to a generic name when the attachment is not on the hit.
String? matchedAttachmentName(api.Message message) {
  final id = message.matchedAttachmentId;
  if (id == null) return null;
  for (final attachment in message.attachments) {
    if (attachment.id == id) return attachment.filename;
  }
  return 'an attachment';
}
