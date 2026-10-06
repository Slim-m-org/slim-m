// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one seam between this app's own window-shell logic and the real
/// `window_manager`/`screen_retriever` plugins, so [DesktopWindowController]
/// and [DesktopWindowShell] can be driven by a fake in a `flutter test` with
/// no real window ever created - decision 0012's own rule for what must stay
/// automatable with no display involved.
library;

import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:screen_retriever/screen_retriever.dart' as sr;
import 'package:window_manager/window_manager.dart' as wm;

import 'relaunch.dart';
import 'window_geometry.dart';

/// The window-lifecycle events this app reacts to, named after
/// `window_manager`'s own event strings rather than invented fresh, so a
/// real event maps onto this enum with no ambiguity.
enum DesktopWindowEventKind {
  close,
  resize,
  move,
  maximize,
  unmaximize,
  fullScreen,
  leaveFullScreen,
  show,
}

/// The eight edges and corners a hand-rolled resize border can grab, named
/// after `window_manager`'s own `ResizeEdge` so this port's type maps onto
/// the real one with no ambiguity - the same shape [DesktopWindowEventKind]
/// already uses for window events.
enum ResizeEdge {
  top,
  bottom,
  left,
  right,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

abstract interface class DesktopWindowPort {
  Future<void> ensureInitialized();

  /// Every event this port ever reports, in arrival order. A real window
  /// manager can fire [DesktopWindowEventKind.resize]/[DesktopWindowEventKind.move]
  /// continuously across one drag - see the decision record's own finding
  /// that Linux has no settled variant - so a caller wanting "once the drag
  /// ends" debounces this stream itself rather than trusting one event.
  Stream<DesktopWindowEventKind> get events;

  Future<WindowRect> getBounds();
  Future<void> setBounds(WindowRect rect);
  Future<void> setSize(WindowSize size);

  /// The smallest the user may drag this window, so a desktop can never be
  /// sized into the phone layout. See [kDesktopMinimumWindowSize].
  Future<void> setMinimumSize(WindowSize size);
  Future<void> center();
  Future<bool> isMaximized();
  Future<void> maximize();
  Future<void> unmaximize();
  Future<bool> isFullScreen();
  Future<void> setFullScreen(bool value);
  Future<void> hide();
  Future<void> show();

  /// Raises the window and gives it input focus - `window_manager`'s own
  /// `focus`, distinct from [show]: a hidden window needs [show] first, but
  /// a visible one merely buried behind another app or lacking focus needs
  /// only this. `IncomingCallOverlay` calls both, in that order, so a ring
  /// reaches the user whether the window is minimized, hidden, or simply
  /// not the one with focus.
  Future<void> focus();
  Future<bool> isVisible();
  Future<void> minimize();
  Future<void> restore();
  Future<void> setPreventClose(bool value);
  Future<void> hideTitleBar();
  Future<void> setResizable(bool value);
  Future<void> startDragging();

  /// Begins a native edge/corner resize drag, the [ResizeEdge] counterpart
  /// to [startDragging] - `gtk_window_begin_resize_drag` under the hood on
  /// Linux, so the compositor drives the resize rather than this app
  /// repositioning the frame itself from Dart.
  Future<void> startResizing(ResizeEdge edge);
  Future<List<DisplayArea>> allDisplays();

  /// A real quit, bypassing whatever [setPreventClose] currently holds - the
  /// tray/Dock menu's own "Quit" item, since ordinary close no longer does.
  Future<void> destroy();

  /// Whether [relaunch] has an honest implementation here; see `relaunch.dart`.
  bool get canRelaunch;

  /// [destroy], with a fresh copy of the app starting once this process is gone.
  Future<void> relaunch();
}

/// The real implementation, a thin adapter with no logic of its own beyond
/// type conversion - every actual decision lives in [DesktopWindowController]
/// and [DesktopWindowShell], which take this as an interface precisely so
/// none of their own logic has to run against the real plugin to be tested.
class WindowManagerDesktopWindowPort
    with wm.WindowListener
    implements DesktopWindowPort {
  final _events = _EventStream();
  bool _initialized = false;

  @override
  Stream<DesktopWindowEventKind> get events => _events.stream;

  /// Idempotent: [DesktopWindowShell] calls this from both its geometry-apply
  /// step and its listener/tray-registration step, sharing one port instance
  /// so the native listener is registered exactly once regardless of how
  /// many times initialization is asked for.
  @override
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    await wm.windowManager.ensureInitialized();
    wm.windowManager.addListener(this);
  }

  @override
  void onWindowClose() => _events.add(DesktopWindowEventKind.close);
  @override
  void onWindowResize() => _events.add(DesktopWindowEventKind.resize);
  @override
  void onWindowMove() => _events.add(DesktopWindowEventKind.move);
  @override
  void onWindowMaximize() => _events.add(DesktopWindowEventKind.maximize);
  @override
  void onWindowUnmaximize() => _events.add(DesktopWindowEventKind.unmaximize);

