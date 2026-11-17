// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How the forward and share pickers group their [ForwardTarget]s.
library;

import 'forward_targets.dart';

/// How many recent conversations "Suggested" offers besides Notes and here.
const suggestedConversationCount = 3;

typedef DestinationSection = ({String title, List<ForwardTarget> targets});

/// The non-empty sections for [search], in display order.
///
/// With no search, "Suggested" leads with [currentChannelId], Notes and the
/// most recent conversations (the server lists DMs newest first), and those
/// rows are not repeated below it. A search drops "Suggested" and filters.
List<DestinationSection> destinationSections(
  List<ForwardTarget> all, {
  required String search,
  String? currentChannelId,
}) {
  final needle = search.trim().toLowerCase();
  final shown = needle.isEmpty
      ? all
      : [
          for (final t in all)
            if (t.matches(needle)) t,
        ];
  final suggested = needle.isEmpty
      ? _suggested(all, currentChannelId)
      : const <ForwardTarget>[];
  final rest = [
    for (final t in shown)
      if (!suggested.contains(t)) t,
  ];
  final sections = <DestinationSection>[
    (title: 'Suggested', targets: suggested),
    (title: 'Channels', targets: [...rest.where((t) => !t.isDm)]),
    (title: 'Direct messages', targets: [...rest.where(_isPersonDm)]),
    (title: 'Groups', targets: [...rest.where((t) => t.isGroup)]),
    (title: 'Notes', targets: [...rest.where((t) => t.isPersonalSpace)]),
  ];
  return [
    for (final s in sections)
      if (s.targets.isNotEmpty) s,
  ];
}

bool _isPersonDm(ForwardTarget t) => t.isDm && !t.isGroup && !t.isPersonalSpace;

List<ForwardTarget> _suggested(
  List<ForwardTarget> all,
  String? currentChannelId,
) => [
  ...all.where((t) => t.channelId == currentChannelId),
  ...all.where((t) => t.isPersonalSpace && t.channelId != currentChannelId),
  ...all
      .where(
        (t) => (_isPersonDm(t) || t.isGroup) && t.channelId != currentChannelId,
      )
      .take(suggestedConversationCount),
];
