// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A [DesktopWindowPort] with no window, no plugin channel, and no platform
/// behind it at all - shared across every desktop-shell test that needs one
/// rather than each rebuilding its own copy.
library;

import 'dart:async';

import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/desktop/window_geometry.dart';

class FakeDesktopWindowPort implements DesktopWindowPort {
  final _controller = StreamController<DesktopWindowEventKind>.broadcast();

  bool maximized = false;
  bool fullScreen = false;
  bool visible = true;
  WindowRect bounds = const WindowRect(x: 10, y: 10, width: 1280, height: 720);

  int hideCalls = 0;
  int focusCalls = 0;
  int minimizeCalls = 0;
  int maximizeCalls = 0;
  int unmaximizeCalls = 0;
  int startDraggingCalls = 0;
  int destroyCalls = 0;
  int showCalls = 0;
  int restoreCalls = 0;
  int centerCalls = 0;
  int hideTitleBarCalls = 0;
  final List<ResizeEdge> startResizingCalls = [];

  WindowSize? lastSize;
  WindowRect? lastBounds;
  bool? lastResizable;

  void emit(DesktopWindowEventKind kind) => _controller.add(kind);

  @override
  Stream<DesktopWindowEventKind> get events => _controller.stream;

  @override
  Future<WindowRect> getBounds() async => bounds;
  @override
  Future<bool> isMaximized() async => maximized;
  @override
  Future<bool> isFullScreen() async => fullScreen;
  @override
  Future<void> hide() async => hideCalls++;
  @override
  Future<void> minimize() async => minimizeCalls++;
  @override
  Future<void> maximize() async {
    maximizeCalls++;
    maximized = true;
  }

  @override
  Future<void> unmaximize() async {
    unmaximizeCalls++;
    maximized = false;
  }

  @override
  Future<void> startDragging() async => startDraggingCalls++;
  @override
  Future<void> startResizing(ResizeEdge edge) async =>
      startResizingCalls.add(edge);
  @override
  Future<void> destroy() async => destroyCalls++;

  @override
  bool canRelaunch = true;
  int relaunchCalls = 0;

  @override
  Future<void> relaunch() async => relaunchCalls++;

  @override
  Future<void> ensureInitialized() async {}
  @override
  Future<void> setBounds(WindowRect rect) async {
    lastBounds = rect;
    bounds = rect;
  }

  @override
  Future<void> setSize(WindowSize size) async => lastSize = size;

  WindowSize? lastMinimumSize;
  @override
  Future<void> setMinimumSize(WindowSize size) async => lastMinimumSize = size;
  @override
  Future<void> center() async => centerCalls++;
  @override
  Future<void> setFullScreen(bool value) async => fullScreen = value;
  @override
  Future<void> show() async => showCalls++;
  @override
  Future<void> focus() async => focusCalls++;
  @override
  Future<bool> isVisible() async => visible;
  @override
  Future<void> restore() async => restoreCalls++;
  @override
  Future<void> setPreventClose(bool value) async {}
  @override
  Future<void> hideTitleBar() async => hideTitleBarCalls++;
  @override
  Future<void> setResizable(bool value) async => lastResizable = value;
  @override
  Future<List<DisplayArea>> allDisplays() async => const [];
}
