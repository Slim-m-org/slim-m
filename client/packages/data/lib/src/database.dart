// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The local database: the client's single source of truth.
///
/// The UI reads only from here, never from the network directly. Anything that
/// arrives, whether pushed over the WebSocket or pulled by catch-up, is written
/// here first and then observed, so both paths converge on the same state and
/// there is one place where ordering and de-duplication are decided.
///
/// Two rules make that safe, and both are enforced in [applyMessage]:
///
/// - Identity is the server's message id (a UUIDv7). Writes are upserts keyed by
///   it, so the same message arriving twice, once live and once from catch-up,
///   is stored once.
/// - Order is the per-channel `seq`. A row is only overwritten by something with
///   a `seq` at least as high, so a late-arriving duplicate of an older state
///   can never clobber a newer one.
library;

import 'package:drift/drift.dart';

import 'message_dto.dart';
import 'pending_attachments_table.dart';

part 'database.g.dart';

/// Locally cached channels.
class Channels extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get kind => text()();
  IntColumn get createdAt => integer()();

  /// A one-line header shown beside the name. Null for no topic.
  TextColumn get topic => text().nullable()();

  /// The highest `seq` this client holds for the channel: the sync cursor.
  IntColumn get cursor => integer().withDefault(const Constant(0))();

  /// How far the user has read, mirrored from the server.
  IntColumn get lastReadSeq => integer().withDefault(const Constant(0))();

  /// The highest `seq` of a message in this channel that mentioned the
  /// caller, the same "sync cursor" shape [cursor] already is: advanced by
  /// [MessageStore.applyMessage] whenever an applied `api.Message` carries
  /// `mentionsMe`, never lowered. `mentionedSeq > lastReadSeq` is the rail's
  /// unread-mention flag, the same `cursor > lastReadSeq` comparison already
  /// drives the plain unread dot - see `rail_channel.dart`.
  IntColumn get mentionedSeq => integer().withDefault(const Constant(0))();

  /// The reader asked to see this channel as unread even though they have
  /// read it, mirrored from the server's own flag. Kept beside
  /// [lastReadSeq] rather than folded into it because the marker is
  /// monotonic on purpose: rewinding it to fake an unread would break the
  /// guarantee that a late mark cannot un-read a channel. See the rail's
  /// `unread` in `rail_channel.dart`, which is the OR of the two.
  /// Nullable for the same reason [restricted] is: an existing row, and a
  /// server too old to report the flag, both read as null, and null renders
  /// the same as false. Nothing here claims somebody marked a channel unread
  /// when this client cannot vouch for it.
  BoolColumn get manuallyUnread => boolean().nullable()();

  /// Whether this is the caller's own personal space, set only by
  /// `channelFromDm` from `dm.user.id == selfId` - never from `name`, which
  /// is a display string another member's own display name can collide with.
  BoolColumn get isPersonalSpace =>
      boolean().withDefault(const Constant(false))();

  /// The other user in this DM, set only by `channelFromDm`. Null for a
  /// non-DM channel, and for a DM row cached before this column existed
  /// until the next channel refresh replaces it.
  TextColumn get dmParticipantId => text().nullable()();

  /// Sort key among the deployment's live, non-DM channels: lower sorts
  /// first, mirroring the server's `channels.position`. Deployment-wide, set
  /// by a manager's drag, not a per-device preference. Meaningless for a DM,
  /// which is never reordered by it.
  IntColumn get position => integer().withDefault(const Constant(0))();

  /// The highest message-op `seq` this client has applied for the channel.
  ///
  /// Nullable, and the nullability is the whole mechanism: null means "I hold
  /// no op cursor, adopt whatever head the next response reports", and there
  /// is no in-band integer that could mean that. Zero means "I am caught up
  /// with a stream that has never had an op", which is a different claim.
  /// A reset clears it back to null rather than lowering it to zero, or the
  /// client asks from 0 forever against a server that has swept.
  IntColumn get opCursor => integer().nullable()();

  /// The message this channel is a thread of, or null for an ordinary
  /// channel. Set only by [MessageStore.upsertChannels]'s callers when they
  /// already hold an `api.Channel` carrying it - see
  /// `providers/threads.dart`. Never used to derive [kind] or overwrites;
  /// it exists locally only so a thread row can be told apart from an
  /// ordinary one when deciding what the rail shows and what a full channel
  /// refresh may prune.
  TextColumn get parentMessageId => text().nullable()();

  /// The rail section this channel is filed under, or null for
  /// uncategorised. Decides placement only, mirroring the server's
  /// `channels.category_id` - see docs/decisions/0006-channel-categories.md.
  /// Not a foreign key here: [ChannelCategories] is replaced on its own path
  /// ([MessageStore.replaceCategories]), never joined against this table for
  /// referential integrity, the same reason `dmParticipantId` names a user
  /// id with no local `Users` table to reference.
  TextColumn get categoryId => text().nullable()();

  /// The minimum interval, in seconds, a non-`MANAGE_CHANNELS` member must
  /// wait between their own messages here, mirroring the server's
  /// `channels.slow_mode_seconds`. 0 means off, and is also what every
  /// existing row defaults to on upgrade until the next channel refresh
  /// fills in the real value.
  IntColumn get slowModeSeconds => integer().withDefault(const Constant(0))();

  /// `channels.join_muted`: joining this voice channel starts with the mic
  /// off. False for every existing row until the next channel refresh.
  BoolColumn get joinMuted => boolean().withDefault(const Constant(false))();

  /// Whether `@everyone` lacks VIEW_CHANNEL here, mirroring the server's
  /// `channels.restricted` - null for a server too old to send it, which
  /// reads the same as false: nothing here claims a channel is public that
  /// this client cannot actually vouch for.
  BoolColumn get restricted => boolean().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Locally cached channel categories: a rail section a channel of any kind
