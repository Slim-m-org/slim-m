// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail's sections: direct messages, and every channel category (plus
/// the implicit uncategorised one) grouped and reordered as one list. See
/// docs/decisions/0006-channel-categories.md.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart'
    show ChannelOrderGroup, NotificationPreference;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/category_nesting.dart';
import '../providers/channel_notification_overrides_controller.dart';
import '../providers/channel_order_controller.dart'
    show categoryOrderControllerProvider;
import '../providers/collapsed_categories_preference.dart';
import '../../members/providers/member_presence.dart' show presenceSeedProvider;
import '../../messages/providers/unread_indicator_rules.dart'
    show unreadIndicatorForChannel;
import '../../../routing/routes.dart';
import 'category_header_menu.dart';
import 'category_tree.dart';
import 'channel_grouping.dart';
import 'channel_kind_icon.dart';
import 'channel_move.dart' show groupsAfterMoveTo;
import 'move_channel_sheet.dart';
import 'channel_rail_channel_rows.dart';
import 'channel_rail_reorder.dart';
import 'channel_rail_section_label.dart';
import 'channel_rail_selection_marker.dart';
import '../../../widgets/context_menu_region.dart' show ContextMenuRegionState;
import 'dm_row.dart';
import 'rail_view.dart';
import 'new_group_dm_sheet.dart';
import '../providers/channel_latest_message_at.dart';

/// A DM is stored locally as an ordinary [Channel] under `kind == 'dm'` (see
/// `providers/dms.dart`), so this reads the same channel stream the
/// category sections do, filtered to that one kind. There is still no way to
/// start a new DM with someone else from here directly; that lives on a
/// member's row in [AppMemberPane], which is where a person already is when
/// they decide to message someone.
///
/// Notes, the DM with yourself, is the footer's button and not a row here.
/// [railDirectMessages] is shared with `orderedChannels`, so cycling matches.
class DirectMessagesSection extends ConsumerWidget {
  const DirectMessagesSection({
    super.key,
    required this.channels,
    required this.selectedId,
    required this.listed,
  });

  final List<Channel> channels;
  final String? selectedId;

  /// Whether [channels] is the server's answer yet, so an empty one may say so.
  final bool listed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Seeds every DM peer's presence dot.
    ref.watch(presenceSeedProvider(null));
    final others = railDirectMessages(channels);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(
          'Direct messages',
          trailingBuilder: (revealed, onFocusChange) => SectionAddGlyph(
            revealed: revealed,
            onFocusChange: onFocusChange,
            semanticLabel: 'New group message',
            onPressed: () => showNewGroupDmSheet(context),
          ),
        ),
        for (final channel in others)
          SelectionMarkerTarget(
            selected: channel.id == selectedId,
            child: DmRow(channel: channel, selected: channel.id == selectedId),
          ),
        if (others.isEmpty && listed)
          const _EmptyHint('No direct messages yet.', depth: 0),
      ],
    );
  }
}

/// Says a section is empty where its rows would be, so its header is not left bare.
class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text, {required this.depth});

  final String text;

  /// How many category levels in, so it lines up with that section's rows.
  final int depth;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s8 + kRailRowInset * depth,
        AppSpacing.s4,
        AppSpacing.s8,
        AppSpacing.s4,
      ),
      child: Text(
        text,
        style: AppText.caption.copyWith(color: tokens.textSecondary),
      ),
    );
  }
}

/// Every non-DM channel, grouped by category and reorderable across every
/// section in one drag - a channel of any kind may be filed under any
/// category, since a category decides placement only (see
/// docs/decisions/0006-channel-categories.md). The implicit uncategorised
/// section is labelled "Channels", the same treatment
/// [DirectMessagesSection] gives its own header (backlog item 55: a "+"
/// with no header above it read as unexplained chrome). Creating a channel
/// or a category is [SpaceMenuButton]'s job now, not a header button here;
/// every named category is exactly the ones this section's own header menu
/// (rename, move, delete) and the rail's background menu (create) manage -
/// there is no separate settings screen for them any more.
class ChannelCategorySections extends ConsumerStatefulWidget {
  const ChannelCategorySections({
    super.key,
    required this.channels,
    required this.categories,
    required this.selectedId,
    required this.onReorder,
    this.canManage = false,
  });

  final List<Channel> channels;
  final List<ChannelCategoryRow> categories;
  final String? selectedId;
  final bool canManage;

  /// Called with the whole rail's new arrangement, grouped by category, once
  /// a drag settles.
  final ValueChanged<List<ChannelOrderGroup>> onReorder;

  @override
  ConsumerState<ChannelCategorySections> createState() =>
      _ChannelCategorySectionsState();
}

