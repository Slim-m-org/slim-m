// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The note tool's own sheet: where a new note's text is typed, with the same
/// input features the message composer has.
///
/// Nothing is sent until this sheet's own submit, so there is nothing for
/// another participant to see somebody "typing into". A placed note is edited
/// in place instead (`CanvasNoteEditor`).
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../widgets/canvas_note_field.dart';

export '../widgets/canvas_note_limits.dart'
    show maxNoteTextBytes, noteWireBytes;

/// Opens the note sheet and answers with the entered text, or null if the
/// person cancelled without typing anything worth keeping.
Future<String?> showCanvasNoteSheet(BuildContext context) {
  return showAppSheet<String?>(
    context,
    builder: (context) => const _CanvasNoteSheet(),
  );
}

class _CanvasNoteSheet extends StatefulWidget {
  const _CanvasNoteSheet();

  @override
  State<_CanvasNoteSheet> createState() => _CanvasNoteSheetState();
}

class _CanvasNoteSheetState extends State<_CanvasNoteSheet> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    // Asked for, not autofocus alone: the sheet's route can still be settling when this builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  bool get _canSubmit => _text.text.trim().isNotEmpty;

  void _submit() {
    if (!_canSubmit) return;
    Navigator.of(context).pop(_text.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Add a note',
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s12),
          Container(
            decoration: BoxDecoration(
              color: tokens.surfaceBase,
              border: Border.all(color: tokens.borderSubtle),
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s12,
              vertical: AppSpacing.s8,
            ),
            child: CanvasNoteField(
              controller: _text,
              focusNode: _focus,
              onSave: _submit,
              hintText: 'What do you want to remember?',
            ),
          ),
          const SizedBox(height: AppSpacing.s12),
          AppButton(
            label: 'Add note',
            variant: AppButtonVariant.primary,
            full: true,
            disabled: !_canSubmit,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