/// may be filed under. Replaced wholesale on its own path
/// ([MessageStore.replaceCategories]), never pruned by [Channels]'s own
/// replace - a category is not a channel and never appears in that list, the
/// same shape a thread needed exempting from `replaceChannels`'s pruning.
///
/// `@DataClassName('ChannelCategoryRow')`: drift's default singular name for
/// this table would be `ChannelCategory`, which collides with `slimm_api`'s
/// own wire model of that exact name - the two would be indistinguishable by
/// name in any file that imports both.
@DataClassName('ChannelCategoryRow')
class ChannelCategories extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// Sort key among the deployment's live categories: lower sorts first.
  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Unsent composer text, one row per channel.
///
/// The one table here that is not a cache of server state: nobody else has
/// these words, so unlike [Messages] a wipe loses something real rather than
/// something refetchable. That is why it is written at all - on a phone, the OS
/// killing a backgrounded app is indistinguishable from a restart to the person
/// who just lost what they typed, and it happens without anyone choosing it.
///
/// Still wiped on sign-out, along with everything else: the next account on this
/// device must never read the last one's unfinished words.
@DataClassName('ChannelDraftRow')
class ChannelDrafts extends Table {
  TextColumn get channelId => text()();

  /// Never empty. An empty draft and no draft have to read the same way, so the
  /// controller deletes the row rather than storing a blank one.
  ///
  /// Named `body` rather than `text`: a column called `text` shadows drift's own
  /// `text()` builder, so the getter recursively returns itself and the analyzer
  /// is the only thing that catches it.
  TextColumn get body => text()();

  /// When it was last typed, so a future "you have unsent drafts" surface can
  /// order them without another migration. Nothing reads it yet.
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {channelId};
}

