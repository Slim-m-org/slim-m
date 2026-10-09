// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The small-splash-then-handoff sequence added by decision 0012's
/// superseding section: [DesktopWindowShell.applyInitialGeometry] sizes and
/// centers the window before the very first frame, [DesktopWindowShell.lockSplashChrome]
/// disables resize and hides the Linux title bar once that frame is up, and
/// [DesktopWindowShell.prepareHandoff]/[DesktopWindowShell.revealAfterHandoff]
/// swap the window to the real saved geometry once bootstrap finishes - all
/// driven against a fake port, per decision 0012's own rule that this class
/// of logic stays automatable with no real display involved.
///
/// [applyInitialGeometry] and [lockSplashChrome] are deliberately two
/// methods, not one, and this file tests them separately for that reason:
/// an Xvfb+fluxbox reproduction showed the window mapping at the native
/// 1280x720 default instead of the splash size when resizing-off and the
/// title bar hide ran before the window was ever shown - see both methods'
/// own doc comments and `main.dart`'s.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/desktop_window_controller.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/desktop/splash_mapped_wait.dart';
import 'package:slimm_app/src/desktop/window_geometry.dart';
import 'package:slimm_app/src/desktop/window_geometry_store.dart';

import 'support/fake_desktop_window_port.dart';

ProviderContainer _container() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() {
    DesktopWindowShell.debugReset();
    debugSplashMappedProbe = () async => true;
  });
  tearDown(DesktopWindowShell.debugReset);

  testWidgets('applyInitialGeometry sizes and centers the window at the '
      'fixed splash size, and touches neither resizing nor the title bar', (
    tester,
  ) async {
    final port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;

    await DesktopWindowShell.applyInitialGeometry();

    expect(port.lastSize, DesktopWindowShell.splashWindowSize);
    expect(port.centerCalls, 1);
    expect(port.lastResizable, isNull);
    expect(port.hideTitleBarCalls, 0);
    expect(DesktopWindowShell.frameless, isFalse);
  });

  testWidgets('lockSplashChrome locks resizing and hides the Linux title '
      'bar, once the splash is already up', (tester) async {
    final port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;

    await DesktopWindowShell.lockSplashChrome();

    expect(port.lastResizable, isFalse);
    expect(port.hideTitleBarCalls, 1);
    expect(DesktopWindowShell.frameless, isTrue);
  });

  testWidgets('prepareHandoff hides the window, unlocks resizing, and falls '
      'back to the default geometry with nothing saved yet', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;
    final container = _container();

    await DesktopWindowShell.prepareHandoff(container);

    expect(port.hideCalls, 1);
    expect(port.lastResizable, isTrue);
    expect(port.lastSize, WindowGeometry.fallback.windowedSize);
    expect(port.centerCalls, 1);
    expect(port.maximizeCalls, 0);
  });

  testWidgets('prepareHandoff leaves the window alone until the splash is '
      'mapped - regression test for a loaded host where bootstrap beat the '
      'first frame and X created the window at the real size, never showing '
      'the splash', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;
    var mapped = false;
    debugSplashMappedProbe = () async => mapped;
    final container = _container();

    final handoff = DesktopWindowShell.prepareHandoff(container);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(port.hideCalls, 0);
    expect(port.lastSize, isNull);

    mapped = true;
    await tester.pump(const Duration(milliseconds: 100));
    await handoff;

    expect(port.hideCalls, 1);
    expect(port.lastSize, WindowGeometry.fallback.windowedSize);
  });

  testWidgets('prepareHandoff restores a saved maximized run state', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      windowGeometryPreferenceKey: jsonEncode(
        const WindowGeometry(
          windowedSize: WindowSize(width: 1400, height: 900),
          runState: WindowRunState.maximized,
        ).toJson(),
      ),
    });
    final port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;
    final container = _container();

    await DesktopWindowShell.prepareHandoff(container);

    expect(port.hideCalls, 1);
    expect(port.lastSize, const WindowSize(width: 1400, height: 900));
    expect(port.maximizeCalls, 1);
  });

  testWidgets('revealAfterHandoff shows the window again once the real UI '
      'has had a frame to paint', (tester) async {
    final port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;

    final reveal = DesktopWindowShell.revealAfterHandoff();

    // Flushes show()'s own microtask before the pump that satisfies the endOfFrame wait after it (a real host runs both on its own).
    await Future<void>.value();
    await tester.pump();
    await reveal;

    expect(port.showCalls, 1);
  });

  testWidgets('revealAfterHandoff shows the window without ever waiting on '
      'a frame while it is still hidden - regression test for the v0.61.0 '
      'handoff timeout, where a hidden window never receives a frame at '
      'all, so waiting on one before show() could only ever time out', (
    tester,
  ) async {
    final port = FakeDesktopWindowPort()..visible = false;
    DesktopWindowShell.debugPort = port;

    final reveal = DesktopWindowShell.revealAfterHandoff();

    // Only a microtask turn runs here, never a pumped frame - a real hidden window never gets one either.
    await Future<void>.value();
    expect(port.showCalls, 1);

    // Lets the trailing, now non-gating, frame wait resolve normally so nothing is left pending.
    await tester.pump();
    await reveal;
  });

  test('a resize before prepareHandoff completes is not persisted; the same '
      'resize after prepareHandoff completes is - regression test for the '
      'client-v0.58.0 splash-geometry bug', () async {
    SharedPreferences.setMockInitialValues({});
    final store = WindowGeometryStore(await SharedPreferences.getInstance());
    final port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;
    final container = _container();

    fakeAsync((async) {
      unawaited(DesktopWindowShell.registerListenersAndTray(container));
      async.flushMicrotasks();

      port.bounds = const WindowRect(x: 45, y: 45, width: 380, height: 460);
      port.emit(DesktopWindowEventKind.resize);
      async.elapse(desktopGeometryDebounce);

      expect(
        store.read(),
        isNull,
        reason: 'the splash is still up; prepareHandoff has not run yet',
      );

      unawaited(DesktopWindowShell.prepareHandoff(container));
      async.flushMicrotasks();

      port.bounds = const WindowRect(x: 100, y: 100, width: 1280, height: 720);
      port.emit(DesktopWindowEventKind.resize);
      async.elapse(desktopGeometryDebounce);
    });

    final saved = store.read();
    expect(saved, isNotNull);
    expect(saved!.windowedSize, const WindowSize(width: 1280, height: 720));
  });

  /// The owner's report, twice: a desktop window opening on the phone
  /// layout. Measured on their KDE Wayland session, one launch in three
  /// built the real UI at the splash's own 380 logical pixels, because the
  /// ready flip raced the compositor's metrics. `main.dart` now reveals
  /// first and flips second, and this is the comparison that decides when
  /// the view has caught up.
  test('the view has caught up only when it reports the applied size', () {
    const target = WindowSize(width: 1280, height: 720);

    expect(viewMatchesSize(const Size(1280, 720), target), isTrue);
    expect(
      viewMatchesSize(const Size(380, 508), target),
      isFalse,
      reason: 'the splash size is exactly the case this exists to catch',
    );
  });

  /// A compositor converts through physical pixels and a fractional device
  /// pixel ratio, so a window that is exactly right can still report
  /// 1279.9998; an exact match would wait out the whole timeout there.
  test('a sub-pixel rounding difference still counts as caught up', () {
    const target = WindowSize(width: 1280, height: 720);

    expect(viewMatchesSize(const Size(1279.9998, 720.0002), target), isTrue);
    expect(viewMatchesSize(const Size(1277, 720), target), isFalse);
  });

  test('no view at all is not a match, so the wait keeps asking', () {
    expect(
      viewMatchesSize(null, const WindowSize(width: 1280, height: 720)),
      isFalse,
    );
  });

  testWidgets('a maximized handoff does not finish while the view still '
      'reports the splash width - the real UI must not build at 380px', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      windowGeometryPreferenceKey: jsonEncode(
        const WindowGeometry(
          windowedSize: WindowSize(width: 1400, height: 900),
          runState: WindowRunState.maximized,
        ).toJson(),
      ),
    });
    final port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;
    await DesktopWindowShell.prepareHandoff(_container());
    tester.view.physicalSize = const Size(380, 507);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var done = false;
    unawaited(DesktopWindowShell.revealAfterHandoff().then((_) => done = true));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump();
    expect(done, isFalse, reason: 'still at the splash width');

    tester.view.physicalSize = const Size(1920, 1080);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump();
    expect(done, isTrue);
  });

  test('viewHasLeftSplash looks at width only', () {
    expect(viewHasLeftSplash(const Size(380, 507)), isFalse);
    expect(viewHasLeftSplash(const Size(1920, 1080)), isTrue);
    expect(viewHasLeftSplash(null), isFalse);
  });
}
