// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet for making a channel category: a name, sent through
/// `POST /categories` ([api.SlimmApi.createCategory]).
///
/// Opened from the rail's own right-click menu, beside "Create channel...".
/// Until this existed a category could only be made from Space settings ->
/// Channel categories, which the owner reported as right-clicking the rail
/// and finding only a channel on offer. `create_channel_sheet.dart` is the
/// shape this mirrors; the admin screen keeps its inline form for the
/// manage-many case.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../char_count.dart';
import '../api_failure.dart';
import '../ids.dart';
import '../providers/providers.dart';

/// The server's own ceiling (`validate_category_name` in
/// `crates/slimm-server/src/http/categories.rs`), refused here rather than
/// round-tripping first.
const int _nameMaxChars = 64;

Future<void> showCreateCategorySheet(BuildContext context) {
  return showAppSheet<void>(
    context,
    builder: (context) => const _CreateCategorySheet(),
  );
}

class _CreateCategorySheet extends ConsumerStatefulWidget {
  const _CreateCategorySheet();

  @override
  ConsumerState<_CreateCategorySheet> createState() =>
      _CreateCategorySheetState();
}

class _CreateCategorySheetState extends ConsumerState<_CreateCategorySheet> {
  final _name = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _nameValid =>
      _name.text.trim().isNotEmpty &&
      trimmedCharCount(_name.text) <= _nameMaxChars;

  bool get _canSubmit => !_submitting && _nameValid;

  /// Names what is missing rather than sitting disabled with no explanation,
  /// the same treatment the channel sheet's button gives.
  String get _buttonLabel {
    if (_submitting) return 'Creating...';
    if (_name.text.trim().isEmpty) return 'Add a category name';
    if (!_nameValid) return 'Name is too long';
    return 'Create category';
  }

  final _createId = newCategoryId();

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final created = await ref
          .read(apiProvider)
          .createCategory(_name.text.trim(), id: _createId);
      final store = await ref.read(storeProvider.future);
      await store.upsertCategory(created);
      if (!mounted) return;
      Navigator.of(context).pop();
    } on api.ApiException catch (e) {
      if (mounted) {
        setState(() => _error = describeApiFailure('create the category', e));
      }
    } finally {
      // Any escape, not just ApiException, must not wedge "Creating..." on.
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final nameLength = trimmedCharCount(_name.text);

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
              'Create a category',
              style: AppText.heading.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s16),
            AppInput(
              controller: _name,
              placeholder: 'Category name',
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_canSubmit) _submit();
              },
              semanticLabel: 'Category name',
            ),
            const SizedBox(height: AppSpacing.s4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '$nameLength/$_nameMaxChars',
                style: AppText.micro.copyWith(
                  color: nameLength > _nameMaxChars
                      ? tokens.dangerText
                      : tokens.textSecondary,
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.s8),
              AppErrorState(message: _error!),
            ],
            const SizedBox(height: AppSpacing.s12),
            AppButton(
              label: _buttonLabel,
              variant: AppButtonVariant.primary,
              full: true,
              disabled: !_canSubmit,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
