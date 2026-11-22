// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel-list reads behind [MessageStore], split out so
/// `message_store.dart` stays under its file budget.
library;

import 'package:drift/drift.dart';
import 'database.dart';
import 'rail_channel.dart';

/// The channel reads [MessageStore] exposes; see its method docs for callers.
class ChannelReads {
  ChannelReads(this.db);

  final SlimmDatabase db;

  /// Rail order over the ordinary list: [watchChannels], [watchRailChannels]
  /// and [allChannels] all read this one query.
  SimpleSelectStatement<$ChannelsTable, Channel> _ordinaryQuery() {
    return db.select(db.channels)
      ..where((c) => c.parentMessageId.isNull())
      ..orderBy([
        (c) => OrderingTerm(expression: c.position),
        (c) => OrderingTerm(expression: c.createdAt),
      ]);
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
    final query = _ordinaryQuery();
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
    final query = _ordinaryQuery();
    return query.watch().distinct(railChannelsUnchanged);
  }

  /// [watchChannels]'s own snapshot, for a caller that wants today's list
  /// once rather than a subscription it would only ever read one value from.
  Future<List<Channel>> allChannels() {
    final query = _ordinaryQuery();
    return query.get();
  }

  /// Watches one channel's own row, by id - unlike [watchChannels], never
  /// filtered to the ordinary list, so this is what a screen already
  /// showing a channel's messages should use to find its own name and read
  /// marker, including a thread's, which [watchChannels] deliberately
  /// excludes.
  ///
  /// Drift re-selects on any write to `channels`, other channels' included,
  /// and rows compare by value, so an unchanged row is dropped here.
  Stream<Channel?> watchChannelRow(String channelId) {
    final query = db.select(db.channels)..where((c) => c.id.equals(channelId));
    return query.watchSingleOrNull().distinct();
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
}
