// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The mount and naming the settings review suites share: a route or an opened
/// overlay at the two review viewports, captured in both themes from one mount.
///
/// Phone is 390x844 and desktop 1280x800; the window is never narrower than
/// that, because a narrow window switches the app to its touch layout.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';

const reviewViewports = <String, Size>{
  'phone': Size(390, 844),
  'desktop': Size(1280, 800),
};

const reviewThemes = ['dark', 'light'];

final _part = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

/// `<surface>[--<state>]--<viewport>-<theme>`, every part a kebab-case slug.
String reviewName(
  String surface,
  String viewport,
  String theme, {
  String? state,
}) {
  for (final part in [surface, ?state]) {
    if (!_part.hasMatch(part)) throw ArgumentError('bad name part: $part');
  }
  return '$surface${state == null ? '' : '--$state'}--$viewport-$theme';
}

typedef ReviewAfter = Future<void> Function(WidgetTester tester);

Future<void> _pumpSettled(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

/// A test-only selection handle under a focused field is not something a
/// person sees on first paint, so it is hidden before each capture.
Future<void> _hideSelectionHandles(WidgetTester tester) async {
  final fields = find.byWidgetPredicate((w) => w is EditableText);
  for (final state in tester.stateList<EditableTextState>(fields)) {
    state.hideToolbar();
  }
  await tester.pump();
}

/// Captures the app built by [build] in each of [themes], switching theme in
/// place so what [prepare] left open stays open.
Future<void> _captureThemes(
  WidgetTester tester,
  ProviderContainer container,
  Widget Function(String theme) build, {
  required String surface,
  required String viewport,
  required List<String> themes,
  String? state,
  bool allowNoText = false,
}) async {
  Object? firstException;
  for (final theme in themes) {
    if (theme != themes.first) {
      await tester.pumpWidget(build(theme));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }
    final name = reviewName(surface, viewport, theme, state: state);
    await _hideSelectionHandles(tester);
    await expectSettled(tester, name, allowNoText: allowNoText);
    await writeSnapshot(tester, name);
    firstException ??= tester.takeException();
  }
  expect(firstException, isNull);
}

Widget Function(String theme) _appBuilder(
  ProviderContainer container,
  GoRouter router,
) =>
    (theme) => UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(
            snapshotThemes[theme]!.brightness,
            snapshotThemes[theme]!.tokens,
          ),
          routerConfig: router,
          builder: appChromeBuilder,
        ),
      ),
    );

void _sizeWindow(WidgetTester tester, String viewport) {
  tester.view.physicalSize = reviewViewports[viewport]!;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// A route of the real router, or of [router] when the fixture one lacks it.
///
/// [freshPerTheme] mounts once per theme instead of switching in place, for a
/// popover that captures its colours when it opens. [beforeTeardown] releases
/// whatever the capture held open, since a pending request leaves a timer.
Future<void> reviewRoute(
  WidgetTester tester, {
  required String surface,
  required String viewport,
  required String route,
  String? state,
  List<Override> overrides = const [],
  bool settleNestedResolve = true,
  ReviewAfter? afterSettle,
  GoRouter? router,
  List<String> themes = reviewThemes,
  bool freshPerTheme = false,
  ReviewAfter? beforeTeardown,
}) async {
  if (freshPerTheme && themes.length > 1) {
    for (final theme in themes) {
      await reviewRoute(
        tester,
        surface: surface,
        viewport: viewport,
        route: route,
        state: state,
        overrides: overrides,
        settleNestedResolve: settleNestedResolve,
        afterSettle: afterSettle,
        router: router,
        themes: [theme],
        beforeTeardown: beforeTeardown,
      );
    }
    return;
  }
  _sizeWindow(tester, viewport);
  final fixture = await fixtureContainer(extraOverrides: overrides);
  final routed = router ?? fixtureRouter(route);
  final build = _appBuilder(fixture.container, routed);
  await tester.pumpWidget(build(themes.first));
  if (router == null && isModalFixtureRoute(route)) {
    await tester.pump();
    unawaited(routed.push(route));
  }
  await _pumpSettled(tester);
  if (settleNestedResolve) await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  if (afterSettle != null) {
    await afterSettle(tester);
    await tester.pump(const Duration(milliseconds: 350));
  }
  await _captureThemes(
    tester,
    fixture.container,
    build,
    surface: surface,
    viewport: viewport,
    themes: themes,
    state: state,
  );
  if (beforeTeardown != null) await beforeTeardown(tester);
  await teardownFixture(tester, fixture.container, fixture.db);
}

const _openerKey = Key('review-overlay-opener');

/// One empty route whose whole surface opens the overlay, so nothing but the
/// overlay itself has text on the page behind it.
GoRouter _hostRouter(FutureOr<void> Function(BuildContext, WidgetRef) open) =>
    GoRouter(
      initialLocation: '/channels/c-general',
      routes: [
        GoRoute(
          path: '/channels/:channelId',
          builder: (context, state) => Scaffold(
            body: Consumer(
              builder: (context, ref, _) => GestureDetector(
                key: _openerKey,
                behavior: HitTestBehavior.opaque,
                onTap: () => open(context, ref),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ],
    );

/// An overlay opened through its own `show*` call over a bare route.
Future<void> reviewOverlay(
  WidgetTester tester, {
  required String surface,
  required String viewport,
  required FutureOr<void> Function(BuildContext, WidgetRef) open,
  String? state,
  List<Override> overrides = const [],
  ReviewAfter? afterOpen,
  List<String> themes = reviewThemes,
  bool freshPerTheme = false,
  ReviewAfter? beforeTeardown,
}) async {
  if (freshPerTheme && themes.length > 1) {
    for (final theme in themes) {
      await reviewOverlay(
        tester,
        surface: surface,
        viewport: viewport,
        open: open,
        state: state,
        overrides: overrides,
        afterOpen: afterOpen,
        themes: [theme],
        beforeTeardown: beforeTeardown,
      );
    }
    return;
  }
  _sizeWindow(tester, viewport);
  final fixture = await fixtureContainer(extraOverrides: overrides);
  final build = _appBuilder(fixture.container, _hostRouter(open));
  await tester.pumpWidget(build(themes.first));
  await tester.pump();
  await tester.tap(find.byKey(_openerKey));
  await _pumpSettled(tester);
  if (afterOpen != null) {
    await afterOpen(tester);
    await _pumpSettled(tester);
  }
  await _captureThemes(
    tester,
    fixture.container,
    build,
    surface: surface,
    viewport: viewport,
    themes: themes,
    state: state,
  );
  if (beforeTeardown != null) await beforeTeardown(tester);
  await teardownFixture(tester, fixture.container, fixture.db);
}

typedef ReviewAnswer = FutureOr<http.Response> Function(http.Request request);

/// An api answering the keys of [answers] (`/path` or `METHOD /path`) itself
/// and the shared fixture for everything else.
Override reviewApi(Map<String, ReviewAnswer> answers) =>
    apiProvider.overrideWith((ref) {
      final client = testApi((request) async {
        final answer =
            answers['${request.method} ${request.url.path}'] ??
            answers[request.url.path];
        return answer == null ? fixtureResponse(request) : answer(request);
      }, session: ref.watch(sessionProvider));
      ref.onDispose(client.close);
      return client;
    });

ReviewAnswer jsonAnswer(Object? body, [int status = 200]) =>
    (_) => jsonHttpResponse(body, status);
