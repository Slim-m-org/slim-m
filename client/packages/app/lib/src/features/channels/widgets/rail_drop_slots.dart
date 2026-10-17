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
  const DropSlot(this.section, this.index, this.y);

  /// For a channel, its section; for a category, unused.
  final int section;

  /// For a channel, its place among that section's channels before the carried
  /// one is taken out; for a category, its place among the named categories.
  final int index;
  final double y;

  @override
  bool operator ==(Object other) =>
      other is DropSlot &&
      other.section == section &&
      other.index == index &&
      other.y == y;

  @override
  int get hashCode => Object.hash(section, index, y);
}

DropSlot? _nearest(Iterable<DropSlot> slots, double pointerY) {
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
DropSlot? channelSlotAt(
  List<RailBox> boxes,
  Set<int> closedSections,
  double pointerY,
) {
  final sections = {for (final b in boxes) b.section}.toList()..sort();
  final slots = <DropSlot>[];
  for (final section in sections) {
    if (closedSections.contains(section)) continue;
    final header = boxes.where(
      (b) => b.section == section && b.kind == RailBoxKind.header,
    );
    final rows = boxes
        .where((b) => b.section == section && b.kind == RailBoxKind.channel)
        .toList();
    final headerVisible = header.isNotEmpty && header.first.visible;
    if (header.isEmpty && rows.isEmpty) continue;
    final start = headerVisible
        ? header.first.bottom
        : rows.isEmpty
        ? header.first.top
        : rows.first.top;
    slots.add(DropSlot(section, 0, start));
    for (var k = 1; k <= rows.length; k++) {
      slots.add(DropSlot(section, k, rows[k - 1].bottom));
    }
  }
  return _nearest(slots, pointerY);
}

/// The gap between category blocks nearest [pointerY]; [named] are the
/// section indices of the real categories, in order. A block runs from its
/// header to its last visible row.
DropSlot? categorySlotAt(
  List<RailBox> boxes,
  List<int> named,
  double pointerY,
) {
  final slots = <DropSlot>[];
  for (var j = 0; j < named.length; j++) {
    final section = named[j];
    final header = boxes.firstWhere(
      (b) => b.section == section && b.kind == RailBoxKind.header,
    );
    slots.add(DropSlot(section, j, header.top));
    if (j == named.length - 1) {
      final rows = boxes.where(
        (b) =>
            b.section == section && b.kind == RailBoxKind.channel && b.visible,
      );
      final bottom = rows.isEmpty ? header.bottom : rows.last.bottom;
      slots.add(DropSlot(section, named.length, bottom));
    }
  }
  return _nearest(slots, pointerY);
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

/// The category order after dropping [movedId] into gap [slotIndex] of
/// [ids], or null when it is already there.
List<String>? categoryIdsAfterDrop(
  List<String> ids,
  String movedId,
  int slotIndex,
) {
  final at = ids.indexOf(movedId);
  if (at < 0 || slotIndex == at || slotIndex == at + 1) return null;
  final next = [...ids]..removeAt(at);
  next.insert(slotIndex > at ? slotIndex - 1 : slotIndex, movedId);
  return next;
}
