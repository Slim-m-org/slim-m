// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The order creating an account goes in: the server answers first, an
/// invite-only Space then checks the code, and only then are a username and
/// password asked for, so nobody fills in a form a server was always going to
/// refuse. Signing in to an existing account skips both gates.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/labeled_field.dart';
import 'invite_code_check.dart';

enum JoinStage { server, invite, account }

/// Whether [probed] is a claimed Space that only takes new members with a
/// code; a server too old to report `claimed` cannot say, so it never asks.
bool invitesOnly(Version? probed) =>
    probed?.inviteRequired == true && probed?.claimed == true;

/// Which part of the form is open for what the server said.
JoinStage joinStageFor({
  required bool creatingAccount,
  required Version? probed,
  required bool inviteAccepted,
}) {
  if (!creatingAccount) return JoinStage.account;
  if (probed == null) return JoinStage.server;
  if (invitesOnly(probed) && !inviteAccepted) return JoinStage.invite;
  return JoinStage.account;
}

/// The invite code the form holds, and the address it checked out on.
class HeldInvite {
  /// [pending] came from onboarding, which checked it on [server] already.
  HeldInvite({String? pending, Uri? server})
    : controller = TextEditingController(text: pending ?? ''),
      _accepted = pending == null ? null : (server: server, code: pending);

  final TextEditingController controller;
  ({Uri? server, String code})? _accepted;

  /// The checked code for [server], which signing up or in sends along.
  String? codeFor(Uri? server) => switch (_accepted) {
    (server: final checkedOn, :final code) when checkedOn == server => code,
    _ => null,
  };

  /// Whether the code in the field is the one that checked out on [server].
  bool acceptedFor(Uri? server) =>
      codeFor(server) != null && codeFor(server) == controller.text.trim();

  void accept(Uri server, String code) =>
      _accepted = (server: server, code: code);

  /// Checks the code in the field on [client]'s [server] and holds it there if
  /// it can be used; otherwise says why. Closes [client].
  Future<String?> check(SlimmApi client, Uri server) async {
    final code = controller.text.trim();
    final problem = await inviteCodeProblem(client, code);
    if (problem == null) accept(server, code);
    return problem;
  }

  void dispose() => controller.dispose();
}

/// The code an invite-only Space asks for before the account fields.
class InviteCodeField extends StatelessWidget {
  const InviteCodeField({
    super.key,
    required this.controller,
    required this.accepted,
    required this.busy,
    required this.onChanged,
    required this.onSubmit,
    this.error,
  });

  final TextEditingController controller;

  /// The code in [controller] checked out on the server in the field.
  final bool accepted;
  final bool busy;
  final String? error;

  /// Gets a whole pasted link too, which fills both fields.
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return LabeledField(
      label: 'Invite code',
      helper: error != null
          ? null
          : accepted
          ? 'Invite accepted.'
          : 'Joining needs an invite. Paste the code or link a member sent you.',
      child: AppInput(
        controller: controller,
        placeholder: 'Code, or an invite link',
        errorText: error,
        autocorrect: false,
        textInputAction: TextInputAction.go,
        semanticLabel: 'Invite code',
        trailing: accepted
            ? Icon(AppIcons.check, size: AppSizes.icon16, color: tokens.accent)
            : null,
        onChanged: onChanged,
        onSubmitted: (_) => busy || accepted ? null : onSubmit(),
      ),
    );
  }
}
