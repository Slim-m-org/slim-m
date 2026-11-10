// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the shell-and-rail review suites share: one mount per surface at the
/// two review windows, dark and light from the same tree, named through
/// `reviewName`. The gestures and seeds those surfaces need are in
/// `ui_review_shell_and_rail_actions.dart`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/features/settings/providers/display_preferences.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../support/fake_sync.dart';
import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';
import 'review_support.dart';

/// The two windows a review capture is taken at; a narrower desktop would flip the app to its touch layout.
enum ShellWindow {
  phone('phone', Size(390, 844), '/channels'),
  desktop('desktop', Size(1280, 800), '/channels/c-general');

  const ShellWindow(this.slug, this.size, this.route);

  final String slug;
  final Size size;

  /// The shell route both windows start on: the full-screen list on a phone, a channel beside the rail on desktop.
  final String route;

  bool get isPhone => this == phone;
}

/// What a surface's arrange step can reach once the shell is mounted.
typedef ShellScene = ({
  ProviderContainer container,
  SlimmDatabase db,
  ShellWindow window,
});

typedef ShellStep =
    Future<void> Function(WidgetTester tester, ShellScene scene);

/// One frame past the longest chrome animation, so an entrance has finished.
const settleDuration = Duration(milliseconds: 350);

/// The Appearance toggle reads this, so a high-contrast capture of Settings shows it on.
final _highContrastOn = highContrastControllerProvider.overrideWith(
  (ref) => HighContrastController(ref)..state = true,
);

/// Connected, as a signed-in session is nearly always; a surface about the connection overrides it.
final _liveSync = syncControllerProvider.overrideWith(
  (ref) => StubSyncController(ref, SyncStatus.live),
);

Future<void> settleFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(settleDuration);
}

/// Profile and avatar fetches answer on the real event loop, which the fake clock never runs.
Future<void> realDelay(WidgetTester tester) => tester.runAsync(
  () => Future<void>.delayed(const Duration(milliseconds: 150)),
);

/// One surface state to capture: its name and everything that sets it up.
/// [scopedOverrides] swap a provider for the tree only; [remount] builds a tree per theme, for a held drag.
class ShellCase {
  const ShellCase({
    required this.surface,
    this.state,
    this.route,
    this.overrides = const [],
    this.scopedOverrides = const [],
    this.seed,
    this.arrange,
    this.release,
    this.highContrast = false,
    this.allowNoText = false,
    this.remount = false,
  });

  final String surface;
  final String? state;
  final String? route;
  final List<Override> overrides;
  final List<Override> scopedOverrides;
  final ShellStep? seed;
  final ShellStep? arrange;
  final ShellStep? release;
  final bool highContrast;
  final bool allowNoText;
  final bool remount;
}

/// Mounts the shell, seeds and arranges it, then captures [spec] in dark and light.
Future<void> shootShell(
  WidgetTester tester,
  ShellWindow window,
  ShellCase spec,
) async {
  const themes = ['dark', 'light'];
  for (final group
      in spec.remount
          ? [
              for (final t in themes) [t],
            ]
          : [themes]) {
    await _captureOnce(tester, window, group, spec);
  }
}

Future<void> _captureOnce(
  WidgetTester tester,
  ShellWindow window,
  List<String> themes,
  ShellCase spec,
) async {
  tester.view.physicalSize = window.size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final fixture = await fixtureContainer(
    extraOverrides: [
      _liveSync,
      if (spec.highContrast) _highContrastOn,
      ...spec.overrides,
    ],
  );
  final scene = (container: fixture.container, db: fixture.db, window: window);
  await spec.seed?.call(tester, scene);
  final location = spec.route ?? window.route;
  final router = fixtureRouter(location);
  Widget build(String theme) {
    final palette = snapshotThemes[theme]!;
    final app = MaterialApp.router(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(
        palette.brightness,
        spec.highContrast ? applyHighContrast(palette.tokens) : palette.tokens,
      ),
      routerConfig: router,
      builder: appChromeBuilder,
    );
    return UncontrolledProviderScope(
      container: fixture.container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: spec.scopedOverrides.isEmpty
            ? app
            : ProviderScope(overrides: spec.scopedOverrides, child: app),
      ),
    );
  }

  await tester.pumpWidget(build(themes.first));
  if (isModalFixtureRoute(location)) {
    // Settle at the base first, then push, so the route opens as the app opens it.
    await tester.pump();
    unawaited(router.push(location));
  }
  await settleFrames(tester);
  await realDelay(tester);
  await tester.pump(settleDuration);
  final arrange = spec.arrange;
  if (arrange != null) {
    await arrange(tester, scene);
    await tester.pump(settleDuration);
    await realDelay(tester);
    await tester.pump(settleDuration);
  }
  Object? firstException;
  for (final theme in themes) {
    if (theme != themes.first) {
      await tester.pumpWidget(build(theme));
      await settleFrames(tester);
    }
    final name = reviewName(spec.surface, spec.state, window.slug, theme);
    await expectSettled(tester, name, allowNoText: spec.allowNoText);
    await writeSnapshot(tester, name);
    firstException ??= tester.takeException();
  }
  expect(firstException, isNull);
  await spec.release?.call(tester, scene);
  await teardownFixture(tester, fixture.container, fixture.db);
}
