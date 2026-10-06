// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pure ordering over a channel listing, shared by the rail's sections and
/// the next/previous-channel shortcuts so the two cannot drift apart the way
/// `orderedChannels` and `DirectMessagesSection` once did: this used to
/// duplicate the personal-space split inline, in raw `createdAt` order, so
/// cycling landed on a different channel than the one the rail showed first.
///
/// Grouping is by category, not by kind, per docs/decisions/
/// 0006-channel-categories.md: `kind` decides a channel's behaviour (a
/// transcript or a call), `categoryId` decides which rail section it renders
/// in, and a channel of any kind may sit in any category.
library;

import 'package:slimm_data/data.dart';

import '../providers/dms.dart';

/// [channels] split into the caller's personal space, if present, and every
/// other channel: the first one flagged [Channel.isPersonalSpace] is pulled
/// out, and any channel after it - there should only ever be one - keeps its
/// place in [others] rather than being dropped.
({Channel? personal, List<Channel> others}) splitPersonalSpace(
  List<Channel> channels,
) {
  Channel? personal;
  final others = <Channel>[];
  for (final channel in channels) {
    if (channel.isPersonalSpace && personal == null) {
      personal = channel;
    } else {
      others.add(channel);
    }
  }
  return (personal: personal, others: others);
}

/// [channels] (already restricted to live, non-DM, non-thread ones) bucketed
/// by category id, each bucket sorted by `position` - `null` for the
/// implicit uncategorised section, which always sorts first regardless of
/// where it falls among [categories].
Map<String?, List<Channel>> channelsByCategory(List<Channel> channels) {
  final sorted = [...channels]
    ..sort((a, b) => a.position.compareTo(b.position));
  final byCategory = <String?, List<Channel>>{};
  for (final channel in sorted) {
    (byCategory[channel.categoryId] ??= []).add(channel);
  }
  return byCategory;
}

/// [channels] grouped and ordered the way the rail renders them: direct
/// messages (the personal space first, then every other DM in listing
/// order), then every non-DM channel bucketed by category - uncategorised
/// first, then each of [categories] in its own position order - mixed kind
/// within a bucket, ordered by the channel's own position.
List<Channel> orderedChannels(
  List<Channel> channels,
  List<ChannelCategoryRow> categories,
) {
  final dms = splitPersonalSpace(
    channels.where((c) => c.kind == dmChannelKind).toList(),
  );
  final byCategory = channelsByCategory(
    channels
        .where((c) => c.kind != dmChannelKind && c.parentMessageId == null)
        .toList(),
  );
  return [
    if (dms.personal != null) dms.personal!,
    ...dms.others,
    ...byCategory[null] ?? const [],
    for (final category in categories) ...byCategory[category.id] ?? const [],
  ];
}
