// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Asking for a six-digit code, or a recovery code instead.
///
/// One sheet for every place that needs current proof: finishing a sign-in,
/// turning the factor off, and reissuing recovery codes. `showAppSheet`, so this
/// is a bottom sheet on a phone and a centred dialog on a desktop
/// (`docs/design/desktop-vs-mobile.md`, rule 4: a short task with a submit).
///
/// The caller owns the request. This sheet collects a code, hands it over, and
/// shows whatever came back if it failed - it never decides what a code means,
/// because the same code can be a sign-in, a disable, or a reissue.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

/// How many digits an authenticator code has. A recovery code is longer, so
/// this is a hint for the numeric keypad and the placeholder, never a limit on
/// what can be typed.
const _codeDigits = 6;

/// What a caller does with the code, returning null on success or the sentence
/// to show if it failed.
typedef TotpCodeSubmit = Future<String?> Function(String code);

/// Opens the sheet. Resolves true once [onSubmit] reported success, and null if
/// it was dismissed.
Future<bool?> showTotpCodeSheet(
  BuildContext context, {
  required String title,
  required String description,
  required String submitLabel,
  required TotpCodeSubmit onSubmit,
  bool dangerous = false,
}) {
  return showAppSheet<bool>(
    context,
    builder: (context) => _TotpCodeSheet(
      title: title,
      description: description,
      submitLabel: submitLabel,
      onSubmit: onSubmit,
      dangerous: dangerous,
    ),
  );
}

class _TotpCodeSheet extends StatefulWidget {
  const _TotpCodeSheet({
    required this.title,
    required this.description,
    required this.submitLabel,
    required this.onSubmit,
    required this.dangerous,
  });

  final String title;
  final String description;
  final String submitLabel;
  final TotpCodeSubmit onSubmit;
  final bool dangerous;

  @override
  State<_TotpCodeSheet> createState() => _TotpCodeSheetState();
}

class _TotpCodeSheetState extends State<_TotpCodeSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Trimmed, and spaces stripped: authenticator apps display `123 456`, and
  /// somebody copying that from their screen should not be told it is wrong.
  String get _code => _controller.text.replaceAll(RegExp(r'\s'), '');

  Future<void> _submit() async {
    if (_code.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final failure = await widget.onSubmit(_code);
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = failure;
      // Cleared so a retype starts empty rather than from the code just refused.
      _controller.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
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
              widget.title,
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(
              widget.description,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s12),
            AppInput(
              controller: _controller,
              focusNode: _focus,
              placeholder: '0' * _codeDigits,
              mono: true,
              autofocus: true,
              enabled: !_busy,
              // Not a number keyboard: a recovery code shares this field and is not digits.
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              inputFormatters: [
                FilteringTextInputFormatter.deny(RegExp(r'\n')),
              ],
              semanticLabel: 'Authentication code',
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.s8),
              AppErrorState(
                message: _error!,
                onDismiss: () => setState(() => _error = null),
              ),
            ],
            const SizedBox(height: AppSpacing.s12),
            AppButton(
              label: _busy ? 'Checking...' : widget.submitLabel,
              variant: widget.dangerous
                  ? AppButtonVariant.danger
                  : AppButtonVariant.primary,
              full: true,
              disabled: _busy || _code.isEmpty,
              onPressed: _submit,
            ),
            const SizedBox(height: AppSpacing.s8),
            AppButton(
              label: 'Cancel',
              variant: AppButtonVariant.ghost,
              full: true,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}
