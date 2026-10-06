// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// The whole `messages` tag: sending, reading, editing, deleting,
/// full-text search and reactions.
///
/// The first three used to sit in `client.dart` and the rest here, which
/// was a line-count boundary rather than a real one.
extension SlimmApiMessages on SlimmApi {
  /// History, newest first. Pass the smallest `seq` already held as [before] to
  /// page backwards.
  Future<List<Message>> listMessages(
    String channelId, {
    int? before,
    int? limit,
  }) async {
    final query = <String, String>{
      if (before != null) 'before': '$before',
      if (limit != null) 'limit': '$limit',
    };
    final json = await _send(
      'GET',
      '/channels/$channelId/messages',
      query: query.isEmpty ? null : query,
    );
    return (json as List<dynamic>)
        .map((m) => Message.fromJson(m as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Fetches one message, enriched exactly like a page from [listMessages] -
  /// for a message outside the currently loaded window, such as jumping to a
  /// reply or a search result. A channel the caller cannot see answers 404,
  /// the same as a message that never existed.
  Future<Message> getMessage({
    required String channelId,
    required String messageId,
  }) async {
    final json = await _send('GET', '/channels/$channelId/messages/$messageId');
    return Message.fromJson(json as Map<String, dynamic>);
  }

  /// Sends a message. [id] must be a client-generated UUIDv7 and makes the send
  /// idempotent, so retrying an uncertain send is always safe. [attachmentIds]
  /// are hex sha256 ids already uploaded through [SlimmApi.uploadAttachment],
  /// in display order; a non-empty list needs ATTACH_FILES in addition to
  /// SEND_MESSAGES. [replyToId] must already name a message in this same
  /// channel (live or deleted) or the send is refused.
  ///
  /// [forwardedFromId] may name a message in any channel the sender can see,
  /// but it must be live: forwarding copies the text, so a deleted original
  /// is refused rather than republished. Only the id goes over the wire - the
  /// server reads the original's author, timestamp and text itself, so a
  /// forward can never be dressed up as something the original never said.
  /// [content] is then the sender's own note and may be empty.
  Future<Message> sendMessage({
    required String channelId,
    required String id,
    required String content,
    List<String> attachmentIds = const [],
    String? replyToId,
    String? forwardedFromId,
  }) async {
    final json = await _send(
      'POST',
      '/channels/$channelId/messages',
      body: {
        'id': id,
        'content': content,
        if (attachmentIds.isNotEmpty) 'attachment_ids': attachmentIds,
        if (replyToId != null) 'reply_to_id': replyToId,
        if (forwardedFromId != null) 'forwarded_from_id': forwardedFromId,
      },
    );
    return Message.fromJson(json as Map<String, dynamic>);
  }

  Future<Message> editMessage({
    required String channelId,
    required String messageId,
    required String content,
  }) async {
    final json = await _send(
      'PATCH',
      '/channels/$channelId/messages/$messageId',
      body: {'content': content},
    );
    return Message.fromJson(json as Map<String, dynamic>);
  }

  /// Soft-deletes a message. Allowed for the author, or a member with
  /// MANAGE_MESSAGES. Deleting an already-deleted message is not an error.
  Future<void> deleteMessage({
    required String channelId,
    required String messageId,
  }) =>
      _send(
        'DELETE',
        '/channels/$channelId/messages/$messageId',
        expectNoContent: true,
      );

  /// Soft-deletes several messages in one act, requiring MANAGE_MESSAGES in
  /// the channel.
  ///
  /// Ids already deleted are skipped rather than refused, but nothing at all is
  /// deleted unless every id resolves to a message in this channel - so a
  /// batch with one bad id leaves the channel untouched rather than half
  /// purged. At most 64 per call; the server refuses more rather than
  /// truncating, so a caller with a longer list has to chunk it and decide for
  /// itself what a partial failure means.
  ///
  /// Each message deleted arrives separately over the WebSocket as
  /// `message.deleted`, not as one aggregate frame.
  Future<void> bulkDeleteMessages({
    required String channelId,
    required List<String> messageIds,
  }) =>
      _send(
        'POST',
        '/channels/$channelId/messages/bulk-delete',
        body: {'message_ids': messageIds},
        expectNoContent: true,
      );

  /// Soft-deletes one author's recent messages in a channel, requiring
  /// MANAGE_MESSAGES: the raid-response shape, naming an author and a time
  /// window instead of up to 64 explicit ids.
  ///
  /// [windowMinutes] must be between 1 and 1440 (24 hours). If more than 64
  /// messages match, the server refuses the whole request rather than
  /// truncating it, so a caller whose window is too wide has to narrow it and
  /// retry - the same rule [bulkDeleteMessages] already keeps for its own cap.
  Future<void> bulkDeleteMessagesByAuthor({
    required String channelId,
    required String authorId,
    required int windowMinutes,
  }) =>
      _send(
        'POST',
        '/channels/$channelId/messages/bulk-delete-by-author',
        body: {'author_id': authorId, 'window_minutes': windowMinutes},
        expectNoContent: true,
      );

  /// Full-text searches a channel's live messages. [q] reaches FTS5 close to
  /// as-is, so its mini query language (`AND`/`OR`/`NOT`, `"phrase"`, a
  /// trailing `*` prefix) is available; it is optional now, since the
  /// Slack-style operators below can carry a search on their own, but the
  /// server refuses a request with none of [q], [from], [inChannel], [has],
  /// [afterDate] or [beforeDate] set. Results are permission-filtered and
  /// keyset paginated on `seq` exactly like [SlimmApi.listMessages].
  ///
  /// [from] narrows to one author's exact username. [inChannel] searches a
  /// named channel instead of [channelId]; a name that does not exist, or
  /// resolves only to channels this caller cannot view, answers with an
  /// empty list rather than an error, so it is never a way to learn a
  /// hidden channel exists. [has] is `attachment`, `link`, or both
  /// comma-separated (`attachment,link`). [afterDate]/[beforeDate] are
  /// `YYYY-MM-DD`: `afterDate` is inclusive of the named day, `beforeDate`
  /// excludes it.
  Future<List<Message>> searchMessages(
    String channelId, {
    String? q,
    int? before,
    int? limit,
    String? from,
    String? inChannel,
    String? has,
    String? afterDate,
    String? beforeDate,
  }) async {
    final query = <String, String>{
      if (q != null) 'q': q,
      if (before != null) 'before': '$before',
      if (limit != null) 'limit': '$limit',
      if (from != null) 'from': from,
      if (inChannel != null) 'in': inChannel,
      if (has != null) 'has': has,
      if (afterDate != null) 'after_date': afterDate,
      if (beforeDate != null) 'before_date': beforeDate,
    };
    final json = await _send(
      'GET',
      '/channels/$channelId/messages/search',
      query: query,
    );
    return (json as List<dynamic>)
        .map((m) => Message.fromJson(m as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// [searchMessages], scoped to every channel the caller can view instead
  /// of one named by a path. Same query language, same operators
  /// ([q]/[from]/[inChannel]/[has]/[afterDate]/[beforeDate], the same
  /// at-least-one-set rule), same permission filtering, same keyset
  /// pagination - only the default scope differs: with no [inChannel], this
  /// searches every channel `VIEW_CHANNEL` grants rather than one path
  /// channel, DMs and threads excluded the same way `GET /channels` excludes
  /// them.
  Future<List<Message>> searchAllMessages({
    String? q,
    int? before,
    int? limit,
    String? from,
    String? inChannel,
    String? has,
    String? afterDate,
    String? beforeDate,
  }) async {
    final query = <String, String>{
      if (q != null) 'q': q,
      if (before != null) 'before': '$before',
      if (limit != null) 'limit': '$limit',
      if (from != null) 'from': from,
      if (inChannel != null) 'in': inChannel,
      if (has != null) 'has': has,
      if (afterDate != null) 'after_date': afterDate,
      if (beforeDate != null) 'before_date': beforeDate,
    };
    final json = await _send('GET', '/search/messages', query: query);
    return (json as List<dynamic>)
        .map((m) => Message.fromJson(m as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Reacts to a message with one [emoji]. Idempotent: reacting twice with
  /// the same emoji leaves one reaction. [emoji] is user content, never
  /// chrome, so it is a plain runtime string rather than a literal in source.
  ///
  /// The server keys the reaction on the string, not on a codepoint: it takes
  /// any non-empty run under 64 bytes (`MAX_EMOJI_BYTES`, `store/reactions.rs`)
  /// and hands it back verbatim in every summary. So one of the deployment's
  /// own emoji rides here as its `:shortcode:`, at most 34 bytes, and the
  /// colons stay unescaped in the path because they are legal there.
  Future<void> addReaction({
    required String messageId,
    required String emoji,
  }) =>
      _send(
        'PUT',
        '/messages/$messageId/reactions/$emoji',
        expectNoContent: true,
      );

  /// Removes the caller's own reaction of one [emoji] from a message.
  /// Idempotent: removing a reaction that is not there succeeds, since the
  /// caller's intent already holds.
  Future<void> removeReaction({
    required String messageId,
    required String emoji,
  }) =>
      _send(
        'DELETE',
        '/messages/$messageId/reactions/$emoji',
        expectNoContent: true,
      );

  /// Who left [emoji] on a message, oldest first, as the caller may see them:
  /// a reactor the caller has blocked is left out, exactly as the tally leaves
  /// them out of the count. [after] is a previous page's `nextCursor`.
  Future<ReactionUsersPage> listReactionUsers({
    required String messageId,
    required String emoji,
    int? limit,
    String? after,
  }) async {
    final json = await _send(
      'GET',
      '/messages/$messageId/reactions/$emoji',
      query: {
        if (limit != null) 'limit': '$limit',
        if (after != null) 'after': after,
      },
    );
    return ReactionUsersPage.fromJson(json as Map<String, dynamic>);
  }

  /// Runs the fenced code block at [blockIndex] in a message and shares the
  /// result: unlike [runModuleCommand], the output is stored against the block
  /// and broadcast, so everyone viewing the message sees it inline without
  /// rerunning. Requires being able to view the message's channel and holding
  /// the command's declared permission.
  Future<RunModuleCommandResult> runCodeBlock({
    required String messageId,
    required int blockIndex,
    required String moduleId,
    required String command,
    required String input,
  }) async {
    final json = await _send(
      'POST',
      '/messages/$messageId/blocks/$blockIndex/run',
      body: {'module_id': moduleId, 'command': command, 'input': input},
    );
    return _decodeShape(
      json,
      'POST /messages/$messageId/blocks/$blockIndex/run',
      RunModuleCommandResult.fromJson,
    );
  }

  /// Pins a message. Idempotent: pinning an already-pinned message leaves the
  /// original pin's timestamp and pinner in place. Requires MANAGE_MESSAGES,
  /// evaluated in this channel specifically.
  Future<void> pinMessage({
    required String channelId,
    required String messageId,
  }) =>
      _send(
        'PUT',
        '/channels/$channelId/messages/$messageId/pin',
        expectNoContent: true,
      );

  /// Unpins a message. Idempotent: unpinning a message that is not pinned
  /// succeeds, since the caller's intent already holds either way.
  Future<void> unpinMessage({
    required String channelId,
    required String messageId,
  }) =>
      _send(
        'DELETE',
        '/channels/$channelId/messages/$messageId/pin',
        expectNoContent: true,
      );

  /// Keeps a message in the caller's own saved list. Idempotent: saving
  /// something already saved leaves the original `savedAt` alone rather than
  /// moving it to the top, so a double tap cannot reorder the list.
  ///
  /// Private throughout - unlike a pin, this needs only the VIEW_CHANNEL that
  /// let them read the message, and nobody else can see the result. A message
  /// in a channel the caller cannot see is a 404 rather than a 403, so this
  /// cannot probe for one.
  Future<void> saveMessage(String messageId) =>
      _send('PUT', '/messages/$messageId/save', expectNoContent: true);

  /// Removes a message from the caller's own saved list. Idempotent, and
  /// never refused: somebody removed from a channel must still be able to
  /// clear their own list of it, and a save whose message has since been
  /// deleted is exactly the entry they most want gone.
  Future<void> unsaveMessage(String messageId) =>
      _send('DELETE', '/messages/$messageId/save', expectNoContent: true);

  /// The caller's own saved messages, newest save first.
  ///
  /// Filtered by what they can see now rather than when they saved it: an
  /// entry whose channel they can no longer view is left out, though the
  /// entry itself is kept server-side in case access returns.
  Future<List<SavedMessage>> listSavedMessages() async {
    final json = await _send('GET', '/saved');
    return (json as List<dynamic>)
        .map((s) => SavedMessage.fromJson(s as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// A channel's pinned messages, newest pin first. Requires only
  /// VIEW_CHANNEL.
  Future<List<PinnedMessage>> listPinnedMessages(String channelId) async {
    final json = await _send('GET', '/channels/$channelId/pins');
    return (json as List<dynamic>)
        .map((p) => PinnedMessage.fromJson(p as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Every version a message has held, oldest first, ending with its current
  /// content. Requires only VIEW_CHANNEL, the same as reading the message; a
  /// deleted, absent, or wrong-channel message answers 404.
  Future<List<MessageRevision>> getMessageHistory(
    String channelId,
    String messageId,
  ) async {
    final json = await _send(
      'GET',
      '/channels/$channelId/messages/$messageId/history',
    );
    return (json as List<dynamic>)
        .map((r) => MessageRevision.fromJson(r as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// How many messages are pinned in a channel. Cheap: a single indexed
  /// count, never a fetch of every pinned message.
  Future<int> pinnedMessageCount(String channelId) async {
    final json = await _send('GET', '/channels/$channelId/pins/count');
    return (json as Map<String, dynamic>)['count'] as int;
  }

  /// Sends a message that carries a poll. Idempotent by [id] exactly like
  /// [SlimmApi.sendMessage], and gated the same way (view plus send in this
  /// channel). [options] needs between 2 and 4 entries. [closeAt] (unix
  /// milliseconds), if given, is when the server starts refusing votes.
  Future<Message> sendPollMessage({
    required String channelId,
    required String id,
    required String question,
    required List<String> options,
    String? content,
    int? closeAt,
  }) async {
    final json = await _send(
      'POST',
      '/channels/$channelId/messages/polls',
      body: {
        'id': id,
        'question': question,
        'options': options,
        if (content != null) 'content': content,
        if (closeAt != null) 'close_at': closeAt,
      },
    );
    return Message.fromJson(json as Map<String, dynamic>);
  }

  /// Launches an installed module's app into [channelId] as a message.
  /// Idempotent by [id] exactly like [SlimmApi.sendMessage], and gated the same
  /// way (view plus send in this channel), plus the caller must currently be
  /// able to reach the app. The returned message carries an `appSurface`; its
  /// interactive state is then the shared code run at block 0.
  Future<Message> launchAppMessage({
    required String channelId,
    required String id,
    required String moduleId,
    required String command,
    String? content,
  }) async {
    final json = await _send(
      'POST',
      '/channels/$channelId/messages/apps',
      body: {
        'id': id,
        'module_id': moduleId,
        'command': command,
        if (content != null) 'content': content,
      },
    );
    return Message.fromJson(json as Map<String, dynamic>);
  }

  /// Casts or changes the caller's vote on a message's poll: one vote per
  /// user, so a second call replaces the first rather than adding to it.
  /// Requires viewing the channel plus SEND_MESSAGES there, and is refused
  /// once the poll's close time has passed.
  Future<void> votePoll({required String messageId, required int option}) =>
      _send(
        'PUT',
        '/messages/$messageId/polls/vote',
        body: {'option': option},
        expectNoContent: true,
      );
}
