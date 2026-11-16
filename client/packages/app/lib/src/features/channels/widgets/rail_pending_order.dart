// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the rail draws while a reorder is in flight: the arrangement asked
/// for, over what the local store still holds until the server confirms it.
library;

import 'package:slimm_api/api.dart' show CategoryOrderGroup, ChannelOrderGroup;
import 'package:slimm_data/data.dart';

/// Renders [pending] (a reorder this client is waiting on, or has just had
/// refused) over [channels], rather than the plain arrangement the local
/// store still holds - the store is not rewritten until the server confirms
/// it. A channel [pending] does not name (a DM, or one that arrived
/// concurrently) keeps its stored category and position.
List<Channel> withPendingChannelOrder(
  List<Channel> channels,
  List<ChannelOrderGroup>? pending,
) {
  if (pending == null) return channels;
  final byId = {for (final channel in channels) channel.id: channel};
  final named = <String>{};
  final overridden = <Channel>[];
  for (final group in pending) {
    for (var i = 0; i < group.channelIds.length; i++) {
      final original = byId[group.channelIds[i]];
      if (original == null) continue;
      named.add(original.id);
      overridden.add(
        original.repositioned(categoryId: group.categoryId, position: i),
      );
    }
  }
  return [
    ...overridden,
    for (final channel in channels)
      if (!named.contains(channel.id)) channel,
  ];
}

/// [withPendingChannelOrder] for the category tree: each category [pending]
/// names takes its parent and place from it.
List<ChannelCategoryRow> withPendingCategoryOrder(
  List<ChannelCategoryRow> categories,
  List<CategoryOrderGroup>? pending,
) {
  if (pending == null) return categories;
  final placed = <String, (String?, int)>{
    for (final group in pending)
      for (final (i, id) in group.categoryIds.indexed) id: (group.parentId, i),
  };
  return [
    for (final category in categories)
      if (placed[category.id] case (final parentId, final position))
        ChannelCategoryRow(
          id: category.id,
          name: category.name,
          position: position,
          parentId: parentId,
        )
      else
        category,
  ];
}