/// Locally cached messages.
///
/// `@DataClassName('MessageRow')`: the same collision `ChannelCategories`
/// renames around above, this time with `message_dto.dart`'s own `Message` -
/// the plain DTO that is the only shape of a message anything outside this
/// package ever sees. See [MessageRowMapping] below for the one place a row
/// becomes one.
@DataClassName('MessageRow')
class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get channelId => text()();
  TextColumn get authorId => text().nullable()();

  /// Sent with the message so rendering a channel needs no lookup per sender.
  /// Null when the author was anonymized, exactly as [authorId] is.
  TextColumn get authorDisplayName => text().nullable()();

  /// Server order key. Zero while a message is only local (an optimistic echo
  /// that has not been acknowledged yet), so pending messages sort last.
  IntColumn get seq => integer().withDefault(const Constant(0))();
  TextColumn get content => text()();
  IntColumn get createdAt => integer()();
  IntColumn get editedAt => integer().nullable()();

  /// The message this one replies to, or null. Only ever the id: the
  /// parent's own content, author and liveness are read by looking that id
  /// up in this same table, never copied onto this row - there is nothing
  /// here for an edit or delete of the parent to leave stale.
  TextColumn get replyToId => text().nullable()();

  /// What this message forwards, snapshotted by the server when the forward
  /// was sent - all null together on a message that forwards nothing.
  ///
  /// Copied onto this row rather than resolved like [replyToId], because a
  /// forward's origin is in another channel this cache may not hold at all,
  /// and outlives being edited or deleted there. Nothing here goes stale:
  /// the snapshot is what was passed on, not what the original says now.
  TextColumn get forwardedMessageId => text().nullable()();
  TextColumn get forwardedChannelId => text().nullable()();
  TextColumn get forwardedAuthorId => text().nullable()();
  TextColumn get forwardedAuthorDisplayName => text().nullable()();
  IntColumn get forwardedAuthorAvatarUpdatedAt => integer().nullable()();
  IntColumn get forwardedCreatedAt => integer().nullable()();
  TextColumn get forwardedContent => text().nullable()();

  /// The forward's original was deleted or aged out; the snapshot is blank.
  BoolColumn get forwardedRemoved =>
      boolean().withDefault(const Constant(false))();

  /// True while the send is in flight. The UI shows these differently and they
  /// are replaced in place by the server's copy on acknowledgement.
  BoolColumn get pending => boolean().withDefault(const Constant(false))();

  /// True when the send failed and the user can retry it.
  BoolColumn get failed => boolean().withDefault(const Constant(false))();

  /// Why [failed] is true, in the server's own words (its `error` body, or a
  /// transport failure's own message) - never a generic "send failed" with
  /// nothing behind it. Null whenever [failed] is false.
  TextColumn get failureReason => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Maps a locally stored row to the DTO everything outside this package
/// reads instead, so nothing beyond here needs drift at all.
extension MessageRowMapping on MessageRow {
  Message toDto() => Message(
        id: id,
        channelId: channelId,
        authorId: authorId,
        authorDisplayName: authorDisplayName,
        seq: seq,
        content: content,
        createdAt: createdAt,
        editedAt: editedAt,
        replyToId: replyToId,
        forwarded: forwardedMessageId == null
            ? null
            : ForwardedMessage(
                messageId: forwardedMessageId!,
                channelId: forwardedChannelId!,
                authorId: forwardedAuthorId,
                authorDisplayName: forwardedAuthorDisplayName,
                authorAvatarUpdatedAt: forwardedAuthorAvatarUpdatedAt,
                createdAt: forwardedCreatedAt!,
                content: forwardedContent!,
                removed: forwardedRemoved,
              ),
        pending: pending,
        failed: failed,
        failureReason: failureReason,
      );
}

@DriftDatabase(
  tables: [
    Channels,
    Messages,
    ChannelCategories,
    ChannelDrafts,
    PendingAttachments
  ],
)
class SlimmDatabase extends _$SlimmDatabase {
  SlimmDatabase(super.e);

  @override
  int get schemaVersion => 21;

