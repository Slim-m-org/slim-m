// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel rail's own slot in `HomeShell`'s row: the rail at full or
/// compact width, or nothing at all, plus the handle that toggles between
/// the first two. Split out of `home_shell.dart`, which sits near this
/// repo's 500-line hard file limit.
///
/// [canvasFullscreen] is the one case where this slot goes to zero width
/// and nothing at all. Returned as a widget list, not a single wrapping
/// widget, so both children sit directly in `HomeShell`'s own `Row`.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'app_panel_reveal.dart';
import 'channel_rail.dart';
import 'rail_drag_handle.dart';

List<Widget> railSlot({
  required BuildContext context,
  required bool expanded,
  required bool canvasFullscreen,
  required double railWidth,
  bool dragging = false,
}) {
  final width = canvasFullscreen
      ? 0.0
      : expanded
      ? railWidth
      : ChannelRail.compactWidth;
  return [
    ClipRect(
      child: AnimatedContainer(
        // A drag moves the edge with the pointer; only a click to narrow or widen animates.
        duration: dragging
            ? Duration.zero
            : AppMotion.reduced(context, AppMotion.base),
        curve: AppMotion.entrance,
        width: width,
        child: canvasFullscreen
            ? const SizedBox.shrink()
            : OverflowBox(
                minWidth: width,
                maxWidth: width,
                alignment: Alignment.centerRight,
                child: const AppPanelReveal(
                  fromLeft: true,
                  child: ChannelRail(),
                ),
              ),
      ),
    ),
    if (!canvasFullscreen) RailDragHandle(railWidth: width),
  ];
}
