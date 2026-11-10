// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ties every other file in this directory into the calls `main.dart` makes:
/// splash window, close-to-tray, geometry persistence, the tray icon and the
/// handoff from the splash to the full-size window.
///
/// Every method is a no-op off Linux, macOS and Windows, so `main.dart` calls
/// them unconditionally. See the superseding section of
/// `docs/decisions/0012-desktop-window-shell.md` for why the splash is a real
/// small window.
library;

import 'dart:async';

import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/accounts/providers/account_host.dart';
import '../features/accounts/providers/account_providers.dart';
import '../providers/providers.dart';
import 'close_behavior.dart';
import 'desktop_window_controller.dart';
import 'desktop_window_port.dart';
import 'providers/close_to_tray_preference.dart';
import 'display_server.dart';
import 'first_run_tray_notice.dart';
import 'second_instance_channel.dart';
import 'splash_mapped_wait.dart';
import 'startup_state.dart' show startupLeavingProvider;
import 'tray/desktop_tray_controller.dart';
import 'tray/linux_tray_probe.dart';
import 'tray/tray_availability.dart';
import 'window_fullscreen_hold.dart' show FullscreenHolds;
import 'window_geometry.dart';
import 'window_final_geometry.dart';
import 'window_geometry_store.dart';
import 'window_view_size.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

export 'window_view_size.dart';

/// The window shell for one process, built in `main.dart` before `runApp` and
/// handed to every account's container through [desktopWindowShellProvider].
class DesktopWindowShell {
  DesktopWindowShell({
    DesktopWindowPort? port,
    bool Function() positionSupported = windowPositionSupported,
    DesktopPlatform? chromePlatform,
    Future<Duration?> Function() splashMappedProbe = queryNativeWindowMapped,
    SecondInstanceChannel? secondInstances,
    bool active = false,
    bool frameless = false,
  }) : port = port ?? WindowManagerDesktopWindowPort(),
       _positionSupported = positionSupported,
       _chromePlatform = chromePlatform,
       _splashMappedProbe = splashMappedProbe,
       _secondInstances = secondInstances ?? SecondInstanceChannel(),
       _active = active,
       _framelessApplied = frameless;

  /// Shared by every step here, and the one port [TitleBar] drags, minimizes
  /// and maximizes through; the native listener must be registered only once.
  final DesktopWindowPort port;

  /// How long a native window or tray call may take before startup proceeds
  /// regardless, so a hung call never leaves the startup screen up forever.
  static const _setupTimeout = Duration(seconds: 5);

  /// The splash's fixed size, unrelated to the saved [WindowGeometry].
  ///
  /// On Linux it must match `gtk_window_set_default_size` in
  /// `linux/runner/my_application.cc`, because the embedder cannot shrink the
  /// window before `runApp`; `splash_native_default_size_test.dart` checks it.
  /// The value lives as [kSplashWindowSize] in `window_geometry.dart` to avoid
  /// an import cycle.
  static const splashWindowSize = kSplashWindowSize;

  /// The Wayland rule: a compositor that cannot place a window has no position to save.
  final bool Function() _positionSupported;

  /// Which platform's splash chrome [lockSplashChrome] applies; null means the host's own.
  final DesktopPlatform? _chromePlatform;

  final Future<Duration?> Function() _splashMappedProbe;
  final SecondInstanceChannel _secondInstances;

  /// The fullscreen holds taken on this window, shared by every video surface.
  final fullscreenHolds = FullscreenHolds();

  /// The native window controller [registerListenersAndTray] builds, for geometry persistence.
  DesktopWindowController? get windowController => _controller;

  /// Writes any pending geometry, then destroys the window through [port].
  Future<void> quit(DesktopWindowPort port) async {
    try {
      await _controller?.flush();
    } catch (error, stack) {
      AppLog.warning(
        LogTag.platform,
        'Could not save the window position on quit',
        error: error,
        stack: stack,
      );
    }
    await port.destroy();
  }

  DesktopWindowController? _controller;
  DesktopTrayController? _trayController;
  AccountHost? _accounts;
  bool _active;
  bool _framelessApplied;

  /// The windowed size [_applyFinalGeometry] asked for; null when maximized or
  /// fullscreen, where the compositor decides.
  WindowSize? _handoffTargetSize;

  /// True when the final run state is maximized or fullscreen, where the size
  /// is the compositor's but the view must still leave the splash's own.
  bool _handoffFillsDisplay = false;

  /// True once [registerListenersAndTray] has run against a real desktop
  /// platform. [DesktopChrome] reads this rather than [isDesktopHost] so a
  /// widget test on a Linux box is not wrapped in chrome it never had.
  bool get active => _active;

