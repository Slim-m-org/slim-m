// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the create-account form says about claiming and invites.
///
/// Split from `sign_in_screen.dart` for its size ceiling. `/version` reports
/// `invite_required` for a brand-new, unclaimed deployment as well as a closed
/// one, so `claimed` picks the wording: unclaimed says the first account is the
/// admin, claimed says a code is needed, and a server too old to report it
/// gets wording true of both. The invite wording is withheld once a code is
/// held this session: telling someone to go and redeem one right after they
/// did is the contradiction this widget exists to avoid.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/providers.dart';
import '../widgets/server_notice.dart';

class InviteRequiredNotice extends ConsumerWidget {
  const InviteRequiredNotice({super.key, required this.version});

  final Version version;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (version.claimed == false) {
      return const ServerNotice(
        icon: AppIcons.invite,
        message:
            'This Space has no members yet, so the first account becomes its '
            'administrator.',
      );
    }
    if (version.inviteRequired != true ||
        ref.watch(pendingInviteProvider) != null) {
      return const SizedBox.shrink();
    }
    return ServerNotice(
      icon: AppIcons.invite,
      message: version.claimed == true
          ? 'Joining needs an invite code. Ask a member for one.'
          : 'Joining may need an invite code. On a brand-new Space the first '
                'account becomes its admin.',
    );
  }
}
