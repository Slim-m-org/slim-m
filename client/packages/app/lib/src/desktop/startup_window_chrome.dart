// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The splash's own way to move its window.
///
/// The Linux splash hides the native title bar, and the real `TitleBar` does
/// not exist until bootstrap finishes, so without this the window cannot be
/// dragged for the whole load. It deliberately has no close button.
library;

import 'package:flutter/material.dart';

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
      ],
    ),
  );
}
