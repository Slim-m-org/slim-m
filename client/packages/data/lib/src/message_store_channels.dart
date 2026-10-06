// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'message_store.dart';

/// The bodies behind [MessageStore.upsertChannels] and
/// [MessageStore.replaceChannels], split out of `message_store.dart` once it
/// grew slow mode's own column and pushed the file past its line budget -
/// the same `part of` shape `message_store_batch.dart` already uses. Private
/// top-level functions, not an extension, so both stay real methods every
/// caller reaches through the type; this runs in the store's own library, so
/// it uses [MessageStore.db] directly.

/// Replaces the known channel list, keeping each channel's local cursor and
/// read marker, which the server's channel list does not carry.
Future<void> _upsertChannels(
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
          parentMessageId: Value(channel.parentMessageId),
          categoryId: Value(channel.categoryId),
          slowModeSeconds: Value(channel.slowModeSeconds),
          joinMuted: Value(channel.joinMuted),
          restricted: Value(channel.restricted),
        ),
        onConflict: DoUpdate(
          (_) => ChannelsCompanion.custom(
            name: Variable(channel.name),
            kind: Variable(channel.kind),
            topic: Variable(channel.topic),
            position: Variable(channel.position),
            isPersonalSpace: Variable(channel.isPersonalSpace),
            dmParticipantId: Variable(channel.dmParticipantId),
            parentMessageId: Variable(channel.parentMessageId),
            categoryId: Variable(channel.categoryId),
            slowModeSeconds: Variable(channel.slowModeSeconds),
            joinMuted: Variable(channel.joinMuted),
            restricted: Variable(channel.restricted),
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
/// A thread is deliberately spared this pruning: `GET /channels` never lists
/// one (see [MessageStore.watchChannels]), so it can never appear in
/// [channels] even while its parent is still fully visible, and pruning on
/// that absence alone would wipe a thread's cached messages on every routine
/// refresh (any role or overwrite edit anywhere in the deployment triggers
/// one). A thread already known locally is kept until an explicit
/// `ChannelDeleted` event removes it - the same event any other channel's
/// deletion is learned through.
Future<void> _replaceChannels(
    MessageStore store, List<api.Channel> channels) async {
  final db = store.db;
  await db.transaction(() async {
    await store.upsertChannels(channels);
    final threadIds = await (db.select(db.channels)
          ..where((c) => c.parentMessageId.isNotNull()))
        .map((c) => c.id)
        .get();
    final keep = {...channels.map((c) => c.id), ...threadIds};
    final stale =
        await (db.select(db.channels)..where((c) => c.id.isNotIn(keep))).get();
    for (final row in stale) {
      await _deleteChannelRows(db, row.id);
    }
  });
}

/// A channel's row and everything keyed to it: its messages and its draft,
/// which would otherwise sit unreachable behind an id nothing lists.
Future<void> _deleteChannelRows(SlimmDatabase db, String channelId) async {
  await (db.delete(db.messages)..where((m) => m.channelId.equals(channelId)))
      .go();
  await (db.delete(db.channelDrafts)
        ..where((d) => d.channelId.equals(channelId)))
      .go();
  await (db.delete(db.channels)..where((c) => c.id.equals(channelId))).go();
}
