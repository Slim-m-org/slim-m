// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pure ordering over a channel listing, shared by the rail's sections and
/// the next/previous-channel shortcuts so the two cannot drift apart the way
/// `orderedChannels` and `DirectMessagesSection` once did: cycling used to
/// land on a different channel than the one the rail showed first.
///
/// Grouping is by category, not by kind, per docs/decisions/
/// 0006-channel-categories.md: `kind` decides a channel's behaviour (a
/// transcript or a call), `categoryId` decides which rail section it renders
/// in, and a channel of any kind may sit in any category.
library;

import 'package:slimm_data/data.dart';

import '../providers/dms.dart';
import 'category_tree.dart';

/// Every DM in [channels] but the caller's own Notes, in listing order: Notes
/// is the footer's button, not a row (decision 0111).
List<Channel> railDirectMessages(List<Channel> channels) => [
  for (final channel in channels)
    if (channel.kind == dmChannelKind && !channel.isPersonalSpace) channel,
];

/// [channels] (already restricted to live, non-DM, non-thread ones) bucketed
/// by category id, each bucket sorted by `position` with every temporary room
/// moved right under its own lobby - `null` for the implicit uncategorised
/// section, which always sorts first regardless of where it falls among
/// [categories].
Map<String?, List<Channel>> channelsByCategory(List<Channel> channels) {
  final sorted = [...channels]
    ..sort((a, b) => a.position.compareTo(b.position));
  final byCategory = <String?, List<Channel>>{};
  for (final channel in sorted) {
    (byCategory[channel.categoryId] ??= []).add(channel);
  }
  return byCategory.map(
    (id, bucket) => MapEntry(id, _roomsUnderLobbies(bucket)),
  );
}

/// Whether [channel] is a temporary room whose lobby sits in [bucket], so the
/// rail draws it one step in under that lobby (decision 0065).
bool isRoomUnderLobby(Channel channel, List<Channel> bucket) {
  final lobbyId = channel.roomLobbyId;
  return lobbyId != null &&
      bucket.any((c) => c.id == lobbyId && c.createsRooms == true);
}

/// Server positions put a room below its lobby, but a drag or a second lobby
/// can interleave them; the rail follows the room's own link instead.
List<Channel> _roomsUnderLobbies(List<Channel> bucket) {
  final lobbies = {
    for (final c in bucket)
      if (c.createsRooms == true) c.id,
  };
  final roomsOf = <String, List<Channel>>{};
  for (final c in bucket) {
    final lobbyId = c.roomLobbyId;
    if (lobbyId != null && lobbies.contains(lobbyId)) {
      (roomsOf[lobbyId] ??= []).add(c);
    }
  }
  if (roomsOf.isEmpty) return bucket;
  return [
    for (final c in bucket)
      if (!lobbies.contains(c.roomLobbyId)) ...[c, ...?roomsOf[c.id]],
  ];
}

/// [channels] grouped and ordered the way the rail renders them: direct
/// messages in listing order, then every non-DM channel bucketed by category -
/// uncategorised first, then each of [categories] in tree order (a parent's
/// own channels before its sub-categories') - mixed kind within a bucket,
/// ordered by the channel's own position. Notes is not a row, so cycling
/// never lands on it.
List<Channel> orderedChannels(
  List<Channel> channels,
  List<ChannelCategoryRow> categories,
) {
  final byCategory = channelsByCategory(
    channels
        .where((c) => c.kind != dmChannelKind && c.parentMessageId == null)
        .toList(),
  );
  return [
    ...railDirectMessages(channels),
    ...byCategory[null] ?? const [],
    for (final category in CategoryTree(categories).ordered)
      ...byCategory[category.id] ?? const [],
  ];
}
