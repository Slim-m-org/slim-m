// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Renaming a soundboard clip (`PATCH /soundboard/{id}`).
///
/// `showAppSheet`: a bottom sheet on a phone, a centred dialog on a desktop
/// (`docs/design/desktop-vs-mobile.md`, rule 4).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../widgets/run_guarded.dart';
import '../../../voice/providers/soundboard_actions.dart';
import '../../../voice/providers/soundboard_clips.dart';
import 'soundboard_intake.dart';

Future<void> showRenameSoundClipSheet(
  BuildContext context, {
  required api.SoundClip clip,
}) => showAppSheet<void>(
  context,
  semanticLabel: 'Rename ${clip.name}',
  builder: (context) => _RenameSoundClipSheet(clip: clip),
);

class _RenameSoundClipSheet extends ConsumerStatefulWidget {
  const _RenameSoundClipSheet({required this.clip});

  final api.SoundClip clip;

  @override
  ConsumerState<_RenameSoundClipSheet> createState() =>
      _RenameSoundClipSheetState();
}

class _RenameSoundClipSheetState extends ConsumerState<_RenameSoundClipSheet>
    with GuardedActionState<_RenameSoundClipSheet> {
  late final _name = TextEditingController(text: widget.clip.name);
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _canSave {
    final trimmed = _name.text.trim();
    return !_busy && trimmed.isNotEmpty && trimmed != widget.clip.name;
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: 'rename the clip',
      action: () => ref
          .read(soundboardActionsProvider)
          .rename(widget.clip.id, name: _name.text.trim()),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;
    ref.invalidate(soundClipsProvider);
    Navigator.of(context).pop();
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
            'Rename clip',
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s12),
          AppInput(
            counterMax: soundClipMaxNameChars,
            controller: _name,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_canSave) unawaited(_save());
            },
            semanticLabel: 'Clip name',
          ),
          if (actionError != null) ...[
            const SizedBox(height: AppSpacing.s8),
            AppErrorState(message: actionError!, onDismiss: clearActionError),
          ],
          const SizedBox(height: AppSpacing.s12),
          AppButton(
            label: _busy ? 'Saving...' : 'Save name',
            variant: AppButtonVariant.primary,
            disabled: !_canSave,
            onPressed: _save,
          ),
        ],
      ),
    );
  }
}
