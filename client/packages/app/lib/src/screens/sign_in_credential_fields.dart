// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The three credential inputs on the sign-in form: username, the display name
/// that only a new account is asked for, and password.
///
/// Split out of `sign_in_screen.dart` when stating the username and password
/// rules in helper text took that file past its hard line ceiling. It is the
/// same seam `sign_in_error.dart` already took - a self-contained piece with no
/// state of its own, driven entirely by what it is handed.
///
/// The username and password rules are stated only while creating an account:
/// they are what a newcomer needs before choosing, and to someone signing in
/// with a password they already have they read as the app doubting it. The
/// server still names the field when it rejects either.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_api/api.dart' show InputLimits, usernameCharacters;

import '../widgets/labeled_field.dart';
import 'sign_in_error.dart';

const usernameRule = 'Letters, digits, _ . and - only. Up to 32 characters.';
const passwordRule = 'At least 8 characters.';
const displayNameHelper =
    'What others see. Defaults to your username. Up to 64 characters.';

class SignInCredentialFields extends StatelessWidget {
  const SignInCredentialFields({
    super.key,
    required this.username,
    required this.displayName,
    required this.password,
    required this.creatingAccount,
    this.askDisplayName = true,
    required this.busy,
    required this.errorFor,
    required this.onSubmit,
    required this.onRecoverAccount,
  });

  final TextEditingController username;
  final TextEditingController displayName;
  final TextEditingController password;

  /// Whether this is a registration, which is the only time a display name is
  /// asked for.
  final bool creatingAccount;

  /// False on the official server, where the name defaults to the username and
  /// is editable later, so joining is username and password only.
  final bool askDisplayName;
  final bool busy;

  /// The error currently owned by a given field, or null when it has none.
  final String? Function(SignInErrorField) errorFor;
  final VoidCallback onSubmit;

  /// Opens the reset-code flow; offered under the password while signing in
  /// only, since a new account has nothing to recover.
  final VoidCallback onRecoverAccount;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LabeledField(
          label: 'Username',
          helper: creatingAccount ? usernameRule : null,
          child: AppInput(
            maxLength: InputLimits.username,
            inputFormatters: [
              FilteringTextInputFormatter.allow(usernameCharacters),
            ],
            controller: username,
            errorText: errorFor(SignInErrorField.username),
            autocorrect: false,
            autofillHints: const [AutofillHints.username],
            textInputAction: TextInputAction.next,
            semanticLabel: 'Username',
          ),
        ),
        if (creatingAccount && askDisplayName) ...[
          const SizedBox(height: AppSpacing.s16),
          LabeledField(
            label: 'Display name',
            helper: displayNameHelper,
            child: AppInput(
              controller: displayName,
              errorText: errorFor(SignInErrorField.displayName),
              textInputAction: TextInputAction.next,
              semanticLabel: 'Display name',
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.s16),
        LabeledField(
          label: 'Password',
          helper: creatingAccount ? passwordRule : null,
          child: AppInput(
            maxLength: InputLimits.password,
            controller: password,
            errorText: errorFor(SignInErrorField.password),
            obscureText: true,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.done,
            semanticLabel: 'Password',
            onSubmitted: (_) => busy ? null : onSubmit(),
          ),
        ),
        if (!creatingAccount)
          Align(
            alignment: Alignment.centerRight,
            child: AppButton(
              label: 'Trouble signing in?',
              variant: AppButtonVariant.ghost,
              disabled: busy,
              onPressed: onRecoverAccount,
            ),
          ),
      ],
    );
  }
}
