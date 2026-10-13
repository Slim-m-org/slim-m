// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas pane's own minimal identity strip.
///
/// This used to be the canvas's entire toolbar - five tools, undo, the
/// overflow menu and close, all pinned across the top with the interactive
/// controls pushed to the far corner. The owner reported the flow did not
/// work: the controls sat far from the hand doing the drawing, and opening
/// the canvas during a call made the call's own controls disappear outright.
/// Both are fixed by moving every interactive control into `CanvasCallDock`,
/// a floating card near the bottom of the pane - see that file's own doc for
/// the full reasoning. What is left here is purely identity: an icon, a
/// label, and the screen-reader landmark `canvas_pane_semantics_test.dart`
/// already depends on. Nothing here is a button.
///
/// The label used to say only "Canvas", dropped as a side effect of that
/// same pass rather than a considered choice: with several voice channels
/// each carrying their own canvas, alt-tabbing back gave no way to tell
/// which one this was, unlike the voice call header beside it. [channelId]
/// resolves the channel's own name through `channelByIdProvider`, the same
/// row `CallChannelName` reads, so a DM's canvas names its peer the
/// identical way `_DmCallBar` already does.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/call_header_facts.dart';

class CanvasBar extends StatelessWidget {
  const CanvasBar({super.key, required this.channelId, this.trailing});

  final String channelId;

  /// Undo, the overflow and close at phone width; null where the dock has them.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final trailing = this.trailing;
    final line = CallHeaderLine(
      channelId: channelId,
      mode: 'Canvas',
      stacked: trailing != null,
      leading: Padding(
        padding: const EdgeInsets.only(right: AppSpacing.s8),
        child: Icon(
          AppIcons.canvas,
          size: AppSizes.icon16,
          color: tokens.textSecondary,
        ),
      ),
    );
    return Container(
      height: trailing == null
          ? AppSizes.headerBar
          : AppSizes.rowTouch + AppSpacing.s8,
      padding: const EdgeInsets.symmetric(horizontal: AppSizes.paneGutter),
      alignment: Alignment.centerLeft,
      // Raised off the drawing surface so the strip reads as a pane header, not canvas.
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
      ),
      child: trailing == null
          ? line
          : Row(
              children: [
                Expanded(child: line),
                const SizedBox(width: AppSpacing.s8),
                trailing,
              ],
            ),
    );
  }
}
