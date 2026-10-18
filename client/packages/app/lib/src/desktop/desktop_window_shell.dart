// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ties every other file in this directory into the calls `main.dart` makes:
/// put the window into small splash mode before it is ever shown, wire up
/// close-to-tray, geometry persistence and the tray icon once the app has a
/// [ProviderContainer] to read the running call's state from, then hand off
/// from the splash to the real, fully-sized window once bootstrap finishes.
///
/// A no-op on every platform but Linux, macOS and Windows: `main.dart` calls
/// every method here unconditionally, and each returns immediately off
/// [currentDesktopPlatform] being null rather than making every call site
/// guard itself.
///
/// See the superseding section of `docs/decisions/0012-desktop-window-shell.md`
/// for why the splash is a real small window rather than the full-size first
/// frame that record originally described.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diagnostics/debug_log.dart';
import '../features/accounts/providers/account_providers.dart';
import '../providers/providers.dart';
import 'close_behavior.dart';
import 'desktop_window_controller.dart';
import 'desktop_window_port.dart';
import 'display_server.dart';
import 'first_run_tray_notice.dart';
import 'splash_mapped_wait.dart';
import 'startup_state.dart' show startupLeavingProvider;
import 'tray/desktop_tray_controller.dart';
import 'tray/linux_tray_probe.dart';
import 'tray/tray_availability.dart';
import 'window_geometry.dart';
import 'window_geometry_store.dart';
import 'window_view_size.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

export 'window_view_size.dart';

class DesktopWindowShell {
  DesktopWindowShell._();

  /// Shared across [applyInitialGeometry] and [registerListenersAndTray]:
  /// the native listener must be registered exactly once, which is what
  /// [WindowManagerDesktopWindowPort.ensureInitialized]'s own idempotence
  /// guards, and both steps need the one real window either way. Not
  /// `final`: [debugPort] is the test-only seam that swaps it for a fake.
  static DesktopWindowPort _port = WindowManagerDesktopWindowPort();

  /// How long [registerListenersAndTray] waits on the native window/tray
  /// calls before giving up and letting startup proceed regardless - a
  /// hang here (a D-Bus call with nothing answering it, say) would
  /// otherwise never resolve, which is the same silent-forever startup
  /// screen a thrown exception used to cause before this file caught one.
  static const _setupTimeout = Duration(seconds: 5);

  /// Named to match the senders, `linux_second_instance_channel.cc` and
  /// the Windows runner's `single_instance.cpp`.
  static const _secondInstanceChannelName =
      'top.npcserver.slimm/second_instance';

  /// The splash's fixed size - room for the 64px brand mark, the wordmark
  /// and a status line, no more - and deliberately unrelated to
  /// [WindowGeometry]: the splash is always this size, regardless of what
  /// the real window's own saved geometry turns out to be. See the startup
  /// screen (`startup_screen.dart`) and decision 0012's superseding section.
  ///
  /// On Linux this value must also match the hardcoded
  /// `gtk_window_set_default_size` in `linux/runner/my_application.cc`: the
  /// GTK/Impeller embedder only completes a resize once a rendered frame at
  /// the new size exists, so [applyInitialGeometry]'s own `setSize` call
  /// below cannot shrink the window before `runApp` - the window must be
  /// born at this size instead. `splash_native_default_size_test.dart`
  /// checks the two stay in sync. macOS and Windows have no such embedder
  /// constraint and are expected to size correctly from `setSize` alone.
  ///
  /// The value itself lives as [kSplashWindowSize] in `window_geometry.dart`
  /// rather than here, so that file's own read-time corruption guard can use
  /// it with no import cycle: this file already imports that one.
  static const splashWindowSize = kSplashWindowSize;

  static bool Function() _positionSupported = windowPositionSupported;

  /// Test-only seam for the Wayland rule, since a test runs on this Linux box.
  @visibleForTesting
  static set debugPositionSupported(bool Function() probe) =>
      _positionSupported = probe;

  @visibleForTesting
  static void debugEnablePersistence() =>
      _controller?.enableGeometryPersistence();

  /// Writes any pending geometry, then destroys the window through [port].
  static Future<void> quit(DesktopWindowPort port) async {
    try {
      await _controller?.flush();
    } catch (error, stack) {
      AppLog.warning(
        LogTag.platform,
        'flushing geometry on quit failed',
        error: error,
        stack: stack,
      );
    }
    await port.destroy();
  }

