// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Moving a channel one step without a drag: the path for a keyboard, a
/// screen reader, and anyone who would rather not hold and carry a row.
///
/// One step is one place among the channels as they are listed, so the first
/// channel of a category steps up into the end of the category above, and the
/// last steps down into the start of the one below. A collapsed category, and
/// every sub-category of a collapsed parent, is stepped over, since its rows
/// are hidden and a channel dropped into it would vanish from the rail. A
/// category the account may not file under is stepped over too.
library;

import 'package:slimm_api/api.dart' show ChannelOrderGroup;

import 'category_tree.dart';
import 'channel_rail_reorder.dart' show ChannelSection, shutSections;

/// The whole rail's arrangement after moving [channelId] one step by [delta],
/// or null when it is already at that end. [collapsed] holds category ids.
List<ChannelOrderGroup>? groupsAfterStep(
  List<ChannelSection> sections,
  String channelId,
  int delta, {
  Set<String> collapsed = const {},
}) {
  final lists = [
    for (final (_, channels) in sections) [for (final c in channels) c.id],
  ];
  final from = lists.indexWhere((ids) => ids.contains(channelId));
  if (from < 0) return null;
  final at = lists[from].indexOf(channelId);
  final within = at + delta;
  if (within >= 0 && within < lists[from].length) {
    lists[from]
      ..removeAt(at)
      ..insert(within, channelId);
    return _groups(sections, lists);
  }
  final closed = {
    ...closedSections(sections, treeOfSections(sections), collapsed),
    ...shutSections(sections),
  };
  var to = from + delta;
  while (to >= 0 && to < sections.length && closed.contains(to)) {
    to += delta;
  }
  if (to < 0 || to >= sections.length) return null;
  lists[from].removeAt(at);
  lists[to].insert(delta < 0 ? lists[to].length : 0, channelId);
  return _groups(sections, lists);
}

List<ChannelOrderGroup> _groups(
  List<ChannelSection> sections,
  List<List<String>> lists,
) => [
  for (var i = 0; i < sections.length; i++)
    ChannelOrderGroup(categoryId: sections[i].$1?.id, channelIds: lists[i]),
];

/// The whole rail's arrangement after filing [channelId], and any temporary
/// rooms under it, at the end of [categoryId] (null for uncategorised), or
/// null when it is already there or no such section is listed.
List<ChannelOrderGroup>? groupsAfterMoveTo(
  List<ChannelSection> sections,
  String channelId,
  String? categoryId,
) {
  final lists = [
    for (final (_, channels) in sections) [for (final c in channels) c.id],
  ];
  final from = lists.indexWhere((ids) => ids.contains(channelId));
  final to = sections.indexWhere((s) => s.$1?.id == categoryId);
  if (from < 0 || to < 0 || from == to) return null;
  final moving = {
    channelId,
    for (final c in sections[from].$2)
      if (c.roomLobbyId == channelId) c.id,
  };
  final carried = [
    for (final id in lists[from])
      if (moving.contains(id)) id,
  ];
  lists[from].removeWhere(moving.contains);
  lists[to].addAll(carried);
  return _groups(sections, lists);
}
