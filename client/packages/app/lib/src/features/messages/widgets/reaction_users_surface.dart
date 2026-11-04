// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opens the who-reacted list in the surface the width asks for: a bottom
/// sheet below [kCompactWidth], an anchored popover beside the chip above it
/// (`docs/design/desktop-vs-mobile.md`, rule 3). Width decides, never platform.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/anchored_popover_or_sheet.dart';
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

  return showAnchoredPopoverOrSheet<void>(
    anchor,
    sheetScrolls: true,
    sheetBuilder: (_) => body(),
    popoverBuilder: (_) => AppMenu(
      width: _popoverWidth,
      children: [
        const SizedBox(height: AppSpacing.s8),
        body(),
        const SizedBox(height: AppSpacing.s4),
      ],
    ),
  );
}
