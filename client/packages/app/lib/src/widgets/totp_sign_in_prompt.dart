// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The second step of signing in, when the account has a second factor.
///
/// A sheet rather than another screen: it is a short task with a submit, which
/// is rule 4 in `docs/design/desktop-vs-mobile.md`, so it renders as a bottom
/// sheet on a phone and a centred dialog on a desktop. It also keeps the
/// sign-in screen's own state intact behind it, which matters because
/// abandoning this must leave somebody where they were rather than half
/// signed in - at this point the password was accepted and no session exists.
///
/// Kept out of `sign_in_screen.dart`, which is already at its line budget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../providers/providers.dart';
import 'totp_code_sheet.dart';
import 'totp_failures.dart';

/// Asks for a code and spends [challenge] on it. True once a session exists.
///
/// A wrong code leaves the challenge live, so the sheet stays open and can be
/// retyped; only an expired or already-spent challenge sends somebody back to
/// the password, and the message says which.
Future<bool> promptForTotpCode(
  BuildContext context,
  WidgetRef ref,
  api.TotpChallenge challenge, {
  String? installId,
}) async {
  final done = await showTotpCodeSheet(
    context,
    title: 'Enter your code',
    description: 'Enter a code from your authenticator, or a recovery code.',
    submitLabel: 'Sign in',
    onSubmit: (code) async {
      try {
        await ref
            .read(apiProvider)
            .verifyTotpChallenge(
              challenge: challenge.challenge,
              code: code,
              installId: installId,
            );
        return null;
      } on api.ApiException catch (e) {
        return _failure(e);
      }
    },
  );
  return done == true;
}

/// One sentence per failure. A 401 here is the challenge, not the password:
/// reusing the sign-in screen's "wrong username or password" would send
/// somebody to retype credentials that were already accepted.
String _failure(api.ApiException e) => switch (e) {
  api.UnauthorizedException() =>
    'This sign-in took too long and has expired. Close this and enter your '
        'password again.',
  _ => totpCodeFailure(e),
};
