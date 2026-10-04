// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Drag-to-reorder across the whole channel-rail listing: every category
/// section in one list, so a channel of any kind can be dragged into any
/// category - the property backlog item #34 asked for. See
/// docs/decisions/0006-channel-categories.md.
///
/// A plain [Column] when nobody may reorder, when no channel exists (a lone
/// header in a reorder list hit-tests a tap to the wrong render object), or
/// when one channel has only its own section to sit in. A lone channel with a
/// second section still reorders: it is the only way to file it there.
/// Otherwise every
/// category's header and channel rows are one flat item list, which is what
/// lets a drag cross a section boundary at all.
///
/// The list is a bare [SliverReorderableList] in a [ShrinkWrappingViewport],
/// not a `ReorderableListView`: that owns an inner scrollable, so a drag's
/// edge auto-scroll would act on a view that never moves and a channel could
/// not be carried past the fold. Without one, the rail's own scroll view is
/// the scrollable the drag scrolls.
///
/// At pointer widths [DesktopRailReorder] takes over: a held press lifts a row
/// or a category header and a line shows where it will land. Below
/// `kCompactWidth` every drag on a row is a scroll, so the row lifts only after
/// a held press on the list below (`docs/design/desktop-vs-mobile.md`, "drag
/// to reorder"); a held press released without moving the row opens its
/// options sheet instead ([onLiftedInPlace]). Move up and Move down in that
/// sheet are the path without a gesture, and a screen reader gets move actions
/// on every row at either width.
///
/// The settle animation of a held drag does not honour `AppMotion` or the OS
/// reduce-motion toggle: [SliverReorderableList] takes no animation style and
/// hardcodes its 250ms slide (Flutter 3.44, `reorderable_list.dart`).
/// Closing that needs a vendored reorder implementation.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ViewportOffset;
import 'package:slimm_api/api.dart' show ChannelOrderGroup;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'desktop_rail_reorder.dart';
import 'rail_drag_lift.dart';

/// One category's ordered channels, `null` for the implicit uncategorised
/// section, which always renders first.
/// The gap a channel row keeps from the rail's left edge.
const kRailRowInset = AppSpacing.s8;

typedef ChannelSection = (ChannelCategoryRow? category, List<Channel> channels);

/// Exposed (not library-private) only so `groupsFromRailItems` can be driven
/// directly from a test without a real drag gesture; nothing outside this
/// file and its test builds these by hand otherwise.
@visibleForTesting
sealed class RailItem {
  const RailItem();
}

@visibleForTesting
class HeaderRailItem extends RailItem {
  const HeaderRailItem(this.category);
  final ChannelCategoryRow? category;
}

@visibleForTesting
class ChannelRailItem extends RailItem {
  const ChannelRailItem(this.channel);
  final Channel channel;
}

/// Renders [sections] as [rowBuilder]-built rows under [headerBuilder]-built
/// headers, reorderable across every section by [canManage].
///
/// At pointer widths a header can be lifted too, which reorders categories
/// through [onReorderCategories] and leaves every channel with its category.
class ReorderableChannelRows extends StatefulWidget {
  const ReorderableChannelRows({
    super.key,
    required this.sections,
    required this.canManage,
    required this.onReorder,
    required this.rowBuilder,
    required this.headerBuilder,
    this.onDragStart,
    this.onDragEnd,
    this.onLiftedInPlace,
    this.onReorderCategories,
    this.carriedRowBuilder,
    this.carriedHeaderBuilder,
    this.carriedRowInset = 0,
    this.collapsed = const {},
  });

  final List<ChannelSection> sections;
  final bool canManage;

  /// Called with the whole rail's new arrangement, grouped by category, once
  /// a drag settles.
  final ValueChanged<List<ChannelOrderGroup>> onReorder;

  /// A held drag has actually started, or just ended - not whether a menu
  /// action moved a channel. `headerBuilder` is invoked with the same item
  /// count either way, so a caller can use these to change what a header
  /// renders without ever changing how many items this list holds; the
  /// underlying [SliverReorderableList] cancels the drag outright the moment
  /// its own item count changes mid-drag.
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;

  /// A touch row was lifted and dropped back where it was, which opens that
  /// row's options rather than leaving a held press with no result.
  final ValueChanged<Channel>? onLiftedInPlace;
  final ValueChanged<List<String>>? onReorderCategories;
  final Widget Function(Channel channel)? carriedRowBuilder;

  /// The gap [rowBuilder] leaves left of a row's face, which the lifted copy
  /// and the slot it leaves behind are drawn without.
  final double carriedRowInset;
  final Widget Function(ChannelCategoryRow? category)? carriedHeaderBuilder;
  final Set<String> collapsed;

  /// Builds one channel's row, told whether *this render* actually wraps it
  /// in a drag listener - false in the plain-[Column] branch, true in the
  /// reorder-list one - so a caller can withhold a competing
  /// long-press gesture (a context menu, say) only where one would actually
  /// compete for the arena.
  /// [longPressDrags] says a held press on this row starts a move, so the
  /// row must withhold its own long-press context menu.
  final Widget Function(Channel channel, bool longPressDrags) rowBuilder;
  final Widget Function(ChannelCategoryRow? category) headerBuilder;

  @override
  State<ReorderableChannelRows> createState() => _ReorderableChannelRowsState();
}