  static DesktopWindowController? _controller;
  static DesktopTrayController? _trayController;
  static bool _active = false;
  static bool _framelessApplied = false;

  /// Windows hides the native title bar for the splash only; the handoff
  /// brings it back, since the real window keeps its native frame there.
  static bool _splashTitleBarHidden = false;

  static DesktopPlatform? _debugPlatform;

  /// Test-only: which platform's splash chrome [lockSplashChrome] applies.
  @visibleForTesting
  static set debugSplashPlatform(DesktopPlatform? platform) =>
      _debugPlatform = platform;

  /// The windowed size [_applyFinalGeometry] asked for, so
  /// [revealAfterHandoff] knows what the view is supposed to settle at.
  /// Null when the run state is maximized or fullscreen, where the final
  /// size is the compositor's to decide and there is nothing to compare.
  static WindowSize? _handoffTargetSize;

  /// True when the final run state is maximized or fullscreen, where the size
  /// is the compositor's but the view must still leave the splash's own.
  static bool _handoffFillsDisplay = false;

  /// Test-only seam: a real desktop-shell test still runs on real Linux
  /// (`dart:io`'s `Platform` cannot tell a CI runner from a launch), so
  /// this is what lets a test drive [registerListenersAndTray] against a
  /// fake port rather than the real plugin.
  @visibleForTesting
  static set debugPort(DesktopWindowPort port) => _port = port;

  /// Restores every static field to its never-started state, for a test
  /// that wants a clean slate.
  @visibleForTesting
  static void debugReset() {
    _port = WindowManagerDesktopWindowPort();
    _controller = null;
    _trayController = null;
    _active = false;
    _framelessApplied = false;
    _splashTitleBarHidden = false;
    _debugPlatform = null;
    _handoffTargetSize = null;
    _handoffFillsDisplay = false;
    _positionSupported = windowPositionSupported;
  }

  /// Flips the two flags [DesktopChrome] reads, so a widget test can render
  /// the active chrome without driving the whole native bring-up. Pair with
  /// [debugPort] and [debugReset]; [frameless] mounts the title bar.
  @visibleForTesting
  static void debugActivate({bool frameless = false}) {
    _active = true;
    _framelessApplied = frameless;
  }

  /// The one port [TitleBar] drags, minimizes and maximizes through.
  static DesktopWindowPort get port => _port;

  /// True once [registerListenersAndTray] has actually run against a real
  /// desktop platform - never true in an ordinary widget test, since
  /// nothing in a `flutter test` run ever calls it. [DesktopChrome] reads
  /// this, not [isDesktopHost], specifically so a test run on this
  /// project's own Linux dev box or CI runner - which really is Linux, as
  /// far as `dart:io`'s `Platform` can tell - does not silently wrap every
  /// existing widget test's tree in a `Column` it never had before.
  static bool get active => _active;

  /// True only once the native frame has actually been hidden - on Linux,
  /// set by [lockSplashChrome], right after the splash's own first frame is
  /// confirmed rasterized, so the splash reads as frameless for all but that
  /// first instant. Stays true (or false, on a failure) for the rest of the
  /// run: nothing resets it back at handoff, since the splash and the ready
  /// app share the one real window and its one frame state throughout.
  static bool get frameless => _framelessApplied;

  /// The close button drawn inside [TitleBar] has no native close event of
  /// its own to reach [DesktopWindowController.requestClose] through, so it
  /// calls this instead - a no-op if the shell was never started. [frameless]
  /// no longer guarantees this is non-null the way it once did: it is now set
  /// during [lockSplashChrome], before [registerListenersAndTray] ever
  /// creates the controller, so a native/tray failure in between can leave
  /// the window frameless with a close button that does nothing. `Ctrl+Q`
  /// (`desktop_quit_shortcut.dart`) is the deliberate, unconditional
  /// fallback for exactly that gap, registered independently of both.
  static Future<void> requestClose() =>
      _controller?.requestClose() ?? Future<void>.value();

