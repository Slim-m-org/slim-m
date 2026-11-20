// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a carried category can land in the two-level tree (decision 0120),
/// and the arrangement a drop there sends. Pure geometry and list arithmetic,
/// apart from the gesture that feeds them.
///
/// A category is offered the gaps between top-level blocks and between the
/// sub-categories of every other open top-level block. A gap that would make
/// a third level - inside a sub-category's block, or any sub-category gap for
/// a category that has its own - is still offered, marked refused, so the
/// line can say why a drop there does nothing.
library;

import 'package:slimm_api/api.dart' show CategoryOrderGroup;
import 'package:slimm_data/data.dart' show CategoryReach;

import 'category_tree.dart';
import 'channel_rail_reorder.dart' show ChannelSection;
import 'rail_drop_slots.dart';

/// What [categorySlotAt] reads besides the measured boxes.
class CategoryCarry {
  const CategoryCarry({
    required this.sections,
    required this.tree,
    required this.carriedId,
    required this.closed,
    required this.inset,
    this.nests = true,
  });

  final List<ChannelSection> sections;
  final CategoryTree tree;
  final String carriedId;

  /// Section indices whose rows are folded away.
  final Set<int> closed;

  /// One level's indent, the rail's row inset.
  final double inset;

  /// False for a server that predates nesting: top-level gaps only.
  final bool nests;
}

/// The category gap nearest [pointerY]. Where a block's last gap and the next
/// top-level gap share a y, the side of it the pointer is on decides: above
/// stays inside the block, below starts the next one.
DropSlot? categorySlotAt(
  List<RailBox> boxes,
  CategoryCarry carry,
  double pointerY,
) {
  final slots = _categorySlots(boxes, carry);
  final nearest = nearestSlot(slots, pointerY);
  if (nearest == null) return null;
  final tied = slots.where((s) => (s.y - nearest.y).abs() < 0.5).toList();
  if (tied.length < 2) return nearest;
  tied.sort((a, b) => a.inset.compareTo(b.inset));
  return pointerY < nearest.y ? tied.last : tied.first;
}

List<DropSlot> _categorySlots(List<RailBox> boxes, CategoryCarry carry) {
  final tree = carry.tree;
  final carried = tree.byId[carry.carriedId];
  if (carried == null) return const [];
  final hasSubs = tree.childrenOf(carried.id).isNotEmpty;
  final sections = carry.sections;
  RailBox? headerOf(int s) => boxes
      .where((b) => b.section == s && b.kind == RailBoxKind.header)
      .firstOrNull;
  double bottomOf(Iterable<int> block) {
    final inBlock = boxes.where((b) => block.contains(b.section));
    return inBlock.fold(0, (y, b) => b.bottom > y ? b.bottom : y);
  }

  final tops = <int>[];
  final subsOf = <int, List<int>>{};
  for (var s = 0; s < sections.length; s++) {
    final category = sections[s].$1;
    if (category == null) continue;
    final parent = tree.parentOf(category);
    if (parent == null) {
      tops.add(s);
      continue;
    }
    final top = tops.lastOrNull;
    if (top != null && sections[top].$1?.id == parent.id) {
      (subsOf[top] ??= []).add(s);
    }
  }
  if (tops.isEmpty) return const [];

  final slots = <DropSlot>[];
  for (final (j, s) in tops.indexed) {
    final header = headerOf(s);
    if (header != null) slots.add(DropSlot(s, j, header.top));
  }
  final last = tops.last;
  slots.add(DropSlot(last, tops.length, bottomOf([last, ...?subsOf[last]])));

  if (!carry.nests) return slots;
  for (final top in tops) {
    final parentId = sections[top].$1!.id;
    if (parentId == carried.id || carry.closed.contains(top)) continue;
    final subs = subsOf[top] ?? const <int>[];
    DropSlot gap(int s, int k, double y) => DropSlot(
      s,
      k,
      y,
      parentId: parentId,
      inset: carry.inset,
      refused: hasSubs,
    );
    if (subs.isEmpty) {
      slots.add(gap(top, 0, bottomOf([top])));
      continue;
    }
    for (final (k, sub) in subs.indexed) {
      final header = headerOf(sub);
      if (header != null) slots.add(gap(sub, k, header.top));
    }
    slots.add(gap(subs.last, subs.length, bottomOf([subs.last])));
    for (final sub in subs) {
      if (sections[sub].$1!.id == carried.id) continue;
      slots.addAll(_insideSub(boxes, sub, carry));
    }
  }
  return slots;
}

