// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The splash's own way to move and close its window.
///
/// The Linux splash hides the native title bar, and the real `TitleBar` does
/// not exist until bootstrap finishes, so without this the window can be
/// neither dragged nor closed for the whole load.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'desktop_window_port.dart';
import 'title_bar.dart' show titleBarHeight;

class StartupWindowChrome extends StatelessWidget {
  const StartupWindowChrome({super.key, required this.port});

  final DesktopWindowPort port;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: titleBarHeight,
    child: Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: const ValueKey('startup-drag-region'),
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => port.startDragging(),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: AppSpacing.s4),
            // destroy, not close: no close-to-tray handler exists this early.
            child: AppIconButton(
              icon: AppIcons.windowClose,
              semanticLabel: 'Close',
              size: AppIconButtonSize.sm,
              variant: AppIconButtonVariant.dangerGhost,
              onPressed: port.destroy,
            ),
          ),
        ),
      ],
    ),
  );
}
