// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The screen reader's and the keyboard's way to move a rail item without a gesture.
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart' show CategoryOrderGroup, ChannelOrderGroup;

import 'category_tree.dart';
import 'channel_move.dart';
import 'channel_rail_reorder.dart' show ChannelSection;
import 'rail_category_slots.dart';

/// The step up and the step down for a channel row, each null where it lands nowhere.
({VoidCallback? up, VoidCallback? down}) channelMoveSteps(
  List<ChannelSection> sections,
  Set<String> collapsed,
  String channelId,
  ValueChanged<List<ChannelOrderGroup>> onReorder,
) {
  VoidCallback? step(int delta) {
    final groups = groupsAfterStep(
      sections,
      channelId,
      delta,
      collapsed: collapsed,
    );
    return groups == null ? null : () => onReorder(groups);
  }

  return (up: step(-1), down: step(1));
}

/// Move up and Move down for a channel row, each offered only where it lands.
Map<CustomSemanticsAction, VoidCallback> channelMoveActions(
  WidgetsLocalizations labels,
  List<ChannelSection> sections,
  Set<String> collapsed,
  String channelId,
  ValueChanged<List<ChannelOrderGroup>> onReorder,
) {
  final (:up, :down) = channelMoveSteps(
    sections,
    collapsed,
    channelId,
    onReorder,
  );
  return {
    if (up != null) CustomSemanticsAction(label: labels.reorderItemUp): up,
    if (down != null)
      CustomSemanticsAction(label: labels.reorderItemDown): down,
  };
}

/// Alt+Up and Alt+Down on a focused channel row, for whoever cannot drag.
Map<ShortcutActivator, VoidCallback> channelMoveShortcuts(
  List<ChannelSection> sections,
  Set<String> collapsed,
  String channelId,
  ValueChanged<List<ChannelOrderGroup>> onReorder,
) {
  final (:up, :down) = channelMoveSteps(
    sections,
    collapsed,
    channelId,
    onReorder,
  );
  return {
    if (up != null)
      const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): up,
    if (down != null)
      const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): down,
  };
}

/// Move category up and down for a header, among its own siblings only.
Map<CustomSemanticsAction, VoidCallback> categoryMoveActions(
  CategoryTree tree,
  String categoryId,
  ValueChanged<List<CategoryOrderGroup>>? onReorder,
) {
  final up = groupsAfterSiblingStep(tree, categoryId, -1);
  final down = groupsAfterSiblingStep(tree, categoryId, 1);
  return {
    if (up != null)
      const CustomSemanticsAction(label: 'Move category up'): () =>
          onReorder?.call(up),
    if (down != null)
      const CustomSemanticsAction(label: 'Move category down'): () =>
          onReorder?.call(down),
  };
}