  /// Puts the window into small splash mode before it is ever shown, so
  /// there is nothing to visibly jump once it appears - `main.dart` calls
  /// this before `runApp`, ahead of the startup screen's own first frame.
  /// The real, saved geometry is not read here at all: it is applied later,
  /// by [prepareHandoff], once bootstrap actually finishes.
  ///
  /// Only size and centering happen here - see [lockSplashChrome] for why
  /// resizing-off and the Linux title bar deliberately do not.
  ///
  /// Bounded by [_setupTimeout] and never throws, for the same reason
  /// [registerListenersAndTray] is not allowed to: this runs before `runApp`,
  /// so a native window or display call that hangs (a portal or compositor
  /// not answering at the instant of launch) would otherwise block the first
  /// frame forever - a silent-forever startup screen strictly worse than the
  /// one that method already guards, since not even an empty window paints.
  /// On a timeout or error the window simply opens at its native default. No
  /// [ProviderContainer] exists this early, so the breadcrumb goes to
  /// [AppLog], which buffers until the app installs its sink.
  static Future<void> applyInitialGeometry() async {
    if (currentDesktopPlatform() == null) return;
    try {
      await _applySplashGeometry().timeout(_setupTimeout);
    } catch (error, stack) {
      AppLog.warning(
        LogTag.platform,
        'initial splash geometry failed',
        error: error,
        stack: stack,
      );
    }
  }

  static Future<void> _applySplashGeometry() async {
    await _port.ensureInitialized();
    await _port.setSize(splashWindowSize);
    await _port.center();
  }

  /// Locks the splash's chrome once the window is actually visible:
  /// resizing off everywhere, and on Linux the native title bar hidden in
  /// favor of the frameless bar `DesktopChrome` draws once the app is
  /// ready. `main.dart` calls this once, right after the first frame is
  /// confirmed rasterized (`WidgetsBinding.waitUntilFirstFrameRasterized`).
  ///
  /// Deliberately not folded into [applyInitialGeometry], despite both
  /// running once and early: an Xvfb+fluxbox reproduction of this exact
  /// sequence showed the window mapping at the native 1280x720 default
  /// instead of [splashWindowSize] whenever `setResizable`/`hideTitleBar`
  /// ran before the window was ever shown - GTK's own resize-before-map
  /// requests are documented as unreliable, and here they raced the still
  /// -pending splash resize and won. Waiting for the real first frame,
  /// after which the window is already realized at the intended size, is
  /// the same ordering the original (pre-splash) title-bar hide already
  /// relied on safely.
  static Future<void> lockSplashChrome() async {
    if (currentDesktopPlatform() == null) return;
    try {
      await _lockSplashChrome().timeout(_setupTimeout);
    } catch (error, stack) {
      AppLog.warning(
        LogTag.platform,
        'splash chrome lock failed',
        error: error,
        stack: stack,
      );
    }
  }

  static Future<void> _lockSplashChrome() async {
    await _port.setResizable(false);
    switch (_debugPlatform ?? currentDesktopPlatform()) {
      case DesktopPlatform.linux:
        await _port.hideTitleBar();
        _framelessApplied = true;
      case DesktopPlatform.windows:
        await _port.hideTitleBar();
        _splashTitleBarHidden = true;
      case DesktopPlatform.macOS || null:
        break;
    }
  }

  /// Hides the window, then applies the real saved-or-default geometry (size,
  /// position where the platform has one, and maximized/fullscreen run
  /// state) while nothing is on screen to see it change - the traded-off
  /// stand-in for what a genuine second top-level window would give for
  /// free (one window gone, the other already there). Pair with
  /// [revealAfterHandoff], called only after the real UI has actually
  /// painted, so `show()` never uncovers a stale splash frame or an empty
  /// one. `main.dart` calls this once bootstrap resolves, before flipping
  /// `appReadyProvider`.
  ///
  /// Bounded and swallowed the same way [applyInitialGeometry] is: a hang or
  /// throw here must not strand the app hidden with nothing to reveal it.
  /// Persistence stays off until [revealAfterHandoff] has settled the view. [splashFloor] is
  /// how long the splash must have been on screen once mapped. [fadeOut] is
  /// how long the splash content dissolves before its window hides.
  static Future<void> prepareHandoff(
    ProviderContainer container, {
    Duration splashFloor = Duration.zero,
    Duration fadeOut = Duration.zero,
  }) async {
    if (currentDesktopPlatform() == null) return;
    await awaitSplashMapped(floor: splashFloor);
    if (fadeOut > Duration.zero) {
      container.read(startupLeavingProvider.notifier).state = true;
      await Future<void>.delayed(fadeOut);
    }
    try {
      await _applyFinalGeometry(container).timeout(_setupTimeout);
    } catch (error, stack) {
      AppLog.warning(
        LogTag.platform,
        'splash handoff geometry failed',
        error: error,
        stack: stack,
      );
    } finally {
      // Not after the reveal settles: on a host that never renders at the new size that wait times out.
      _controller?.enableGeometryPersistence();
    }
  }

