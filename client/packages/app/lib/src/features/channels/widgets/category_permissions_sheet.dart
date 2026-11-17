// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A category's permissions (decision 0064): the channel grid in category
/// mode, saved to the category and copied into everything synced beneath it.
/// A sub-category's sheet also says whether it follows its parent (0120).
/// A Private switch and who can see it come first; the grid is Advanced (0124).
library;

import 'package:flutter/material.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../settings/widgets/admin/category_sync_banner.dart';
import '../../settings/widgets/admin/channel_permissions_grid.dart';
import '../../settings/widgets/settings_disclosure.dart';
import 'category_private_section.dart';

/// The folded row that opens the full grid.
const categoryAdvancedToggleKey = Key('category-permissions-advanced');

Future<void> showCategoryPermissionsSheet(
  BuildContext context, {
  required String categoryId,
  required String categoryName,
  bool isSubCategory = false,
  bool holdsSubCategories = false,
  List<ChannelCategoryRow> subCategories = const [],
  List<Channel> channels = const [],
}) => showAppSheet<void>(
  context,
  maxWidth: 960,
  builder: (context) => _CategoryPermissionsSheet(
    categoryId: categoryId,
    name: categoryName,
    isSubCategory: isSubCategory,
    holdsSubCategories: holdsSubCategories,
    subCategories: subCategories,
    channels: channels,
  ),
);

class _CategoryPermissionsSheet extends StatelessWidget {
  const _CategoryPermissionsSheet({
    required this.categoryId,
    required this.name,
    required this.isSubCategory,
    required this.holdsSubCategories,
    required this.subCategories,
    required this.channels,
  });

  final String categoryId;
  final String name;
  final bool isSubCategory;

  /// A top-level category on a server that nests, whose name its sub-categories' viewers see.
  final bool holdsSubCategories;

  final List<ChannelCategoryRow> subCategories;

  /// Every channel filed under it or one of its sub-categories.
  final List<Channel> channels;

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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
          child: CategoryPrivateSection(
            categoryId: categoryId,
            name: name,
            subCategories: subCategories,
            channels: channels,
          ),
        ),
        const SizedBox(height: AppSpacing.s12),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s16,
            0,
            AppSpacing.s16,
            AppSpacing.s16,
          ),
          child: SettingsDisclosure(
            title: 'Advanced',
            summary: 'Every permission',
            toggleKey: categoryAdvancedToggleKey,
            children: [
              ChannelPermissionsGrid.forCategory(categoryId: categoryId),
            ],
          ),
        ),
      ],
    );
  }
}
