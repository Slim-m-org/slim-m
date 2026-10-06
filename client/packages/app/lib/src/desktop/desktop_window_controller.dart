// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reacts to the window's own lifecycle: persists geometry on a settled
/// resize or move, and routes a close through [resolveCloseAction] rather
/// than letting the OS quit the process. One controller rather than two,
/// per decision 0012's framing - "one shape rather than three features".
library;

import 'dart:async';
import 'dart:math' as math;

import 'close_behavior.dart';
import 'desktop_window_port.dart';
import 'window_geometry.dart';
import 'window_geometry_store.dart';

/// How long to wait after the last resize/move event before writing, on the
/// assumption the drag has ended.
///
/// Only load-bearing on Linux: `window_manager`'s own `WindowListener` doc
/// comment marks `onWindowResized`/`onWindowMoved` (the settled variants)
/// `@platforms macos,windows` only, confirmed by reading the Linux plugin's
/// native source - it emits only the continuous `resize`/`move` events,
/// mapped from GTK's `check-resize` and `configure-event`, both of which
/// fire repeatedly across one drag. So on Linux this debounce is the only
/// thing standing in for a settled event the platform never reports.
const desktopGeometryDebounce = Duration(milliseconds: 500);

class DesktopWindowController {
  DesktopWindowController({
    required this.port,
    required this.store,
    required this.platform,
    required this.trayAvailable,
    this.onShow,
    this.debounce = desktopGeometryDebounce,
    bool geometryPersistenceEnabled = false,
  }) : _geometryPersistenceEnabled = geometryPersistenceEnabled;

  final DesktopWindowPort port;
  final WindowGeometryStore store;
  final DesktopPlatform platform;

  /// Queried live on every close, never cached - a tray host can appear or
  /// disappear mid-session, and a stale cached answer would be wrong in
  /// either direction. See decision 0012's own reasoning for why this is
  /// not a startup-time check.
  final Future<bool> Function() trayAvailable;

  /// Fired once per window-show, carrying whichever [CloseAction] the most
  /// recently routed close actually resolved to (null if this controller has
  /// never routed one yet) - not re-probed at show time, since the tray
  /// probe is live and could answer differently by then, and a caller
  /// describing what just happened has to describe the real resolved
  /// outcome rather than a fresh guess.
  final void Function(CloseAction? lastCloseAction)? onShow;

  final Duration debounce;

  /// Gates every actual write, checked inside [_writeNow] rather than
  /// [_scheduleWrite]: a debounced write is left free to schedule at any
  /// time, since it always re-reads live bounds when it fires, and rejecting
  /// it only at the point of persistence is what lets a write scheduled
  /// while this was false still land the correct geometry once it later
  /// fires true, rather than being lost for having been scheduled too
  /// early. False by default rather than true: a caller that forgets to
  /// call [enableGeometryPersistence] gets the safe behaviour - nothing
  /// persisted - rather than silently writing whatever the window's bounds
  /// happen to be at construction time, which is how PR #934 shipped a
  /// splash size into every user's saved geometry.
  bool _geometryPersistenceEnabled;

  Timer? _debounceTimer;
  StreamSubscription<DesktopWindowEventKind>? _subscription;
  CloseAction? _lastCloseAction;

  /// Flips [_geometryPersistenceEnabled] on, permanently, for the rest of
  /// this controller's life. [DesktopWindowShell.prepareHandoff] is the one
  /// caller, once the real window has actually been resized to its real
  /// geometry - not [DesktopWindowShell.revealAfterHandoff], which only
  /// shows a window that is by then already correctly sized. Before this
  /// runs, the window is either still the splash or mid-handoff to its real
  /// shape, and nothing observed before this call is the user's real
  /// windowed size.
  void enableGeometryPersistence() => _geometryPersistenceEnabled = true;

  void start() {
    _subscription = port.events.listen(_onEvent);
  }

  void dispose() {
    _debounceTimer?.cancel();
    _subscription?.cancel();
  }

  Future<void> _onEvent(DesktopWindowEventKind kind) async {
    switch (kind) {
      case DesktopWindowEventKind.resize:
        _scheduleWrite();
        await _holdMinimumSize();
      case DesktopWindowEventKind.move:
        _scheduleWrite();
      case DesktopWindowEventKind.maximize:
      case DesktopWindowEventKind.unmaximize:
      case DesktopWindowEventKind.fullScreen:
      case DesktopWindowEventKind.leaveFullScreen:
        await _writeNow();
      case DesktopWindowEventKind.close:
        await requestClose();
      case DesktopWindowEventKind.show:
        onShow?.call(_lastCloseAction);
    }
  }

  /// The one place "close" is actually carried out, reached both from the
  /// native close/delete-event and from the custom title bar's own close
  /// button once the native one no longer exists to trigger that event at
  /// all - a title-bar button that only called [DesktopWindowPort.hide]
  /// directly would skip the tray-availability fallback entirely, hiding
  /// the window with nothing to bring it back on a Linux desktop with no
  /// tray host registered.
  Future<void> requestClose() async {
    await _writeNow();
    await _routeClose();
  }

  bool _holdingMinimum = false;

  /// Sizes the window back up when a drag took it below the floor.
  ///
  /// The OS minimum is not honored everywhere, notably under Wayland, where a
  /// window can be dragged to a sliver and the layout overflows. Gated like
  /// persistence: the splash is deliberately smaller than the floor.
  Future<void> _holdMinimumSize() async {
    if (!_geometryPersistenceEnabled || _holdingMinimum) return;
    _holdingMinimum = true;
    try {
      if (await port.isMaximized() || await port.isFullScreen()) return;
      final bounds = await port.getBounds();
      final floor = WindowGeometry.minimumWindowSize;
      if (bounds.width >= floor.width && bounds.height >= floor.height) return;
      await port.setSize(
        WindowSize(
          width: math.max(bounds.width, floor.width),
          height: math.max(bounds.height, floor.height),
        ),
      );
    } finally {
      _holdingMinimum = false;
    }
  }

  void _scheduleWrite() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, _writeNow);
  }

  Future<void> _writeNow() async {
    _debounceTimer?.cancel();
    if (!_geometryPersistenceEnabled) return;
    await store.write(await _currentGeometry());
  }

  /// While maximized or fullscreen, [DesktopWindowPort.getBounds] answers
  /// with the maximized/fullscreen rectangle, not the windowed one - writing
  /// that as [WindowGeometry.windowedSize] would overwrite the very value a
  /// later "return to windowed" needs, so only [WindowRunState] moves and the
  /// previously stored windowed size and position are kept untouched.
  Future<WindowGeometry> _currentGeometry() async {
    final previous = store.read() ?? WindowGeometry.fallback;
    final maximized = await port.isMaximized();
    final fullscreen = await port.isFullScreen();
    if (maximized || fullscreen) {
      return previous.copyWith(
        runState: fullscreen
            ? WindowRunState.fullscreen
            : WindowRunState.maximized,
      );
    }
    final bounds = await port.getBounds();
    return WindowGeometry(
      windowedSize: WindowSize(width: bounds.width, height: bounds.height),
      position: bounds,
      runState: WindowRunState.windowed,
    );
  }

  Future<void> _routeClose() async {
    final action = resolveCloseAction(
      platform: platform,
      trayAvailable: await trayAvailable(),
    );
    _lastCloseAction = action;
    switch (action) {
      case CloseAction.hideToTray:
        await port.hide();
      case CloseAction.minimizeToTaskbar:
        await port.minimize();
    }
  }
}
