// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one file that touches Flutter's experimental windowing API.
///
/// Everything else in the app sees [PopOutWindowHandle], so a breaking change
/// in the framework's `_window.dart` lands here and nowhere else. The API only
/// works when the Linux build injects the `windowing` feature flag; see
/// `linux/flutter/CMakeLists.txt` and docs/decisions/0040.
library;

// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'package:flutter/foundation.dart' show VoidCallback, kIsWeb;
import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_linux.dart';
import 'package:flutter/widgets.dart';
import 'package:slimm_platform/platform.dart' show isLinuxHost;

import '../desktop_window_port.dart' show ResizeEdge;
import 'popout_gtk_drag.dart';
import 'popout_windowing.dart' show PopOutWindowFactory, PopOutWindowHandle;

/// Null wherever a pop-out cannot be offered: web, every platform whose build
/// does not carry the windowing flag, and a Linux build made without it.
PopOutWindowFactory? nativePopOutWindowFactory() {
  if (kIsWeb || !isLinuxHost || !isWindowingEnabled) return null;
  return _NativePopOutWindow.new;
}

const _minSize = Size(240, 160);

class _NativePopOutWindow
    with RegularWindowControllerDelegate
    implements PopOutWindowHandle {
  _NativePopOutWindow({
    required String title,
    required Size size,
    required bool decorated,
    required this.onCloseRequested,
  }) {
    // The public factory has no decorated option; the Linux controller does.
    _controller = RegularWindowControllerLinux(
      owner: WidgetsBinding.instance.windowingOwner as WindowingOwnerLinux,
      size: size,
      decorated: decorated,
      constraints: BoxConstraints(
        minWidth: _minSize.width,
        minHeight: _minSize.height,
      ),
      title: title,
      delegate: this,
    );
  }

  final VoidCallback onCloseRequested;
  late final RegularWindowControllerLinux _controller;
  late final _drag = GtkWindowDrag(_controller.windowHandle);

  @override
  void onWindowCloseRequested(RegularWindowController controller) =>
      onCloseRequested();

  @override
  Widget host(Widget child) =>
      RegularWindow(controller: _controller, child: child);

  @override
  void destroy() => _controller.destroy();

  @override
  void beginMove() => _drag.move();

  @override
  void beginResize(ResizeEdge edge) => _drag.resize(edge);
}
