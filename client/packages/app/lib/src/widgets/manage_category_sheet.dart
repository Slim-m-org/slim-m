// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Renaming and deleting a category: the sheet the header's context menu
/// opens for a rename, and the confirm-then-delete the same menu runs directly.
/// `PATCH`/`DELETE /categories/{id}` ([api.SlimmApiChannelAdmin]).
///
/// The counterpart to `manage_channel_sheet.dart` for a category, which has
/// only a name - no topic and no last-channel guard - so this is the same
/// shape with the middle taken out. Deleting a category never deletes its
/// channels; they fall back to uncategorised, which the confirmation says so a
/// manager is not left guessing whether a delete takes the rooms with it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../char_count.dart';
import '../api_failure.dart';
import '../providers/channel_order_controller.dart';
import '../providers/providers.dart';
import 'app_snackbar.dart';
import 'confirm_dialog.dart';
import 'run_guarded.dart';

/// The one confirmation for deleting a category, asked the same way wherever
/// the delete was started from.
///
/// Shared rather than written twice: the sheet's danger zone and the header's
/// own context menu both reach the same irreversible act, and a warning that
/// said something different depending on which route you took would be worse
/// than either wording alone. The point it has to make is that the channels
/// survive - a manager who thinks a delete takes the rooms with it will not
/// press the button.
Future<bool> confirmCategoryDeletion(
  BuildContext context,
  ChannelCategoryRow category,
) => confirmDangerousAction(
  context,
  title: 'Delete "${category.name}"?',
  message:
      'Its channels are never deleted with it - they fall back to '
      'uncategorised. This cannot be undone.',
  confirmLabel: 'Delete',
  cancelLabel: 'Keep category',
);

/// Deletes [category] and drops it from the local store.
///
/// The store write is not a cache nicety: the rail reads categories from
/// drift, so leaving the row behind would keep the header on screen until the
/// next sync told it otherwise.
Future<void> deleteCategoryAndForget(
  WidgetRef ref,
  ChannelCategoryRow category,
) async {
  await ref.read(apiProvider).deleteCategory(category.id);
  final store = await ref.read(storeProvider.future);
  await store.removeCategory(category.id);
}

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
  ChannelCategoryRow category,
) async {
  if (!await confirmCategoryDeletion(context, category)) return;
  final failure = await runGuarded(
    whatFailed: 'delete the category',
    action: () => deleteCategoryAndForget(ref, category),
  );
  if (failure != null && context.mounted) showAppSnackbar(context, failure);
}

/// Swaps [category] with its neighbour [delta] steps away (-1 up, 1 down) in
/// [ordered], the rail header menu's own reorder path. Not a drag: a category
/// header dragged through the rail's flat, single-list channel rows would
/// risk silently reassigning the channels it passed over on the way, since
/// that list attributes every channel to whichever header precedes it. A
/// menu step can only ever mean "these two categories, swapped."
///
/// Reports a failure the same way [confirmAndDeleteCategory] does: the menu
/// has already closed by the time the request answers, so a snackbar carries
/// it rather than an inline [AppErrorState] with nowhere left to sit.
Future<void> moveCategoryAndReport(
  BuildContext context,
  WidgetRef ref,
  List<ChannelCategoryRow> ordered,
  ChannelCategoryRow category,
  int delta,
) async {
  final index = ordered.indexWhere((c) => c.id == category.id);
  final target = index + delta;
  if (index < 0 || target < 0 || target >= ordered.length) return;

  final ids = [for (final c in ordered) c.id];
  ids.insert(target, ids.removeAt(index));
  final controller = ref.read(categoryOrderControllerProvider.notifier);
  await controller.reorder(ids);

  final error = ref.read(categoryOrderControllerProvider).error;
  if (error == null) return;
  controller.dismiss();
  if (context.mounted) showAppSnackbar(context, error);
}

/// The server's own ceiling (`CATEGORY_NAME_MAX_CHARS` in
/// `crates/slimm-server/src/http/categories.rs`), so the check here never
/// disagrees with the one the request is judged against.
const int _nameMaxChars = 64;

Future<void> showManageCategorySheet(
  BuildContext context,
  ChannelCategoryRow category,
) {
  return showAppSheet<void>(
    context,
    builder: (context) => _ManageCategorySheet(category: category),
  );
}

class _ManageCategorySheet extends ConsumerStatefulWidget {
  const _ManageCategorySheet({required this.category});

  final ChannelCategoryRow category;

  @override
  ConsumerState<_ManageCategorySheet> createState() =>
      _ManageCategorySheetState();
}

class _ManageCategorySheetState extends ConsumerState<_ManageCategorySheet> {
  late final _name = TextEditingController(text: widget.category.name);
  bool _saving = false;
  bool _deleting = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _dirty => _name.text.trim() != widget.category.name;

  bool get _nameValid =>
      _name.text.trim().isNotEmpty &&
      trimmedCharCount(_name.text) <= _nameMaxChars;

  bool get _canSave => !_saving && !_deleting && _dirty && _nameValid;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final updated = await ref
          .read(apiProvider)
          .updateCategory(
            categoryId: widget.category.id,
            name: _name.text.trim(),
          );
      final store = await ref.read(storeProvider.future);
      await store.upsertCategory(updated);
      if (mounted) Navigator.of(context).pop();
    } on api.ApiException catch (e) {
      if (mounted) {
        setState(() => _error = describeApiFailure('rename the category', e));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await confirmCategoryDeletion(context, widget.category);
    if (confirmed) await _delete();
  }

  Future<void> _delete() async {
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      await deleteCategoryAndForget(ref, widget.category);
      if (mounted) Navigator.of(context).pop();
    } on api.ApiException catch (e) {
      if (mounted) {
        setState(() => _error = describeApiFailure('delete the category', e));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        MediaQuery.viewInsetsOf(context).bottom + AppSpacing.s16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Manage category',
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s12),
            AppInput(
              controller: _name,
              placeholder: 'Category name',
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _canSave ? _save() : null,
              semanticLabel: 'Category name',
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.s8),
              AppErrorState(message: _error!),
            ],
            const SizedBox(height: AppSpacing.s12),
            AppButton(
              label: _saving ? 'Saving...' : 'Save changes',
              variant: AppButtonVariant.primary,
              full: true,
              disabled: !_canSave,
              onPressed: _save,
            ),
            const SizedBox(height: AppSpacing.s20),
            Container(height: 1, color: tokens.borderSubtle),
            const SizedBox(height: AppSpacing.s12),
            Text(
              'DANGER ZONE',
              style: AppText.label.copyWith(color: tokens.dangerText),
            ),
            const SizedBox(height: AppSpacing.s8),
            AppButton(
              label: _deleting ? 'Deleting...' : 'Delete category',
              variant: AppButtonVariant.danger,
              full: true,
              disabled: _saving || _deleting,
              onPressed: _confirmDelete,
            ),
          ],
        ),
      ),
    );
  }
}
