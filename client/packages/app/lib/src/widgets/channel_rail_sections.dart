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

import '../providers/channel_notification_overrides_controller.dart';
import '../providers/channel_order_controller.dart'
    show categoryOrderControllerProvider;
import '../providers/collapsed_categories_preference.dart';
import '../providers/member_presence.dart' show presenceSeedProvider;
import '../providers/unread_indicator_rules.dart';
import '../routing/routes.dart';
import 'category_header_menu.dart';
import 'channel_grouping.dart';
import 'channel_kind_icon.dart';
import 'channel_move.dart';
import 'channel_rail_channel_rows.dart';
import 'channel_rail_reorder.dart';
import 'channel_rail_section_label.dart';
import 'channel_rail_selection_marker.dart';
import 'context_menu_region.dart' show ContextMenuRegionState;
import 'dm_row.dart';
import 'personal_space_row.dart';

/// A DM is stored locally as an ordinary [Channel] under `kind == 'dm'` (see
/// `providers/dms.dart`), so this reads the same channel stream the
/// category sections do, filtered to that one kind. There is still no way to
/// start a new DM with someone else from here directly; that lives on a
/// member's row in [AppMemberPane], which is where a person already is when
/// they decide to message someone.
///
/// A DM with yourself - your personal space - is the one exception: it gets
/// its own always-present [PersonalSpaceRow] rather than being something you
/// find by searching your own name in the member list. [splitPersonalSpace]
/// reads [Channel.isPersonalSpace], not [Channel.name]: another member can
/// freely set their own display name to [personalSpaceName], and their DM
/// must still render, and open, as an ordinary row rather than as this one.
/// `orderedChannels` (`channel_grouping.dart`) calls the same function, so
/// the next/previous-channel shortcuts cycle in the order shown here.
class DirectMessagesSection extends ConsumerWidget {
  const DirectMessagesSection({
    super.key,
    required this.channels,
    required this.selectedId,
  });

  final List<Channel> channels;
  final String? selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Seeds every DM peer's presence dot.
    ref.watch(presenceSeedProvider(null));
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final split = splitPersonalSpace(channels);
    final personal = split.personal;
    final others = split.others;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('Direct messages'),
        SelectionMarkerTarget(
          selected: personal != null && personal.id == selectedId,
          child: PersonalSpaceRow(
            channel: personal,
            selected: personal != null && personal.id == selectedId,
          ),
        ),
        if (others.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s8,
              vertical: AppSpacing.s4,
            ),
            child: Text(
              'Start one from the member list.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          )
        else
          for (final channel in others)
            SelectionMarkerTarget(
              selected: channel.id == selectedId,
              child: DmRow(
                channel: channel,
                selected: channel.id == selectedId,
              ),
            ),
      ],
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

