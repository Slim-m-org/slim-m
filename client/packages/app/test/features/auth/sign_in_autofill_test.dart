// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A new account's password field asks the password manager to generate and
/// save one; signing in asks it to fill the saved one. Both sit in one group.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/auth/widgets/sign_in_credential_fields.dart';
import 'package:slimm_design_system/design_system.dart';

Future<Iterable<String>?> _passwordHints(
  WidgetTester tester, {
  required bool creatingAccount,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: SignInCredentialFields(
          username: TextEditingController(),
          displayName: TextEditingController(),
          password: TextEditingController(),
          creatingAccount: creatingAccount,
          busy: false,
          errorFor: (_) => null,
          onSubmit: () {},
          onRecoverAccount: () {},
        ),
      ),
    ),
  );
  expect(find.byType(AutofillGroup), findsOneWidget);
  final passwordField = find.byWidgetPredicate(
    (w) => w is AppInput && w.obscureText,
  );
  return tester.widget<AppInput>(passwordField).autofillHints;
}

void main() {
  testWidgets('sign-up asks for a new password', (tester) async {
    final hints = await _passwordHints(tester, creatingAccount: true);

    expect(hints, [AutofillHints.newPassword]);
  });

  testWidgets('sign-in asks for the saved password', (tester) async {
    final hints = await _passwordHints(tester, creatingAccount: false);

    expect(hints, [AutofillHints.password]);
  });
}
