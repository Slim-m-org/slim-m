// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Moving a channel one step without a drag: the path for a keyboard, a
/// screen reader, and anyone who would rather not hold and carry a row.
///
/// One step is one place among the channels as they are listed, so the first
/// channel of a category steps up into the end of the category above, and the
/// last steps down into the start of the one below. A collapsed category is
/// stepped over, since its rows are hidden and a channel dropped into it
/// would vanish from the rail.
library;

import 'package:slimm_api/api.dart' show ChannelOrderGroup;

import 'channel_rail_reorder.dart' show ChannelSection;

/// What a channel row's menu needs to offer Move up and Move down.
class ChannelMoveActions {
  const ChannelMoveActions({required this.canMove, required this.move});

  /// Whether a step of [delta] (-1 up, +1 down) lands anywhere.
  final bool Function(int delta) canMove;
  final void Function(int delta) move;
}

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
  var to = from + delta;
  while (to >= 0 && to < sections.length) {
    final id = sections[to].$1?.id;
    if (id == null || !collapsed.contains(id)) break;
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
