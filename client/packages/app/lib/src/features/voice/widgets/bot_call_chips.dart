// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One chip per bot on the call, for a dock too small to show the controls
/// themselves. A tap opens them as a sheet (docs/design/desktop-vs-mobile.md,
/// rule 1: menus become sheets on a compact window).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/control_options_menu.dart';
import '../../../widgets/control_swatch_row.dart' show ControlOptionEntry;
import 'bot_call_controls.dart';
import 'call_dock_button.dart';

/// How many chips [botCallChipsFor] draws for [channelId], for the dock's fit check.
int botCallChipCount(WidgetRef ref, String channelId) =>
    botCallGroupsFor(ref, channelId).length;

/// The same bot controls as mic-menu rows, for a dock with no slot for the chips.
List<ControlOptionEntry> botCallMenuOptions(WidgetRef ref, String channelId) =>
    [
      for (final group in botCallGroupsFor(ref, channelId))
        ControlOption(
          label: '${group.bot.botDisplayName} controls',
          icon: AppIcons.callControl,
          onSelected: () => showBotControlsSheet(
            context: ref.context,
            channelId: channelId,
            botUserId: group.bot.botUserId,
          ),
        ),
    ];

/// The chips, or null when no bot on the call offers controls.
Widget? botCallChipsFor(WidgetRef ref, String channelId) {
  final groups = botCallGroupsFor(ref, channelId);
  if (groups.isEmpty) return null;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < groups.length; i++) ...[
        if (i > 0) const SizedBox(width: AppSpacing.s8),
        CallDockButton(
          icon: AppIcons.callControl,
          tooltip: '${groups[i].bot.botDisplayName} controls',
          active: false,
          onPressed: () => showBotControlsSheet(
            context: ref.context,
            channelId: channelId,
            botUserId: groups[i].bot.botUserId,
          ),
        ),
      ],
    ],
  );
}

/// The sheet follows the call: it closes itself once its bot leaves.
Future<void> showBotControlsSheet({
  required BuildContext context,
  required String channelId,
  required String botUserId,
}) => showAppSheet<void>(
  context,
  builder: (_) => Consumer(
    builder: (sheetContext, ref, _) {
      final groups = [
        for (final g in botCallGroupsFor(ref, channelId))
          if (g.bot.botUserId == botUserId) g,
      ];
      if (groups.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (sheetContext.mounted) Navigator.of(sheetContext).pop();
        });
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s16,
          AppSpacing.s8,
          AppSpacing.s16,
          AppSpacing.s16,
        ),
        child: BotCallControls(channelId: channelId, groups: groups),
      );
    },
  ),
);