  /// Un-minimising emits `restore`, never `show`, and the controller reads
  /// `show` as the window coming back.
  @override
  void onWindowRestore() => _events.add(DesktopWindowEventKind.show);

  @override
  void onWindowEnterFullScreen() =>
      _events.add(DesktopWindowEventKind.fullScreen);
  @override
  void onWindowLeaveFullScreen() =>
      _events.add(DesktopWindowEventKind.leaveFullScreen);

  /// `WindowListener` carries no `onWindowShow`/`onWindowHide` slots of its
  /// own - only its catch-all does, since the Dart map wiring every other
  /// slot never mapped those two names; see `window_manager.dart`'s own
  /// `_methodCallHandler`.
  @override
  void onWindowEvent(String eventName) {
    if (eventName == 'show') _events.add(DesktopWindowEventKind.show);
  }

  @override
  Future<WindowRect> getBounds() async {
    final bounds = await wm.windowManager.getBounds();
    return WindowRect(
      x: bounds.left,
      y: bounds.top,
      width: bounds.width,
      height: bounds.height,
    );
  }

  @override
  Future<void> setBounds(WindowRect rect) => wm.windowManager.setBounds(
    null,
    position: Offset(rect.x, rect.y),
    size: Size(rect.width, rect.height),
  );

  @override
  Future<void> setSize(WindowSize size) =>
      wm.windowManager.setSize(Size(size.width, size.height));

  @override
  Future<void> setMinimumSize(WindowSize size) =>
      wm.windowManager.setMinimumSize(Size(size.width, size.height));

  @override
  Future<void> center() => wm.windowManager.center();

  @override
  Future<bool> isMaximized() => wm.windowManager.isMaximized();

  @override
  Future<void> maximize() => wm.windowManager.maximize();

  @override
  Future<void> unmaximize() => wm.windowManager.unmaximize();

  @override
  Future<bool> isFullScreen() => wm.windowManager.isFullScreen();

  @override
  Future<void> setFullScreen(bool value) =>
      wm.windowManager.setFullScreen(value);

  @override
  Future<void> hide() => wm.windowManager.hide();

  @override
  Future<void> show() => wm.windowManager.show();

  @override
  Future<void> focus() => wm.windowManager.focus();

  @override
  Future<bool> isVisible() => wm.windowManager.isVisible();

  @override
  Future<void> minimize() => wm.windowManager.minimize();

  @override
  Future<void> restore() => wm.windowManager.restore();

  @override
  Future<void> setPreventClose(bool value) =>
      wm.windowManager.setPreventClose(value);

  @override
  Future<void> hideTitleBar() => wm.windowManager.setTitleBarStyle(
    wm.TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );

  @override
  Future<void> setResizable(bool value) => wm.windowManager.setResizable(value);

  @override
  Future<void> startDragging() => wm.windowManager.startDragging();

  @override
  Future<void> startResizing(ResizeEdge edge) =>
      wm.windowManager.startResizing(_toPluginEdge(edge));

  @override
  Future<void> destroy() => wm.windowManager.destroy();

  @override
  bool get canRelaunch => canRelaunchThisProcess();

  @override
  Future<void> relaunch() async {
    await spawnRelaunch();
    await destroy();
  }

  @override
  Future<List<DisplayArea>> allDisplays() async {
    final displays = await sr.ScreenRetriever.instance.getAllDisplays();
    return displays
        .map(
          (display) => DisplayArea(
            x: display.visiblePosition?.dx ?? 0,
            y: display.visiblePosition?.dy ?? 0,
            width: (display.visibleSize ?? display.size).width,
            height: (display.visibleSize ?? display.size).height,
          ),
        )
        .toList(growable: false);
  }
}

/// [ResizeEdge] and `window_manager`'s own `ResizeEdge` are deliberately two
/// separate enums (this port's whole point), so every call site needs this
/// one explicit mapping rather than a cast.
wm.ResizeEdge _toPluginEdge(ResizeEdge edge) => switch (edge) {
  ResizeEdge.top => wm.ResizeEdge.top,
  ResizeEdge.bottom => wm.ResizeEdge.bottom,
  ResizeEdge.left => wm.ResizeEdge.left,
  ResizeEdge.right => wm.ResizeEdge.right,
  ResizeEdge.topLeft => wm.ResizeEdge.topLeft,
  ResizeEdge.topRight => wm.ResizeEdge.topRight,
  ResizeEdge.bottomLeft => wm.ResizeEdge.bottomLeft,
  ResizeEdge.bottomRight => wm.ResizeEdge.bottomRight,
};

/// A plain broadcast wrapper so the port's own class does not have to manage
/// a `StreamController`'s lifecycle inline with everything else it does.
class _EventStream {
  final _controller = StreamController<DesktopWindowEventKind>.broadcast();
  Stream<DesktopWindowEventKind> get stream => _controller.stream;
  void add(DesktopWindowEventKind event) => _controller.add(event);
}
