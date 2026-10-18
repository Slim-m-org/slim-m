// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The activity panel and its always-mounted announcer, as an actual
/// accessibility tree rather than a widget reasoned about on paper - see
/// this file's own dumped-tree assertion for why that distinction mattered
/// elsewhere in this product.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_log.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_panel.dart';
import 'package:slimm_design_system/design_system.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _container() => ProviderContainer(
  overrides: [
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    liveEventsProvider.overrideWithValue(const Stream.empty()),
    mockApiOverride((request) async {
      if (request.url.path == '/users') {
        return http.Response(
          jsonEncode([
            {
              'id': 'alice',
              'username': 'alice',
              'display_name': 'Alice',
              'created_at': 0,
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('[]', 200);
    }),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  testWidgets('each entry renders as its own real sentence, both as visible text and '
      'as a Semantics label a screen reader reads', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    // Not addTearDown: tearDown runs after the binding's pending-timer check, so the announce Timer must be cancelled in the test body itself.
    final log = CanvasActivityLog(isBlocked: (_) => false);
    log
      ..recordPlacedLive(
        const api.CanvasObject(
          id: 'a',
          kind: 'stroke',
          zIndex: 1,
          x: 0,
          y: 0,
          w: 1,
          h: 1,
          props: {},
          authorId: 'alice',
          seq: 1,
          createdAt: 0,
        ),
      )
      ..recordClearedLive('op-2');

    await _pump(
      tester,
      container,
      CanvasActivityPanel(
        activityLog: log,
        summary: '2 objects: 2 strokes',
        objectCount: 2,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('2 objects: 2 strokes'), findsOneWidget);
    expect(find.text('The canvas was cleared.'), findsOneWidget);
    // AppListRow merges its `meta` timestamp into the same label, hence substring rather than equality.
    expect(
      find.bySemanticsLabel(RegExp(RegExp.escape('The canvas was cleared.'))),
      findsOneWidget,
    );
    // Resolved through the real profile fetch, not left at a raw id.
    expect(find.text('Alice placed a stroke.'), findsOneWidget);

    // The real tree, not a widget read on paper: two rows plus the header.
    final tree = tester
        .binding
        .renderViews
        .first
        .owner!
        .semanticsOwner!
        .rootSemanticsNode!
        .toStringDeep();
    expect(tree, contains('The canvas was cleared.'));
    expect(tree, contains('2 objects: 2 strokes'));
    expect(
      'isFocusable'.allMatches(tree).length,
      2,
      reason: 'both rows must be real Tab stops, not swipe-only',
    );
    // Dumped once by hand: each row carries `actions: focus, flags: isFocusable`, so Tab reaches it, not only a screen reader's own swipe.
    log.dispose();
  });

  testWidgets('an empty log says so rather than rendering a blank list', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    final log = CanvasActivityLog(isBlocked: (_) => false);
    addTearDown(log.dispose);

    await _pump(
      tester,
      container,
      CanvasActivityPanel(
        activityLog: log,
        summary: 'no objects',
        objectCount: 0,
      ),
    );

    expect(find.text('No canvas activity yet.'), findsOneWidget);
    expect(
      find.textContaining("before you joined"),
      findsNothing,
      reason: 'a genuinely empty canvas has nothing to explain away',
    );
  });

  /// canvas.md: the summary above ("N objects") and an empty log below used
  /// to contradict each other with nothing explaining why - content can
  /// predate this viewer's own activity-log session (a catch-up gap, or ops
  /// aged past retention), which is exactly this state for a real user.
  testWidgets(
    'a nonzero object count above an empty log explains the gap rather '
    'than contradicting it',
    (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      final log = CanvasActivityLog(isBlocked: (_) => false);
      addTearDown(log.dispose);

      await _pump(
        tester,
        container,
        CanvasActivityPanel(
          activityLog: log,
          summary: '11 objects: 2 strokes, 2 images, 3 notes, 4 shapes',
          objectCount: 11,
        ),
      );

      expect(find.text('No canvas activity yet.'), findsOneWidget);
      expect(
        find.text("Activity from before you joined isn't shown here."),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'the announcer is silent until a batch actually flushes, then carries '
    'the summary as its live-region label',
    (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      // Not addTearDown: see the earlier test's own note on the announce Timer.
      final log = CanvasActivityLog(
        isBlocked: (_) => false,
        announceDelay: const Duration(milliseconds: 1),
      );

      await _pump(tester, container, CanvasActivityAnnouncer(activityLog: log));
      await tester.pump();

      final region = find.byKey(CanvasActivityAnnouncer.liveRegionKey);
      final before = tester.widget<Semantics>(region);
      expect(before.properties.liveRegion, isTrue);
      expect(before.properties.label, '');

      log.recordClearedLive('op-1');
      await tester.pump(const Duration(milliseconds: 5));

      final after = tester.widget<Semantics>(region);
      expect(after.properties.label, 'The canvas was cleared.');
      log.dispose();
    },
  );
}
