// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pop-out on Windows: a regular Win32 window from Flutter's experimental
/// windowing API, with the system's own title bar, so it needs no drag area
/// or resize edges of its own. See docs/decisions/0040.
library;

// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:ffi' as ffi;

import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_win32.dart';
import 'package:flutter/widgets.dart';

import '../desktop_window_port.dart' show ResizeEdge;
import 'popout_windowing.dart' show PopOutWindowHandle;

const _minSize = Size(240, 160);

class Win32PopOutWindow
    with RegularWindowControllerDelegate
    implements PopOutWindowHandle {
  Win32PopOutWindow({
    required String title,
    required Size size,
    required bool decorated,
    required this.onCloseRequested,
  }) {
    _controller = RegularWindowControllerWin32(
      owner: WidgetsBinding.instance.windowingOwner as WindowingOwnerWin32,
      size: size,
      constraints: BoxConstraints(
        minWidth: _minSize.width,
        minHeight: _minSize.height,
      ),
      title: title,
      resizable: true,
      delegate: this,
    );
  }

  final VoidCallback onCloseRequested;
  late final RegularWindowControllerWin32 _controller;

  @override
  void onWindowCloseRequested(RegularWindowController controller) =>
      onCloseRequested();

  @override
  Widget host(Widget child) =>
      RegularWindow(controller: _controller, child: child);

  @override
  void destroy() => _controller.destroy();

  @override
  bool get drawsOwnFrame => false;

  @override
  void beginMove() {}

  @override
  void beginResize(ResizeEdge edge) {}

  @override
  Future<void> keepAbove() async {
    _setWindowPos(
      _controller.windowHandle,
      _hwndTopmost,
      0,
      0,
      0,
      0,
      _swpNoSize | _swpNoMove | _swpNoActivate,
    );
  }
}

final _hwndTopmost = ffi.Pointer<ffi.Void>.fromAddress(-1);
const _swpNoSize = 0x0001;
const _swpNoMove = 0x0002;
const _swpNoActivate = 0x0010;

final _setWindowPos = ffi.DynamicLibrary.open('user32.dll')
    .lookupFunction<
      ffi.Int32 Function(
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<ffi.Void>,
        ffi.Int32,
        ffi.Int32,
        ffi.Int32,
        ffi.Int32,
        ffi.Uint32,
      ),
      int Function(
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<ffi.Void>,
        int,
        int,
        int,
        int,
        int,
      )
    >('SetWindowPos');