  /// True once the native frame has been hidden by [lockSplashChrome]; it stays
  /// as it is for the run, since the splash and the app share one window.
  bool get frameless => _framelessApplied;

  /// What the close button inside [TitleBar] calls, a no-op if the shell was
  /// never started. [frameless] can be true before the controller exists, so
  /// `Ctrl+Q` (`desktop_quit_shortcut.dart`) is the fallback for that gap.
  Future<void> requestClose() =>
      _controller?.requestClose() ?? Future<void>.value();

  /// Puts the window into small splash mode before it is ever shown, so
  /// nothing visibly jumps; the saved geometry waits for [prepareHandoff].
  ///
  /// Bounded by [_setupTimeout] and never throws: a hung window call here
  /// would block the first frame, so on a timeout the window opens at its
  /// native default and the breadcrumb goes to [AppLog].
  Future<void> applyInitialGeometry() async {
    if (currentDesktopPlatform() == null) return;
    try {
      await _applySplashGeometry().timeout(_setupTimeout);
    } catch (error, stack) {
      AppLog.warning(
        LogTag.platform,
        'Could not place the startup splash window',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> _applySplashGeometry() async {
    await port.ensureInitialized();
    await port.setSize(splashWindowSize);
    await port.center();
  }

  /// Locks the splash's chrome once the window is visible: resizing off, and
  /// on Linux and Windows the native title bar hidden for `DesktopChrome`'s
  /// frameless one.
  ///
  /// Not folded into [applyInitialGeometry]: resize-before-map requests are
  /// unreliable under GTK and raced the splash resize, so this waits for the
  /// first rasterized frame.
  Future<void> lockSplashChrome() async {
    if (currentDesktopPlatform() == null) return;
    try {
      await _lockSplashChrome().timeout(_setupTimeout);
    } catch (error, stack) {
      AppLog.warning(
        LogTag.platform,
        'Could not lock the startup splash window frame',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> _lockSplashChrome() async {
    await port.setResizable(false);
    switch (_chromePlatform ?? currentDesktopPlatform()) {
      case DesktopPlatform.linux || DesktopPlatform.windows:
        await port.hideTitleBar();
        _framelessApplied = true;
      case DesktopPlatform.macOS || null:
        break;
    }
  }

  /// Hides the window, then applies the real saved-or-default geometry while
  /// nothing is on screen to see it change. Pair with [revealAfterHandoff],
  /// called once the real UI has painted.
  ///
  /// Bounded and swallowed like [applyInitialGeometry], so a hang here cannot
  /// strand the app hidden. Persistence stays off until the reveal settles.
  /// [splashFloor] is how long the splash must have been on screen once mapped,
  /// and [fadeOut] how long its content dissolves before the window hides.
  Future<void> prepareHandoff(
    ProviderContainer container, {
    Duration splashFloor = Duration.zero,
    Duration fadeOut = Duration.zero,
  }) async {
    if (currentDesktopPlatform() == null) return;
    await awaitSplashMapped(floor: splashFloor, probe: _splashMappedProbe);
    if (fadeOut > Duration.zero) {
      container.read(startupLeavingProvider.notifier).state = true;
      await Future<void>.delayed(fadeOut);
    }
    try {
      await _applyFinalGeometry(container).timeout(_setupTimeout);
    } catch (error, stack) {
      AppLog.warning(
        LogTag.platform,
        'Could not restore the window size and position after startup',
        error: error,
        stack: stack,
      );
    } finally {
      // Not after the reveal settles: on a host that never renders at the new size that wait times out.
      _controller?.enableGeometryPersistence();
    }
  }

  Future<void> _applyFinalGeometry(ProviderContainer container) async {
    final prefs = await container.read(preferencesProvider.future);
    await applyFinalGeometry(
      port,
      WindowGeometryStore(prefs),
      positionSupported: _positionSupported(),
      onTarget: (target) {
        _handoffTargetSize = target.size;
        _handoffFillsDisplay = target.fillsDisplay;
      },
    );
  }

  /// Shows the window again after [prepareHandoff], then waits, best-effort,
  /// for the real UI to paint ([SchedulerBinding.endOfFrame]).
  ///
  /// The wait runs after `show()` because a hidden window never receives a
  /// compositor frame callback on this embedder, so waiting first only burns
  /// [_setupTimeout] (decision 0012's 2026-08-28 addendum has the measurement).
  /// One stale splash frame may show for a vsync tick, but at the right size.
  /// The bound only keeps a stalled host from hanging this method.
  Future<void> revealAfterHandoff() async {
    if (currentDesktopPlatform() == null) return;
    await _reveal();
  }

  Future<void> _reveal() async {
    try {
      await port.show();
    } catch (error, stack) {
      AppLog.warning(
        LogTag.platform,
        'Could not show the main window after startup',
        error: error,
        stack: stack,
      );
    }
    try {
      await SchedulerBinding.instance.endOfFrame.timeout(_setupTimeout);
    } catch (error, stack) {
      AppLog.warning(
        LogTag.platform,
        'The first frame took too long to appear after the window opened',
        error: error,
        stack: stack,
      );
    }
    await awaitViewAtHandoffSize(
      target: _handoffTargetSize,
      fillsDisplay: _handoffFillsDisplay,
      timeout: _setupTimeout,
    );
  }

  /// Registers the receiving end of the runners' notification that a second
  /// launch was turned away in favour of this process. `main.dart` calls this
  /// right after [applyInitialGeometry], before there is a [ProviderContainer],
  /// since a second launch can race the very start of this process.
  void registerSecondInstanceHandler() {
    if (currentDesktopPlatform() == null) return;
    _secondInstances.register(raise);
  }

  /// Fires each time another launch hands over to this running instance.
  Stream<void> get secondLaunches => _secondInstances.launches;

  /// Brings the window forward for a notification click or a second launch.
  ///
  /// show() un-hides a tray-hidden window; restore() raises a minimised one.
  Future<void> raise() async {
    if (currentDesktopPlatform() == null) return;
    try {
      await port.show();
      await port.restore();
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'Could not bring the window to the front',
        error,
        stack,
      );
    }
  }

  /// Wires geometry persistence, close-to-tray/minimise and the tray icon, all
  /// of which need [container] for the running call's state.
  ///
  /// Never throws and never hangs past [_setupTimeout], because `main.dart`
  /// awaits it before flipping the app ready; a failure is logged and the app
  /// opens with no tray, no custom title bar and no geometry persistence.
  Future<void> registerListenersAndTray(ProviderContainer container) async {
    final platform = currentDesktopPlatform();
    if (platform == null) return;
    _active = true;
    try {
      await _bringUpWindowAndTray(container, platform).timeout(_setupTimeout);
    } catch (error, stack) {
      AppLog.warning(
        LogTag.platform,
        'Could not set up the window and tray',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> _bringUpWindowAndTray(
    ProviderContainer container,
    DesktopPlatform platform,
  ) async {
    await port.ensureInitialized();

    final prefs = await container.read(preferencesProvider.future);
    final store = WindowGeometryStore(prefs);
    final trayAvailable = trayAvailabilityCheck(
      platform: platform,
      probe: const MethodChannelLinuxTrayProbe(),
    );

    _accounts = container.read(accountHostProvider);
    _controller = DesktopWindowController(
      port: port,
      store: store,
      platform: platform,
      trayAvailable: trayAvailable,
      positionSupported: _positionSupported,
      onShow: (action) => _offerFirstRunNoticeIfNeeded(container, action),
      fullscreenHeld: () => fullscreenHolds.any,
      keepInTray: () => _onScreen(container).read(closeToTrayProvider),
      quit: () => quit(port),
    )..start();
    // Read now so the stored choice has loaded before the first close.
    container.read(closeToTrayProvider);

    await port.setPreventClose(true);
    // The Linux title bar is hidden by lockSplashChrome, not here; see decision 0012's superseding section.

    _trayController = DesktopTrayController(
      port: port,
      container: container,
      host: _accounts,
    );
    await _trayController!.start();
  }

  /// [action] is null on a show that was never preceded by a routed close
  /// on this controller (the very first launch) - nothing happened yet to
  /// describe, so there is nothing to offer.
  Future<void> _offerFirstRunNoticeIfNeeded(
    ProviderContainer container,
    CloseAction? action,
  ) async {
    if (action == null) return;
    final screen = _onScreen(container);
    final notice = await screen.read(firstRunTrayNoticeProvider.future);
    if (notice.hasBeenShown(action)) return;
    screen.read(firstRunTrayNoticeCloseActionProvider.notifier).state = action;
  }

  /// The account on screen owns the settings a close acts on; the first one built may be gone.
  ProviderContainer _onScreen(ProviderContainer fallback) =>
      _accounts?.active?.container ?? fallback;
}

final desktopWindowShellProvider = Provider<DesktopWindowShell>(
  (ref) => DesktopWindowShell(),
);