  /// How each schema version is reached, and why v3 throws the cache away.
  ///
  /// v2 added the author's display name and left existing rows null, on the
  /// assumption that the next sync would replace them. It does not: sync is
  /// keyset on `seq` and only ever asks for messages newer than the cursor, so
  /// every message that predated the upgrade kept a null name permanently and
  /// rendered as an unknown author. On a real client that was 19 of 22
  /// messages.
  ///
  /// v3 drops the message cache and rewinds the cursor, and that is the whole
  /// fix. This table is a cache of server state with no local-only rows worth
  /// keeping, so the cost is one catch-up sync and the benefit is that the
  /// client cannot be left holding a version of a message the server has a
  /// better copy of.
  ///
  /// v4 adds `channels.topic` in place instead. Unlike the message cache,
  /// channels are fully refetched on every sync rather than paged by a cursor,
  /// so a null topic fills itself in on the next connect without dropping
  /// anything.
  ///
  /// v5 adds `channels.isPersonalSpace` the same way: it defaults to false for
  /// every existing row, and the next channel refresh (`ChannelRefresher`)
  /// sets it correctly on whichever row is the caller's own personal space,
  /// since that refresh always replaces the whole channel list.
  ///
  /// v6 adds `channels.dmParticipantId` the same way again: null until the
  /// next refresh fills it in for every DM row.
  ///
  /// v7 adds `channels.opCursor` and then does what v3 did, for a reason of
  /// its own rather than a repeat of v3's. Edits and deletes made before the
  /// server had an op stream to record them in are unrecoverable by any
  /// mechanism: no cursor can reach behind the first op ever written, so a
  /// message this cache holds a stale copy of would stay stale forever. The
  /// cache is dropped once to close that pre-log epoch, and every op from
  /// here on reconciles without another wipe.
  ///
  /// v8 adds `channels.position` in place, the same shape as v4's topic:
  /// every existing row defaults to 0, and the next channel refresh replaces
  /// it with the server's real value, since channels are refetched whole
  /// rather than paged by a cursor.
  ///
  /// v9 adds `messages.replyToId` in place, unlike v2's `authorDisplayName` -
  /// deliberately not a wipe. That one needed one because the server already
  /// held display names a keyset sync could never page back far enough to
  /// backfill. `reply_to_id` has no such gap: it is new on the server in the
  /// same release, so no message any existing local cache holds could
  /// possibly be a reply the server knows about but this column does not -
  /// there is nothing to backfill, only rows that were correctly never a
  /// reply in the first place.
  ///
  /// v10 adds `channels.parentMessageId` in place, the same shape as v9:
  /// threads are new on both sides in the same release, so there is no
  /// existing row this column could ever need to backfill for.
  ///
  /// v11 adds `messages.failureReason` in place, the same shape as v9 and
  /// v10 again: a failed send is local-only state a server was never asked
  /// about, so an existing failed row simply keeps rendering the generic
  /// retry it always had until the user retries or discards it.
  ///
  /// v12 adds `channels.categoryId` in place and creates [ChannelCategories]
  /// fresh, the same "new on both sides in the same release, nothing to
  /// backfill" shape as v9 and v10: every existing row's `categoryId` reads
  /// null until the next channel refresh fills it in, and the empty
  /// categories table is populated by that same refresh
  /// ([ChannelRefresher.refresh] calling [MessageStore.replaceCategories]).
  ///
  /// v13 adds the seven `messages.forwarded*` columns in place, the same
  /// "new on both sides in the same release, nothing to backfill" shape as
  /// v9 and v10. Forwards that predate it were composed into message text
  /// and are indistinguishable from ordinary content by design; they stay
  /// exactly as they read today rather than being guessed at.
  ///
  /// v14 adds `channels.mentionedSeq` in place, defaulting every existing
  /// row to 0 like v8's `position`. An unread mention already sitting in a
  /// channel's cache from before this version stays unbadged until the next
  /// message, edit, or full resync touches that channel - the same gap v2's
  /// own doc comment describes for a keyset sync that only ever asks for
  /// messages newer than what is already cached, accepted here for the same
  /// reason: nothing server-side can be paged back through to backfill it.
  ///
  /// v15 adds `channels.slowModeSeconds` in place, the same shape as v8's
  /// `position` and v14's `mentionedSeq`: every existing row defaults to 0
  /// (off), and the next channel refresh replaces it with the server's real
  /// value, since channels are refetched whole rather than paged by a
  /// cursor.
  ///
  /// v16 adds `channels.restricted` in place, the same shape again: every
  /// existing row reads null (unknown, which renders the same as "not
  /// restricted") until the next channel refresh fills in the server's real
  /// value.
  ///
  /// v19 adds `channels.joinMuted` in place the same way, false until the
  /// next channel refresh.
  ///
  /// v20 adds `messages.forwardedRemoved`, false for every existing row.
  ///
  /// v21 adds the `pending_attachments` table, empty for every existing send.
  ///
  /// v17 adds `channels.manuallyUnread` the same way: false for every existing
  /// row, and the next refresh reads each channel's real flag back from the
  /// server, since the refresher already fetches read state per channel.
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(messages, messages.authorDisplayName);
          }
          // Channels are refetched whole on every sync, so this column can be
          // added in place. See the doc comment above.
          if (from < 4) {
            await m.addColumn(channels, channels.topic);
          }
          if (from < 5) {
            await m.addColumn(channels, channels.isPersonalSpace);
          }
          if (from < 6) {
            await m.addColumn(channels, channels.dmParticipantId);
          }
          if (from < 7) {
            await m.addColumn(channels, channels.opCursor);
          }
          if (from < 8) {
            await m.addColumn(channels, channels.position);
          }
          if (from < 9) {
            await m.addColumn(messages, messages.replyToId);
          }
          if (from < 10) {
            await m.addColumn(channels, channels.parentMessageId);
          }
          if (from < 11) {
            await m.addColumn(messages, messages.failureReason);
          }
          if (from < 12) {
            await m.addColumn(channels, channels.categoryId);
            await m.createTable(channelCategories);
          }
          if (from < 13) {
            await m.addColumn(messages, messages.forwardedMessageId);
            await m.addColumn(messages, messages.forwardedChannelId);
            await m.addColumn(messages, messages.forwardedAuthorId);
            await m.addColumn(messages, messages.forwardedAuthorDisplayName);
            await m.addColumn(
              messages,
              messages.forwardedAuthorAvatarUpdatedAt,
            );
            await m.addColumn(messages, messages.forwardedCreatedAt);
            await m.addColumn(messages, messages.forwardedContent);
          }
          if (from < 14) {
            await m.addColumn(channels, channels.mentionedSeq);
          }
          if (from < 15) {
            await m.addColumn(channels, channels.slowModeSeconds);
          }
          if (from < 16) {
            await m.addColumn(channels, channels.restricted);
          }
          if (from < 17) {
            await m.addColumn(channels, channels.manuallyUnread);
          }
          if (from < 18) {
            await m.createTable(channelDrafts);
          }
          if (from < 19) {
            await m.addColumn(channels, channels.joinMuted);
          }
          if (from < 20) {
            await m.addColumn(messages, messages.forwardedRemoved);
          }
          if (from < 21) {
            await m.createTable(pendingAttachments);
          }
          // v2's null display names and the pre-op-stream epoch are both
          // unreachable by a keyset sync. See the doc comment above.
          if (from < 7) {
            await m.deleteTable(messages.actualTableName);
            await m.createTable(messages);
            await m.database.customStatement('UPDATE channels SET cursor = 0');
          }
        },
        beforeOpen: (details) async {
          // Keyset reads and unread counts both scan a channel newest-first, so the
          // index has to match that order to be used.
          await customStatement(
            'CREATE INDEX IF NOT EXISTS messages_channel_seq '
            'ON messages (channel_id, seq DESC)',
          );
          // The ids of a send that landed or was discarded have nothing left to retry.
          await customStatement(
            'DELETE FROM pending_attachments WHERE message_id NOT IN '
            '(SELECT id FROM messages WHERE pending = 1 OR failed = 1)',
          );
        },
      );
}
