// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A category header's own context menu (mark all read for anyone; rename,
/// move, collapse, delete for a manager), split out of `channel_rail_sections.dart` for the review budget. The null,
/// id-less implicit "Channels" section never reaches this: it has nothing
/// here to manage.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/channel_notification_overrides_controller.dart';
import '../providers/collapsed_categories_preference.dart';
import 'context_menu_region.dart';
import 'manage_category_sheet.dart';
import 'mark_read_action.dart';
import 'row_menu_notifications.dart';

class CategoryHeaderMenu extends ConsumerWidget {
  const CategoryHeaderMenu({
    super.key,
    required this.category,
    required this.categories,
    required this.collapsed,
    required this.label,
    this.channels = const [],
    this.canManage = true,
  });

  final ChannelCategoryRow category;

  /// Every real category, in the order the rail currently shows them - the
  /// full list [moveCategoryAndReport] and the drag target both need to
  /// compute a new arrangement, not just this one row.
  final List<ChannelCategoryRow> categories;
  final Set<String> collapsed;
  final Widget label;

  /// The channels filed under [category], for "Mark all as read".
  final List<Channel> channels;

  /// Whether the caller may rename, move, collapse and delete; without it
  /// the menu offers only "Mark all as read", and nothing when there is none.
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overrides = ref.watch(channelNotificationOverridesProvider);
    final hasUnread = channels.any(
      (c) => channelShowsUnread(c, overrides.overrideFor(c.id), isDm: false),
    );
    if (!canManage && !hasUnread) return label;
    final categoryIndex = categories.indexWhere((c) => c.id == category.id);
    final isCollapsed = collapsed.contains(category.id);
    // Both verbs directly: deleting used to be a menu, a sheet, a danger zone and a confirmation.
    final menu = ContextMenuRegion(
      // A held press lifts the header on a pointer; touch opens this menu from it instead.
      enableLongPress: AppTouchTargets.of(context),
      itemsBuilder: (context, close) => [
        ?markAllReadMenuItem(
          context,
          ProviderScope.containerOf(context, listen: false),
          channels,
          close,
        ),
        if (canManage && hasUnread) const AppMenuDivider(),
        if (canManage) ...[
          AppMenuItem(
            label: 'Rename category...',
            leading: AppIcons.edit,
            onTap: () {
              close();
              showManageCategorySheet(context, category);
            },
          ),
          if (categoryIndex > 0)
            AppMenuItem(
              label: 'Move category up',
              leading: AppIcons.moveUp,
              onTap: () {
                close();
                unawaited(
                  moveCategoryAndReport(context, ref, categories, category, -1),
                );
              },
            ),
          if (categoryIndex >= 0 && categoryIndex < categories.length - 1)
            AppMenuItem(
              label: 'Move category down',
              leading: AppIcons.moveDown,
              onTap: () {
                close();
                unawaited(
                  moveCategoryAndReport(context, ref, categories, category, 1),
                );
              },
            ),
          AppMenuItem(
            label: isCollapsed ? 'Expand category' : 'Collapse category',
            leading: isCollapsed ? AppIcons.unfold : AppIcons.fold,
            onTap: () {
              close();
              unawaited(
                ref
                    .read(collapsedCategoriesProvider.notifier)
                    .toggle(category.id),
              );
            },
          ),
          AppMenuItem(
            label: 'Delete category...',
            leading: AppIcons.delete,
            tone: AppMenuItemTone.danger,
            onTap: () {
              close();
              unawaited(confirmAndDeleteCategory(context, ref, category));
            },
          ),
        ],
      ],
      child: label,
    );
    return menu;
  }
}