  @override
  Widget build(BuildContext context) {
    final channels = widget.channels;
    final categories = widget.categories;
    final selectedId = widget.selectedId;
    final canManage = widget.canManage;
    final onReorder = widget.onReorder;
    final collapsed = ref.watch(collapsedCategoriesProvider);
    final byCategory = channelsByCategory(channels);
    final implicitEmpty = (byCategory[null] ?? const <Channel>[]).isEmpty;
    // An empty category is a drop target for a manager and a dead header for
    // anyone else; migration 0031's unconditional Text/Voice seed gives every
    // fresh deployment two of them (the 2026-08-11 review's M8). The implicit
    // section gets the same structural treatment now - see `header` for why
    // it still renders as nothing while empty and idle.
    final sections = <ChannelSection>[
      for (final section in <ChannelSection>[
        (null, byCategory[null] ?? const []),
        for (final category in categories)
          (category, byCategory[category.id] ?? const []),
      ])
        if (canManage || section.$2.isNotEmpty) section,
    ];

    // Every channel hangs off its header rather than sharing its left edge, which is what read as floating rows between dividers.
    //
    // A collapsed category's rows render as zero-height rather than being
    // left out of `sections`/`_items` entirely: `ReorderableChannelRows`
    // builds its reorder payload from exactly the items it renders, and
    // dropping a collapsed category's channels from that payload would tell
    // the server to clear its membership the next time any other channel
    // moves. Zero size keeps every channel's identity and position in the
    // list - just invisible and unreachable by a drag - while collapsed.
    final overrides = ref.watch(channelNotificationOverridesProvider);

    // Breaking out of a collapsed category is an unread indicator like any other, so it reads the same rule the rows do.
    Widget row(Channel channel, bool longPressDrags, {bool carried = false}) {
      final pinnedOpen =
          channel.id == selectedId ||
          unreadIndicatorFor(
            channelOverride: overrides.overrideFor(channel.id),
            isDm: false,
            unread: false,
            mentioned: channel.mentionedSeq > channel.lastReadSeq,
            manuallyUnread: false,
          ).mentioned;
      if (channel.categoryId != null &&
          collapsed.contains(channel.categoryId) &&
          !pinnedOpen) {
        return const SizedBox.shrink();
      }
      Widget body(Widget? kebab) => channel.kind == 'voice'
          ? VoiceChannelRow(
              channel: channel,
              selected: channel.id == selectedId,
              trailingExtra: kebab,
            )
          : _TextChannelRow(
              channel: channel,
              selected: channel.id == selectedId,
              trailingExtra: kebab,
            );
      // The lifted copy is just the face of the row: no menu, kebab or hover.
      if (carried) return body(null);
      return Padding(
        padding: const EdgeInsets.only(left: kRailRowInset),
        child: SelectionMarkerTarget(
          selected: channel.id == selectedId,
          child: ManagedChannelRow(
            canManage: canManage,
            reorderable: longPressDrags,
            menuKey: _menuKeys.putIfAbsent(
              channel.id,
              GlobalKey<ContextMenuRegionState>.new,
            ),
            move: ChannelMoveActions(
              canMove: (delta) =>
                  groupsAfterStep(
                    sections,
                    channel.id,
                    delta,
                    collapsed: collapsed,
                  ) !=
                  null,
              move: (delta) {
                final groups = groupsAfterStep(
                  sections,
                  channel.id,
                  delta,
                  collapsed: collapsed,
                );
                if (groups != null) onReorder(groups);
              },
            ),
            channel: channel,
            row: body,
          ),
        ),
      );
    }

    Widget header(ChannelCategoryRow? category, {bool carried = false}) {
      // Structurally always an item (see _dragging's doc comment); nothing while idle and empty.
      if (category == null && implicitEmpty && !_dragging) {
        return const SizedBox.shrink();
      }
      // Any section, the implicit uncategorised one included: it is a real place a channel can live.
      final label = SectionLabel(
        category?.name ?? 'Channels',
        collapsed: collapsed.contains(category?.id),
        onToggle: category == null
            ? null
            : () => unawaited(
                ref
                    .read(collapsedCategoriesProvider.notifier)
                    .toggle(category.id),
              ),
        trailingBuilder: !canManage
            ? null
            : (revealed, onFocusChange) => AddChannelGlyph(
                categoryId: category?.id,
                categoryName: category?.name ?? 'Channels',
                revealed: revealed && !carried,
                onFocusChange: onFocusChange,
              ),
      );
      // Only a real category has a menu; the null section is the id-less implicit 'Channels' bucket.
      if (category == null || carried) return label;
      return CategoryHeaderMenu(
        category: category,
        categories: categories,
        collapsed: collapsed,
        label: label,
        channels: byCategory[category.id] ?? const [],
        canManage: canManage,
      );
    }

    return ReorderableChannelRows(
      sections: sections,
      canManage: canManage,
      onReorder: onReorder,
      rowBuilder: row,
      carriedRowBuilder: (channel) => row(channel, true, carried: true),
      carriedRowInset: kRailRowInset,
      headerBuilder: header,
      carriedHeaderBuilder: (category) => header(category, carried: true),
      collapsed: collapsed,
      onReorderCategories: (ids) => unawaited(
        ref.read(categoryOrderControllerProvider.notifier).reorder(ids),
      ),
      onDragStart: () => setState(() => _dragging = true),
      onDragEnd: () => setState(() => _dragging = false),
      onHeldInPlace: (channel) => _menuKeys[channel.id]?.currentState?.open(),
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
        (s) => s.overrideFor(channel.id),
      ),
    );
    final muted = override == NotificationPreference.nothing;
    final indicator = unreadIndicatorFor(
      channelOverride: override,
      isDm: false,
      unread: channel.cursor > channel.lastReadSeq,
      mentioned: channel.mentionedSeq > channel.lastReadSeq,
      manuallyUnread: channel.manuallyUnread ?? false,
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
      onTap: () => context.go(Routes.channel(channel.id)),
    );
  }
}
