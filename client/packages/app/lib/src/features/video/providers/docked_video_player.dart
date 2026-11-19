// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A player that draws in a native view floating over the Flutter window,
/// placed by the docked panel.
library;

import 'embedded_video_player.dart';

/// A rect in logical pixels, relative to the Flutter view's top left.
typedef NativeViewRect = ({double x, double y, double width, double height});

abstract interface class DockedVideoPlayer implements EmbeddedVideoPlayer {
  Future<void> setBounds(NativeViewRect rect);

  /// Hidden while something Flutter draws (a menu, a dialog) would overlap
  /// it, since a native view always paints on top.
  Future<void> setVisible(bool visible);

  /// Takes the page out of fullscreen, when the window left it first.
  Future<void> exitFullscreen();
}
