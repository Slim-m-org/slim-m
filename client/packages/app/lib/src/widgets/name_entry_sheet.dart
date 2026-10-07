// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared body of the create-channel and create-category sheets: a name
/// field with its counter, the submit button that names what is missing, and
/// the persistent failure state. What differs between them (the noun, the
/// extra fields, the request) comes in through the constructor.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../api_failure.dart';
import '../entity_name.dart';

/// Makes the thing named [name] and returns what to do once the sheet has
/// closed (a navigation, say), or null for nothing.
typedef NameEntryCreate = Future<VoidCallback?> Function(String name);

class NameEntrySheet extends StatefulWidget {
  const NameEntrySheet({
    super.key,
    required this.noun,
    required this.title,
    required this.onCreate,
    this.subtitle,
    this.extraFields = const [],
  });

  /// Lower-case, as it reads in a sentence: `channel`, `category`.
  final String noun;
  final String title;
  final String? subtitle;

  /// Placed between the counter and the failure state.
  final List<Widget> extraFields;

  final NameEntryCreate onCreate;

  @override
  State<NameEntrySheet> createState() => _NameEntrySheetState();
}

class _NameEntrySheetState extends State<NameEntrySheet> {
  final _name = TextEditingController();
  bool _submitting = false;
  String? _error;

  String get _label =>
      '${widget.noun[0].toUpperCase()}${widget.noun.substring(1)}';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _canSubmit => !_submitting && entityNameValid(_name.text);

  /// Names what is missing rather than sitting disabled with no explanation.
  String get _buttonLabel {
    if (_submitting) return 'Creating...';
    if (entityNameLength(_name.text) == 0) return 'Add a ${widget.noun} name';
    if (!entityNameValid(_name.text)) return 'Name is too long';
    return 'Create ${widget.noun}';
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final afterClose = await widget.onCreate(_name.text.trim());
      if (!mounted) return;
      Navigator.of(context).pop();
      afterClose?.call();
    } on api.ApiException catch (e) {
      if (mounted) {
        setState(
          () => _error = describeApiFailure('create the ${widget.noun}', e),
        );
      }
    } finally {
      // Any escape, not just ApiException, must not wedge "Creating..." on.
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final nameLength = entityNameLength(_name.text);

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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: AppText.heading.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            if (widget.subtitle != null) ...[
              const SizedBox(height: AppSpacing.s4),
              Text(
                widget.subtitle!,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ],
            const SizedBox(height: AppSpacing.s16),
            AppInput(
              controller: _name,
              placeholder: '$_label name',
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_canSubmit) _submit();
              },
              semanticLabel: '$_label name',
            ),
            const SizedBox(height: AppSpacing.s4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '$nameLength/$entityNameMaxChars',
                style: AppText.micro.copyWith(
                  color: nameLength > entityNameMaxChars
                      ? tokens.dangerText
                      : tokens.textSecondary,
                ),
              ),
            ),
            ...widget.extraFields,
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
