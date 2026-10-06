// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The locked-out person's half of account recovery: spending a one-time code
/// an admin issued (`POST /auth/reset`, `SlimmApi.resetPassword`).
///
/// Unauthenticated on purpose, and that is the whole point of the flow: the
/// person using this cannot sign in, so there is no session to hang the call
/// off. It talks to the server through [probeApiProvider], the same seam
/// sign-in's own probe and the invite dialog use, because the address in the
/// field is exactly as untrusted here as it is there.
///
/// It deliberately says nothing about *why* a code was refused. The server
/// answers unknown, expired and already-spent identically so live codes
/// cannot be mined, and naming the reason here would undo that from the
/// client side - the same reasoning `onboarding_dialogs.dart` records for
/// invite codes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../api_failure.dart';
import '../default_server.dart';
import '../providers/providers.dart';
import '../server_scheme_policy.dart';
import '../widgets/labeled_field.dart';
import '../widgets/server_identity_confirmation.dart';

/// Validates [target], confirms the server's identity, then opens the sheet.
///
/// Returns null when the address itself is unusable, so the caller can put
/// that error on its own address field, and false when the person backed out
/// or the identity check refused.
///
/// The identity check is the point of this wrapper. Sign-in runs
/// [confirmServerIdentity] before it sends a password, and a reset sends a
/// one-time code *and* a new password, so skipping it here would have made
/// recovery the softest door onto the same account.
Future<bool?> startAccountRecovery(
  BuildContext context,
  WidgetRef ref,
  Uri? target,
) async {
  if (target == null || requireSecureScheme(target) != null) return null;
  final trusted = await confirmServerIdentity(
    context,
    ref,
    target,
    silentFirstConnect: isOfficialServer(target),
  );
  if (!trusted || !context.mounted) return false;
  return showResetPasswordSheet(context, target);
}

/// Opens the redeem sheet against [server], returning true when a password
/// was actually set, so the caller can say so where the person is looking.
Future<bool> showResetPasswordSheet(BuildContext context, Uri server) async {
  final done = await showAppSheet<bool>(
    context,
    builder: (context) => _ResetPasswordSheet(server: server),
  );
  return done ?? false;
}

class _ResetPasswordSheet extends ConsumerStatefulWidget {
  const _ResetPasswordSheet({required this.server});

  final Uri server;

  @override
  ConsumerState<_ResetPasswordSheet> createState() =>
      _ResetPasswordSheetState();
}

class _ResetPasswordSheetState extends ConsumerState<_ResetPasswordSheet> {
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Checked here as well as on the server so the rule is visible before a
  /// round trip spends the code, which is the one thing that cannot be undone.
  bool get _passwordLongEnough =>
      _password.text.length >= api.kPasswordMinChars;

  Future<void> _submit() async {
    if (_code.text.trim().isEmpty) {
      setState(() => _error = 'Enter the code your admin gave you.');
      return;
    }
    if (!_passwordLongEnough) {
      setState(
        () => _error =
            'Choose a password of at least ${api.kPasswordMinChars} characters.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    final client = ref.read(probeApiProvider)(widget.server);
    try {
      await client.resetPassword(
        code: _code.text.trim(),
        newPassword: _password.text,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on api.ApiException catch (e) {
      setState(
        () => _error = e is api.TransportException
            ? 'Could not reach that server.'
            : sentenceCase(e.message),
      );
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
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
              'Use a reset code',
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(
              'This Space has no password reset by email. Ask an admin for a '
              'one-time code, then set a new password here. You will be '
              'signed out on every device.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s16),
            LabeledField(
              label: 'Reset code',
              child: AppInput(
                controller: _code,
                mono: true,
                autocorrect: false,
                semanticLabel: 'Reset code',
                textInputAction: TextInputAction.next,
              ),
            ),
            const SizedBox(height: AppSpacing.s16),
            LabeledField(
              label: 'New password',
              helper: 'At least ${api.kPasswordMinChars} characters.',
              child: AppInput(
                controller: _password,
                obscureText: true,
                autofillHints: const [AutofillHints.newPassword],
                semanticLabel: 'New password',
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _busy ? null : _submit(),
              ),
            ),
            if (_error case final error?) ...[
              const SizedBox(height: AppSpacing.s16),
              AppErrorState(message: error),
            ],
            const SizedBox(height: AppSpacing.s16),
            AppButton(
              label: _busy ? 'Setting password...' : 'Set new password',
              variant: AppButtonVariant.primary,
              size: AppButtonSize.lg,
              full: true,
              busy: _busy,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
