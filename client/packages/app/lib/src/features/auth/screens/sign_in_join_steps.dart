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
  required bool inviteNeeded,
  required bool inviteAccepted,
}) {
  if (!creatingAccount) return JoinStage.account;
  if (probed == null) return JoinStage.server;
  if (inviteNeeded && !inviteAccepted) return JoinStage.invite;
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
  Uri? _linkedTo;

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

  /// A pasted link named [server], so its code is asked for there whatever
  /// that Space's join policy: an invite can grant a role even on an open one.
  void linkTo(Uri server) => _linkedTo = server;

  /// Whether the code field shows on [server] once it has answered [probed].
  bool shownOn(Uri? server, Version? probed) =>
      invitesOnly(probed) ||
      (probed != null && server != null && server == _linkedTo);

  /// Whether a code has to check out on [server] before the account fields.
  bool neededOn(Uri? server, Version? probed) =>
      invitesOnly(probed) ||
      (shownOn(server, probed) && controller.text.trim().isNotEmpty);

  /// Which part of the form is open on [server] for what it said.
  JoinStage stageOn(Uri? server, Version? probed, {required bool creating}) =>
      joinStageFor(
        creatingAccount: creating,
        probed: probed,
        inviteNeeded: neededOn(server, probed),
        inviteAccepted: acceptedFor(server),
      );

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

/// The code an invite-only Space asks for before the account fields, or one
/// a pasted link brought; it opens only while [creatingAccount].
class InviteCodeField extends StatelessWidget {
  const InviteCodeField({
    super.key,
    required this.invite,
    required this.server,
    required this.probed,
    required this.creatingAccount,
    required this.busy,
    required this.onChanged,
    required this.onSubmit,
    this.error,
  });

  final HeldInvite invite;

  /// The address in the server field, and what it said about itself.
  final Uri? server;
  final Version? probed;
  final bool creatingAccount;
  final bool busy;
  final String? error;

  /// Gets a whole pasted link too, which fills both fields.
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final shown = creatingAccount && invite.shownOn(server, probed);
    return AppRevealBand(
      child: shown
          ? Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s16),
              child: _field(context),
            )
          : null,
    );
  }

  Widget _field(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final accepted = invite.acceptedFor(server);
    return LabeledField(
      label: 'Invite code',
      helper: error != null
          ? null
          : accepted
          ? 'Invite accepted.'
          : invitesOnly(probed)
          ? 'Joining needs an invite. Paste the code or link a member sent you.'
          : null,
      child: AppInput(
        controller: invite.controller,
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
