// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The status editor reached by tapping your own avatar in the sidebar
/// (`presence_menu.dart`'s `PresenceMenuButton`, backlog item 128): the same
/// free-text status line `status_text_row.dart`'s personal-settings row
/// edits, offered from where a person actually looks to change how they
/// present rather than only from Settings. `PATCH /me` (`SlimmApi.updateMe`).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Unprefixed extension methods need the declaring library imported - see api.dart's own `show` list comment.
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/member_presence.dart' show memberProfileOverridesProvider;
import '../providers/providers.dart';
import 'run_guarded.dart';
import 'status_text_row.dart' show statusTextLength, statusTextMaxChars;

/// Opens the sheet seeded with [current] (the caller's status as of the tap
/// that opened it); `showAppSheet` decides bottom sheet versus dialog.
Future<void> showStatusEditorSheet(BuildContext context, String current) {
  return showAppSheet<void>(
    context,
    builder: (context) => _StatusEditorSheet(current: current),
  );
}

class _StatusEditorSheet extends ConsumerStatefulWidget {
  const _StatusEditorSheet({required this.current});

  /// What the server held when the sheet was opened, trimmed. Seeds the
  /// field's controller once, at construction, the same one-shot seeding
  /// `edit_display_name_sheet.dart` uses for the same reason: nothing here
  /// needs to react to a value changing out from under an edit in progress,
  /// since the sheet closes on its own success.
  final String current;

  @override
  ConsumerState<_StatusEditorSheet> createState() => _StatusEditorSheetState();
}

class _StatusEditorSheetState extends ConsumerState<_StatusEditorSheet>
    with GuardedActionState<_StatusEditorSheet> {
  late final _controller = TextEditingController(text: widget.current);
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _dirty => _controller.text.trim() != widget.current;
  bool get _valid => statusTextLength(_controller.text) <= statusTextMaxChars;
  bool get _canSave => !_saving && _dirty && _valid;
  bool get _canClear =>
      !_saving &&
      (_controller.text.trim().isNotEmpty || widget.current.isNotEmpty);

  /// Applies [text] and pops the sheet on success; a refusal leaves it open
  /// with [actionError] rendered inline, the same as every other guarded
  /// write in this app, rather than closing over a change that never landed.
  Future<void> _apply(String text) async {
    setState(() => _saving = true);
    final ok = await guard(
      whatFailed: 'update your status',
      action: () async {
        final profile = await ref.read(apiProvider).updateMe(statusText: text);
        ref.invalidate(meProvider);
        ref.read(memberProfileOverridesProvider.notifier).applyKnown(profile);
      },
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop();
  }

  Future<void> _save() => _apply(_controller.text.trim());

  Future<void> _clear() {
    _controller.clear();
    return _apply('');
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final length = statusTextLength(_controller.text);

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
              'Set a status',
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s12),
            AppInput(
              controller: _controller,
              placeholder: 'What are you up to?',
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_canSave) unawaited(_save());
              },
              semanticLabel: 'Status text',
            ),
            const SizedBox(height: AppSpacing.s4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '$length/$statusTextMaxChars',
                style: AppText.micro.copyWith(
                  color: length > statusTextMaxChars
                      ? tokens.dangerText
                      : tokens.textSecondary,
                ),
              ),
            ),
            if (actionError != null) ...[
              const SizedBox(height: AppSpacing.s8),
              AppErrorState(message: actionError!, onDismiss: clearActionError),
            ],
            const SizedBox(height: AppSpacing.s12),
            Row(
              children: [
                Expanded(
                  child: AppButton(
                    label: 'Clear',
                    variant: AppButtonVariant.ghost,
                    disabled: !_canClear,
                    onPressed: _clear,
                  ),
                ),
                const SizedBox(width: AppSpacing.s8),
                Expanded(
                  child: AppButton(
                    label: _saving ? 'Saving...' : 'Save',
                    variant: AppButtonVariant.primary,
                    disabled: !_canSave,
                    onPressed: _save,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
