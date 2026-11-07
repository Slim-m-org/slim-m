// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pop-out window as the rest of the app sees it. The native side, which
/// touches Flutter's experimental windowing API, is chosen by conditional
/// export: it pulls in `dart:ffi` through the Linux controller, which a web
/// build cannot compile, so web gets a factory that always says no.
/// See docs/decisions/0040.
library;

import 'package:flutter/widgets.dart';

import '../desktop_window_port.dart' show ResizeEdge;

export 'popout_windowing_none.dart'
    if (dart.library.ffi) 'popout_windowing_native.dart';

/// A native window whose content is built in the main engine's widget tree.
abstract interface class PopOutWindowHandle {
  /// The view to hand `ViewAnchor`, rendering [child] in this window.
  Widget host(Widget child);

  void destroy();

  /// Hands the pointer to the window manager to move the window; only an
  /// undecorated window needs it, since a decorated one has its own title bar.
  void beginMove();

  void beginResize(ResizeEdge edge);

  /// Holds the window to [aspect] (width over height) through every resize, so the picture fills it with no bars.
  void fitAspect(double aspect);

  /// Keeps the window above every other one, as a pop-out should stay in view.
  Future<void> keepAbove();

  /// Whether the app draws the move area, resize edges and close button, because the OS draws none.
  bool get drawsOwnFrame;
}

/// The pop-out's own window title, distinct from the main window's, so a window manager script can find it.
const popOutWindowTitle = 'slim-m pop-out';

typedef PopOutWindowFactory =
    PopOutWindowHandle Function({
      required String title,
      required Size size,
      required bool decorated,
      required VoidCallback onCloseRequested,
    });