/// Every gap above a sub-category's last row, where only a third level would go.
List<DropSlot> _insideSub(List<RailBox> boxes, int sub, CategoryCarry carry) {
  if (carry.closed.contains(sub)) return const [];
  final header = boxes
      .where((b) => b.section == sub && b.kind == RailBoxKind.header)
      .firstOrNull;
  final rows = boxes
      .where(
        (b) => b.section == sub && b.kind == RailBoxKind.channel && b.visible,
      )
      .toList();
  if (header == null || !header.visible || rows.isEmpty) return const [];
  final id = carry.sections[sub].$1!.id;
  return [
    for (var k = 0; k < rows.length; k++)
      DropSlot(
        sub,
        k,
        k == 0 ? header.bottom : rows[k - 1].bottom,
        parentId: id,
        inset: carry.inset * 2,
        refused: true,
      ),
  ];
}

/// The whole arrangement after dropping [movedId] into [slot], or null when
/// that changes nothing or would make a third level.
List<CategoryOrderGroup>? categoryGroupsAfterDrop(
  CategoryTree tree,
  String movedId,
  DropSlot slot,
) {
  final moved = tree.byId[movedId];
  final into = slot.parentId;
  if (moved == null || slot.refused || into == movedId) return null;
  if (into != null && tree.childrenOf(movedId).isNotEmpty) return null;
  final lists = <String?, List<String>>{
    null: [for (final c in tree.topLevel) c.id],
    for (final top in tree.topLevel)
      top.id: [for (final c in tree.childrenOf(top.id)) c.id],
  };
  final from = tree.parentOf(moved)?.id;
  final target = lists[into];
  final source = lists[from]!;
  if (target == null) return null;
  final at = source.indexOf(movedId);
  final same = from == into;
  if (same && (slot.index == at || slot.index == at + 1)) return null;
  source.removeAt(at);
  final place = same && slot.index > at ? slot.index - 1 : slot.index;
  target.insert(place.clamp(0, target.length), movedId);
  final after = keepFixedInPlace(tree, [
    CategoryOrderGroup(parentId: null, categoryIds: lists[null]!),
    for (final MapEntry(:key, :value) in lists.entries)
      if (key != null && value.isNotEmpty)
        CategoryOrderGroup(parentId: key, categoryIds: value),
  ]);
  final unchanged = after.every(
    (g) => _sameIds(g.categoryIds, _currentIds(tree, g.parentId)),
  );
  return unchanged ? null : after;
}

List<String> _currentIds(CategoryTree tree, String? parentId) => [
  for (final c in parentId == null ? tree.topLevel : tree.childrenOf(parentId))
    c.id,
];

bool _sameIds(List<String> a, List<String> b) =>
    a.length == b.length && a.indexed.every((e) => b[e.$1] == e.$2);

/// [groups] with every category this account may not move put back at the
/// index it holds among its siblings now, as the server will put it.
List<CategoryOrderGroup> keepFixedInPlace(
  CategoryTree tree,
  List<CategoryOrderGroup> groups,
) => [
  for (final group in groups)
    CategoryOrderGroup(
      parentId: group.parentId,
      categoryIds: _withFixed(tree, group),
    ),
];

List<String> _withFixed(CategoryTree tree, CategoryOrderGroup group) {
  bool fixed(String id) => !(tree.byId[id]?.canManage ?? true);
  final ids = [
    for (final id in group.categoryIds)
      if (!fixed(id)) id,
  ];
  for (final (i, id) in _currentIds(tree, group.parentId).indexed) {
    if (fixed(id)) ids.insert(i.clamp(0, ids.length), id);
  }
  return ids;
}

/// The arrangement after moving [categoryId] past its next sibling this
/// account may move in the direction of [delta], each one it may not move
/// staying where it is; null when there is none.
List<CategoryOrderGroup>? groupsAfterSiblingStep(
  CategoryTree tree,
  String categoryId,
  int delta,
) {
  final category = tree.byId[categoryId];
  if (category == null) return null;
  final parentId = tree.parentOf(category)?.id;
  final siblings = [for (final c in tree.siblingsOf(category)) c.id];
  final at = siblings.indexOf(categoryId);
  if (at < 0) return null;
  var to = at + delta.sign;
  while (to >= 0 &&
      to < siblings.length &&
      !(tree.byId[siblings[to]]?.canManage ?? true)) {
    to += delta.sign;
  }
  if (to < 0 || to >= siblings.length) return null;
  siblings[at] = siblings[to];
  siblings[to] = categoryId;
  return [
    for (final group in tree.groups)
      group.parentId == parentId
          ? CategoryOrderGroup(parentId: parentId, categoryIds: siblings)
          : group,
  ];
}
