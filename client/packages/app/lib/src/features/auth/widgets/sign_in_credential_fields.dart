// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two credential inputs on the sign-in form: username and password.
///
/// Split out of `sign_in_screen.dart` when stating the username and password
/// rules in helper text took that file past its hard line ceiling. It is the
/// same seam `sign_in_error.dart` already took - a self-contained piece with no
/// state of its own, driven entirely by what it is handed.
///
/// The password rule is stated only while creating an account, and the username
/// rule only once a keystroke breaks it: the field drops a disallowed character
/// or one past the limit, and saying why at that moment beats a line of fine
/// print that is always there. The server still names the field when it
/// rejects either.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_api/api.dart'
    show InputLimits, kPasswordMinChars, usernameCharacters;

import '../../../widgets/labeled_field.dart';
import 'sign_in_error.dart';

const usernameRule = 'Letters, digits, _ . and - only. Up to 32 characters.';
const passwordRule = 'At least $kPasswordMinChars characters.';

class SignInCredentialFields extends StatelessWidget {
  const SignInCredentialFields({
    super.key,
    required this.username,
    required this.password,
    required this.creatingAccount,
    this.usernameInvalid = false,
    required this.busy,
    required this.errorFor,
    required this.onSubmit,
    required this.onRecoverAccount,
  });

  final TextEditingController username;
  final TextEditingController password;

  /// Whether this is a registration, which states the password rule.
  final bool creatingAccount;

  /// Marks the username as failed too, for an error shown under the password.
  final bool usernameInvalid;
  final bool busy;

  /// The error currently owned by a given field, or null when it has none.
  final String? Function(SignInErrorField) errorFor;
  final VoidCallback onSubmit;

  /// Opens the reset-code flow; offered under the password while signing in
  /// only, since a new account has nothing to recover.
  final VoidCallback onRecoverAccount;

  @override
  Widget build(BuildContext context) {
    return AutofillGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UsernameField(
            controller: username,
            explainRejections: creatingAccount,
            serverError: errorFor(SignInErrorField.username),
            invalid: usernameInvalid,
          ),
          const SizedBox(height: AppSpacing.s16),
          LabeledField(
            label: 'Password',
            // The rule and the error never stack: the error replaces it.
            helper:
                creatingAccount && errorFor(SignInErrorField.password) == null
                ? passwordRule
                : null,
            child: AppInput(
              maxLength: InputLimits.password,
              controller: password,
              errorText: errorFor(SignInErrorField.password),
              obscureText: true,
              autofillHints: [
                creatingAccount
                    ? AutofillHints.newPassword
                    : AutofillHints.password,
              ],
              textInputAction: TextInputAction.done,
              semanticLabel: 'Password',
              onSubmitted: (_) => busy ? null : onSubmit(),
            ),
          ),
          if (!creatingAccount)
            Align(
              alignment: Alignment.centerRight,
              child: AppButton(
                label: 'Forgot password?',
                variant: AppButtonVariant.ghost,
                disabled: busy,
                onPressed: onRecoverAccount,
              ),
            ),
        ],
      ),
    );
  }
}

/// The username input, which says why a keystroke did nothing only when one did.
class UsernameField extends StatefulWidget {
  const UsernameField({
    super.key,
    required this.controller,
    required this.explainRejections,
    this.serverError,
    this.invalid = false,
  });

  final TextEditingController controller;

  /// Only while creating an account; signing in never needs the rule.
  final bool explainRejections;
  final String? serverError;
  final bool invalid;

  @override
  State<UsernameField> createState() => _UsernameFieldState();
}

class _UsernameFieldState extends State<UsernameField> {
  bool _rejected = false;

  late final _formatter = _ReportingFilter(
    onEdit: (rejected) {
      if (rejected == _rejected || !mounted) return;
      setState(() => _rejected = rejected);
    },
  );

  @override
  Widget build(BuildContext context) {
    final explain = widget.explainRejections && _rejected;
    return LabeledField(
      label: 'Username',
      child: AppInput(
        maxLength: InputLimits.username,
        inputFormatters: [_formatter],
        controller: widget.controller,
        errorText: widget.serverError ?? (explain ? usernameRule : null),
        invalid: widget.invalid,
        autocorrect: false,
        autofillHints: const [AutofillHints.username],
        textInputAction: TextInputAction.next,
        semanticLabel: 'Username',
      ),
    );
  }
}

/// Drops what a username cannot hold, and reports whether this edit tried to.
class _ReportingFilter extends TextInputFormatter {
  _ReportingFilter({required this.onEdit});

  final ValueChanged<bool> onEdit;
  final _allow = FilteringTextInputFormatter.allow(usernameCharacters);

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final filtered = _allow.formatEditUpdate(oldValue, newValue);
    final tooLong = filtered.text.length > InputLimits.username;
    if (newValue.text != oldValue.text) {
      onEdit(filtered.text != newValue.text || tooLong);
    }
    return filtered;
  }
}
