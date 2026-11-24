// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Renaming a category, and the confirm-then-delete the header's context menu
/// runs directly; the sheet is rename only, so delete has one entry point.
/// `PATCH`/`DELETE /categories/{id}` ([api.SlimmApiChannelAdmin]).
///
/// The counterpart to `manage_channel_sheet.dart` for a category, which has
/// only a name - no topic and no last-channel guard - so this is the same
/// shape with the middle taken out. Deleting a category never deletes what is
/// in it; everything moves up one level (decision 0120), which the
/// confirmation says so a manager is not left guessing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../entity_name.dart';
import '../providers/channel_order_controller.dart';
import '../../../widgets/menu_outcome.dart';
import '../../../widgets/confirm_dialog.dart';
import '../../../widgets/name_sheet.dart';
import '../../../widgets/run_guarded.dart';
import '../providers/channel_actions.dart';
import 'category_tree.dart';
import 'rail_category_slots.dart';

const _deleteCategoryAction = 'delete the category';

/// The one confirmation for deleting a category, asked the same way wherever
/// the delete was started from.
///
/// The point it has to make is that the contents survive, and where they go:
/// a manager who thinks a delete takes the rooms with it will not press it.
Future<bool> confirmCategoryDeletion(
  BuildContext context,
  ChannelCategoryRow category, {
  String? parentName,
  bool hasSubCategories = false,
}) => confirmDangerousAction(
  context,
  title: 'Delete "${category.name}"?',
  message:
      '${_whereContentsGo(parentName, hasSubCategories)} '
      'This cannot be undone.',
  confirmLabel: 'Delete',
  cancelLabel: 'Keep category',
);

String _whereContentsGo(String? parentName, bool hasSubCategories) {
  if (parentName != null) {
    return 'Its channels are never deleted with it - they move up into '
        '"$parentName".';
  }
  if (hasSubCategories) {
    return 'Its channels are never deleted with it - they fall back to '
        'uncategorised, and its sub-categories become categories of their own.';
  }
  return 'Its channels are never deleted with it - they fall back to '
      'uncategorised.';
}

/// Deletes [category] and drops it from the local store.
///
/// The store write is not a cache nicety: the rail reads categories from
/// drift, so leaving the row behind would keep the header on screen until the
/// next sync told it otherwise.
Future<void> deleteCategoryAndForget(
  ChannelActions actions,
  ChannelCategoryRow category,
) => actions.deleteCategory(category);

/// Confirms, then deletes, without opening the sheet on the way.
///
/// This is the header context menu's own path. It reports a failure through
/// [runGuarded]'s sentence rather than an inline [AppErrorState], because a
/// menu has already closed by the time the request answers and has nowhere to
/// put one - the case `run_guarded.dart` documents as the one a SnackBar is
/// actually for.
Future<void> confirmAndDeleteCategory(
  BuildContext context,
  WidgetRef ref,
  ChannelCategoryRow category, {
  String? parentName,
  bool hasSubCategories = false,
}) async {
  final actions = ref.read(channelActionsProvider);
  final confirmed = await confirmCategoryDeletion(
    context,
    category,
    parentName: parentName,
    hasSubCategories: hasSubCategories,
  );
  if (!confirmed) return;
  final failure = await runGuarded(
    whatFailed: _deleteCategoryAction,
    action: () => deleteCategoryAndForget(actions, category),
  );
  if (failure != null && context.mounted) showMenuFailure(context, failure);
}

/// Moves [category] one place among its siblings by [delta] (-1 up, 1 down),
/// the header menu's own reorder path, as one whole arrangement.
///
/// A refusal stays in [categoryOrderControllerProvider], which the rail
/// shows inline with a retry; the menu has already closed by then.
Future<void> moveCategoryAndReport(
  BuildContext context,
  List<ChannelCategoryRow> categories,
  ChannelCategoryRow category,
  int delta,
) async {
  final groups = groupsAfterSiblingStep(
    CategoryTree(categories),
    category.id,
    delta,
  );
  if (groups == null) return;
  await ProviderScope.containerOf(
    context,
    listen: false,
  ).read(categoryOrderControllerProvider.notifier).arrange(groups);
}

Future<void> showRenameCategorySheet(
  BuildContext context,
  ChannelCategoryRow category,
) => showNameSheet(
  context,
  title: 'Rename category',
  fieldLabel: 'Category name',
  placeholder: 'Category name',
  initial: category.name,
  maxChars: entityNameMaxChars,
  whatFailed: 'rename the category',
  onSave: (container, name) =>
      container.read(channelActionsProvider).renameCategory(category.id, name),
);