class _ChannelCategorySectionsState
    extends ConsumerState<ChannelCategorySections> {
  /// Whether a channel is currently being dragged. The implicit "Channels"
  /// header is the only way to pull a channel out of every named category
  /// (removing it from the row menu was backlog item 135's own follow-up),
  /// and it is not drawn once empty - so it is drawn empty for the length of
  /// a drag, and only then. It stays a structural item at every other time
  /// too (see `header` below): `ReorderableChannelRows` cancels an
  /// in-progress drag outright the moment its item count changes, so
  /// flipping this bit must never add or remove an item, only change what
  /// one item renders as.
  bool _dragging = false;

  /// One per channel, so a lifted-and-dropped row can open its own menu.
  final _menuKeys = <String, GlobalKey<ContextMenuRegionState>>{};
  final _categoryMenuKeys = <String, GlobalKey<ContextMenuRegionState>>{};

  @override
  Widget build(BuildContext context) {
    final tree = CategoryTree(widget.categories);
    // An empty category is a drop target for a manager and a dead header for anyone else (the 2026-08-11 review's M8).
    final sections = railSections(
      widget.channels,
      tree,
      canManage: widget.canManage,
    );
    final view = RailView(
      sections: sections,
      byCategory: channelsByCategory(widget.channels),
      tree: tree,
      collapsed: ref.watch(collapsedCategoriesProvider),
      overrides: ref.watch(channelNotificationOverridesProvider),
      selectedId: widget.selectedId,
    );

    return ReorderableChannelRows(
      sections: sections,
      canManage: widget.canManage,
      onReorder: widget.onReorder,
      rowBuilder: (channel, longPressDrags) =>
          _row(view, channel, longPressDrags),
      carriedRowBuilder: (channel) => _row(view, channel, true, carried: true),
      carriedRowInset: kRailRowInset,
      headerBuilder: (category) => _header(view, category),
      carriedHeaderBuilder: (category) =>
          _header(view, category, carried: true),
      collapsed: view.collapsed,
      categoriesNest: ref.watch(categoriesNestProvider),
      headingOnly: ref.watch(headingOnlyCategoriesProvider),
      onReorderCategories: (groups) => unawaited(
        ref.read(categoryOrderControllerProvider.notifier).arrange(groups),
      ),
      onDragStart: () => setState(() => _dragging = true),
      onDragEnd: () => setState(() => _dragging = false),
      onHeldInPlace: (channel) => _menuKeys[channel.id]?.currentState?.open(),
    );
  }

  // A folded row renders zero-height rather than leaving `sections`: the reorder payload is built from exactly the items rendered, and a missing channel would be cleared from its category.
  // Every channel hangs off its header rather than sharing its left edge, which is what read as floating rows between dividers.
  Widget _row(
    RailView view,
    Channel channel,
    bool longPressDrags, {
    bool carried = false,
  }) {
    final selected = channel.id == widget.selectedId;
    if (view.rowHidden(channel)) return const SizedBox.shrink();
    Widget body(Widget? kebab) => channel.kind == 'voice'
        ? VoiceChannelRow(
            channel: channel,
            selected: selected,
            trailingExtra: kebab,
          )
        : _TextChannelRow(
            channel: channel,
            selected: selected,
            trailingExtra: kebab,
          );
    // The lifted copy is just the face of the row: no menu, kebab or hover.
    if (carried) return body(null);
    final depth =
        view.tree.depthOf(view.tree.byId[channel.categoryId]) +
        (view.nestedRoom(channel) ? 1 : 0);
    return KeepsLatestMessageLoaded(
      channelId: channel.id,
      child: Padding(
        padding: EdgeInsets.only(left: kRailRowInset * (1 + depth)),
        child: SelectionMarkerTarget(
          selected: selected,
          child: ManagedChannelRow(
            canManage: widget.canManage,
            reorderable: longPressDrags,
            menuKey: _menuKeys.putIfAbsent(
              channel.id,
              GlobalKey<ContextMenuRegionState>.new,
            ),
            moveToCategory: _moveToCategory(view, channel),
            channel: channel,
            row: body,
          ),
        ),
      ),
    );
  }

  VoidCallback? _moveToCategory(RailView view, Channel channel) {
    final movable =
        widget.canManage &&
        channel.roomLobbyId == null &&
        widget.categories.isNotEmpty;
    if (!movable) return null;
    return () => unawaited(
      showMoveChannelSheet(
        context,
        channel: channel,
        categories: widget.categories,
        onPick: (id) {
          final groups = groupsAfterMoveTo(view.sections, channel.id, id);
          if (groups != null) widget.onReorder(groups);
        },
      ),
    );
  }

  Widget _header(
    RailView view,
    ChannelCategoryRow? category, {
    bool carried = false,
  }) {
    // Structurally always an item (see _dragging's doc comment); nothing while idle and empty.
    if (category == null && view.channelsOf(null).isEmpty && !_dragging) {
      return const SizedBox.shrink();
    }
    if (category != null && !carried && view.headerHidden(category)) {
      return const SizedBox.shrink();
    }
    final place = category == null ? 'Channels' : view.tree.pathOf(category);
    final menuKey = category == null || carried
        ? null
        : _categoryMenuKeys.putIfAbsent(
            category.id,
            GlobalKey<ContextMenuRegionState>.new,
          );
    // A phone header's menu opens from the held press, as a row's does.
    final kebab = menuKey != null && !AppTouchTargets.of(context);
    // Any section, the implicit uncategorised one included: it is a real place a channel can live.
    final label = SectionLabel(
      category?.name ?? 'Channels',
      collapsed: view.folded(category),
      muted:
          category != null &&
          ref.watch(
            channelNotificationOverridesProvider.select(
              (s) => s.isCategoryMuted(category.id),
            ),
          ),
      indicator: category == null ? null : view.rollupOf(category),
      onToggle: category == null
          ? null
          : () => unawaited(
              ref
                  .read(collapsedCategoriesProvider.notifier)
                  .toggleShown(category.id, parentId: category.parentId),
            ),
      trailingBuilder: !widget.canManage && !kebab
          ? null
          : (revealed, onFocusChange) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.canManage)
                  AddChannelGlyph(
                    categoryId: category?.id,
                    categoryName: place,
                    initialKind: kindToAddIn(
                      category,
                      view.channelsOf(category),
                    ),
                    revealed: revealed && !carried,
                    onFocusChange: onFocusChange,
                  ),
                if (kebab)
                  CategoryMenuGlyph(
                    categoryName: place,
                    revealed: revealed,
                    onFocusChange: onFocusChange,
                    onPressed: () => menuKey.currentState?.open(),
                  ),
              ],
            ),
    );
    // Only a real category has a menu; the null section is the id-less implicit 'Channels' bucket.
    if (category == null || carried) return label;
    final depth = view.tree.depthOf(category);
    final header = CategoryHeaderMenu(
      category: category,
      categories: widget.categories,
      collapsed: view.collapsed,
      label: label,
      channels: view.channelsBeneath(category),
      canManage:
          widget.canManage &&
          !ref.watch(headingOnlyCategoriesProvider).contains(category.id),
      menuKey: menuKey,
    );
    final indented = depth == 0
        ? header
        : Padding(
            padding: EdgeInsets.only(left: kRailRowInset * depth),
            child: header,
          );
    // Only a manager sees an empty category; it is a place to add or drop a channel, so it says so.
    final empty =
        !view.folded(category) &&
        view.channelsBeneath(category).isEmpty &&
        view.tree.childrenOf(category.id).isEmpty;
    if (!empty) return indented;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        indented,
        // Hidden but sized during a drag, so the rows under the finger do not jump as it starts.
        Visibility(
          visible: !_dragging,
          maintainState: true,
          maintainAnimation: true,
          maintainSize: true,
          child: _EmptyHint('No channels yet.', depth: depth + 1),
        ),
      ],
    );
  }
}

class _TextChannelRow extends ConsumerWidget {
  const _TextChannelRow({
    required this.channel,
    required this.selected,
    this.trailingExtra,
  });

  final Channel channel;
  final bool selected;
  final Widget? trailingExtra;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // Read state is untouched by this; only what the row draws about it changes.
    final override = ref.watch(
      channelNotificationOverridesProvider.select(
        (s) => s.effectiveFor(channel),
      ),
    );
    final muted = override == NotificationPreference.nothing;
    final indicator = unreadIndicatorForChannel(
      channel,
      channelOverride: override,
      isDm: false,
    );
    return AppListRow(
      label: channel.name,
      selected: selected,
      unread: indicator.unread,
      mentioned: indicator.mentioned,
      muted: muted,
      leading: ChannelKindIcon(
        isVoice: false,
        restricted: channel.restricted ?? false,
        color: selected ? tokens.accent : tokens.textSecondary,
      ),
      trailing: muted
          ? Icon(
              AppIcons.notificationsOff,
              size: AppSizes.icon16,
              color: tokens.textSecondary,
            )
          : null,
      trailingExtra: trailingExtra,
      revealTrailingExtraOnHover: true,
      onTap: () => context.go(Routes.channel(channel.id)),
    );
  }
}
