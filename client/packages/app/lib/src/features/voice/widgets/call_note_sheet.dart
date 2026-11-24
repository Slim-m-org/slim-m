// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Add a note": one field that leaves a note on the running call's
/// transcript, readable by everyone who may read it. A sheet on a phone and a
/// dialog on a wide window (docs/design/desktop-vs-mobile.md rule 4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../ids.dart';
import '../providers/call_mark_actions.dart';

const callNoteFieldKey = Key('call-note-field');
const callNoteSaveKey = Key('call-note-save');

Future<void> showCallNoteSheet(BuildContext context) => showAppSheet<void>(
  context,
  semanticLabel: 'Add a note',
  builder: (_) => const _CallNoteSheet(),
);

class _CallNoteSheet extends ConsumerStatefulWidget {
  const _CallNoteSheet();

  @override
  ConsumerState<_CallNoteSheet> createState() => _CallNoteSheetState();
}

class _CallNoteSheetState extends ConsumerState<_CallNoteSheet> {
  final _text = TextEditingController();
  final _markId = RetryId(newCallMarkId);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String get _note => _text.text.trim();

  bool get _canSave =>
      !_saving &&
      _note.isNotEmpty &&
      _note.characters.length <= api.InputLimits.callNote;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final failed = await ref
        .read(callMarkActionsProvider)
        .mark(note: _note, id: _markId.forRequest(_note));
    if (!mounted) return;
    if (failed == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = false;
      _error = failed;
    });
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
            style: AppText.heading.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(
            'Everyone who can read this call\'s transcript sees it.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s16),
          AppInput(
            key: callNoteFieldKey,
            controller: _text,
            placeholder: 'Note',
            autofocus: true,
            minLines: 2,
            maxLines: 5,
            counterMax: api.InputLimits.callNote,
            onChanged: (_) => setState(() {}),
            semanticLabel: 'Note',
          ),
          if (_error case final error?) ...[
            const SizedBox(height: AppSpacing.s8),
            AppErrorState(message: error),
          ],
          const SizedBox(height: AppSpacing.s12),
          AppButton(
            key: callNoteSaveKey,
            label: _saving ? 'Saving...' : 'Save note',
            variant: AppButtonVariant.primary,
            full: true,
            disabled: !_canSave,
            onPressed: _save,
          ),
        ],
      ),
    );
  }
}
