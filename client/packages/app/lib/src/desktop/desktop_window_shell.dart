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

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart' show Size, WidgetsBinding;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diagnostics/debug_log.dart';
import '../providers/providers.dart';
import 'close_behavior.dart';
import 'desktop_window_controller.dart';
import 'desktop_window_port.dart';
import 'first_run_tray_notice.dart';
import 'tray/desktop_tray_controller.dart';
import 'tray/linux_tray_probe.dart';
import 'tray/tray_availability.dart';
import 'window_geometry.dart';
import 'window_geometry_store.dart';
import 'window_view_size.dart';

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

  /// Named to match `linux_second_instance_channel.cc`, the only sender.
  static const _secondInstanceChannelName =
      'top.npcserver.slimm/linux_second_instance';

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

  static DesktopWindowController? _controller;
  static DesktopTrayController? _trayController;
  static bool _active = false;
  static bool _framelessApplied = false;

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
  /// that wants a clean slate rather than whatever an earlier test in the
  /// same file left behind.
  @visibleForTesting
  static void debugReset() {
    _port = WindowManagerDesktopWindowPort();
    _controller = null;
    _trayController = null;
    _active = false;
    _framelessApplied = false;
    _handoffTargetSize = null;
    _handoffFillsDisplay = false;
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
  /// [debugPrint] rather than the app log this file uses elsewhere.
  static Future<void> applyInitialGeometry() async {
    if (currentDesktopPlatform() == null) return;
    try {
      await _applySplashGeometry().timeout(_setupTimeout);
    } catch (error) {
      debugPrint('desktop: initial splash geometry failed: $error');
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
    } catch (error) {
      debugPrint('desktop: splash chrome lock failed: $error');
    }
  }

  static Future<void> _lockSplashChrome() async {
    await _port.setResizable(false);
    if (currentDesktopPlatform() == DesktopPlatform.linux) {
      await _port.hideTitleBar();
      _framelessApplied = true;
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
  /// [DesktopWindowController.enableGeometryPersistence] is flipped
  /// unconditionally afterwards, success or failure: whatever this method
  /// could do to reach the real geometry has already happened by then, and
  /// leaving persistence disabled forever on a failure would silently
  /// disable geometry persistence for the rest of the run - the same
  /// "must not strand the app" reasoning [applyInitialGeometry] already
  /// applies to its own failures.
  static Future<void> prepareHandoff(ProviderContainer container) async {
    if (currentDesktopPlatform() == null) return;
    try {
      await _applyFinalGeometry(container).timeout(_setupTimeout);
    } catch (error) {
      debugPrint('desktop: splash handoff geometry failed: $error');
    }
    _controller?.enableGeometryPersistence();
  }

  static Future<void> _applyFinalGeometry(ProviderContainer container) async {
    await _port.hide();

    final prefs = await container.read(preferencesProvider.future);
    final saved = WindowGeometryStore(prefs).read() ?? WindowGeometry.fallback;
    // Size clamp before the display clamp so a saved size below the floor is never restored where the OS minimum is not honored (Wayland); see clampSizeToMinimum.
    final geometry = clampToAttachedDisplays(
      clampSizeToMinimum(saved),
      await _port.allDisplays(),
    );

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
    try {
      await _port.show();
    } catch (error) {
      debugPrint('desktop: splash handoff reveal failed: $error');
    }
    try {
      await SchedulerBinding.instance.endOfFrame.timeout(_setupTimeout);
    } catch (error) {
      debugPrint('desktop: post-reveal frame wait failed: $error');
    }
    await _awaitMetricsAtHandoffSize();
  }

  /// Waits, bounded, for the view to actually report the size
  /// [_applyFinalGeometry] asked for.
  ///
  /// This is what keeps the real UI from ever laying out at the splash's
  /// 380px. `main.dart` flips `appReadyProvider` only after this returns, so
  /// the first frame of the real app is built against the window it is
  /// really in. Without it the flip races the compositor's own metrics, and
  /// on a launch that loses the race the whole app builds at
  /// [LayoutClass.compact] - a desktop window rendering the phone layout,
  /// which the owner reported twice. Measured on their KDE Wayland session:
  /// one launch in three built the real UI at 380 logical pixels.
  ///
  /// A maximized or fullscreen run state has no size of ours to match, so it
  /// waits for the view to stop reporting the splash's size instead; without
  /// that the real UI built at 380px and a first-launch sheet latched the
  /// phone presentation for good. Fails open on the timeout, because a window
  /// whose metrics never arrive must still get its app: a wrong layout is
  /// recoverable by resizing, a splash that never leaves is not.
  static Future<void> _awaitMetricsAtHandoffSize() async {
    final target = _handoffTargetSize;
    if (target == null && !_handoffFillsDisplay) return;
    final deadline = DateTime.now().add(_setupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final size = _currentViewSize();
      final reached = target != null
          ? viewMatchesSize(size, target)
          : viewHasLeftSplash(size);
      if (reached) return;
      try {
        await SchedulerBinding.instance.endOfFrame.timeout(_metricsPollStep);
      } catch (_) {
        // A frame that never came is not a reason to stop asking.
      }
    }
    debugPrint(
      'desktop: view never reported the handoff size $target; '
      'last seen ${_currentViewSize()}',
    );
  }

  /// How long one poll waits for a frame before re-reading the view size: a
  /// hidden or idle window can go a while without painting, and the size may
  /// change without one.
  static const _metricsPollStep = Duration(milliseconds: 100);

  static Size? _currentViewSize() {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return null;
    final ratio = view.devicePixelRatio;
    if (ratio <= 0) return null;
    return view.physicalSize / ratio;
  }

  /// Registers the Linux-only receiving end of
  /// `linux_second_instance_channel.cc`'s notification that a launcher
  /// click re-entered the native `activate` handler in this process rather
  /// than starting a second one. `main.dart` calls this right after
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
    try {
      await _port.show();
      await _port.restore();
    } catch (_) {}
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
      onShow: (action) => _offerFirstRunNoticeIfNeeded(container, action),
    )..start();

    await _port.setPreventClose(true);
    // The Linux title bar is hidden by lockSplashChrome, not here; see decision 0012's superseding section.

    _trayController = DesktopTrayController(port: _port, container: container);
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
