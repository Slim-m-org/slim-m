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

/// Every DM in [channels] but the caller's own Notes, in listing order: Notes
/// is the footer's button, not a row (decision 0111).
List<Channel> railDirectMessages(List<Channel> channels) => [
  for (final channel in channels)
    if (channel.kind == dmChannelKind && !channel.isPersonalSpace) channel,
];

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
/// messages in listing order, then every non-DM channel bucketed by category -
/// uncategorised first, then each of [categories] in its own position order -
/// mixed kind within a bucket, ordered by the channel's own position. Notes is
/// not a row, so cycling never lands on it.
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
    for (final category in categories) ...byCategory[category.id] ?? const [],
  ];
}
