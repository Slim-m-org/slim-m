// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the voice review suites share: the two review viewports, the PNG name
/// rule, one routed mount that captures dark then light from a single build,
/// and the call fixtures (people, a call that has run a while, a controller).
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/call_dock_hint.dart'
    show shareHintSeenKey;
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_design_system/design_system.dart';

import '../support/fake_sync.dart';
import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';

export 'ui_review_voice_fakes.dart';

/// The two windows a review capture is taken at; desktop is never narrower,
/// because a narrow window switches the app to its touch layout.
const reviewViewportSizes = <String, Size>{
  'phone': Size(390, 844),
  'desktop': Size(1280, 800),
};

/// Both viewports, the default for a surface that exists at both widths.
const reviewViewports = ['phone', 'desktop'];

const reviewThemes = ['dark', 'light'];

/// `<surface>[--<state>]--<viewport>-<theme>`, the name every review PNG carries.
String reviewVoiceName(
  String surface,
  String viewport,
  String theme, {
  String? state,
}) => state == null
    ? '$surface--$viewport-$theme'
    : '$surface--$state--$viewport-$theme';

typedef ReviewStep =
    Future<void> Function(WidgetTester tester, ProviderContainer container);

/// A short run of timed frames: long enough for a menu, a sheet or a toast to
/// land, without `pumpAndSettle` waiting on a ticker that never stops.
Future<void> reviewFrames(WidgetTester tester, {int frames = 4}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// A right-click held past the press deadline, the way a mouse makes one.
Future<void> reviewRightClick(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(
    tester.getCenter(target),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await tester.pump(kPressTimeout + const Duration(milliseconds: 20));
  await gesture.up();
  await reviewFrames(tester);
}

Future<void> reviewLongPress(WidgetTester tester, Finder target) async {
  await tester.longPress(target);
  await reviewFrames(tester);
}

/// Opens a menu the way the viewport's own input does: a long press on a
/// phone, a right-click on a desktop.
Future<void> reviewOpenMenu(
  WidgetTester tester,
  String viewport,
  Finder target,
) => viewport == 'phone'
    ? reviewLongPress(tester, target)
    : reviewRightClick(tester, target);

/// Parks a mouse over [target], which is what reveals a hover-only control.
Future<void> reviewHover(WidgetTester tester, Finder target) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await tester.pump();
  await mouse.moveTo(tester.getCenter(target));
  await reviewFrames(tester);
}

/// A routed mount of the real shell at [route], captured in [reviewThemes]
/// from one build: the surface is settled in dark, [step] drives it (open a
/// menu, hover a tile), and the same tree is re-themed for light.
///
/// [seed] runs against the container before the first frame, for data the
/// shared fixture does not carry (an extra channel, a bot member).
/// [modal] pushes [route] over the channel shell, as a settings screen opens.
/// [release] frees anything a capture held open (a request that never answers)
/// once the PNGs are written, so the test does not end with a timer pending.
Future<void> renderReview(
  WidgetTester tester, {
  required String surface,
  required String viewport,
  required String route,
  String? state,
  List<Override> overrides = const [],
  Future<void> Function(ProviderContainer container)? seed,
  ReviewStep? step,
  List<Widget> overlays = const [],
  List<RouteBase> extraRoutes = const [],
  bool modal = false,
  bool openChat = false,
  VoidCallback? release,
  List<api.Message>? messages,
  bool settleJoinTransition = false,
  bool allowNoText = false,
  List<String> themes = reviewThemes,
}) async {
  tester.view.physicalSize = reviewViewportSizes[viewport]!;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final fixture = await fixtureContainer(
    extraOverrides: [
      // Connected, so no capture carries the harness's own offline banner.
      syncControllerProvider.overrideWith(StubSyncController.new),
      ...overrides,
    ],
    messages: messages,
  );
  // The first-run share hint is a tooltip over the dock that no review wants.
  SharedPreferences.setMockInitialValues({shareHintSeenKey: true});
  if (seed != null) await seed(fixture.container);
  final router = _routerFor(
    route,
    extraRoutes,
    modal: modal,
    openChat: openChat,
  );
  Widget build(String theme) {
    final app = MaterialApp.router(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(
        snapshotThemes[theme]!.brightness,
        snapshotThemes[theme]!.tokens,
      ),
      routerConfig: router,
      builder: overlays.isEmpty
          ? appChromeBuilder
          : (context, child) => Stack(
              children: [appChromeBuilder(context, child), ...overlays],
            ),
    );
    return UncontrolledProviderScope(
      container: fixture.container,
      child: RepaintBoundary(key: snapshotBoundary, child: app),
    );
  }

  await tester.pumpWidget(build(themes.first));
  if (modal) {
    await tester.pump();
    unawaited(router.push(route));
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  if (settleJoinTransition) {
    await tester.pump(const Duration(milliseconds: 350));
  }
  await tester.pump(const Duration(milliseconds: 350));
  if (step != null) {
    await step(tester, fixture.container);
    await tester.pump(const Duration(milliseconds: 350));
  }
  Object? firstException;
  for (final theme in themes) {
    if (theme != themes.first) {
      await tester.pumpWidget(build(theme));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }
    final name = reviewVoiceName(surface, viewport, theme, state: state);
    await expectSettled(tester, name, allowNoText: allowNoText);
    await writeSnapshot(tester, name);
    firstException ??= tester.takeException();
  }
  expect(firstException, isNull);

  release?.call();
  await teardownFixture(tester, fixture.container, fixture.db);
}

/// The fixture's own routes plus [extra], so a surface the matrix router does
/// not carry (call stats) can still be pushed over the shell.
GoRouter _routerFor(
  String route,
  List<RouteBase> extra, {
  required bool modal,
  required bool openChat,
}) {
  final base = fixtureRouter(modal ? '/channels/c-general' : route);
  if (extra.isEmpty && !modal && !openChat) return base;
  return GoRouter(
    initialLocation: modal ? '/channels/c-general' : route,
    routes: [
      for (final r in base.configuration.routes)
        if (!openChat || r is! ShellRoute) r,
      if (openChat) _chatShell,
      ...extra,
    ],
  );
}

/// The shell with its channel route handed `?chat=1`, as the real router does.
final _chatShell = ShellRoute(
  builder: (context, state, child) => HomeShell(child: child),
  routes: [
    GoRoute(
      path: '/channels/:channelId',
      builder: (context, state) => ConversationPane(
        channelId: state.pathParameters['channelId']!,
        openChat: true,
      ),
    ),
  ],
);
