// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two ways out from under the sign-in button: the other mode of this
/// form, and a different Space.
///
/// Split from `sign_in_screen.dart` for the size ceiling. They read as
/// alternatives to the action above rather than a list under it, which is why
/// they share one [Wrap]. "Trouble signing in?" lives under the password
/// instead, because it is about that field and not a way out of the screen.
///
/// A Space is one deployment, so to a user "server" and "Space" are the same
/// thing. One action leads to the onboarding choice, which already offers an
/// invite, an address, or the official Space - the two routes differ only in
/// what you hold, never in where you are going.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class SignInAlternatives extends StatelessWidget {
  const SignInAlternatives({
    super.key,
    required this.creatingAccount,
    required this.busy,
    required this.onToggleCreating,
    required this.onUseDifferentSpace,
  });

  final bool creatingAccount;
  final bool busy;
  final VoidCallback onToggleCreating;

  /// Once a Space is remembered this is the only way back to invite redemption.
  final VoidCallback onUseDifferentSpace;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.center,
    spacing: AppSpacing.s8,
    runSpacing: AppSpacing.s4,
    children: [
      AppButton(
        label: creatingAccount
            ? 'I already have an account'
            : 'Create an account instead',
        variant: AppButtonVariant.ghost,
        wrapLabel: true,
        disabled: busy,
        onPressed: onToggleCreating,
      ),
      AppButton(
        label: 'Use a different Space',
        variant: AppButtonVariant.ghost,
        wrapLabel: true,
        disabled: busy,
        onPressed: onUseDifferentSpace,
      ),
    ],
  );
}
