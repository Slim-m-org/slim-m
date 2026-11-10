// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The mount, the names and the fake server the conversation-and-search review
/// suites share: one real shell on a route, both themes captured from one
/// mount, and an `act` step for everything that needs a tap or a seeded row.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/home_shell.dart' show HomeShell;
import 'package:slimm_data/data.dart' show MessageStore;
import 'package:slimm_design_system/design_system.dart';

import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';
import 'review_support.dart' as review;
import 'ui_review_conversation_and_search_server.dart';

export 'ui_review_conversation_and_search_server.dart';

/// The two windows a review frame is taken at; desktop never narrower, or the app switches to its touch layout.
enum ReviewViewport {
  phone('phone', Size(390, 844)),
  desktop('desktop', Size(1280, 800));

  const ReviewViewport(this.slug, this.size);

  final String slug;
  final Size size;
}

const bothViewports = ReviewViewport.values;
const bothThemes = ['dark', 'light'];

/// [review.reviewName] with the viewport as a [ReviewViewport].
String reviewName(
  String surface,
  String? state,
  ReviewViewport viewport,
  String theme,
) => review.reviewName(surface, state, viewport.slug, theme);

/// What an `act` step can reach: the tester, the app's container and the frame size.
class ReviewRig {
  ReviewRig(this.tester, this.container, this.viewport);

  final WidgetTester tester;
  final ProviderContainer container;
  final ReviewViewport viewport;

  bool get isPhone => viewport == ReviewViewport.phone;

  Future<MessageStore> get store => container.read(storeProvider.future);

  /// A context under the router, for the `show*` entry points the app opens from a button.
  BuildContext get shellContext =>
      tester.element(find.byWidgetPredicate((w) => w is HomeShell));

  SemanticsHandle? _semantics;

  /// Turns semantics on so a control can be found by its accessible name; released after the capture.
  void enableSemantics() => _semantics ??= tester.ensureSemantics();

  void release() => _semantics?.dispose();

  /// A timed frame, which unlike `pumpAndSettle` cannot hang on a spinner.
  Future<void> pumpFor([int milliseconds = 350]) =>
      tester.pump(Duration(milliseconds: milliseconds));

  Future<void> settle() async {
    await tester.pump();
    await pumpFor();
    await pumpFor();
  }

  /// A tap on the first widget showing [label], then enough time for what it opens.
  Future<void> tapText(String label) async {
    await tester.tap(find.text(label).first);
    await settle();
  }

  /// A tap on the control with this accessible name; call [enableSemantics] and let a frame pass first.
  Future<void> tapByLabel(String label) async {
    await tester.tap(find.bySemanticsLabel(label).first);
    await settle();
  }

  /// Types [text] into [field], then lets a debounce and a reply land.
  Future<void> typeInto(Finder field, String text) async {
    await tester.enterText(field, text);
    await settle();
    await pumpFor();
  }
}

typedef ReviewAct = Future<void> Function(ReviewRig rig);

/// Rows written to the local store before the shell mounts, so the first frame already has them.
typedef ReviewSeed = Future<void> Function(MessageStore store);

/// Mounts the real shell and writes a dark and a light frame for [surface] and [state].
///
/// [route] is a shell route; [pushRoute] is pushed over [route] after the first frame,
/// the way settings and a thread are reached in the app. [router] replaces the shared
/// fixture's, for a route it does not carry.
Future<void> renderReview(
  WidgetTester tester, {
  required String surface,
  required ReviewViewport viewport,
  String? state,
  String route = '/channels/c-general',
  String? pushRoute,
  GoRouter? router,
  List<Override> overrides = const [],
  ReviewServe? serve,
  int permissions = -1,
  int? timedOutUntil,
  String? timeoutReason,
  List<api.Message>? messages,
  ReviewSeed? seed,
  ReviewAct? act,
  bool allowNoText = false,
  bool knownTransient = false,
  Duration drain = Duration.zero,
  List<String> themes = bothThemes,
  int settleFrames = 2,
}) async {
  tester.view.physicalSize = viewport.size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final client = reviewClient(
    serve: serve,
    permissions: permissions,
    timedOutUntil: timedOutUntil,
    timeoutReason: timeoutReason,
  );
  final fixture = await fixtureContainer(
    extraOverrides: [reviewApi(client), ...overrides],
    messages: messages,
  );
  if (seed != null) {
    await seed(await fixture.container.read(storeProvider.future));
  }
  final goRouter = router ?? fixtureRouter(route);
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
        routerConfig: goRouter,
        builder: appChromeBuilder,
      ),
    ),
  );

  await tester.pumpWidget(build(themes.first));
  final pushed =
      pushRoute ??
      (router == null && isModalFixtureRoute(route) ? route : null);
  if (pushed != null) {
    await tester.pump();
    unawaited(goRouter.push(pushed));
  }
  // Two pumps settle on-mount entrance animations; pumpAndSettle would hang on a spinner.
  await tester.pump();
  for (var i = 0; i < settleFrames; i++) {
    await tester.pump(const Duration(milliseconds: 350));
  }
  final rig = ReviewRig(tester, fixture.container, viewport);
  if (act != null) {
    await act(rig);
    await tester.pump(const Duration(milliseconds: 350));
  }

  Object? firstException;
  for (final theme in themes) {
    if (theme != themes.first) {
      await tester.pumpWidget(build(theme));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }
    final name = reviewName(surface, state, viewport, theme);
    await expectSettled(
      tester,
      name,
      knownTransient: knownTransient,
      allowNoText: allowNoText,
    );
    await writeSnapshot(tester, name);
    firstException ??= tester.takeException();
  }
  expect(firstException, isNull);

  // Lets timers the surface started (a flash fading out) finish while it is still mounted.
  await tester.pump(drain);
  rig.release();
  fixture.container.dispose();
  releaseHungRequests();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  await fixture.db.close();
}

/// Registers one test per viewport that renders [surface] at [state].
void reviewCase(
  String surface, {
  String? state,
  List<ReviewViewport> viewports = bothViewports,
  String route = '/channels/c-general',
  String? pushRoute,
  GoRouter Function()? router,
  List<Override> Function()? overrides,
  ReviewServe? serve,
  int permissions = -1,
  int? timedOutUntil,
  String? timeoutReason,
  List<api.Message> Function()? messages,
  ReviewSeed? seed,
  ReviewAct? act,
  bool allowNoText = false,
  bool knownTransient = false,
  Duration drain = Duration.zero,
  List<String> themes = bothThemes,
  int settleFrames = 2,
  TargetPlatform? platform,
}) {
  for (final viewport in viewports) {
    testWidgets(
      '$surface${state == null ? '' : ' $state'} at ${viewport.slug}'
      '${themes.length == 1 ? ' (${themes.single})' : ''} fits its viewport',
      (tester) => renderReview(
        tester,
        surface: surface,
        state: state,
        viewport: viewport,
        route: route,
        pushRoute: pushRoute,
        router: router?.call(),
        overrides: overrides?.call() ?? const [],
        serve: serve,
        permissions: permissions,
        timedOutUntil: timedOutUntil,
        timeoutReason: timeoutReason,
        messages: messages?.call(),
        seed: seed,
        act: act,
        allowNoText: allowNoText,
        knownTransient: knownTransient,
        drain: drain,
        themes: themes,
        settleFrames: settleFrames,
      ),
      variant: platform == null
          ? const DefaultTestVariant()
          : TargetPlatformVariant.only(platform),
    );
  }
}
