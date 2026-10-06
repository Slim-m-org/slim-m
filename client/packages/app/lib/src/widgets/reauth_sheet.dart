// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Asking for the account password, and a current two-factor code when one is
/// on, before a change a stolen session must not be able to make.
///
/// `showAppSheet`, so a bottom sheet on a phone and a centred dialog on a
/// desktop (`docs/design/desktop-vs-mobile.md`, rule 4: a short task with a
/// submit). The caller owns the request, as `totp_code_sheet.dart` does: this
/// collects the proof, hands it over, and shows what came back if it failed.
/// The failure stays on screen as an `AppErrorState` until dismissed or retried.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

/// What a caller does with the proof, returning null on success or the
/// sentence to show if it failed. [code] is null unless the sheet asked for one.
typedef ReauthSubmit = Future<String?> Function(String password, String? code);

/// The sentence for a failed proof. A wrong password is the ordinary case and
/// gets its own words; a 403 is never a signed-out session here.
String reauthFailure(api.ApiException e) => switch (e) {
  api.ForbiddenException() => 'That password is not correct.',
  api.RateLimitedException() =>
    'Too many attempts. Wait a few minutes and try again.',
  api.BadRequestException() =>
    'That code was not accepted. Check the code and try again.',
  _ => e.message,
};

/// Opens the sheet. Resolves true once [onSubmit] reported success, and null if
/// it was dismissed.
Future<bool?> showReauthSheet(
  BuildContext context, {
  required String title,
  required String description,
  required String submitLabel,
  required ReauthSubmit onSubmit,
  bool askForCode = false,
  bool dangerous = false,
}) {
  return showAppSheet<bool>(
    context,
    builder: (context) => _ReauthSheet(
      title: title,
      description: description,
      submitLabel: submitLabel,
      onSubmit: onSubmit,
      askForCode: askForCode,
      dangerous: dangerous,
    ),
  );
}

class _ReauthSheet extends StatefulWidget {
  const _ReauthSheet({
    required this.title,
    required this.description,
    required this.submitLabel,
    required this.onSubmit,
    required this.askForCode,
    required this.dangerous,
  });

  final String title;
  final String description;
  final String submitLabel;
  final ReauthSubmit onSubmit;
  final bool askForCode;
  final bool dangerous;

  @override
  State<_ReauthSheet> createState() => _ReauthSheetState();
}

class _ReauthSheetState extends State<_ReauthSheet> {
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  String get _codeText => _code.text.replaceAll(RegExp(r'\s'), '');

  bool get _ready =>
      _password.text.isNotEmpty && (!widget.askForCode || _codeText.isNotEmpty);

  Future<void> _submit() async {
    if (!_ready || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final failure = await widget.onSubmit(
      _password.text,
      widget.askForCode ? _codeText : null,
    );
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = failure;
      _password.clear();
      _code.clear();
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
        AppSpacing.s16,
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
              controller: _password,
              placeholder: 'Your password',
              obscureText: true,
              autofocus: true,
              enabled: !_busy,
              textInputAction: widget.askForCode
                  ? TextInputAction.next
                  : TextInputAction.done,
              autocorrect: false,
              autofillHints: const [AutofillHints.password],
              semanticLabel: 'Your password',
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => widget.askForCode ? null : _submit(),
            ),
            if (widget.askForCode) ...[
              const SizedBox(height: AppSpacing.s8),
              AppInput(
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
              label: _busy ? 'Checking...' : widget.submitLabel,
              variant: widget.dangerous
                  ? AppButtonVariant.danger
                  : AppButtonVariant.primary,
              full: true,
              disabled: _busy || !_ready,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
