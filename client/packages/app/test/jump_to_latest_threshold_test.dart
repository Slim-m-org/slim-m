// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The jump-to-latest arrow used to key off `_atLatestSlop`, a 4-logical-
/// pixel tolerance meant for overscroll bounce, so it counted a reader as
/// "scrolled away" for the smallest real drag or settle. `TranscriptScrollTracker`
/// (`channel_transcript_scroll.dart`) now asks a second, coarser question for
/// the arrow alone: has the reader left a meaningful fraction of the
/// viewport, not merely the last few pixels of it.
///
/// Leaving that fraction is still not enough on its own: the owner reported
/// the arrow showing while the newest messages were already on screen, which
/// traced back to it appearing the instant a scroll crossed the threshold,
/// including while still heading further into history. It now shows only
/// once a sample past the threshold moves back toward the latest message,
/// not merely for having crossed it.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _seedCount = 80;

api.Message _message(String id, int seq) => api.Message(
  id: id,
  channelId: 'c1',
  authorId: 'alice',
  authorDisplayName: 'Alice',
  seq: seq,
  content: 'message $seq',
  createdAt: seq * 60000,
  editedAt: null,
);

Map<String, dynamic> _meJson() => {
  'id': 'bob',
  'username': 'bob',
  'display_name': 'Bob',
  'created_at': 0,
  'permissions': 0,
};

http.Response _emptyJsonList() => http.Response(
  jsonEncode([]),
  200,
  headers: {'content-type': 'application/json'},
);

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _mount(WidgetTester tester) async {
  tester.view.physicalSize = const Size(500, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);

  await store.upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
  ]);
  await store.applyMessages([
    for (var seq = 1; seq <= _seedCount; seq++) _message('m$seq', seq),
  ]);

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.method == 'PUT' && request.url.path.endsWith('/read')) {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              return http.Response(
                jsonEncode({'last_read_seq': body['seq'], 'unread': 0}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.method == 'GET' && request.url.path == '/me') {
              return http.Response(
                jsonEncode(_meJson()),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return _emptyJsonList();
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: ChannelScreen(channelId: 'c1')),
      ),
    ),
  );
  await _flush(tester);
}

ScrollController _transcriptScroll(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView)).controller!;

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  const jumpButton = Key('jump-to-latest-tap-target');

  testWidgets('a small nudge well under the viewport-relative threshold does not '
      'show the arrow', (tester) async {
    await _mount(tester);
    final scroll = _transcriptScroll(tester);

    // Below both the 96px floor and 30% of this harness's viewport: a single accidental drag, not a reader leaving the tail.
    scroll.jumpTo(60);
    await _flush(tester);

    expect(find.byKey(jumpButton), findsNothing);

    await _unmount(tester);
  });

  testWidgets(
    'crossing the viewport-relative threshold alone does not show the '
    'arrow, only heading back toward the latest message while still past it',
    (tester) async {
      await _mount(tester);
      final scroll = _transcriptScroll(tester);
      final threshold = scroll.position.viewportDimension * 0.3;
      expect(
        threshold,
        greaterThan(96),
        reason:
            'the seeded viewport must make the fraction the binding term, '
            'or this test would not exercise it over the fixed floor',
      );

      // Crossing the threshold on the way away must not reveal the arrow.
      scroll.jumpTo(threshold + 200);
      await _flush(tester);
      expect(find.byKey(jumpButton), findsNothing);

      // Moving further into history is still not "heading back".
      scroll.jumpTo(threshold + 300);
      await _flush(tester);
      expect(find.byKey(jumpButton), findsNothing);

      // Only once a sample moves back toward latest, still past the threshold, does the arrow appear.
      scroll.jumpTo(threshold + 100);
      await _flush(tester);
      expect(find.byKey(jumpButton), findsOneWidget);

      scroll.jumpTo(20);
      await _flush(tester);
      expect(find.byKey(jumpButton), findsNothing);

      await _unmount(tester);
    },
  );

  testWidgets(
    'reversing back into history hides the arrow again, even mid-return',
    (tester) async {
      await _mount(tester);
      final scroll = _transcriptScroll(tester);
      final threshold = scroll.position.viewportDimension * 0.3;

      scroll.jumpTo(threshold + 300);
      await _flush(tester);
      scroll.jumpTo(threshold + 100);
      await _flush(tester);
      expect(find.byKey(jumpButton), findsOneWidget);

      // Heading away again, still well past the threshold: hidden.
      scroll.jumpTo(threshold + 250);
      await _flush(tester);
      expect(find.byKey(jumpButton), findsNothing);

      await _unmount(tester);
    },
  );
}
