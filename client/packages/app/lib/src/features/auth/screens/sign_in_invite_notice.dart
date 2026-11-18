// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the create-account form says about invites.
///
/// Split from `sign_in_screen.dart` for its size ceiling. `/version` reports
/// `invite_required` for a brand-new, unclaimed deployment as well as a closed
/// one, so `claimed` decides: a claimed Space asks for the code itself before
/// the account fields (`sign_in_join_steps.dart`), an unclaimed one says
/// nothing here because "the first account becomes the administrator" is a
/// warning in the acknowledge modal, and only a server too old to report
/// `claimed` gets this hedge, true of both. It is withheld once a code is held
/// this session: telling someone to go and redeem one right after they did is
/// the contradiction this widget exists to avoid.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import '../../../widgets/server_notice.dart';

class InviteRequiredNotice extends ConsumerWidget {
  const InviteRequiredNotice({super.key, required this.version});

  final Version version;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (version.claimed != null) return const SizedBox.shrink();
    if (version.inviteRequired != true ||
        ref.watch(pendingInviteProvider) != null) {
      return const SizedBox.shrink();
    }
    return const ServerNotice(
      icon: AppIcons.invite,
      message:
          'Joining may need an invite code. On a brand-new Space the first '
          'account becomes its admin.',
    );
  }
}