  static Future<void> _applyFinalGeometry(ProviderContainer container) async {
    await _port.hide();
    if (_splashTitleBarHidden) {
      await _port.showTitleBar();
      _splashTitleBarHidden = false;
    }

    final prefs = await container.read(preferencesProvider.future);
    final saved = WindowGeometryStore(prefs).read() ?? WindowGeometry.fallback;
    // Size clamp before the display clamp so a saved size below the floor is never restored where the OS minimum is not honored (Wayland); see clampSizeToMinimum.
    final sized = clampToAttachedDisplays(
      clampSizeToMinimum(saved),
      await _port.allDisplays(),
    );
    final geometry = _positionSupported()
        ? sized
        : sized.copyWith(clearPosition: true);

    await _port.setResizable(true);
    // After the splash, which is deliberately smaller than this floor.
    await _port.setMinimumSize(WindowGeometry.minimumWindowSize);
    final position = geometry.position;
    if (position != null) {
      await _port.setBounds(
        WindowRect(
          x: position.x,
          y: position.y,
          width: geometry.windowedSize.width,
          height: geometry.windowedSize.height,
        ),
      );
    } else {
      await _port.setSize(geometry.windowedSize);
      await _port.center();
    }

    switch (geometry.runState) {
      case WindowRunState.maximized:
        _handoffTargetSize = null;
        _handoffFillsDisplay = true;
        await _port.maximize();
      case WindowRunState.fullscreen:
        _handoffTargetSize = null;
        _handoffFillsDisplay = true;
        await _port.setFullScreen(true);
      case WindowRunState.windowed:
        _handoffTargetSize = geometry.windowedSize;
        _handoffFillsDisplay = false;
    }
  }

  /// Shows the window again after [prepareHandoff] applied the real geometry
  /// and `appReadyProvider` flipped, then waits, best-effort, for the
  /// swapped-in real UI to actually paint ([SchedulerBinding.endOfFrame]).
  /// `main.dart` calls this right after flipping `appReadyProvider` true.
  ///
  /// The wait runs *after* `show()`, not before, despite this method's own
  /// name suggesting the reveal should come last: a hidden top-level window
  /// never receives a compositor frame callback on this embedder at all, so
  /// waiting on a frame while still hidden cannot time out early or late -
  /// it can only ever time out, on any host, because there is no frame to
  /// wait for. Confirmed by instrumenting a real launch on the reporter's
  /// own KDE Wayland session: the wait failed after the full
  /// [_setupTimeout] every time while the window stayed hidden, then
  /// resolved within a single frame the instant [_port.show] ran. Waiting
  /// first and revealing second, the order this replaces, could only ever
  /// spend that timeout for nothing before doing the exact same `show()`
  /// its own timeout fallback already did - see decision 0012's 2026-08-28
  /// addendum for the measurement.
  ///
  /// This still does not promise a literally flash-free transition: the one
  /// frame `show()` exposes is whatever Flutter last painted before
  /// [prepareHandoff] hid the window - the splash, at the splash's small
  /// bounds - for at most one vsync tick until the already-pending
  /// `appReadyProvider` frame lands. That exposure is not new: the previous
  /// ordering's own timeout fallback showed the window in exactly the same
  /// state, on every launch on this platform, since the wait it ran first
  /// could never succeed. [prepareHandoff] having already applied the real
  /// geometry before either ordering calls `show()` is what keeps that
  /// exposure to "stale content, right-sized window" rather than a visible
  /// resize as well.
  ///
  /// The post-`show()` wait is bounded by [_setupTimeout] purely so a host
  /// that stalls for a genuinely different reason gets logged rather than
  /// hanging this method forever; nothing downstream awaits this method's
  /// completion, so the bound protects a log line, not a caller.
  static Future<void> revealAfterHandoff() async {
    if (currentDesktopPlatform() == null) return;
    await _reveal();
  }

