// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Changing your own password: the current one, the new one twice, and a
/// current two-factor code when that is on.
///
/// `showAppSheet`, so a bottom sheet on a phone and a centred dialog on a
/// desktop (`docs/design/desktop-vs-mobile.md`, rule 4: a short task with a
/// submit). It follows `reauth_sheet.dart`: the caller owns the request, and a
/// refusal stays on screen as an `AppErrorState` rather than closing the sheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

import '../screens/sign_in_credential_fields.dart' show passwordRule;
import 'labeled_field.dart';

/// What a caller does with the typed values, returning null on success or the
/// sentence to show if it failed.
typedef ChangePasswordSubmit =
    Future<String?> Function(String current, String next, String? code);

/// Matches the server's rule and the sign-up form's `passwordRule`.
const minPasswordLength = 8;

/// Opens the sheet. Resolves true once [onSubmit] reported success.
Future<bool?> showChangePasswordSheet(
  BuildContext context, {
  required bool askForCode,
  required ChangePasswordSubmit onSubmit,
}) => showAppSheet<bool>(
  context,
  builder: (context) =>
      _ChangePasswordSheet(askForCode: askForCode, onSubmit: onSubmit),
);

class _ChangePasswordSheet extends StatefulWidget {
  const _ChangePasswordSheet({
    required this.askForCode,
    required this.onSubmit,
  });

  final bool askForCode;
  final ChangePasswordSubmit onSubmit;

  @override
  State<_ChangePasswordSheet> createState() => _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends State<_ChangePasswordSheet> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    _code.dispose();
    super.dispose();
  }

  String get _codeText => _code.text.replaceAll(RegExp(r'\s'), '');

  bool get _mismatch => _confirm.text.isNotEmpty && _confirm.text != _next.text;

  bool get _ready =>
      _current.text.isNotEmpty &&
      _next.text.length >= minPasswordLength &&
      _confirm.text == _next.text &&
      (!widget.askForCode || _codeText.isNotEmpty);

  Future<void> _submit() async {
    if (!_ready || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? failure;
    try {
      failure = await widget.onSubmit(
        _current.text,
        _next.text,
        widget.askForCode ? _codeText : null,
      );
    } on Object {
      failure = 'Something went wrong. Try again.';
    }
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = failure;
      _current.clear();
      _code.clear();
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
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Change password',
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(
              'Your other devices are signed out.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s12),
            _field(
              label: 'Current password',
              controller: _current,
              autofocus: true,
              hint: AutofillHints.password,
            ),
            const SizedBox(height: AppSpacing.s8),
            _field(
              label: 'New password',
              helper: passwordRule,
              controller: _next,
              hint: AutofillHints.newPassword,
            ),
            const SizedBox(height: AppSpacing.s8),
            _field(
              label: 'Repeat new password',
              controller: _confirm,
              hint: AutofillHints.newPassword,
              errorText: _mismatch ? 'The passwords do not match.' : null,
              last: !widget.askForCode,
            ),
            if (widget.askForCode) ...[
              const SizedBox(height: AppSpacing.s8),
              LabeledField(
                label: 'Authentication code',
                child: AppInput(
                  controller: _code,
                  placeholder: '000000',
                  mono: true,
                  enabled: !_busy,
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
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.s8),
              AppErrorState(
                message: _error!,
                onDismiss: () => setState(() => _error = null),
              ),
            ],
            const SizedBox(height: AppSpacing.s12),
            AppButton(
              label: _busy ? 'Checking...' : 'Change password',
              full: true,
              disabled: _busy || !_ready,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    required String hint,
    String? helper,
    String? errorText,
    bool autofocus = false,
    bool last = false,
  }) => LabeledField(
    label: label,
    helper: helper,
    child: AppInput(
      controller: controller,
      obscureText: true,
      autofocus: autofocus,
      enabled: !_busy,
      errorText: errorText,
      textInputAction: last ? TextInputAction.done : TextInputAction.next,
      autocorrect: false,
      autofillHints: [hint],
      semanticLabel: label,
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => last ? _submit() : null,
    ),
  );
}
