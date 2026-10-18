// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The app's lifecycle state as one provider, so a widget that animates for
/// its own sake can stop when nobody is looking without registering its own
/// observer. `resumed` is the only state in which the window is focused and
/// visible: desktop embedders report `inactive` for an unfocused window and
/// `hidden` for a minimised one, and a phone's `inactive`/`paused` cover the
/// same ground.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

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
  AppLifecycleNotifier({required bool mobile})
    : super(
        WidgetsBinding.instance.lifecycleState ??
            (mobile ? AppLifecycleState.hidden : AppLifecycleState.resumed),
      ) {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      this.state = state;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final appLifecycleProvider =
    StateNotifierProvider<AppLifecycleNotifier, AppLifecycleState>(
      (ref) =>
          AppLifecycleNotifier(mobile: ref.watch(mobileLifecycleHostProvider)),
    );

/// Whether the window is focused and visible right now.
final appFocusedProvider = Provider<bool>(
  (ref) => ref.watch(appLifecycleProvider) == AppLifecycleState.resumed,
);

/// Whether a timer-driven refresh of [context] would be seen: the app is in
/// the foreground and no route or tab above it has turned tickers off.
bool isSeenNow(BuildContext context) {
  final state = WidgetsBinding.instance.lifecycleState;
  final focused = state == null || state == AppLifecycleState.resumed;
  return focused && TickerMode.valuesOf(context).enabled;
}

/// Whether a phone has left the screen; a desktop window never counts, and
/// `inactive` is only a pulled shade.
bool isBackgroundedOnPhone(AppLifecycleState state, {required bool mobile}) =>
    mobile &&
    (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached);
