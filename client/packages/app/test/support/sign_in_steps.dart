// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Getting the sign-in form to its create step the way a person does.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import 'async_wait.dart';

/// The `/version` capability that makes the form ask the server who exists.
const usernameCheckCapability = 'username_check';

/// The text field the sign-in form labels [label].
Finder signInField(String label) =>
    find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label);

Finder signInButton(String label) => find.widgetWithText(AppButton, label);

/// Takes the older-server way to the create step, which a server without
/// `username_check` offers as a button.
Future<void> chooseCreateInstead(WidgetTester tester) async {
  await tester.ensureVisible(signInButton('Create an account instead'));
  await tester.tap(signInButton('Create an account instead'));
  await pumpFrames(tester);
}

/// Submits [username] and [password] on a server that answers the lookup with
/// no account, which opens the create step. [button] is 'Continue' on a first visit.
Future<void> submitUntilCreateStep(
  WidgetTester tester, {
  required String username,
  required String password,
  String button = 'Sign in',
}) async {
  await tester.enterText(signInField('Username'), username);
  await tester.enterText(signInField('Password'), password);
  await tester.tap(signInButton(button));
  await pumpFrames(tester, frames: 30);
}

/// Fills the confirm field and submits the create step.
Future<void> confirmAndCreate(WidgetTester tester, String confirm) async {
  await tester.enterText(signInField('Confirm password'), confirm);
  await tester.tap(signInButton('Create account'));
  await pumpFrames(tester);
}
