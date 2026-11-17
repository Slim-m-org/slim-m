// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Move to category...": every category a channel can be filed under, and
/// "No category", as a sheet rather than a long menu
/// (docs/design/desktop-vs-mobile.md rule 4).
library;

import 'package:flutter/material.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'category_tree.dart';

/// Lists [categories] with [channel]'s own marked; picking one calls [onPick]
/// with its id, or null for uncategorised.
Future<void> showMoveChannelSheet(
  BuildContext context, {
  required Channel channel,
  required List<ChannelCategoryRow> categories,
  required ValueChanged<String?> onPick,
}) {
  final paths = categoryPaths(categories);
  return showAppSheet<void>(
    context,
    bare: true,
    semanticLabel: 'Move ${channel.name} to',
    builder: (sheetContext) {
      void pick(String? id) {
        Navigator.of(sheetContext).pop();
        onPick(id);
      }

      return SafeArea(
        top: false,
        child: AppSheetMenu(
          children: [
            AppMenuLabel('Move ${channel.name} to'),
            AppMenuItem(
              label: 'No category',
              leading: AppIcons.hash,
              selected: channel.categoryId == null,
              onTap: () => pick(null),
            ),
            for (final entry in paths.entries)
              AppMenuItem(
                label: entry.value,
                leading: AppIcons.category,
                selected: channel.categoryId == entry.key,
                onTap: () => pick(entry.key),
              ),
          ],
        ),
      );
    },
  );
}