class _ReorderableChannelRowsState extends State<ReorderableChannelRows> {
  int? _liftedFrom;

  List<RailItem> get _items => [
    for (final (category, channels) in widget.sections) ...[
      HeaderRailItem(category),
      for (final channel in channels) ChannelRailItem(channel),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final channelCount = items.whereType<ChannelRailItem>().length;
    final nowhereToMove =
        channelCount == 0 || (channelCount == 1 && widget.sections.length < 2);
    final touch = AppTouchTargets.of(context);
    if (widget.canManage && !touch) {
      return DesktopRailReorder(
        sections: widget.sections,
        collapsed: widget.collapsed,
        rowBuilder: widget.rowBuilder,
        carriedRowBuilder: widget.carriedRowBuilder,
        carriedRowInset: widget.carriedRowInset,
        carriedHeaderBuilder: widget.carriedHeaderBuilder,
        headerBuilder: widget.headerBuilder,
        onReorder: widget.onReorder,
        onReorderCategories: widget.onReorderCategories,
      );
    }
    if (!widget.canManage || nowhereToMove) {
      return Column(
        // A Column centres by default and a header is only as wide as its word, so without the manager's add glyph every heading sat centred.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in items)
            switch (item) {
              HeaderRailItem(:final category) => widget.headerBuilder(category),
              ChannelRailItem(:final channel) => widget.rowBuilder(
                channel,
                false,
              ),
            },
        ],
      );
    }
    // A bare viewport has no Scrollable, so a drag's edge auto-scroll moves the rail's own.
    final list = ShrinkWrappingViewport(
      offset: _fixedOffset,
      axisDirection: AxisDirection.down,
      crossAxisDirection: Viewport.getDefaultCrossAxisDirection(
        context,
        AxisDirection.down,
      ),
      slivers: [
        SliverReorderableList(
          itemCount: items.length,
          proxyDecorator: (child, _, animation) =>
              RailDragLift(animation: animation, child: child),
          onReorderStart: (index) {
            _liftedFrom = index;
            AppHaptics.impact();
            widget.onDragStart?.call();
          },
          onReorderEnd: (index) {
            AppHaptics.selection();
            widget.onDragEnd?.call();
            _openIfDroppedInPlace(items, index);
          },
          onReorderItem: (oldIndex, newIndex) =>
              _reorder(items, oldIndex, newIndex),
          itemBuilder: (context, index) => _item(items, index),
        ),
      ],
    );
    // A host with no scroll view of its own still needs the one a drag looks up.
    return Scrollable.maybeOf(context) == null
        ? SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: list,
          )
        : list;
  }

  void _openIfDroppedInPlace(List<RailItem> items, int droppedAt) {
    final from = _liftedFrom;
    _liftedFrom = null;
    if (!AppTouchTargets.of(context) || from != droppedAt) return;
    final item = items[droppedAt];
    if (item is ChannelRailItem) widget.onLiftedInPlace?.call(item.channel);
  }

  void _reorder(List<RailItem> items, int oldIndex, int newIndex) {
    final moved = items[oldIndex];
    if (moved is! ChannelRailItem) return;
    final rearranged = [...items]
      ..removeAt(oldIndex)
      ..insert(newIndex, moved);
    widget.onReorder(groupsFromRailItems(rearranged, widget.sections));
  }

  Widget _item(List<RailItem> items, int i) => switch (items[i]) {
    HeaderRailItem(:final category) => KeyedSubtree(
      key: ValueKey('header-${category?.id}'),
      child: widget.headerBuilder(category),
    ),
    ChannelRailItem(:final channel) => ReorderableDelayedDragStartListener(
      key: ValueKey(channel.id),
      index: i,
      child: RailGrabFeedback(child: widget.rowBuilder(channel, true)),
    ),
  };
}

final _fixedOffset = ViewportOffset.zero();

/// Walks [items] in order, attributing every channel to whichever header
/// last preceded it, and answers one [ChannelOrderGroup] per category that
/// either still holds a channel or is named in [sections] - a category
/// [sections] names but that now holds nothing still gets an empty group, so
/// a drag that empties it still tells the server to clear it rather than
/// leaving its old contents unmentioned.
///
/// Deliberately keyed off the accumulated map rather than filtered by
/// [sections]: a channel can be attributed to a category (`null` included)
/// that [sections] does not list at all - dropped above every header, before
/// the implicit uncategorised section ever became a section in its own
/// right, is exactly how one reached production - and filtering by
/// [sections] there would silently drop it from the payload the server then
/// rejects outright (`ReorderChannelsError::Mismatch`, "Missing live
/// channel(s)") rather than send a request naming every live channel once.
@visibleForTesting
List<ChannelOrderGroup> groupsFromRailItems(
  List<RailItem> items,
  List<ChannelSection> sections,
) {
  final byCategory = <String?, List<String>>{
    for (final (category, _) in sections) category?.id: [],
  };
  String? current;
  for (final item in items) {
    switch (item) {
      case HeaderRailItem(:final category):
        current = category?.id;
      case ChannelRailItem(:final channel):
        (byCategory[current] ??= []).add(channel.id);
    }
  }
  return [
    for (final categoryId in byCategory.keys)
      ChannelOrderGroup(
        categoryId: categoryId,
        channelIds: byCategory[categoryId] ?? const [],
      ),
  ];
}
