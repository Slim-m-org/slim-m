// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Windows' half of the experimental windowing API: the main window and the
/// pop-out. The engine there renders only windows made from Dart, so the
/// runner leaves the main one to [claimNativeMainWindow] too; see
/// `windows/runner/main_window.h` and docs/decisions/0040.
library;

// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:ui' show AppExitType;

import 'package:flutter/foundation.dart' show VoidCallback, kIsWeb;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_win32.dart';
import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_platform/platform.dart' show isWindowsHost;

import '../desktop_window_port.dart' show ResizeEdge;
import 'popout_windowing.dart' show NativeMainWindow, PopOutWindowHandle;

/// user32's `SetWindowPos`.
typedef SetWindowPos =
    int Function(
      HWND window,
      HWND insertAfter,
      int x,
      int y,
      int width,
      int height,
      int flags,
    );

SetWindowPos _user32SetWindowPos() =>
    ffi.DynamicLibrary.open('user32.dll').lookupFunction<
      ffi.Int32 Function(
        HWND,
        HWND,
        ffi.Int32,
        ffi.Int32,
        ffi.Int32,
        ffi.Int32,
        ffi.Uint32,
      ),
      SetWindowPos
    >('SetWindowPos');

/// `HWND_TOPMOST`, which is `(HWND)-1`.
final hwndTopmost = HWND.fromAddress(-1);

/// SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE: change the z-order only.
const swpZOrderOnly = 0x0001 | 0x0002 | 0x0010;

const _minSize = Size(240, 160);

const _mainWindowChannel = MethodChannel('top.npcserver.slimm/main_window');

/// The runner's window had this size and title before Dart made it.
const _mainWindowSize = Size(1280, 720);
const _mainWindowTitle = 'slim-m';

/// Creates the main window and lets the runner register the plugins against
/// it; null wherever the runner makes the main window itself. Runs first in
/// `main`, since no plugin answers before it returns.
Future<NativeMainWindow?> claimNativeMainWindow() async {
  if (kIsWeb || !isWindowingEnabled || !isWindowsHost) return null;
  final window = _Win32MainWindow();
  await _mainWindowChannel.invokeMethod<void>('ready');
  return window;
}

class _Win32MainWindow
    with RegularWindowControllerDelegate
    implements NativeMainWindow {
  _Win32MainWindow() {
    _controller = RegularWindowControllerWin32(
      owner: WidgetsBinding.instance.windowingOwner as WindowingOwnerWin32,
      delegate: this,
      size: _mainWindowSize,
      title: _mainWindowTitle,
      resizable: true,
    );
    // runApp draws into the implicit view, so the main window must be it.
    assert(
      _controller.rootView ==
          WidgetsBinding.instance.platformDispatcher.implicitView,
    );
  }

  late final RegularWindowControllerWin32 _controller;

  @override
  VoidCallback? onCloseRequested;

  /// The runner shows the window on the next drawn frame, so one is asked for.
  @override
  Future<void> reveal() async {
    await _mainWindowChannel.invokeMethod<void>('reveal');
    SchedulerBinding.instance.scheduleForcedFrame();
  }

  @override
  void onWindowCloseRequested(RegularWindowController controller) {
    final handler = onCloseRequested;
    if (handler != null) return handler();
    unawaited(ServicesBinding.instance.exitApplication(AppExitType.required));
  }
}

/// The [PopOutWindowFactory] for Windows. The Win32 controller has no
/// undecorated window, so [decorated] is ignored and the OS draws the frame;
/// the runner keeps its minimum size (`popout_window_proc.cpp`).
PopOutWindowHandle openWin32PopOutWindow({
  required String title,
  required Size size,
  required bool decorated,
  required VoidCallback onCloseRequested,
}) {
  final delegate = _CloseDelegate(onCloseRequested);
  final controller = RegularWindowControllerWin32(
    owner: WidgetsBinding.instance.windowingOwner as WindowingOwnerWin32,
    delegate: delegate,
    size: size,
    title: title,
    resizable: true,
  );
  AppLog.debug(
    LogTag.platform,
    'Pop-out opened: view ${controller.rootView.viewId}, phase '
    '${SchedulerBinding.instance.schedulerPhase.name}',
  );
  return Win32PopOutWindow(
    controller,
    windowHandle: () => controller.windowHandle,
  );
}

class _CloseDelegate with RegularWindowControllerDelegate {
  _CloseDelegate(this.onCloseRequested);

  final VoidCallback onCloseRequested;

  @override
  void onWindowCloseRequested(RegularWindowController controller) =>
      onCloseRequested();
}

/// A pop-out on Windows; [windowHandle] and [setWindowPos] are seams for tests.
class Win32PopOutWindow implements PopOutWindowHandle {
  Win32PopOutWindow(
    this._controller, {
    required HWND Function() windowHandle,
    SetWindowPos? setWindowPos,
    void Function(VoidCallback) defer = Timer.run,
  }) : _windowHandle = windowHandle,
       _setWindowPos = setWindowPos,
       _defer = defer;

  final RegularWindowController _controller;
  final HWND Function() _windowHandle;
  final void Function(VoidCallback) _defer;
  SetWindowPos? _setWindowPos;
  double? _aspect;
  bool _destroyed = false;

  @override
  Widget host(Widget child) =>
      RegularWindow(controller: _controller, child: child);

  @override
  void destroy() {
    _destroyed = true;
    _controller.destroy();
  }

  @override
  void beginMove() {}

  @override
  void beginResize(ResizeEdge edge) {}

  /// Win32 has no aspect hint like GTK's, so the height is matched to the
  /// width once for each new shape; a user's own resize is left alone. The
  /// resize waits for the frame that reported the shape to end, since Windows
  /// sizes a view by waiting on a frame of the new size.
  @override
  void fitAspect(double aspect) {
    if (!aspect.isFinite || aspect <= 0) return;
    final last = _aspect;
    if (last != null && (aspect - last).abs() < last * 0.01) return;
    _aspect = aspect;
    _defer(() {
      if (_destroyed) return;
      final width = _controller.contentSize.width;
      final height = width / aspect;
      _controller.setSize(
        Size(width, height < _minSize.height ? _minSize.height : height),
      );
    });
  }

  @override
  bool get drawsOwnFrame => false;

  @override
  Future<void> keepAbove() async {
    final setWindowPos = _setWindowPos ??= _user32SetWindowPos();
    setWindowPos(_windowHandle(), hwndTopmost, 0, 0, 0, 0, swpZOrderOnly);
  }
}
