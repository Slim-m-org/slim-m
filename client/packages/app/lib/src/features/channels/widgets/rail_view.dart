// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What one build of the rail's category sections resolved once, shared by
/// its row and header builders: the tree, what is folded, and what lights.
library;

import 'package:slimm_data/data.dart';

import '../../messages/providers/unread_indicator_rules.dart';
import '../providers/channel_notification_overrides_controller.dart';
import 'category_tree.dart';
import 'channel_grouping.dart' show isRoomUnderLobby;
import 'channel_rail_reorder.dart' show ChannelSection;

class RailView {
  const RailView({
    required this.sections,
    required this.byCategory,
    required this.tree,
    required this.collapsed,
    required this.overrides,
    required this.selectedId,
  });

  final List<ChannelSection> sections;
  final Map<String?, List<Channel>> byCategory;
  final CategoryTree tree;
  final Set<String> collapsed;
  final ChannelNotificationOverridesState overrides;
  final String? selectedId;

  UnreadIndicator indicatorOf(Channel channel) => unreadIndicatorForChannel(
    channel,
    channelOverride: overrides.effectiveFor(channel),
    isDm: false,
  );

  /// A row a fold still shows: the selected one, or one that lights.
  bool surfaced(Channel channel) =>
      channel.id == selectedId || indicatorOf(channel).lit;

  /// Folded by its own header, or by its parent's.
  bool folded(ChannelCategoryRow? category) =>
      category != null &&
      (collapsed.contains(category.id) ||
          collapsed.contains(tree.parentOf(category)?.id));

  /// A folded category's row, unless it is one a notification points at.
  bool rowHidden(Channel channel) =>
      folded(tree.byId[channel.categoryId]) && !surfaced(channel);

  /// A sub-category under a folded parent keeps its heading only above a surfaced row.
  bool headerHidden(ChannelCategoryRow category) {
    final parent = tree.parentOf(category);
    if (parent == null || !collapsed.contains(parent.id)) return false;
    return !channelsOf(category).any(surfaced);
  }

  List<Channel> channelsOf(ChannelCategoryRow? category) =>
      byCategory[category?.id] ?? const [];

  /// A temporary room listed under its lobby, one step further in.
  bool nestedRoom(Channel channel) =>
      isRoomUnderLobby(channel, byCategory[channel.categoryId] ?? const []);

  /// A category's own channels and every one of its sub-categories'.
  List<Channel> channelsBeneath(ChannelCategoryRow category) => [
    ...channelsOf(category),
    for (final sub in tree.childrenOf(category.id)) ...channelsOf(sub),
  ];

  /// What a folded header shows for the rows it hides, sub-categories
  /// included; a mention outranks plain unread. Null while it is open.
  UnreadIndicator? rollupOf(ChannelCategoryRow category) {
    if (!collapsed.contains(category.id)) return null;
    final all = channelsBeneath(category).map(indicatorOf);
    return (
      unread: all.any((i) => i.unread),
      mentioned: all.any((i) => i.mentioned),
    );
  }
}

extension RailIndicatorLit on UnreadIndicator {
  bool get lit => unread || mentioned;
}
