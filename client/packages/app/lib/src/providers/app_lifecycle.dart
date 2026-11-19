// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The app's lifecycle state as one provider, so a widget that animates for
/// its own sake can stop when nobody is looking without registering its own
/// observer. `resumed` is the only state in which the window is focused and
/// visible: desktop embedders report `inactive` for an unfocused window and
/// `hidden` for a minimised one, and a phone's `inactive`/`paused` cover the
/// same ground.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import '../desktop/desktop_window_port.dart';
import '../desktop/desktop_window_shell.dart';
import '../desktop/display_server.dart';

/// Whether this build runs on a phone, where an embedder that has not yet
/// reported a state means a background launch rather than a window waiting to
/// open. A provider so a test can pick either side; `isDesktopHost` is always
/// true under `flutter test`.
final mobileLifecycleHostProvider = Provider<bool>(
  (ref) => isIOSHost || isAndroidHost,
);

/// How often to look for a frame that was asked for and never drawn, or null
/// to not look. Only a Wayland session needs it: a minimised window gets no
/// state change there, only no frames. See `docs/window-states.md`.
final frameStallCheckProvider = Provider<Duration?>(
  (ref) =>
      isLinuxHost &&
          isWaylandSession(Platform.environment) &&
          !Platform.environment.containsKey('FLUTTER_TEST')
      ? const Duration(seconds: 1)
      : null,
);

/// Checks in a row that must find the same frame undrawn before the window counts as hidden.
const frameStallChecks = 3;

class AppLifecycleNotifier extends StateNotifier<AppLifecycleState>
    with WidgetsBindingObserver {
  /// A state the embedder has not reported counts as hidden on a phone, so a
  /// process woken in the background never claims the user is looking at it.
  AppLifecycleNotifier({
    required bool mobile,
    required Stream<DesktopWindowEventKind> windowEvents,
    Duration? frameStallCheck,
  }) : _bindingState =
           WidgetsBinding.instance.lifecycleState ??
           (mobile ? AppLifecycleState.hidden : AppLifecycleState.resumed),
       super(
         WidgetsBinding.instance.lifecycleState ??
             (mobile ? AppLifecycleState.hidden : AppLifecycleState.resumed),
       ) {
    WidgetsBinding.instance.addObserver(this);
    _windowEvents = windowEvents.listen(_onWindowEvent);
    if (frameStallCheck != null) {
      SchedulerBinding.instance.addPersistentFrameCallback(_onFrameDrawn);
      _stallCheck = Timer.periodic(frameStallCheck, (_) => _checkFrameStall());
    }
  }

  AppLifecycleState _bindingState;
  bool _windowMinimized = false;
  bool _inTray = false;
  bool _framesStalled = false;
  int _undrawnChecks = 0;
  Timer? _stallCheck;
  StreamSubscription<DesktopWindowEventKind>? _windowEvents;

  bool get _knownHidden => _windowMinimized || _inTray || _framesStalled;

  void _publish() {
    if (!mounted) return;
    state = _knownHidden ? AppLifecycleState.hidden : _bindingState;
  }

  /// The embedder moving from hidden to on screen also ends a minimise or a
  /// stay in the tray: a window restored without focus reports only
  /// `inactive`, and Windows sends no restore event for a maximised one.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cameBack = !isWindowVisible(_bindingState) && isWindowVisible(state);
    _bindingState = state;
    if (state == AppLifecycleState.resumed || cameBack) {
      _windowMinimized = false;
      _inTray = false;
    }
    _publish();
  }

  /// A window event that proves the window is on screen wins over a stale
  /// embedder, except while the app itself holds the window in the tray:
  /// opening the tray menu on Windows focuses the hidden window.
  void _onWindowEvent(DesktopWindowEventKind kind) {
    switch (kind) {
      case DesktopWindowEventKind.hide:
        _inTray = true;
      case DesktopWindowEventKind.minimize:
        _windowMinimized = true;
      case DesktopWindowEventKind.show:
        _inTray = false;
        _windowMinimized = false;
        _correctBinding(focused: false);
      case DesktopWindowEventKind.maximize || DesktopWindowEventKind.unmaximize
          when _windowMinimized && !_inTray:
        _windowMinimized = false;
        _correctBinding(focused: false);
      case DesktopWindowEventKind.focus when !_inTray:
        _windowMinimized = false;
        _correctBinding(focused: true);
      case DesktopWindowEventKind.blur when !_knownHidden:
        if (_bindingState == AppLifecycleState.resumed) {
          _moveBinding(AppLifecycleState.inactive);
        }
      default:
        return;
    }
    _publish();
  }

  /// Brings Flutter's own state up to what the window just proved. The
  /// provider alone is not enough: the scheduler draws no frame while the
  /// binding still says hidden, so nothing would repaint.
  void _correctBinding({required bool focused}) {
    if (focused) return _moveBinding(AppLifecycleState.resumed);
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

  void _onFrameDrawn(Duration _) {
    if (!mounted) return;
    _undrawnChecks = 0;
    if (!_framesStalled) return;
    _framesStalled = false;
    Timer.run(_publish);
  }

  /// A frame asked for and still not drawn several checks later means the
  /// compositor has stopped showing the window, which is all a Wayland
  /// minimise ever tells the app.
  void _checkFrameStall() {
    final scheduler = SchedulerBinding.instance;
    final waiting = scheduler.framesEnabled && scheduler.hasScheduledFrame;
    _undrawnChecks = waiting ? _undrawnChecks + 1 : 0;
    if (_undrawnChecks < frameStallChecks || _framesStalled) return;
    _framesStalled = true;
    _publish();
  }

  @override
  void dispose() {
    _stallCheck?.cancel();
    unawaited(_windowEvents?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final appLifecycleProvider =
    StateNotifierProvider<AppLifecycleNotifier, AppLifecycleState>(
      (ref) => AppLifecycleNotifier(
        mobile: ref.watch(mobileLifecycleHostProvider),
        frameStallCheck: ref.watch(frameStallCheckProvider),
        windowEvents: ref.read(desktopWindowShellProvider).port.events,
      ),
    );

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
