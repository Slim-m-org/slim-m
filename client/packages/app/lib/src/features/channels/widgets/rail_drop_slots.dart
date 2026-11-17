// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a carried channel or category can land, resolved from the measured
/// boxes of the rail's items. Pure geometry and list arithmetic, so the
/// rules live apart from the gesture that feeds them.
library;

import 'package:slimm_api/api.dart' show ChannelOrderGroup;

import 'channel_rail_reorder.dart' show ChannelSection;

enum RailBoxKind { header, channel }

/// One rail item's vertical extent, in a coordinate space shared by all.
class RailBox {
  const RailBox({
    required this.kind,
    required this.section,
    required this.top,
    required this.bottom,
  });

  final RailBoxKind kind;

  /// Index into the rail's sections.
  final int section;
  final double top;
  final double bottom;

  bool get visible => bottom - top > 0.5;
}

/// A gap a carried item can drop into, and the y the insertion line shows at.
class DropSlot {
  const DropSlot(
    this.section,
    this.index,
    this.y, {
    this.parentId,
    this.inset = 0,
    this.refused = false,
  });

  /// For a channel, its section; for a category, the section the gap sits by.
  final int section;

  /// For a channel, its place among that section's channels before the carried
  /// one is taken out; for a category, its place among its new siblings.
  final int index;
  final double y;

  /// For a category, the top-level one it would land under; null for the top.
  final String? parentId;

  /// How far right of a top-level heading's edge the line starts.
  final double inset;

  /// Where a third level would be (decision 0120): shown, never sent.
  final bool refused;

  @override
  bool operator ==(Object other) =>
      other is DropSlot &&
      other.section == section &&
      other.index == index &&
      other.y == y &&
      other.parentId == parentId &&
      other.inset == inset &&
      other.refused == refused;

  @override
  int get hashCode => Object.hash(section, index, y, parentId, inset, refused);
}

DropSlot? nearestSlot(Iterable<DropSlot> slots, double pointerY) {
  DropSlot? best;
  for (final slot in slots) {
    if (best == null ||
        (slot.y - pointerY).abs() <= (best.y - pointerY).abs()) {
      best = slot;
    }
  }
  return best;
}

/// The channel gap nearest [pointerY], skipping [closedSections] (a folded
/// category has no visible gap to drop into). An empty section whose header is
/// not drawn - the idle uncategorised one - is still a gap, at its header's
/// own edge, so reaching it never shifts the rail under the pointer.
/// [insetOf] gives a section's line inset, deeper for a sub-category.
DropSlot? channelSlotAt(
  List<RailBox> boxes,
  Set<int> closedSections,
  double pointerY, {
  double Function(int section)? insetOf,
}) {
  final sections = {for (final b in boxes) b.section}.toList()..sort();
  final slots = <DropSlot>[
    for (final section in sections)
      if (!closedSections.contains(section))
        ..._sectionSlots(boxes, section, insetOf?.call(section) ?? 0),
  ];
  return nearestSlot(slots, pointerY);
}

List<DropSlot> _sectionSlots(List<RailBox> boxes, int section, double inset) {
  final header = boxes.where(
    (b) => b.section == section && b.kind == RailBoxKind.header,
  );
  final rows = boxes
      .where((b) => b.section == section && b.kind == RailBoxKind.channel)
      .toList();
  if (header.isEmpty && rows.isEmpty) return const [];
  return [
    DropSlot(section, 0, _firstGapY(header, rows), inset: inset),
    for (var k = 1; k <= rows.length; k++)
      DropSlot(section, k, rows[k - 1].bottom, inset: inset),
  ];
}

double _firstGapY(Iterable<RailBox> header, List<RailBox> rows) {
  if (header.isNotEmpty && header.first.visible) return header.first.bottom;
  if (rows.isEmpty) return header.first.top;
  return rows.first.top;
}

/// The rail's arrangement after dropping [channelId] into [slot], or null
/// when that is where it already is.
List<ChannelOrderGroup>? groupsAfterDrop(
  List<ChannelSection> sections,
  String channelId,
  DropSlot slot,
) {
  final lists = [
    for (final (_, channels) in sections) [for (final c in channels) c.id],
  ];
  final from = lists.indexWhere((ids) => ids.contains(channelId));
  if (from < 0) return null;
  final at = lists[from].indexOf(channelId);
  final same = slot.section == from;
  if (same && (slot.index == at || slot.index == at + 1)) return null;
  lists[from].removeAt(at);
  final into = same && slot.index > at ? slot.index - 1 : slot.index;
  lists[slot.section].insert(
    into.clamp(0, lists[slot.section].length),
    channelId,
  );
  return [
    for (var i = 0; i < sections.length; i++)
      ChannelOrderGroup(categoryId: sections[i].$1?.id, channelIds: lists[i]),
  ];
}
