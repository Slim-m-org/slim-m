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
}

typedef PopOutWindowFactory =
    PopOutWindowHandle Function({
      required String title,
      required Size size,
      required bool decorated,
      required VoidCallback onCloseRequested,
    });
