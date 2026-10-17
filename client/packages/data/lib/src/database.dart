// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The local database: the client's single source of truth. Live pushes and
/// catch-up both write here first, so they converge; [applyMessage] keys rows
/// by the server's message id and only lets an equal or higher `seq` replace
/// one, so a duplicate or a late, older copy changes nothing.
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

  /// Temporary voice rooms (decision 0065), nullable so an existing row and
  /// a row built in code read as "not a lobby, no limit, not a room".
  BoolColumn get createsRooms => boolean().nullable()();
  IntColumn get userLimit => integer().nullable()();
  TextColumn get roomOwnerId => text().nullable()();
  BoolColumn get roomLocked => boolean().nullable()();

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
  int get schemaVersion => 23;

  /// How each schema version is reached. Most add a column in place that the
  /// next channel refresh fills in. v3 and v7 drop the message cache and rewind
  /// the cursor instead, because a keyset sync only pages forward and could
  /// never backfill what they fixed (display names, and edits made before the
  /// op log existed).
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
          if (from < 22) {
            await m.addColumn(channels, channels.createsRooms);
            await m.addColumn(channels, channels.userLimit);
            await m.addColumn(channels, channels.roomOwnerId);
            await m.addColumn(channels, channels.roomLocked);
          }
          // A table made by the v21 step above already has the column.
          if (from >= 21 && from < 23) {
            await m.addColumn(
                pendingAttachments, pendingAttachments.mentionReply);
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
