// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one sheet a single name is typed in: renaming a category, a member or
/// a webhook.
///
/// `showAppSheet`: a bottom sheet on a phone, a centred dialog on a desktop
/// (`docs/design/desktop-vs-mobile.md`, rule 4).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import 'run_guarded.dart';

/// A second way out of the sheet beside saving, such as removing a nickname.
class NameSheetAction {
  const NameSheetAction({
    required this.label,
    required this.whatFailed,
    required this.run,
  });

  final String label;
  final String whatFailed;
  final Future<void> Function(WidgetRef ref) run;
}

/// Opens the sheet; true once [onSave] or [secondary] succeeded and closed it.
///
/// [problem] says why a typed name cannot be used, under the field; [blocked]
/// says why nothing can be saved whatever the name, such as a file too large.
Future<bool> showNameSheet(
  BuildContext context, {
  required String title,
  required String fieldLabel,
  required int maxChars,
  required String whatFailed,
  required Future<void> Function(WidgetRef ref, String name) onSave,
  String initial = '',
  String? caption,
  String? placeholder,
  String saveLabel = 'Save name',
  String savingLabel = 'Saving...',
  bool requireChange = true,
  String? Function(String name)? problem,
  String? blocked,
  NameSheetAction? secondary,
}) async {
  final saved = await showAppSheet<bool>(
    context,
    semanticLabel: title,
    builder: (_) => _NameSheet(
      title: title,
      fieldLabel: fieldLabel,
      maxChars: maxChars,
      whatFailed: whatFailed,
      onSave: onSave,
      initial: initial,
      caption: caption,
      placeholder: placeholder,
      saveLabel: saveLabel,
      savingLabel: savingLabel,
      requireChange: requireChange,
      problem: problem,
      blocked: blocked,
      secondary: secondary,
    ),
  );
  return saved ?? false;
}

class _NameSheet extends ConsumerStatefulWidget {
  const _NameSheet({
    required this.title,
    required this.fieldLabel,
    required this.maxChars,
    required this.whatFailed,
    required this.onSave,
    required this.initial,
    required this.caption,
    required this.placeholder,
    required this.saveLabel,
    required this.savingLabel,
    required this.requireChange,
    required this.problem,
    required this.blocked,
    required this.secondary,
  });

  final String title;
  final String fieldLabel;
  final int maxChars;
  final String whatFailed;
  final Future<void> Function(WidgetRef ref, String name) onSave;
  final String initial;
  final String? caption;
  final String? placeholder;
  final String saveLabel;
  final String savingLabel;
  final bool requireChange;
  final String? Function(String name)? problem;
  final String? blocked;
  final NameSheetAction? secondary;

  @override
  ConsumerState<_NameSheet> createState() => _NameSheetState();
}

class _NameSheetState extends ConsumerState<_NameSheet>
    with GuardedActionState<_NameSheet> {
  late final _name = TextEditingController(text: widget.initial);
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _trimmed => _name.text.trim();

  String? get _problem =>
      _trimmed.isEmpty ? null : widget.problem?.call(_trimmed);

  bool get _canSave {
    final name = _trimmed;
    return !_busy &&
        widget.blocked == null &&
        name.isNotEmpty &&
        inputCharCount(name) <= widget.maxChars &&
        (!widget.requireChange || name != widget.initial.trim()) &&
        _problem == null;
  }

  Future<void> _run(String whatFailed, Future<void> Function() action) async {
    setState(() => _busy = true);
    final ok = await guard(whatFailed: whatFailed, action: action);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _busy = false);
  }

  Future<void> _save() {
    final name = _trimmed;
    return _run(widget.whatFailed, () => widget.onSave(ref, name));
  }

  @override
  Widget build(BuildContext context) {
    final secondary = widget.secondary;
    final save = AppButton(
      label: _busy ? widget.savingLabel : widget.saveLabel,
      variant: AppButtonVariant.primary,
      full: true,
      disabled: !_canSave,
      onPressed: _save,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppSheetHeader(
              widget.title,
              caption: widget.caption,
              padding: const EdgeInsets.only(bottom: AppSpacing.s12),
              trailing: AppIconButton(
                icon: AppIcons.dismiss,
                semanticLabel: 'Close',
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ),
            AppInput(
              counterMax: widget.maxChars,
              controller: _name,
              placeholder: widget.placeholder,
              autofocus: true,
              errorText: _problem,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_canSave) unawaited(_save());
              },
              semanticLabel: widget.fieldLabel,
            ),
            if (widget.blocked case final blocked?) ...[
              const SizedBox(height: AppSpacing.s8),
              AppErrorState(message: blocked),
            ],
            if (actionError case final error?) ...[
              const SizedBox(height: AppSpacing.s8),
              AppErrorState(message: error, onDismiss: clearActionError),
            ],
            const SizedBox(height: AppSpacing.s12),
            if (secondary == null)
              save
            else
              Row(
                spacing: AppSpacing.s8,
                children: [
                  Expanded(
                    child: AppButton(
                      label: secondary.label,
                      variant: AppButtonVariant.ghost,
                      full: true,
                      disabled: _busy,
                      onPressed: () =>
                          _run(secondary.whatFailed, () => secondary.run(ref)),
                    ),
                  ),
                  Expanded(child: save),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
