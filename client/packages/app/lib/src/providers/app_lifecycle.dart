// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The app's lifecycle state as one provider, so a widget that animates for
/// its own sake can stop when nobody is looking without registering its own
/// observer. `resumed` is the only state in which the window is focused and
/// visible: desktop embedders report `inactive` for an unfocused window and
/// `hidden` for a minimised one, and a phone's `inactive`/`paused` cover the
/// same ground.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_platform/platform.dart';

import '../desktop/desktop_window_port.dart';
import '../desktop/desktop_window_shell.dart';

/// Whether this build runs on a phone, where an embedder that has not yet
/// reported a state means a background launch rather than a window waiting to
/// open. A provider so a test can pick either side; `isDesktopHost` is always
/// true under `flutter test`.
final mobileLifecycleHostProvider = Provider<bool>(
  (ref) => isIOSHost || isAndroidHost,
);

class AppLifecycleNotifier extends StateNotifier<AppLifecycleState>
    with WidgetsBindingObserver {
  /// A state the embedder has not reported counts as hidden on a phone, so a
  /// process woken in the background never claims the user is looking at it.
  AppLifecycleNotifier({
    required bool mobile,
    required Stream<DesktopWindowEventKind> windowEvents,
    bool Function()? inTray,
    bool Function()? suspended,
    Future<bool> Function()? stillMinimized,
  }) : _inTray = inTray ?? _never,
       _suspended = suspended ?? _never,
       _stillMinimized = stillMinimized,
       _bindingState =
           WidgetsBinding.instance.lifecycleState ??
           (mobile ? AppLifecycleState.hidden : AppLifecycleState.resumed),
       super(
         WidgetsBinding.instance.lifecycleState ??
             (mobile ? AppLifecycleState.hidden : AppLifecycleState.resumed),
       ) {
    WidgetsBinding.instance.addObserver(this);
    _windowEvents = windowEvents.listen(_onWindowEvent);
    // One made while the window is already in the tray or suspended starts hidden.
    _publish();
  }

  static bool _never() => false;

  /// Asked of the window each time, never remembered: every account has a
  /// notifier of its own, and one made after the hide would not have seen it.
  final bool Function() _inTray;

  /// The compositor's own word that it is not painting the window, asked each
  /// time for the same reason. The one sign of a minimise on Wayland.
  final bool Function() _suspended;

  /// Asks the window whether it is minimised; null when nothing can answer.
  final Future<bool> Function()? _stillMinimized;
  AppLifecycleState _bindingState;
  bool _windowMinimized = false;
  bool _blurred = false;
  bool _focusHeld = false;
  StreamSubscription<DesktopWindowEventKind>? _windowEvents;

  bool get _knownHidden => _windowMinimized || _inTray() || _suspended();

  /// Whether a focus event could be Windows activating a window it left minimised.
  bool get _mayBeMinimized =>
      _stillMinimized != null &&
      (_windowMinimized || !isWindowVisible(_bindingState));

  void _publish() {
    if (!mounted) return;
    if (_knownHidden) {
      state = AppLifecycleState.hidden;
    } else if (_blurred && _bindingState == AppLifecycleState.resumed) {
      state = AppLifecycleState.inactive;
    } else {
      state = _bindingState;
    }
  }

  /// The embedder moving from hidden to on screen also ends a minimise: a
  /// window restored without focus reports only `inactive`, and Windows sends
  /// no restore event for a maximised one.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cameBack = !isWindowVisible(_bindingState) && isWindowVisible(state);
    _bindingState = state;
    _blurred = false;
    if (state == AppLifecycleState.resumed || cameBack) {
      _windowMinimized = false;
    }
    _publish();
  }

  /// A window event that proves the window is on screen wins over a stale
  /// embedder, except while the app itself holds the window in the tray:
  /// opening the tray menu on Windows focuses the hidden window.
  void _onWindowEvent(DesktopWindowEventKind kind) {
    if (kind == DesktopWindowEventKind.blur) _focusHeld = false;
    switch (kind) {
      case DesktopWindowEventKind.hide ||
          DesktopWindowEventKind.suspend ||
          DesktopWindowEventKind.unsuspend:
        break;
      case DesktopWindowEventKind.minimize:
        _windowMinimized = true;
        _focusHeld = false;
      // A focus that came just ahead of the restore, while the window still said minimised, counts now.
      case DesktopWindowEventKind.show when !_inTray():
        _windowMinimized = false;
        _correctBinding(focused: _focusHeld);
      case DesktopWindowEventKind.maximize || DesktopWindowEventKind.unmaximize
          when _windowMinimized && !_inTray():
        _windowMinimized = false;
        _correctBinding(focused: _focusHeld);
      case DesktopWindowEventKind.focus when !_inTray():
        _focusHeld = true;
        if (_mayBeMinimized) return unawaited(_focusIfRestored());
        _windowMinimized = false;
        _correctBinding(focused: true);
      // Provider only: a pop-out window taking focus must not park the whole app's focus.
      case DesktopWindowEventKind.blur when !_knownHidden:
        _blurred = true;
      default:
        return;
    }
    _publish();
  }

  /// A focus event alone does not end a minimise: the window is asked, and a
  /// blur in the meantime leaves it on screen but unfocused.
  Future<void> _focusIfRestored() async {
    final minimized = await _askMinimized();
    if (!mounted || minimized != false || _inTray()) return;
    _windowMinimized = false;
    _correctBinding(focused: _focusHeld);
    if (!_focusHeld) _blurred = true;
    _publish();
  }

  /// Null while the window cannot answer. Any other failure believes the
  /// focus, so a broken query never leaves a focused window paused.
  Future<bool?> _askMinimized() async {
    try {
      return await _stillMinimized!();
    } on WindowNotQueryable {
      return null;
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'Could not ask the window whether it is minimised; trusting the focus',
        error,
        stack,
      );
      return false;
    }
  }

  /// Brings Flutter's own state up to what the window just proved. The
  /// provider alone is not enough: the scheduler draws no frame while the
  /// binding still says hidden, so nothing would repaint.
  void _correctBinding({required bool focused}) {
    if (focused) {
      _blurred = false;
      return _moveBinding(AppLifecycleState.resumed);
    }
    if (!isWindowVisible(_bindingState)) {
      _moveBinding(AppLifecycleState.inactive);
    }
  }

  /// Walks the binding to [target] one step at a time, the only moves
  /// `AppLifecycleListener` accepts.
  void _moveBinding(AppLifecycleState target) {
    const order = [
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ];
    final binding = WidgetsBinding.instance;
    final current = binding.lifecycleState;
    var at = current == null ? -1 : order.indexOf(current);
    final to = order.indexOf(target);
    while (at >= 0 && at != to) {
      at += at < to ? 1 : -1;
      binding.handleAppLifecycleStateChanged(order[at]);
    }
    _bindingState = target;
  }

  @override
  void dispose() {
    unawaited(_windowEvents?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final appLifecycleProvider =
    StateNotifierProvider<AppLifecycleNotifier, AppLifecycleState>((ref) {
      final port = ref.read(desktopWindowShellProvider).port;
      return AppLifecycleNotifier(
        mobile: ref.watch(mobileLifecycleHostProvider),
        windowEvents: port.events,
        inTray: () => port.hiddenByApp,
        suspended: () => port.suspendedByCompositor,
        stillMinimized: port.isMinimized,
      );
    });

/// Whether the window is focused and visible right now.
///
/// A selection of the notifier rather than a provider of its own, so a
/// listener hears it at once: a derived provider is only recomputed on a
/// frame, and a hidden window draws none. See `docs/window-states.md`.
final appFocusedProvider = appLifecycleProvider.select(
  (state) => state == AppLifecycleState.resumed,
);

/// Whether the window is on screen, focused or not: a desktop window behind
/// another app reports `inactive` and is still being watched, say mid-call.
bool isWindowVisible(AppLifecycleState state) =>
    state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

final appVisibleProvider = appLifecycleProvider.select(isWindowVisible);

/// Whether a timer-driven refresh of [context] would be seen: the window is on
/// screen, focused or not, and no route or tab above it has turned tickers off.
bool isSeenNow(BuildContext context) {
  final container = ProviderScope.containerOf(context, listen: false);
  return isWindowVisible(container.read(appLifecycleProvider)) &&
      TickerMode.valuesOf(context).enabled;
}

/// The container [context] sits under, or null for a widget mounted bare, as
/// a test of one widget does. For a plain `State` that follows the window.
ProviderContainer? windowScopeOf(BuildContext context) {
  final scope = context
      .getElementForInheritedWidgetOfExactType<UncontrolledProviderScope>();
  return (scope?.widget as UncontrolledProviderScope?)?.container;
}

/// Whether a phone has left the screen; a desktop window never counts, and
/// `inactive` is only a pulled shade.
bool isBackgroundedOnPhone(AppLifecycleState state, {required bool mobile}) =>
    mobile &&
    (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached);