  static Future<void> _reveal() async {
    try {
      await _port.show();
    } catch (error, stack) {
      AppLog.warning(
        LogTag.platform,
        'splash handoff reveal failed',
        error: error,
        stack: stack,
      );
    }
    try {
      await SchedulerBinding.instance.endOfFrame.timeout(_setupTimeout);
    } catch (error, stack) {
      AppLog.warning(
        LogTag.platform,
        'post-reveal frame wait failed',
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
  /// launch was turned away in favour of this process: the Linux GtkApplication
  /// re-entering `activate`, or the Windows runner's named mutex. `main.dart` calls this right after
  /// [applyInitialGeometry], before there is a [ProviderContainer], since a
  /// second launch racing the very start of this process is not something
  /// any later ordering could rule out.
  static void registerSecondInstanceHandler() {
    if (currentDesktopPlatform() == null) return;
    const MethodChannel(
      _secondInstanceChannelName,
    ).setMethodCallHandler(_onSecondInstanceCall);
  }

  /// show() is the same call [DesktopTrayController]'s own toggle makes to
  /// un-hide a tray-hidden window; restore() additionally raises one that
  /// was only minimised or merely behind other windows - both reuse the
  /// port's existing methods rather than a second "make it visible" path.
  /// Best-effort: the process-level dedup this exists for already happened
  /// natively, in `my_application.cc`'s own early return, before this ran.
  static Future<void> _onSecondInstanceCall(MethodCall call) async {
    if (call.method != 'focus') return;
    await raise();
  }

  /// Brings the window forward for a notification click or a second launch.
  static Future<void> raise() async {
    if (currentDesktopPlatform() == null) return;
    try {
      await _port.show();
      await _port.restore();
    } catch (error, stack) {
      AppLog.swallowed(LogTag.platform, 'raise failed, ignored', error, stack);
    }
  }

  /// Wires geometry persistence, close-to-tray/minimise, and the tray icon
  /// itself - everything that needs [container] to reach a running call's
  /// state, so it runs after the container exists rather than before
  /// `runApp` the way [applyInitialGeometry] does.
  ///
  /// Never throws and never hangs past [_setupTimeout]: `main.dart` awaits
  /// this before flipping the app ready, and a startup screen with no
  /// timeout and no error state of its own must not be the thing a failure
  /// here leaves the user staring at forever. A failure - thrown or timed
  /// out - is logged and swallowed, matching [restoreSession]'s own
  /// precedent; the app reaches a usable window with no tray, no custom
  /// title bar and no geometry persistence rather than no window at all.
  static Future<void> registerListenersAndTray(
    ProviderContainer container,
  ) async {
    final platform = currentDesktopPlatform();
    if (platform == null) return;
    _active = true;
    try {
      await _bringUpWindowAndTray(container, platform).timeout(_setupTimeout);
    } catch (error, stack) {
      container
          .read(debugLogProvider.notifier)
          .record(
            'desktop',
            'window shell setup failed: $error',
            detail: stack,
          );
    }
  }

  static Future<void> _bringUpWindowAndTray(
    ProviderContainer container,
    DesktopPlatform platform,
  ) async {
    await _port.ensureInitialized();

    final prefs = await container.read(preferencesProvider.future);
    final store = WindowGeometryStore(prefs);
    final trayAvailable = trayAvailabilityCheck(
      platform: platform,
      probe: const MethodChannelLinuxTrayProbe(),
    );

    _controller = DesktopWindowController(
      port: _port,
      store: store,
      platform: platform,
      trayAvailable: trayAvailable,
      positionSupported: _positionSupported,
      onShow: (action) => _offerFirstRunNoticeIfNeeded(container, action),
    )..start();

    await _port.setPreventClose(true);
    // The Linux title bar is hidden by lockSplashChrome, not here; see decision 0012's superseding section.

    _trayController = DesktopTrayController(
      port: _port,
      container: container,
      host: container.read(accountHostProvider),
    );
    await _trayController!.start();
  }

  /// [action] is null on a show that was never preceded by a routed close
  /// on this controller (the very first launch) - nothing happened yet to
  /// describe, so there is nothing to offer.
  static Future<void> _offerFirstRunNoticeIfNeeded(
    ProviderContainer container,
    CloseAction? action,
  ) async {
    if (action == null) return;
    final notice = await container.read(firstRunTrayNoticeProvider.future);
    if (notice.hasBeenShown(action)) return;
    container.read(firstRunTrayNoticeCloseActionProvider.notifier).state =
        action;
  }
}
