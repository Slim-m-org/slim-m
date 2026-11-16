// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Move into...": the top-level categories a category can be filed under
/// (decision 0120), offered as a sheet rather than a long menu
/// (docs/design/desktop-vs-mobile.md rule 4).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/channel_order_controller.dart';

/// Lists [targets]; picking one files [category] at the end of its
/// sub-categories. A refusal lands in the rail's reorder error.
Future<void> showMoveCategorySheet(
  BuildContext context, {
  required ChannelCategoryRow category,
  required List<ChannelCategoryRow> targets,
}) {
  final orders = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(categoryOrderControllerProvider.notifier);
  return showAppSheet<void>(
    context,
    bare: true,
    semanticLabel: 'Move ${category.name} into',
    builder: (sheetContext) => SafeArea(
      top: false,
      child: AppSheetMenu(
        children: [
          AppMenuLabel('Move ${category.name} into'),
          for (final target in targets)
            AppMenuItem(
              label: target.name,
              leading: AppIcons.category,
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(orders.move(category.id, target.id));
              },
            ),
        ],
      ),
    ),
  );
}
