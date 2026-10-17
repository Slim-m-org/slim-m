// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opens the who-reacted list in the surface the width asks for: a bottom
/// sheet below [kCompactWidth], an anchored popover beside the chip above it
/// (`docs/design/desktop-vs-mobile.md`, rule 3). Width decides, never platform.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../features/members/widgets/member_profile_popover.dart';
import 'reaction_users_list.dart';

const double _popoverWidth = 280;

Future<void> showReactionUsers(
  BuildContext anchor, {
  required String messageId,
  required api.ReactionSummary reaction,
  Map<String, String> customEmoji = const {},
}) {
  Widget body() => ReactionUsersBody(
    messageId: messageId,
    reaction: reaction,
    customEmoji: customEmoji,
  );

  if (MediaQuery.sizeOf(anchor).width < kCompactWidth) {
    return showAppSheet<void>(anchor, scrolls: true, builder: (_) => body());
  }

  final box = anchor.findRenderObject() as RenderBox?;
  final overlay =
      Overlay.of(anchor, rootOverlay: true).context.findRenderObject()
          as RenderBox?;
  final origin = box == null || overlay == null
      ? Offset.zero
      : box.localToGlobal(Offset.zero, ancestor: overlay);
  return showGeneralDialog<void>(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.transparent,
    transitionDuration: AppMotion.reduced(anchor, AppMotion.base),
    pageBuilder: (context, _, _) => AnchoredMemberPopover(
      origin: origin,
      anchorSize: box?.size ?? Size.zero,
      child: AppMenu(
        width: _popoverWidth,
        children: [
          const SizedBox(height: AppSpacing.s8),
          body(),
          const SizedBox(height: AppSpacing.s4),
        ],
      ),
    ),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: AppMotion.entrance,
        reverseCurve: AppMotion.exit,
      ),
      child: child,
    ),
  );
}
