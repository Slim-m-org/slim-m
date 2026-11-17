// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A category's permissions (decision 0064): the channel grid in category
/// mode, saved to the category and copied into everything synced beneath it.
/// A sub-category's sheet also says whether it follows its parent (0120).
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../settings/widgets/admin/category_sync_banner.dart';
import '../../settings/widgets/admin/channel_permissions_grid.dart';

Future<void> showCategoryPermissionsSheet(
  BuildContext context, {
  required String categoryId,
  required String categoryName,
  bool isSubCategory = false,
  bool holdsSubCategories = false,
}) => showAppSheet<void>(
  context,
  maxWidth: 960,
  builder: (context) => _CategoryPermissionsSheet(
    categoryId: categoryId,
    name: categoryName,
    isSubCategory: isSubCategory,
    holdsSubCategories: holdsSubCategories,
  ),
);

class _CategoryPermissionsSheet extends StatelessWidget {
  const _CategoryPermissionsSheet({
    required this.categoryId,
    required this.name,
    required this.isSubCategory,
    required this.holdsSubCategories,
  });

  final String categoryId;
  final String name;
  final bool isSubCategory;

  /// A top-level category on a server that nests, whose name its sub-categories' viewers see.
  final bool holdsSubCategories;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final caption = AppText.caption.copyWith(color: tokens.textSecondary);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s16,
            AppSpacing.s16,
            AppSpacing.s16,
            AppSpacing.s4,
          ),
          child: Text('$name · Permissions', style: AppText.heading),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s16,
            0,
            AppSpacing.s16,
            AppSpacing.s12,
          ),
          child: Text(
            holdsSubCategories
                ? 'Channels and sub-categories that follow this category get '
                      'these permissions. Anyone who can see a channel in one '
                      'of its sub-categories also sees its name.'
                : 'Channels that follow this category get these permissions.',
            style: caption,
          ),
        ),
        if (isSubCategory)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
            child: CategorySyncBanner.forSubCategory(categoryId: categoryId),
          ),
        ChannelPermissionsGrid.forCategory(categoryId: categoryId),
      ],
    );
  }
}
