// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A category's permissions (decision 0064): the channel grid in category
/// mode, saved to the category and copied into everything synced beneath it.
/// A sub-category's sheet opens on whether it follows its parent (0120).
/// A Private switch and who can see it come first; the grid is Advanced (0125).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/admin_providers.dart';
import '../../settings/widgets/admin/channel_permissions_grid.dart';
import '../../settings/widgets/settings_disclosure.dart';
import 'category_private_section.dart';
import 'sub_category_follow_row.dart';

/// The folded row that opens the full grid.
const categoryAdvancedToggleKey = Key('category-permissions-advanced');

Future<void> showCategoryPermissionsSheet(
  BuildContext context, {
  required String categoryId,
  required String categoryName,
  String? parentName,
  bool holdsSubCategories = false,
  List<ChannelCategoryRow> subCategories = const [],
  List<Channel> channels = const [],
}) => showAppSheet<void>(
  context,
  maxWidth: 960,
  builder: (context) => _CategoryPermissionsSheet(
    categoryId: categoryId,
    name: categoryName,
    parentName: parentName,
    holdsSubCategories: holdsSubCategories,
    subCategories: subCategories,
    channels: channels,
  ),
);

class _CategoryPermissionsSheet extends ConsumerStatefulWidget {
  const _CategoryPermissionsSheet({
    required this.categoryId,
    required this.name,
    required this.parentName,
    required this.holdsSubCategories,
    required this.subCategories,
    required this.channels,
  });

  final String categoryId;
  final String name;

  /// Set for a sub-category, which may follow this parent's permissions (0120).
  final String? parentName;

  /// A top-level category on a server that nests, whose name its sub-categories' viewers see.
  final bool holdsSubCategories;

  final List<ChannelCategoryRow> subCategories;

  /// Every channel filed under it or one of its sub-categories.
  final List<Channel> channels;

  @override
  ConsumerState<_CategoryPermissionsSheet> createState() =>
      _CategoryPermissionsSheetState();
}

class _CategoryPermissionsSheetState
    extends ConsumerState<_CategoryPermissionsSheet> {
  bool _advanced = false;

  bool _followsParent() =>
      widget.parentName != null &&
      ref
              .watch(categoryOverwritesSyncedProvider(widget.categoryId))
              .valueOrNull ==
          true;

  @override
  Widget build(BuildContext context) {
    final parentName = widget.parentName;
    final follows = _followsParent();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSheetHeader(
            '${widget.name} · Permissions',
            padding: const EdgeInsets.only(bottom: AppSpacing.s16),
            caption: widget.holdsSubCategories
                ? 'Channels and sub-categories that follow this category get '
                      'these permissions. Anyone who can see a channel in one '
                      'of its sub-categories also sees its name.'
                : 'Channels that follow this category get these permissions.',
          ),
          CategoryPrivateSection(
            categoryId: widget.categoryId,
            name: widget.name,
            subCategories: widget.subCategories,
            channels: widget.channels,
            followsParent: follows,
            leading: [
              if (parentName != null)
                SubCategoryFollowRow(
                  categoryId: widget.categoryId,
                  parentName: parentName,
                ),
            ],
            trailing: [
              if (!follows)
                SettingsDisclosure(
                  title: 'Advanced',
                  summary: 'Every permission',
                  toggleKey: categoryAdvancedToggleKey,
                  initiallyExpanded: _advanced,
                  onExpandedChanged: (open) => setState(() => _advanced = open),
                  children: const [],
                ),
            ],
          ),
          if (_advanced && !follows) ...[
            const SizedBox(height: AppSpacing.s16),
            ChannelPermissionsGrid.forCategory(categoryId: widget.categoryId),
          ],
        ],
      ),
    );
  }
}
