// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The three credential inputs on the sign-in form: username, the display name
/// that only a new account is asked for, and password.
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
import 'package:slimm_api/api.dart' show InputLimits, usernameCharacters;

import '../../../widgets/labeled_field.dart';
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
    return AutofillGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UsernameField(
            controller: username,
            explainRejections: creatingAccount,
            serverError: errorFor(SignInErrorField.username),
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
                label: 'Trouble signing in?',
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
  });

  final TextEditingController controller;

  /// Only while creating an account; signing in never needs the rule.
  final bool explainRejections;
  final String? serverError;

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
