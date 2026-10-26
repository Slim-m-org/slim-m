// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How the activity panel and its announcer resolve an actor's name and keep
/// their relative times current: one sentence for both surfaces, a row that
/// only rebuilds for its own author, and a timestamp that ages while the
/// panel sits idle.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
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

ProviderContainer _container({Future<void>? gate}) => ProviderContainer(
  overrides: [
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    liveEventsProvider.overrideWithValue(const Stream.empty()),
    mockApiOverride((request) async {
      if (request.url.path != '/users') return http.Response('[]', 200);
      await gate;
      final ids = request.url.queryParameters['ids']!.split(',');
      return http.Response(
        jsonEncode([
          for (final id in ids)
            {
              'id': id,
              'username': id,
              'display_name': id == 'alice' ? 'Alice' : 'Name $id',
              'created_at': 0,
            },
        ]),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  ],
);

api.CanvasObject _obj(String id, String author) => api.CanvasObject(
  id: id,
  kind: 'stroke',
  zIndex: 1,
  x: 0,
  y: 0,
  w: 1,
  h: 1,
  props: const {},
  authorId: author,
  seq: 1,
  createdAt: 0,
);

Future<void> _pump(WidgetTester tester, ProviderContainer c, Widget w) =>
    tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(body: w),
        ),
      ),
    );

String _liveLabel(WidgetTester tester) => tester
    .getSemantics(find.byKey(CanvasActivityAnnouncer.liveRegionKey))
    .label;

Future<void> _settleRequests(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
}

void main() {
  testWidgets('the announcer waits for an uncached actor and names them like '
      'the row does', (tester) async {
    final gate = Completer<void>();
    final container = _container(gate: gate.future);
    addTearDown(container.dispose);
    final log = CanvasActivityLog(isBlocked: (_) => false);
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      container,
      Column(
        children: [
          CanvasActivityAnnouncer(activityLog: log),
          Expanded(
            child: CanvasActivityPanel(
              activityLog: log,
              summary: '1 object',
              objectCount: 1,
            ),
          ),
        ],
      ),
    );

    log.recordPlacedLive(_obj('a', 'alice'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(_liveLabel(tester), isNot('Someone placed a stroke.'));

    gate.complete();
    await _settleRequests(tester);
    await tester.pump(const Duration(seconds: 2));
    final row = tester
        .widgetList<Text>(find.textContaining('placed a stroke'))
        .map((t) => t.data!)
        .single;
    expect(row, 'Alice placed a stroke.');
    expect(_liveLabel(tester), row);

    log.dispose();
    handle.dispose();
  });

  testWidgets('resolving an unrelated profile rebuilds no activity row', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    final log = CanvasActivityLog(isBlocked: (_) => false);
    for (var i = 0; i < 12; i++) {
      log.recordPlacedLive(_obj('o$i', 'u$i'));
    }
    await _pump(
      tester,
      container,
      SizedBox(
        height: 2000,
        child: CanvasActivityPanel(
          activityLog: log,
          summary: '12',
          objectCount: 12,
        ),
      ),
    );
    await _settleRequests(tester);
    await tester.pump(const Duration(milliseconds: 50));

    var rowBuilds = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget.runtimeType.toString() == '_ActivityRow') rowBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    await tester.runAsync(
      () => container.read(batchProfilesControllerProvider.notifier).resolve([
        'somebody-not-in-the-log',
      ]),
    );
    await tester.pump();
    debugOnRebuildDirtyWidget = null;

    expect(rowBuilds, 0);
    log.dispose();
  });

  testWidgets('a row ages in an idle open panel', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    final log = CanvasActivityLog(isBlocked: (_) => false);
    await tester.runAsync(
      () => container.read(batchProfilesControllerProvider.notifier).resolve([
        'u0',
      ]),
    );
    log.recordPlacedLive(_obj('o', 'u0'));
    await _pump(
      tester,
      container,
      CanvasActivityPanel(activityLog: log, summary: '1', objectCount: 1),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('just now'), findsOneWidget);

    await tester.pump(const Duration(minutes: 5));

    expect(find.text('just now'), findsNothing);
    expect(find.text('5m ago'), findsOneWidget);
    log.dispose();
  });

  testWidgets('repeated identical summaries are announced aloud', (
    tester,
  ) async {
    final announcements = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      (message) async {
        if (message is Map && message['type'] == 'announce') {
          final data = message['data'] as Map?;
          if (data?['message'] is String) {
            announcements.add(data!['message'] as String);
          }
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(
            SystemChannels.accessibility,
            null,
          );
    });

    final container = _container();
    addTearDown(container.dispose);
    await tester.runAsync(
      () => container.read(batchProfilesControllerProvider.notifier).resolve([
        'alice',
      ]),
    );
    final log = CanvasActivityLog(
      isBlocked: (_) => false,
      announceDelay: Duration.zero,
    );
    await _pump(tester, container, CanvasActivityAnnouncer(activityLog: log));

    log.recordPlacedLive(_obj('a1', 'alice'));
    await tester.pump(Duration.zero);

    log.recordPlacedLive(_obj('a2', 'alice'));
    await tester.pump(Duration.zero);

    expect(announcements, [
      'Alice placed a stroke.',
      'Alice placed a stroke.',
    ], reason: 'repeated identical summaries must both be announced');
    log.dispose();
  });
}
