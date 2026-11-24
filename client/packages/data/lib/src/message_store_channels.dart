// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bodies behind [MessageStore.upsertChannels] and
/// [MessageStore.replaceChannels], a sibling library that takes the store so
/// `message_store.dart` stays under its file budget.
library;

import 'package:drift/drift.dart';
import 'package:slimm_api/api.dart' as api;
import 'database.dart';
import 'message_store.dart';

String? joinMemberIds(List<String> ids) => ids.isEmpty ? null : ids.join(',');

/// Replaces the known channel list, keeping each channel's local cursor and
/// read marker, which the server's channel list does not carry.
Future<void> upsertChannels(
    MessageStore store, List<api.Channel> channels) async {
  final db = store.db;
  await db.batch((batch) {
    for (final channel in channels) {
      batch.insert(
        db.channels,
        ChannelsCompanion.insert(
          id: channel.id,
          name: channel.name,
          kind: channel.kind,
          createdAt: channel.createdAt,
          topic: Value(channel.topic),
          position: Value(channel.position),
          isPersonalSpace: Value(channel.isPersonalSpace),
          dmParticipantId: Value(channel.dmParticipantId),
          dmMemberIds: Value(joinMemberIds(channel.dmMemberIds)),
          parentMessageId: Value(channel.parentMessageId),
          categoryId: Value(channel.categoryId),
          slowModeSeconds: Value(channel.slowModeSeconds),
          joinMuted: Value(channel.joinMuted),
          defaultNotification: Value(channel.defaultNotification.wire),
          restricted: Value(channel.restricted),
          createsRooms: Value(channel.createsRooms),
          userLimit: Value(channel.userLimit),
          roomOwnerId: Value(channel.roomOwnerId),
          roomLobbyId: Value(channel.roomLobbyId),
          roomLocked: Value(channel.roomLocked),
        ),
        onConflict: DoUpdate(
          (_) => ChannelsCompanion.custom(
            name: Variable(channel.name),
            kind: Variable(channel.kind),
            topic: Variable(channel.topic),
            position: Variable(channel.position),
            isPersonalSpace: Variable(channel.isPersonalSpace),
            dmParticipantId: Variable(channel.dmParticipantId),
            dmMemberIds: Variable(joinMemberIds(channel.dmMemberIds)),
            parentMessageId: Variable(channel.parentMessageId),
            categoryId: Variable(channel.categoryId),
            slowModeSeconds: Variable(channel.slowModeSeconds),
            joinMuted: Variable(channel.joinMuted),
            defaultNotification: Variable(channel.defaultNotification.wire),
            restricted: Variable(channel.restricted),
            createsRooms: Variable(channel.createsRooms),
            userLimit: Variable(channel.userLimit),
            roomOwnerId: Variable(channel.roomOwnerId),
            roomLobbyId: Variable(channel.roomLobbyId),
            roomLocked: Variable(channel.roomLocked),
          ),
        ),
      );
    }
  });
}

/// Replaces the whole known channel list with exactly what the server
/// returned, pruning any channel (and its cached messages) that dropped out -
/// a permission revoked live, or a delete this device did not perform
/// itself. [MessageStore.upsertChannels] must never gain this: a
/// single-channel call (a rename, a freshly created channel) would wipe
/// every other row.
///
/// A thread is spared the absence test: `GET /channels` never lists one (see
/// [MessageStore.watchChannels]), so pruning on that absence alone would wipe
/// a thread's cached messages on every routine refresh. It goes with its
/// parent instead: a thread whose parent message sits in a pruned channel is
/// deleted too, since access to the thread is access to the parent's channel.
Future<void> replaceChannels(MessageStore store, List<api.Channel> channels,
    {Set<String> alsoKeep = const {}}) async {
  final db = store.db;
  await db.transaction(() async {
    await store.upsertChannels(channels);
    final threadIds = await (db.select(db.channels)
          ..where((c) => c.parentMessageId.isNotNull()))
        .map((c) => c.id)
        .get();
    final keep = {...channels.map((c) => c.id), ...threadIds, ...alsoKeep};
    final stale =
        await (db.select(db.channels)..where((c) => c.id.isNotIn(keep))).get();
    final staleIds = stale.map((c) => c.id).toList();
    for (final threadId in await threadIdsUnder(db, staleIds)) {
      await deleteChannelRows(db, threadId);
    }
    for (final id in staleIds) {
      await deleteChannelRows(db, id);
    }
  });
}

/// The held threads whose parent message sits in one of [channelIds].
Future<List<String>> threadIdsUnder(
    SlimmDatabase db, List<String> channelIds) async {
  if (channelIds.isEmpty) return const [];
  final parents = db.selectOnly(db.messages)
    ..addColumns([db.messages.id])
    ..where(db.messages.channelId.isIn(channelIds));
  return (db.select(db.channels)
        ..where((c) => c.parentMessageId.isInQuery(parents)))
      .map((c) => c.id)
      .get();
}

/// A channel's row and everything keyed to it: its messages, its draft and its
/// personal canvas layout, which would otherwise sit unreachable behind an id nothing lists.
Future<void> deleteChannelRows(SlimmDatabase db, String channelId) async {
  await (db.delete(db.messages)..where((m) => m.channelId.equals(channelId)))
      .go();
  await (db.delete(db.channelDrafts)
        ..where((d) => d.channelId.equals(channelId)))
      .go();
  await (db.delete(db.canvasPersonalLayouts)
        ..where((l) => l.channelId.equals(channelId)))
      .go();
  await (db.delete(db.channels)..where((c) => c.id.equals(channelId))).go();
}
