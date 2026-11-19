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
  }) : _bindingState =
           WidgetsBinding.instance.lifecycleState ??
           (mobile ? AppLifecycleState.hidden : AppLifecycleState.resumed),
       super(
         WidgetsBinding.instance.lifecycleState ??
             (mobile ? AppLifecycleState.hidden : AppLifecycleState.resumed),
       ) {
    WidgetsBinding.instance.addObserver(this);
    _windowEvents = windowEvents.listen(_onWindowEvent);
  }

  AppLifecycleState _bindingState;
  bool _windowMinimized = false;
  StreamSubscription<DesktopWindowEventKind>? _windowEvents;

  /// The embedder moving from hidden to on screen also ends a minimise: a
  /// window restored without focus reports only `inactive`, and Windows sends
  /// no restore event for a maximised one.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cameBack = !isWindowVisible(_bindingState) && isWindowVisible(state);
    _bindingState = state;
    if (state == AppLifecycleState.resumed || cameBack) {
      _windowMinimized = false;
    }
    this.state = _windowMinimized ? AppLifecycleState.hidden : state;
  }

  /// A focused window is visible whatever the binding last said: after a
  /// locked screen or a launch behind another window the embedder can leave
  /// it at `hidden`, and the video pause would never lift.
  void _onWindowEvent(DesktopWindowEventKind kind) {
    switch (kind) {
      case DesktopWindowEventKind.minimize:
        _windowMinimized = true;
        state = AppLifecycleState.hidden;
      case DesktopWindowEventKind.show ||
              DesktopWindowEventKind.maximize ||
              DesktopWindowEventKind.unmaximize
          when _windowMinimized:
        _windowMinimized = false;
        state = _bindingState;
      case DesktopWindowEventKind.focus:
        _windowMinimized = false;
        _bindingState = AppLifecycleState.resumed;
        state = AppLifecycleState.resumed;
      case DesktopWindowEventKind.blur when !_windowMinimized:
        if (state == AppLifecycleState.resumed) {
          state = AppLifecycleState.inactive;
        }
      default:
        break;
    }
  }

  @override
  void dispose() {
    unawaited(_windowEvents?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final appLifecycleProvider =
    StateNotifierProvider<AppLifecycleNotifier, AppLifecycleState>(
      (ref) => AppLifecycleNotifier(
        mobile: ref.watch(mobileLifecycleHostProvider),
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

/// Whether a phone has left the screen; a desktop window never counts, and
/// `inactive` is only a pulled shade.
bool isBackgroundedOnPhone(AppLifecycleState state, {required bool mobile}) =>
    mobile &&
    (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached);
