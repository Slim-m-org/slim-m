// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two-level category tree the rail draws (decision 0120), built from the
/// flat rows the local store holds, where a position orders siblings only.
library;

import 'package:slimm_api/api.dart' show CategoryOrderGroup;
import 'package:slimm_data/data.dart';

import 'channel_grouping.dart';
import 'channel_rail_reorder.dart' show ChannelSection;

/// [categories] arranged as the rail shows them.
///
/// Each top-level category comes first by position, followed by its own
/// sub-categories by position. A sub-category whose parent this device does
/// not hold draws as a top-level one after every block until the next refresh,
/// never under whichever heading happens to precede it.
class CategoryTree {
  CategoryTree(List<ChannelCategoryRow> categories)
    : byId = {for (final c in categories) c.id: c} {
    final sorted = [...categories]..sort(_bySiblingOrder);
    final children = <String, List<ChannelCategoryRow>>{};
    final tops = <ChannelCategoryRow>[];
    final orphans = <ChannelCategoryRow>[];
    for (final category in sorted) {
      final parent = _heldParent(category);
      if (parent != null) {
        (children[parent.id] ??= []).add(category);
      } else if (category.parentId == null) {
        tops.add(category);
      } else {
        orphans.add(category);
      }
    }
    _children = children;
    topLevel = [...tops, ...orphans];
    ordered = [
      for (final top in topLevel) ...[top, ...?children[top.id]],
    ];
  }

  final Map<String, ChannelCategoryRow> byId;

  /// Every top-level category in order, orphaned sub-categories last.
  late final List<ChannelCategoryRow> topLevel;

  /// Every category in tree order: each top-level one, then its children.
  late final List<ChannelCategoryRow> ordered;
  late final Map<String, List<ChannelCategoryRow>> _children;

  /// A parent must itself be top-level, so a stale row can never draw a third level.
  ChannelCategoryRow? _heldParent(ChannelCategoryRow category) {
    final parent = byId[category.parentId];
    if (parent == null || parent.parentId != null) return null;
    return parent;
  }

  /// The heading [category] draws under, or null when it draws at the top.
  ChannelCategoryRow? parentOf(ChannelCategoryRow? category) =>
      category == null ? null : _heldParent(category);

  /// 1 for a sub-category drawn under its parent, else 0.
  int depthOf(ChannelCategoryRow? category) =>
      parentOf(category) == null ? 0 : 1;

  List<ChannelCategoryRow> childrenOf(String categoryId) =>
      _children[categoryId] ?? const [];

  /// The siblings [category] moves among: its parent's children, or the top level.
  List<ChannelCategoryRow> siblingsOf(ChannelCategoryRow category) {
    final parent = parentOf(category);
    return parent == null ? topLevel : childrenOf(parent.id);
  }

  /// How a place is named outside the rail: "gamers / cs2".
  String pathOf(ChannelCategoryRow category) {
    final parent = parentOf(category);
    return parent == null ? category.name : '${parent.name} / ${category.name}';
  }

  /// The whole arrangement as `PUT /categories/order` takes it.
  List<CategoryOrderGroup> get groups => [
    CategoryOrderGroup(
      parentId: null,
      categoryIds: [for (final c in topLevel) c.id],
    ),
    for (final top in topLevel)
      if (childrenOf(top.id).isNotEmpty)
        CategoryOrderGroup(
          parentId: top.id,
          categoryIds: [for (final c in childrenOf(top.id)) c.id],
        ),
  ];
}

int _bySiblingOrder(ChannelCategoryRow a, ChannelCategoryRow b) {
  final byPosition = a.position.compareTo(b.position);
  return byPosition != 0 ? byPosition : a.id.compareTo(b.id);
}

/// Every category's id to how it is named outside the rail ("gamers / cs2").
Map<String, String> categoryPaths(List<ChannelCategoryRow> categories) {
  final tree = CategoryTree(categories);
  return {for (final c in tree.ordered) c.id: tree.pathOf(c)};
}

/// The tree [sections] were built from, for a caller handed only the sections.
CategoryTree treeOfSections(List<ChannelSection> sections) =>
    CategoryTree([for (final (category, _) in sections) ?category]);

/// The rail's sections in tree order: uncategorised, then each top-level
/// category with its own channels, then each of its sub-categories.
///
/// A manager sees every section, since an empty one is where the next channel
/// goes. Anyone else sees a top-level section when it or one of its
/// sub-categories holds a channel, and a sub-category when it holds one, so a
/// parent listed only as a container still heads its sub-categories.
List<ChannelSection> railSections(
  List<Channel> channels,
  CategoryTree tree, {
  required bool canManage,
}) {
  final byCategory = channelsByCategory(channels);
  bool holds(ChannelCategoryRow? category) =>
      (byCategory[category?.id] ?? const []).isNotEmpty;
  bool shown(ChannelCategoryRow? category) =>
      canManage ||
      holds(category) ||
      (category != null && tree.childrenOf(category.id).any(holds));
  return [
    for (final category in <ChannelCategoryRow?>[null, ...tree.ordered])
      if (shown(category)) (category, byCategory[category?.id] ?? const []),
  ];
}

/// The indices of the sections [collapsed] hides: a folded category, and every
/// sub-category of a folded parent.
Set<int> closedSections(
  List<ChannelSection> sections,
  CategoryTree tree,
  Set<String> collapsed,
) => {
  for (var s = 0; s < sections.length; s++)
    if (collapsed.contains(sections[s].$1?.id) ||
        collapsed.contains(tree.parentOf(sections[s].$1)?.id))
      s,
};
