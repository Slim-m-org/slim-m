// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Stateless pieces of the sign-in form, split from `sign_in_screen.dart` for
/// its size ceiling: the address field, the notices above the credentials, and
/// the error that belongs to no field.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/labeled_field.dart';
import '../../../widgets/server_notice.dart';
import 'sign_in_invite_notice.dart';
import 'sign_in_wording.dart';

/// The Space's address, shown for every server but the compiled-in official one.
class SignInServerField extends StatelessWidget {
  const SignInServerField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    this.error,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final String? error;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.s8),
    child: LabeledField(
      label: 'Server',
      child: AppInput(
        controller: controller,
        focusNode: focusNode,
        placeholder: 'your-server-address.com',
        mono: true,
        errorText: error,
        keyboardType: TextInputType.url,
        autocorrect: false,
        semanticLabel: 'Server',
        onChanged: onChanged,
      ),
    ),
  );
}

/// What is worth knowing before the credentials: an invite may be needed, the
/// typed name has no account yet, or this Space cannot send push.
class SignInNotices extends StatelessWidget {
  const SignInNotices({
    super.key,
    required this.probed,
    required this.creatingAccount,
    this.noAccountNamed,
  });

  /// What the server said about itself, or null while it has not.
  final Version? probed;
  final bool creatingAccount;

  /// The username the server said has no account, while the create step is open.
  final String? noAccountNamed;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (probed case final version? when creatingAccount)
        InviteRequiredNotice(version: version),
      if (noAccountNamed case final name? when creatingAccount)
        NoAccountNotice(username: name, space: probed?.displayName),
      if (probed?.pushEnabled == false)
        const ServerNotice(
          icon: AppIcons.notificationsOff,
          message:
              'This Space cannot send push notifications. '
              'You can still use it, but phones will only see '
              'new messages while the app is open.',
        ),
    ],
  );
}

/// A failure that belongs to no one field, announced as it appears.
class SignInFormError extends StatelessWidget {
  const SignInFormError({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s16),
      child: Semantics(
        liveRegion: true,
        child: Text(
          message,
          style: AppText.caption.copyWith(color: tokens.dangerText),
        ),
      ),
    );
  }
}
