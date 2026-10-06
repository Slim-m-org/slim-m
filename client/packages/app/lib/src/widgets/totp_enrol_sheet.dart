// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turning on the second factor: scan or type the secret, prove a code, then
/// write down the recovery codes.
///
/// `showAppSheet`, so a bottom sheet on a phone and a centred dialog on a
/// desktop (`docs/design/desktop-vs-mobile.md`, rule 4).
///
/// Three steps in one sheet rather than three surfaces, because the middle one
/// is the whole point: nothing is enforced until a code off the authenticator is
/// verified, so a person who scans and then closes the sheet has changed nothing
/// about how they sign in. Decision 0048 has the reasoning.
///
/// The secret is shown as a QR code *and* as text. The text is not a fallback
/// for a decorative QR: a desktop showing a QR on the same screen the
/// authenticator would have to photograph is the normal case here, and typing
/// 32 characters is what that person actually does.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/providers.dart';
import '../providers/toasts.dart';
import 'reauth_sheet.dart';
import 'totp_failures.dart';
import 'totp_recovery_codes.dart';

/// Opens the enrolment flow: the password first, since a session token alone
/// cannot turn the factor on (decision 0048), then the setup sheet. Resolves
/// true once the factor is on, so the caller can refresh whatever showed it as
/// off, and null if it was abandoned at either step.
Future<bool?> showTotpEnrolSheet(BuildContext context, WidgetRef ref) async {
  api.TotpEnrolment? enrolment;
  String? confirmedPassword;
  final proved = await showReauthSheet(
    context,
    title: 'Confirm it is you',
    description:
        'Enter your password to start setting up two-factor authentication.',
    submitLabel: 'Continue',
    onSubmit: (password, _) async {
      try {
        enrolment = await ref
            .read(apiProvider)
            .beginTotpEnrolment(password: password);
        confirmedPassword = password;
        return null;
      } on api.ApiException catch (e) {
        return reauthFailure(e);
      }
    },
  );
  final started = enrolment;
  final password = confirmedPassword;
  if (proved != true || started == null || password == null) return null;
  if (!context.mounted) return null;
  return showAppSheet<bool>(
    context,
    builder: (context) =>
        _TotpEnrolSheet(enrolment: started, password: password),
  );
}

class _TotpEnrolSheet extends ConsumerStatefulWidget {
  const _TotpEnrolSheet({required this.enrolment, required this.password});

  final api.TotpEnrolment enrolment;
  final String password;

  @override
  ConsumerState<_TotpEnrolSheet> createState() => _TotpEnrolSheetState();
}

class _TotpEnrolSheetState extends ConsumerState<_TotpEnrolSheet> {
  final _controller = TextEditingController();
  List<String>? _recoveryCodes;
  bool _busy = false;
  String? _codeError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _code => _controller.text.replaceAll(RegExp(r'\s'), '');

  Future<void> _confirm() async {
    if (_code.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _codeError = null;
    });
    try {
      final codes = await ref
          .read(apiProvider)
          .confirmTotpEnrolment(_code, password: widget.password);
      if (!mounted) return;
      setState(() => _recoveryCodes = codes);
    } on api.ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _codeError = _confirmFailure(e);
        _controller.clear();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A wrong code is the ordinary case and gets its own sentence; everything
  /// else falls back to what the server said.
  String _confirmFailure(api.ApiException e) => switch (e) {
    api.ForbiddenException() => reauthFailure(e),
    _ => totpCodeFailure(e),
  };

  void _copySecret(String secret) {
    Clipboard.setData(ClipboardData(text: secret));
    ref
        .read(toastsProvider.notifier)
        .show('Setup key copied.', severity: AppToastSeverity.success);
  }

  @override
  Widget build(BuildContext context) {
    final codes = _recoveryCodes;
    if (codes != null) {
      return TotpRecoveryCodesView(
        codes: codes,
        headline: 'Two-factor authentication is on',
        onDone: () => Navigator.of(context).pop(true),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        MediaQuery.viewInsetsOf(context).bottom + AppSpacing.s16,
      ),
      child: SingleChildScrollView(child: _setup(context)),
    );
  }

  Widget _setup(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final enrolment = widget.enrolment;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Set up two-factor authentication',
          style: AppText.body.copyWith(
            color: tokens.textPrimary,
            fontWeight: AppWeights.semi,
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        Text(
          'Scan this with an authenticator app, or type the key in by hand. '
          'Then enter the code it shows, so nothing is switched on until we '
          'know it works.',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s12),
        _Qr(uri: enrolment.provisioningUri),
        const SizedBox(height: AppSpacing.s12),
        _SecretBlock(
          secret: enrolment.secret,
          onCopy: () => _copySecret(enrolment.secret),
        ),
        const SizedBox(height: AppSpacing.s12),
        AppInput(
          controller: _controller,
          placeholder: '000000',
          mono: true,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          semanticLabel: 'Code from your authenticator app',
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _confirm(),
        ),
        if (_codeError != null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(
            message: _codeError!,
            onDismiss: () => setState(() => _codeError = null),
          ),
        ],
        const SizedBox(height: AppSpacing.s12),
        AppButton(
          label: _busy ? 'Checking...' : 'Turn on',
          variant: AppButtonVariant.primary,
          full: true,
          disabled: _busy || _code.isEmpty,
          onPressed: _confirm,
        ),
      ],
    );
  }
}

/// The provisioning URI as a scannable square.
///
/// On a white plate regardless of theme, because a scanner reads contrast and
/// the dark-theme surface colours do not give it enough of one.
class _Qr extends StatelessWidget {
  const _Qr({required this.uri});

  final String uri;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: QrImageView(
          data: uri,
          size: 180,
          // The URI is short, and a denser code is harder to read off another screen.
          errorCorrectionLevel: QrErrorCorrectLevel.M,
          backgroundColor: const Color(0xFFFFFFFF),
          semanticsLabel: 'QR code for your authenticator app',
        ),
      ),
    );
  }
}

/// The base32 secret, selectable and copyable for anyone typing it in.
class _SecretBlock extends StatelessWidget {
  const _SecretBlock({required this.secret, required this.onCopy});

  final String secret;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Or type this key in',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s4),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: tokens.surfaceBase,
            border: Border.all(color: tokens.borderSubtle),
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
          padding: const EdgeInsets.all(AppSpacing.s12),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  secret,
                  style: AppText.code.copyWith(color: tokens.textPrimary),
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              AppButton(
                label: 'Copy',
                variant: AppButtonVariant.ghost,
                size: AppButtonSize.sm,
                onPressed: onCopy,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
