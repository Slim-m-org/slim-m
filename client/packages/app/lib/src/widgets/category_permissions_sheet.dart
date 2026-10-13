// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A category's permissions (decision 0064): the channel grid in category
/// mode, saved to the category and copied into every channel synced to it.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../screens/admin/channel_permissions_grid.dart';

Future<void> showCategoryPermissionsSheet(
  BuildContext context, {
  required String categoryId,
  required String categoryName,
}) => showAppSheet<void>(
  context,
  maxWidth: 960,
  builder: (context) =>
      CategoryPermissionsSheet(categoryId: categoryId, name: categoryName),
);

class CategoryPermissionsSheet extends StatelessWidget {
  const CategoryPermissionsSheet({
    super.key,
    required this.categoryId,
    required this.name,
  });

  final String categoryId;
  final String name;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
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
            'Channels that follow this category get these permissions.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ),
        ChannelPermissionsGrid.forCategory(categoryId: categoryId),
      ],
    );
  }
}
