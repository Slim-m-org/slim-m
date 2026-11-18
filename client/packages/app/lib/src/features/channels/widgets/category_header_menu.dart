// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A category header's own context menu (mark all read for anyone; rename,
/// nest, move, collapse, delete for a manager), split out of `channel_rail_sections.dart` for the review budget. The null,
/// id-less implicit "Channels" section never reaches this: it has nothing
/// here to manage.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../permissions.dart';
import '../../../providers/admin_providers.dart';
import '../providers/channel_notification_overrides_controller.dart';
import '../providers/category_nesting.dart';
import '../providers/channel_order_controller.dart';
import '../providers/collapsed_categories_preference.dart';
import 'category_permissions_sheet.dart';
import 'category_tree.dart';
import 'create_category_sheet.dart';
import '../../../widgets/context_menu_region.dart';
import 'manage_category_sheet.dart';
import 'move_category_sheet.dart';
import 'rail_category_slots.dart';
import '../../messages/widgets/mark_read_action.dart';
import 'row_menu_notifications.dart';

class CategoryHeaderMenu extends ConsumerStatefulWidget {
  const CategoryHeaderMenu({
    super.key,
    required this.category,
    required this.categories,
    required this.collapsed,
    required this.label,
    this.channels = const [],
    this.canManage = true,
    this.menuKey,
  });

  /// Lets the header's kebab open this menu, as a channel row's does.
  final GlobalKey<ContextMenuRegionState>? menuKey;

  final ChannelCategoryRow category;

  /// Every real category, in the order the rail currently shows them - the
  /// full list [moveCategoryAndReport] and the drag target both need to
  /// compute a new arrangement, not just this one row.
  final List<ChannelCategoryRow> categories;
  final Set<String> collapsed;
  final Widget label;

  /// The channels filed under [category] and its sub-categories, for "Mark all as read".
  final List<Channel> channels;

  /// Whether the caller may rename, move, collapse and delete; without it
  /// the menu offers only "Mark all as read", and nothing when there is none.
  final bool canManage;

  @override
  ConsumerState<CategoryHeaderMenu> createState() => _CategoryHeaderMenuState();
}

class _CategoryHeaderMenuState extends ConsumerState<CategoryHeaderMenu> {
  // The fold button is the header's tab stop; this node only carries the menu key and the semantics boundary.
  final _menuFocus = FocusNode(skipTraversal: true);

  ChannelCategoryRow get category => widget.category;
  List<ChannelCategoryRow> get categories => widget.categories;
  Set<String> get collapsed => widget.collapsed;
  Widget get label => widget.label;
  List<Channel> get channels => widget.channels;
  bool get canManage => widget.canManage;

  @override
  void dispose() {
    _menuFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final overrides = ref.watch(channelNotificationOverridesProvider);
    final hasUnread = channels.any(
      (c) => channelShowsUnread(c, overrides.effectiveFor(c), isDm: false),
    );
    if (!canManage && !hasUnread) return label;
    final menu = ContextMenuRegion(
      key: widget.menuKey,
      // A held press lifts the header on a pointer; touch opens this menu from it instead.
      enableLongPress: AppTouchTargets.of(context),
      focusNode: _menuFocus,
      itemsBuilder: (context, close) => [
        ?markAllReadMenuItem(
          context,
          ProviderScope.containerOf(context, listen: false),
          channels,
          close,
        ),
        if (canManage && hasUnread) const AppMenuDivider(),
        if (canManage) ..._manageItems(context, ref, close),
      ],
      child: label,
    );
    return menu;
  }

  // Both verbs directly: deleting used to be a menu, a sheet, a danger zone and a confirmation.
  List<Widget> _manageItems(
    BuildContext context,
    WidgetRef ref,
    VoidCallback close,
  ) {
    final tree = CategoryTree(categories);
    final nests = ref.watch(categoriesNestProvider);
    final parent = tree.parentOf(category);
    final subs = tree.childrenOf(category.id);
    final targets = [
      for (final top in tree.topLevel)
        if (top.id != category.id &&
            top.id != parent?.id &&
            top.parentId == null)
          top,
    ];
    final isCollapsed =
        collapsed.contains(category.id) || collapsed.contains(parent?.id);
    void then(VoidCallback action) {
      close();
      action();
    }

    return [
      AppMenuItem(
        label: 'Rename category...',
        leading: AppIcons.edit,
        onTap: () => then(() => showRenameCategorySheet(context, category)),
      ),
      if (nests && parent == null)
        AppMenuItem(
          label: 'Create sub-category...',
          leading: AppIcons.addCategory,
          onTap: () => then(
            () => unawaited(
              showCreateCategorySheet(context, parentId: category.id),
            ),
          ),
        ),
      if (groupsAfterSiblingStep(tree, category.id, -1) != null)
        _moveItem(context, close, up: true),
      if (groupsAfterSiblingStep(tree, category.id, 1) != null)
        _moveItem(context, close, up: false),
      if (nests && subs.isEmpty && targets.isNotEmpty)
        AppMenuItem(
          label: 'Move into...',
          leading: AppIcons.moveIntoCategory,
          onTap: () => then(
            () => unawaited(
              showMoveCategorySheet(
                context,
                category: category,
                targets: targets,
              ),
            ),
          ),
        ),
      if (nests && parent != null)
        AppMenuItem(
          label: 'Move out of ${parent.name}',
          leading: AppIcons.moveOutOfCategory,
          onTap: () => then(
            () => unawaited(
              ref
                  .read(categoryOrderControllerProvider.notifier)
                  .move(category.id, null),
            ),
          ),
        ),
      AppMenuItem(
        label: isCollapsed ? 'Expand category' : 'Collapse category',
        leading: isCollapsed ? AppIcons.unfold : AppIcons.fold,
        onTap: () => then(
          () => unawaited(
            ref
                .read(collapsedCategoriesProvider.notifier)
                .toggleShown(category.id, parentId: parent?.id),
          ),
        ),
      ),
      if (ref.watch(myPermissionsProvider).hasPermission(Perm.manageRoles))
        AppMenuItem(
          label: 'Permissions...',
          leading: AppIcons.permissions,
          onTap: () => then(
            () => unawaited(
              showCategoryPermissionsSheet(
                context,
                categoryId: category.id,
                categoryName: tree.pathOf(category),
                parentName: parent?.name,
                holdsSubCategories: nests && parent == null,
                subCategories: subs,
                channels: channels,
              ),
            ),
          ),
        ),
      AppMenuItem(
        label: 'Delete category...',
        leading: AppIcons.delete,
        tone: AppMenuItemTone.danger,
        onTap: () => then(
          () => unawaited(
            confirmAndDeleteCategory(
              context,
              ref,
              category,
              parentName: parent?.name,
              hasSubCategories: subs.isNotEmpty,
            ),
          ),
        ),
      ),
    ];
  }

  Widget _moveItem(
    BuildContext context,
    VoidCallback close, {
    required bool up,
  }) => AppMenuItem(
    label: up ? 'Move category up' : 'Move category down',
    leading: up ? AppIcons.moveUp : AppIcons.moveDown,
    onTap: () {
      close();
      unawaited(
        moveCategoryAndReport(context, categories, category, up ? -1 : 1),
      );
    },
  );
}
