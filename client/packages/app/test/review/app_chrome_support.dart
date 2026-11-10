// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The mount and the naming every app-chrome review suite shares.
///
/// The review desktop is 1280x800, and `renderSurfaceThemes` reads its size
/// from a const map that is not this batch's to edit, so this mounts the same
/// seeded fixture at any size and writes the same PNGs through
/// `writeSnapshot`, once per theme from a single mount.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_app/src/desktop/update_watch.dart';
import 'package:slimm_app/src/providers/providers.dart' show appInfoProvider;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../desktop/support/desktop_shell_fixture.dart';
import '../desktop/support/fake_desktop_window_port.dart';
import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';
import 'review_support.dart' as review;

const reviewPhone = Size(390, 844);
const reviewDesktop = Size(1280, 800);

/// The two review viewports and the size each one's window must be.
const reviewViewports = {'phone': reviewPhone, 'desktop': reviewDesktop};

/// `<surface>[--<state>]--<viewport>-<theme>`, the name the gallery parses.
String chromeName(
  String surface, {
  String? state,
  required String viewport,
  required String theme,
}) {
  if (!review.reviewThemes.contains(theme)) {
    throw ArgumentError.value(theme, 'theme', 'must be dark or light');
  }
  return review.reviewName(surface, state, viewport, theme);
}

/// What a step that runs after the first settle can reach.
typedef ChromeApp = ({
  WidgetTester tester,
  ProviderContainer container,
  GoRouter router,
});

/// Puts [chrome] around the app the way `main.dart` puts its own wrappers.
typedef ChromeWrap = Widget Function(BuildContext context, Widget app);

/// Mounts the real shell at [route] in the [viewport] window, settles it,
/// and captures dark then light, asserting no overflow along the way.
Future<void> captureChromeApp(
  WidgetTester tester, {
  required String route,
  required String viewport,
  required String surface,
  String? state,
  List<Override> overrides = const [],
  ChromeWrap? wrap,
  Future<void> Function(ChromeApp app)? afterSettle,
  bool allowNoText = false,
}) async {
  tester.view.physicalSize = reviewViewports[viewport]!;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final fixture = await fixtureContainer(extraOverrides: overrides);
  final router = fixtureRouter(route);
  Widget build(String theme) => UncontrolledProviderScope(
    container: fixture.container,
    child: RepaintBoundary(
      key: snapshotBoundary,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(
          snapshotThemes[theme]!.brightness,
          snapshotThemes[theme]!.tokens,
        ),
        routerConfig: router,
        // The test window is transparent, so a banner above the shell needs a base to read on.
        builder: (context, child) {
          final app = appChromeBuilder(context, child);
          return ColoredBox(
            color: Theme.of(context).extension<AppTokens>()!.surfaceBase,
            child: wrap == null ? app : wrap(context, app),
          );
        },
      ),
    ),
  );

  await tester.pumpWidget(build('dark'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
  if (afterSettle != null) {
    await afterSettle((
      tester: tester,
      container: fixture.container,
      router: router,
    ));
    await tester.pump(const Duration(milliseconds: 350));
  }
  Object? firstException;
  for (final theme in const ['dark', 'light']) {
    if (theme != 'dark') {
      await tester.pumpWidget(build(theme));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }
    final name = chromeName(
      surface,
      state: state,
      viewport: viewport,
      theme: theme,
    );
    await expectSettled(tester, name, allowNoText: allowNoText);
    await writeSnapshot(tester, name);
    firstException ??= tester.takeException();
  }
  expect(firstException, isNull);

  await teardownFixture(tester, fixture.container, fixture.db);
}

/// A desktop window shell over a fake port, wired the way the running app has one.
///
/// The update watcher gets no timer and the app version is fixed, so a capture
/// never waits on a poll or reads the platform for either.
List<Override> desktopChromeOverrides({
  FakeDesktopWindowPort? port,
  bool frameless = true,
  ClientUpdate? update,
}) => [
  desktopWindowShellProvider.overrideWithValue(
    shellFor(port, active: true, frameless: frameless),
  ),
  updateWatcherProvider.overrideWith(
    (ref) => UpdateWatcher(ref, shouldRun: () => false),
  ),
  appInfoProvider.overrideWith(
    (ref) async => PackageInfo(
      appName: 'slim-m',
      packageName: 'top.npcserver.slimm',
      version: '0.127.0',
      buildNumber: '1',
    ),
  ),
  if (update != null) inSessionUpdateProvider.overrideWith((ref) => update),
];

/// The newer build the update surfaces announce, on an rpm install.
const reviewUpdate = ClientUpdate(
  version: '0.128.0',
  releaseUrl: 'https://example.invalid/releases/0.128.0',
  format: InstallFormat.rpm,
);
