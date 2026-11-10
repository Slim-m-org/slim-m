// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Mounts the real shell at a review window, drives one overlay or state over it, and captures both themes from that one mount.
///
/// Stands in for `review_support.dart` until batch review-harness-and-auth lands; the names match so the swap is an import.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/providers/providers.dart'
    show apiProvider, sessionProvider;
import 'package:slimm_design_system/design_system.dart';

import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';

/// The two windows a review captures at; desktop is never narrower, or the app switches to its touch layout.
enum ReviewViewport {
  phone('phone', Size(390, 844)),
  desktop('desktop', Size(1280, 800));

  const ReviewViewport(this.slug, this.size);

  final String slug;
  final Size size;
}

/// The only place a review PNG's name is built: `<surface>[--<state>]--<viewport>-<theme>`.
String reviewName(
  String surface, {
  String? state,
  required ReviewViewport viewport,
  required String theme,
}) => '$surface${state == null ? '' : '--$state'}--${viewport.slug}-$theme';

/// A JSON reply, as the server sends one.
http.Response reviewJson(Object? body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);

/// A 204, the reply to a write with nothing to say.
http.Response reviewNoContent() => http.Response('', 204);

/// Answers with [handler] where it returns a reply, and from the fixture's own fake server where it returns null.
Override reviewApi(FutureOr<http.Response?> Function(http.Request) handler) =>
    apiProvider.overrideWith((ref) {
      final client = api.SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: ref.watch(sessionProvider),
        httpClient: MockClient(
          (request) async => await handler(request) ?? fixtureResponse(request),
        ),
      );
      ref.onDispose(client.close);
      return client;
    });

/// What a case's `drive` holds: the mounted app and the few moves every overlay case makes.
class ReviewRig {
  ReviewRig(this.tester, this.container, this.router);

  final WidgetTester tester;
  final ProviderContainer container;
  final GoRouter router;

  /// A context under the root navigator, the kind the app's own call sites hold.
  BuildContext get context =>
      router.routerDelegate.navigatorKey.currentState!.overlay!.context;

  /// Lets an opened route finish animating in and a fetch behind it land.
  Future<void> settle() async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));
  }

  /// Lets work that leaves the fake clock (a platform channel reply) come back before the frames that show it.
  Future<void> settleReal() async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await settle();
  }

  Future<void> open(Future<Object?> Function(BuildContext context) show) async {
    unawaited(show(context));
    await settle();
  }

  Future<void> tapText(String label) async {
    await tester.tap(find.text(label));
    await settle();
  }

  Future<void> tapTooltip(String tooltip) async {
    await tester.tap(find.byTooltip(tooltip));
    await settle();
  }

  /// Types into [field] of the [of] inputs the open sheet holds; the sheet is above the composer, so it is counted from the end.
  Future<void> type(String text, {int field = 0, int of = 1}) async {
    final inputs = find.bySubtype<EditableText>();
    final index = tester.widgetList(inputs).length - of + field;
    await tester.enterText(inputs.at(index), text);
    await settle();
  }
}

typedef ReviewDrive = Future<void> Function(ReviewRig rig);

/// Registers one test per viewport: mount the shell, run [drive], capture dark and light.
void reviewCase(
  String surface, {
  String? state,
  ReviewDrive? drive,
  List<Override> Function()? overrides,
  Iterable<ReviewViewport> viewports = ReviewViewport.values,
}) {
  for (final viewport in viewports) {
    testWidgets(
      '$surface${state == null ? '' : ' $state'} at ${viewport.slug} fits in both themes',
      (tester) => _capture(
        tester,
        surface,
        state,
        viewport,
        overrides?.call() ?? const [],
        drive,
      ),
    );
  }
}

Future<void> _capture(
  WidgetTester tester,
  String surface,
  String? state,
  ReviewViewport viewport,
  List<Override> overrides,
  ReviewDrive? drive,
) async {
  tester.view.physicalSize = viewport.size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // The test default is android, which draws touch text-selection handles on the desktop window.
  if (viewport == ReviewViewport.desktop) {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  }
  try {
    await _mountAndCapture(tester, surface, state, viewport, overrides, drive);
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<void> _mountAndCapture(
  WidgetTester tester,
  String surface,
  String? state,
  ReviewViewport viewport,
  List<Override> overrides,
  ReviewDrive? drive,
) async {
  final fixture = await fixtureContainer(extraOverrides: overrides);
  final router = fixtureRouter('/channels/c-general');
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
        builder: appChromeBuilder,
      ),
    ),
  );

  await tester.pumpWidget(build('dark'));
  final rig = ReviewRig(tester, fixture.container, router);
  await rig.settle();
  if (drive != null) await drive(rig);

  Object? firstException;
  for (final theme in const ['dark', 'light']) {
    if (theme != 'dark') {
      await tester.pumpWidget(build(theme));
      await rig.settle();
    }
    final name = reviewName(
      surface,
      state: state,
      viewport: viewport,
      theme: theme,
    );
    await expectSettled(tester, name);
    await writeSnapshot(tester, name);
    firstException ??= tester.takeException();
  }
  expect(firstException, isNull);

  // A toast, snackbar or request-timeout timer outliving the test fails it.
  await tester.pump(const Duration(seconds: 60));
  await teardownFixture(tester, fixture.container, fixture.db);
}
