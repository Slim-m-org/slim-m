// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Writing to and reading from the local store.
library;

import 'package:drift/drift.dart';
import 'package:slimm_api/api.dart' as api;

import 'database.dart';
import 'message_dto.dart';
import 'rail_channel.dart';

part 'message_store_batch.dart';
part 'message_store_channels.dart';
part 'message_store_cursors.dart';
part 'message_store_drafts.dart';
part 'message_store_rows.dart';
part 'message_store_recovery.dart';
part 'message_store_retention.dart';

/// The local store's read and write surface.
///
/// Every write path in the app goes through here, which is what makes the two
/// delivery routes (live WebSocket push and REST catch-up) safe to interleave:
/// they can arrive in any order, repeat each other, or overlap, and the result
/// is the same.
class MessageStore {
  MessageStore(this.db);

  final SlimmDatabase db;

  // --- Reads ---

  /// Watches the newest [limit] messages in a channel, oldest first, as the UI
  /// renders them, with pending sends after every delivered one.
  ///
  /// The window is the *newest* rows, which took a correction: this ordered
  /// `seq` ascending under the same limit, so it returned the oldest 200. Local
  /// rows are never pruned and history pagination does not exist, so once a
  /// channel passed 200 cached messages the transcript was pinned to the first
  /// 200 ever synced and every later arrival was invisible until a sign-out.
  /// The read marker froze with it, since the screen takes the newest row it is
  /// given as the newest there is. `database.dart`'s index is
  /// `(channel_id, seq DESC)` under a comment saying reads scan newest-first,
  /// and this read was the one that did not.
  ///
  /// Pending sorts last, which is what the schema always claimed and the
  /// ordering never delivered: a local-only row carries `seq` 0, which is the
  /// *lowest* value, so ascending put an unsent message at the top of the
  /// transcript rather than the bottom - permanently, for a failed one, since
  /// `markFailed` leaves the zero in place. The first ordering term is what
  /// fixes that, and it has to come before the limit rather than after it in
  /// Dart, or a channel holding 200 delivered rows would cut the sender's own
  /// unsent message off the end.
  Stream<List<Message>> watchChannel(String channelId, {int limit = 200}) {
    final query = db.select(db.messages)
      ..where((m) => m.channelId.equals(channelId))
      ..orderBy([
        // Pending first here, so the reverse below puts them last.
        (m) => OrderingTerm(
              expression: m.seq.equals(0),
              mode: OrderingMode.desc,
            ),
        (m) => OrderingTerm(expression: m.seq, mode: OrderingMode.desc),
        (m) => OrderingTerm(expression: m.createdAt, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    return query.watch().map(
          (rows) => rows.reversed.map((r) => r.toDto()).toList(growable: false),
        );
  }

  /// [watchChannel]'s own query and ordering, fetched once rather than
  /// watched. For a caller that only needs a single snapshot (finding the
  /// caller's own last message to edit, say) opening a live query would mean
  /// a subscription to cancel again with nothing ever built to hold it -
  /// and, in a widget test, a real one left the drift stream machinery's own
  /// zero-duration cleanup timer pending past the test's end.
  Future<List<Message>> channelSnapshot(String channelId,
      {int limit = 200}) async {
    final query = db.select(db.messages)
      ..where((m) => m.channelId.equals(channelId))
      ..orderBy([
        (m) => OrderingTerm(
              expression: m.seq.equals(0),
              mode: OrderingMode.desc,
            ),
        (m) => OrderingTerm(expression: m.seq, mode: OrderingMode.desc),
        (m) => OrderingTerm(expression: m.createdAt, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    final rows = await query.get();
    return rows.reversed.map((r) => r.toDto()).toList(growable: false);
  }

  /// Position first, then creation order as the tiebreak every DM (whose
  /// position is never set) falls back to - the same ordering the server's
  /// own `list_channels` applies, so a cold-started rail matches a synced one.
  ///
  /// Excludes a thread (`parentMessageId` set), mirroring the server's own
  /// `list_channels` exclusion: a thread is a hidden sub-channel reached
  /// from the message it was opened on, never a rail entry. [watchChannel]
  /// (singular, by id) is unaffected, so a thread's own messages still watch
  /// and send normally once a caller already holds its id.
  Stream<List<Channel>> watchChannels() {
    final query = db.select(db.channels)
      ..where((c) => c.parentMessageId.isNull())
      ..orderBy([
        (c) => OrderingTerm(expression: c.position),
        (c) => OrderingTerm(expression: c.createdAt),
      ]);
    return query.watch();
  }

  /// [watchChannels]'s own rows and ordering, deduped to the fields
  /// `channel_rail.dart` actually renders or groups by (CP8).
  ///
  /// [watchChannels] is a table-wide watch: it re-emits on any write to
  /// `channels`, and drift's [Channel] equality is over every column, so a
  /// write nothing on screen reads - [setOpCursor] moving the message-op
  /// cursor, or [applyMessage]'s own advance of the ordinary one - still
  /// produces a genuinely different [Channel] list and re-triggers every
  /// subscriber. The rail pays for this on every incoming message anywhere
  /// in the deployment, rebuilding rows for channels the write never
  /// touched. This keeps the same query and still emits full [Channel]
  /// rows - every existing row widget keeps reading them unmodified,
  /// [Channel.cursor]/[Channel.lastReadSeq] included - but folds each
  /// emission down to [RailChannelKey] first, so a new emission that
  /// projects identically to the last one is dropped rather than passed on.
  ///
  /// A projected `unread` is the derived boolean the rail shows, not the raw
  /// `cursor`/`lastReadSeq` behind it: a channel already unread stays
  /// unread through every further message, so only the flip in or out of
  /// that state is a real rebuild for a text channel row, a DM row or the
  /// personal space row to make. See `rail_channel.dart` for the projection.
  Stream<List<Channel>> watchRailChannels() {
    final query = db.select(db.channels)
      ..where((c) => c.parentMessageId.isNull())
      ..orderBy([
        (c) => OrderingTerm(expression: c.position),
        (c) => OrderingTerm(expression: c.createdAt),
      ]);
    return query.watch().distinct(railChannelsUnchanged);
  }

  /// [watchChannels]'s own snapshot, for a caller that wants today's list
  /// once rather than a subscription it would only ever read one value from.
  Future<List<Channel>> allChannels() {
    final query = db.select(db.channels)
      ..where((c) => c.parentMessageId.isNull())
      ..orderBy([
        (c) => OrderingTerm(expression: c.position),
        (c) => OrderingTerm(expression: c.createdAt),
      ]);
    return query.get();
  }

  /// Watches one channel's own row, by id - unlike [watchChannels], never
  /// filtered to the ordinary list, so this is what a screen already
  /// showing a channel's messages should use to find its own name and read
  /// marker, including a thread's, which [watchChannels] deliberately
  /// excludes.
  Stream<Channel?> watchChannelRow(String channelId) {
    final query = db.select(db.channels)..where((c) => c.id.equals(channelId));
    return query.watchSingleOrNull();
  }

  /// [watchChannelRow]'s own snapshot: a thread included, unlike
  /// [allChannels], for a caller that wants today's answer once rather than
  /// a subscription - a widget test proving a row was written being the
  /// usual reason, since a stream's own `.first` needs the fake test clock
  /// pumped for its subscription-cleanup timer to ever resolve.
  Future<Channel?> channelRow(String channelId) {
    final query = db.select(db.channels)..where((c) => c.id.equals(channelId));
    return query.getSingleOrNull();
  }

  /// Whether a channel row exists locally.
  Future<bool> hasChannel(String channelId) async {
    final row = await (db.select(db.channels)
          ..where((c) => c.id.equals(channelId)))
        .getSingleOrNull();
    return row != null;
  }

  /// Whether [messageId] is already held for [channelId] - present at all,
  /// regardless of whether it falls inside whatever window [watchChannel]
  /// currently returns. Used to tell a jump to a message it has already got
  /// apart from one that still needs older history paged in first.
  Future<bool> hasMessage(String channelId, String messageId) async {
    final row = await (db.select(db.messages)
          ..where(
            (m) => m.channelId.equals(channelId) & m.id.equals(messageId),
          ))
        .getSingleOrNull();
    return row != null;
  }

  /// The smallest `seq` among [channelId]'s already-delivered rows, or null
  /// where none are delivered yet. Read straight off the database rather than
  /// off whatever a screen currently has loaded, so a caller can page a
  /// channel's history backwards with no transcript on screen for it at all.
  Future<int?> oldestLocalSeq(String channelId) async {
    final query = db.select(db.messages)
      ..where(
        (m) => m.channelId.equals(channelId) & m.seq.isBiggerThanValue(0),
      )
      ..orderBy([(m) => OrderingTerm(expression: m.seq)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    return row?.seq;
  }

  /// The highest message-op seq applied for a channel, or null where this
  /// client holds no op cursor at all.
  ///
  /// Null and zero are different answers and the caller must keep them apart:
  /// see [Channels.opCursor].
  Future<int?> opCursorFor(String channelId) => _opCursorFor(this, channelId);

  /// The highest message seq applied to a channel, or null when the channel is
  /// not held locally. Zero is a channel held with no messages.
  Future<int?> cursorFor(String channelId) => _cursorFor(this, channelId);

  /// Moves a channel's op cursor forward, or clears it when [seq] is null.
  ///
  /// Monotonic in the same shape [_advanceCursor] is, with one difference
  /// that matters: null is a clear, never a lowering to zero. Adopting a
  /// server-reported head is also a forward move, so it goes through here.
  Future<void> setOpCursor(String channelId, int? seq) =>
      _setOpCursor(this, channelId, seq);

  /// Every message currently marked failed, across every channel - what
  /// `SyncController` reads to retry each one once on reconnect. Order is
  /// unspecified: nothing downstream cares which failed row goes first.
  Future<List<Message>> failedMessages() async {
    final query = db.select(db.messages)..where((m) => m.failed.equals(true));
    final rows = await query.get();
    return rows.map((r) => r.toDto()).toList(growable: false);
  }

  /// Every channel's cursors, for a bundled catch-up request.
  Future<List<api.ScopeCursor>> allCursors() async {
    final rows = await db.select(db.channels).get();
    return rows
        .map((c) => api.ScopeCursor(
              channelId: c.id,
              afterSeq: c.cursor,
              afterOpSeq: c.opCursor,
            ))
        .toList(growable: false);
  }

  // --- Writes ---

  /// Replaces the known channel list, keeping each channel's local cursor and
  /// read marker, which the server's channel list does not carry. The body
  /// lives in `message_store_channels.dart`, alongside [replaceChannels].
  Future<void> upsertChannels(List<api.Channel> channels) =>
      _upsertChannels(this, channels);

  /// Replaces the whole known channel list with exactly what the server
  /// returned, pruning any channel (and its cached messages) that dropped
  /// out - a permission revoked live, or a delete this device did not
  /// perform itself. [upsertChannels] must never gain this: a single-channel
  /// call (a rename, a freshly created channel) would wipe every other row.
  /// The body lives in `message_store_channels.dart`.
  Future<void> replaceChannels(List<api.Channel> channels) =>
      _replaceChannels(this, channels);

  /// Applies one message from the server, whichever route it arrived by.
  ///
  /// Idempotent and order-safe: re-applying the same message changes nothing,
  /// and an older version of a message can never overwrite a newer one. This is
  /// the single place those two rules live.
  Future<void> applyMessage(api.Message message) async {
    await db.transaction(() async {
      final existing = await (db.select(db.messages)
            ..where((m) => m.id.equals(message.id)))
          .getSingleOrNull();

      // A stale copy of something already stored: ignore it. Pending rows are
      // always replaced, since the server's version is authoritative.
      if (existing != null && !existing.pending && existing.seq > message.seq) {
        return;
      }

      await db.into(db.messages).insertOnConflictUpdate(_rowFor(message));

      await _advanceCursor(message.channelId, message.seq);
      if (message.mentionsMe) {
        await _advanceMentionCursor(message.channelId, message.seq);
      }
    });
  }

  /// Applies a batch, for catch-up and scroll-back, in one transaction and with
  /// far fewer round trips than a call to [applyMessage] per message. The body
  /// lives in `message_store_batch.dart`; the same idempotency and ordering
  /// rules [applyMessage] enforces are applied there.
  Future<void> applyMessages(Iterable<api.Message> messages) =>
      _applyMessagesBatched(this, messages);

  /// Drops a channel's cached messages and rewinds its cursor. Used when the
  /// server answers catch-up with `reset`, meaning the gap was too large to
  /// stream and local state cannot be trusted. Only server-confirmed rows are
  /// dropped: `markFailed` also sets `pending:false`, so a failed send must be
  /// excluded here too or it is destroyed instead of kept for retry.
  Future<void> resetChannel(String channelId) async {
    await db.transaction(() async {
      await (db.delete(db.messages)
            ..where((m) =>
                m.channelId.equals(channelId) &
                m.pending.equals(false) &
                m.failed.equals(false)))
          .go();
      await (db.update(db.channels)..where((c) => c.id.equals(channelId)))
          .write(const ChannelsCompanion(
        cursor: Value(0),
        mentionedSeq: Value(0),
        opCursor: Value(null),
      ));
    });
  }

  /// Drops a channel this account deleted server-side, along with its
  /// cached messages. [upsertChannels] only ever inserts or updates, so a
  /// channel removed on the server would otherwise sit in the local list
  /// forever; this is the direct path for one already-known id.
  /// [replaceChannels] is the other, for a full server refresh.
  Future<void> removeChannel(String channelId) async {
    await db.transaction(() async {
      await (db.delete(db.messages)
            ..where((m) => m.channelId.equals(channelId)))
          .go();
      await (db.delete(db.channels)..where((c) => c.id.equals(channelId))).go();
    });
  }

  /// Drops everything this device has cached: every channel, every message,
  /// every cursor and read marker, including pending sends.
  ///
  /// Unlike [resetChannel] this keeps nothing at all, because it is called when
  /// the cached data stops belonging to whoever is about to use the app: a sign
  /// out, an account deletion, or a switch to a different server. A pending
  /// send is the previous account's unsent message and must go with the rest,
  /// which is exactly why this cannot be built out of [resetChannel].
  Future<void> clear() async {
    await db.transaction(() async {
      await db.delete(db.messages).go();
      await db.delete(db.channels).go();
      // Drafts: the one thing here nobody else has a copy of. See clear's doc.
      await db.delete(db.channelDrafts).go();
    });
  }

  /// Every channel's unsent composer text, as a map. See
  /// `message_store_drafts.dart`.
  Future<Map<String, String>> drafts() => _drafts(this);

  /// Saves [text] as [channelId]'s draft, or deletes the row when it is empty.
  Future<void> saveDraft(String channelId, String text, {required int now}) =>
      _saveDraft(this, channelId, text, now);

  Future<void> clearDraft(String channelId) => _clearDraft(this, channelId);

  /// Records a message the user just sent, before the server has seen it, so it
  /// appears immediately. Replaced in place by [applyMessage] on acknowledgement
  /// because both are keyed by the same client-generated id.
  Future<void> addPending({
    required String id,
    required String channelId,
    required String authorId,
    required String content,
    String? replyToId,
  }) async {
    await db.into(db.messages).insertOnConflictUpdate(
          MessagesCompanion.insert(
            id: id,
            channelId: channelId,
            authorId: Value(authorId),
            content: content,
            createdAt: DateTime.now().millisecondsSinceEpoch,
            pending: const Value(true),
            failed: const Value(false),
            failureReason: const Value(null),
            replyToId: Value(replyToId),
          ),
        );
  }

  /// Marks a pending send as failed so the UI can offer a retry, naming why
  /// so a retry against the same doomed content is not the user's only clue.
  /// The row is kept rather than dropped, so nothing typed is silently lost.
  Future<void> markFailed(String id, {required String reason}) async {
    await (db.update(db.messages)..where((m) => m.id.equals(id)))
        .write(MessagesCompanion(
      pending: const Value(false),
      failed: const Value(true),
      failureReason: Value(reason),
    ));
  }

  /// Drops one message's local row: a pending or failed send the user chose
  /// not to keep, or one just deleted server-side (this device's own delete
  /// call, or a live `message.deleted` event for someone else's) that must
  /// vanish from every view. Same operation either way.
  Future<void> discard(String id) async {
    await (db.delete(db.messages)..where((m) => m.id.equals(id))).go();
  }

  /// Applies an edit to a message already held, and does nothing else.
  ///
  /// Three things it deliberately does not do, because each is a one-word
  /// mistake with no symptom until much later: it never inserts, so an edit
  /// for a message this client does not hold is dropped rather than
  /// materialised as a row with no `seq`; it never writes `seq`, which
  /// belongs to the message stream and not to this one; and it never advances
  /// the message cursor, which would skip whatever sits between.
  Future<void> applyEdit(
      String messageId, String content, int? editedAt) async {
    await (db.update(db.messages)..where((m) => m.id.equals(messageId)))
        .write(MessagesCompanion(
      content: Value(content),
      editedAt: Value(editedAt),
    ));
  }

  /// Clears a forward's snapshot once its original was removed; the note stays.
  Future<void> removeForwardSnapshot(String messageId) =>
      _removeForwardSnapshot(db, messageId);

  /// Mirrors the server's read marker.
  Future<void> setReadMarker(
    String channelId,
    int seq, {
    bool? manuallyUnread,
  }) async {
    await db.transaction(() async {
      final row = await (db.select(db.channels)
            ..where((c) => c.id.equals(channelId)))
          .getSingleOrNull();
      if (row == null) return;
      // The marker only moves forward; the flag is independent of it.
      final advancing = seq > row.lastReadSeq;
      if (!advancing && manuallyUnread == null) return;
      await (db.update(db.channels)..where((c) => c.id.equals(channelId)))
          .write(ChannelsCompanion(
        lastReadSeq: advancing ? Value(seq) : const Value.absent(),
        manuallyUnread: manuallyUnread == null
            ? const Value.absent()
            : Value(manuallyUnread),
      ));
    });
  }

  /// Caps every channel's delivered rows to the newest [ceiling], deleting
  /// whatever is older. Body in `message_store_retention.dart`, which also
  /// explains why this is safe to call unconditionally rather than only for
  /// channels a caller knows are closed.
  Future<void> pruneToRetentionCeiling(int ceiling) =>
      _pruneToRetentionCeiling(this, ceiling);

  /// The message ids currently held for [channelIds]. See
  /// `message_store_retention.dart` for the reachability reading a caller may
  /// only place on this after [pruneToRetentionCeiling] has already run.
  Future<Set<String>> reachableMessageIds(Iterable<String> channelIds) =>
      _reachableMessageIds(this, channelIds);

  /// Moves a channel's cursor forward. Never backwards: the cursor is the
  /// high-water mark of what has been applied.
  Future<void> _advanceCursor(String channelId, int seq) async {
    final row = await (db.select(db.channels)
          ..where((c) => c.id.equals(channelId)))
        .getSingleOrNull();
    if (row == null || row.cursor >= seq) return;
    await (db.update(db.channels)..where((c) => c.id.equals(channelId)))
        .write(ChannelsCompanion(cursor: Value(seq)));
  }

  /// [_advanceCursor]'s own shape for `mentionedSeq`, only ever called for a
  /// message whose `mentionsMe` is true.
  Future<void> _advanceMentionCursor(String channelId, int seq) async {
    final row = await (db.select(db.channels)
          ..where((c) => c.id.equals(channelId)))
        .getSingleOrNull();
    if (row == null || row.mentionedSeq >= seq) return;
    await (db.update(db.channels)..where((c) => c.id.equals(channelId)))
        .write(ChannelsCompanion(mentionedSeq: Value(seq)));
  }
}
