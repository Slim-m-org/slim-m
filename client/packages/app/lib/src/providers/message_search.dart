// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The message-search calls `ChannelSearchController` (the in-channel search
/// bar) and the command palette's message section make: [searchChannelMessages]
/// for one channel, [searchAllMessages] for the command palette's
/// cross-channel scope.
///
/// The two in-channel callers had already diverged once - both called
/// `searchMessages` and both independently filtered blocked authors, but only
/// the controller told a 403 apart from any other failure. Centralising the
/// call is what stops that happening again: a caller gets both the filtering
/// and the error distinction for free, rather than having to remember to copy
/// them; [_runSearch] is what the two public functions share once the only
/// difference left is which endpoint to call.
///
/// This is also the one place a raw search-bar string turns into the
/// Slack-style operators `http::search` accepts
/// ([parseSearchQuery]), so every caller gets the same operator support
/// automatically rather than each having to parse it themselves.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../features/members/providers/blocks_controller.dart';
import 'message_search_query.dart';
import 'providers.dart';

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
/// Taking this instead of either ref type directly is what lets both
/// `ChannelSearchController` (a `Ref`) and the command palette (a
/// `WidgetRef`) call the same helper - the two share no common supertype in
/// this Riverpod version, but their `read` methods have identical signatures.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// Parses [query] for the operators [ParsedSearchQuery] documents, searches
/// [channelId] (or the `in:`-named channel) for whatever remains, and drops
/// any hit from a blocked author - the same filtering the transcript, pins
/// and typing already apply.
///
/// A [query] made entirely of whitespace parses to
/// [ParsedSearchQuery.isEmpty], which this refuses locally with
/// [MessageSearchFailed] rather than sending a request the server would
/// refuse anyway with the same 400 a hand-typed empty query already gets.
Future<MessageSearchResult> searchChannelMessages(
  ProviderReader read,
  String channelId,
  String query, {
  int? limit,
}) => _runSearch(
  read,
  query,
  (parsed) => read(apiProvider).searchMessages(
    channelId,
    q: parsed.text.isEmpty ? null : parsed.text,
    limit: limit,
    from: parsed.from,
    inChannel: parsed.inChannel,
    has: parsed.has,
    afterDate: parsed.afterDate,
    beforeDate: parsed.beforeDate,
  ),
);

/// [searchChannelMessages], scoped to every channel the caller can view
/// instead of one - the command palette's cross-channel search, backed by
/// `GET /search/messages` rather than the per-channel route. Same operator
/// parsing, same blocked-author filtering, same 403-versus-any-other-failure
/// distinction; only the endpoint and its default scope differ.
Future<MessageSearchResult> searchAllMessages(
  ProviderReader read,
  String query, {
  int? limit,
}) => _runSearch(
  read,
  query,
  (parsed) => read(apiProvider).searchAllMessages(
    q: parsed.text.isEmpty ? null : parsed.text,
    limit: limit,
    from: parsed.from,
    inChannel: parsed.inChannel,
    has: parsed.has,
    afterDate: parsed.afterDate,
    beforeDate: parsed.beforeDate,
  ),
);

/// The shared tail of [searchChannelMessages] and [searchAllMessages]: parse
/// [query], refuse an empty one locally, run [call] against whichever
/// endpoint the caller chose, then drop blocked authors and tell a 403 apart
/// from any other failure.
Future<MessageSearchResult> _runSearch(
  ProviderReader read,
  String query,
  Future<List<api.Message>> Function(ParsedSearchQuery parsed) call,
) async {
  final parsed = parseSearchQuery(query);
  if (parsed.isEmpty) {
    return const MessageSearchFailed();
  }
  try {
    final hits = await call(parsed);
    final blocks = read(blocksProvider);
    return MessageSearchHits(
      hits
          .where((message) => !blocks.contains(message.authorId))
          .toList(growable: false),
    );
  } on api.ForbiddenException {
    return const MessageSearchForbidden();
  } on api.ApiException {
    return const MessageSearchFailed();
  }
}
