// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reproduces the "second round, 2026-07-31" backlog entry: sending a message
/// briefly shows an extra day divider above it that then disappears.
///
/// Pumped frame by frame, never `pumpAndSettle`: the flash is a difference
/// between two adjacent frames, and settling would land past it without ever
/// seeing it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart'
    show StagedSend;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_app/src/features/composer/widgets/composer.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_parts.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

/// The real controller opens a websocket to a server that is not there. See
/// `channel_screen_test.dart`, which needs the same seam for the same reason.
///
/// Sets [initialSyncCompleteProvider] directly: this fixture seeds real
/// same-day history and its own assertion is about what happens *after*
/// catch-up, so it stands in for a session that has already caught up once,
/// not one still racing its first round (that race is
/// `channel_screen_day_divider_sync_race_test.dart`'s job). The write is
/// deferred past a real `await`, or Riverpod refuses it as a provider
/// modifying another provider mid-initialization - the same reason the real
/// [SyncController.start] naturally clears this guard by the time it gets
/// there (its own first `await`, inside `_teardown`, comes first).
class _NoopSyncController extends SyncController {
  _NoopSyncController(this._testRef) : super(_testRef);

  final Ref _testRef;

  @override
  Future<void> start() async {
    await Future<void>.value();
    _testRef.read(initialSyncCompleteProvider.notifier).state = true;
  }
}

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.Message _message(String id, int seq, int createdAt) => api.Message(
  id: id,
  channelId: 'c1',
  authorId: 'alice',
  authorDisplayName: 'Alice',
  seq: seq,
  content: 'message $seq',
  createdAt: createdAt,
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

void main() {
  testWidgets(
    'sending a message does not flash a transient day divider above it',
    (tester) async {
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final now = DateTime.now().millisecondsSinceEpoch;

      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MessageStore(db);
      await store.upsertChannels([
        const api.Channel(
          id: 'c1',
          name: 'general',
          kind: 'text',
          createdAt: 0,
        ),
      ]);
      // Already today's, so the one real divider sits above m1, never here.
      await store.applyMessages([
        _message('m1', 1, now - 5000),
        _message('m2', 2, now - 4000),
        _message('m3', 3, now - 3000),
      ]);

      // Gates the send response so the test can pump through the transition.
      final sendGate = Completer<void>();

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          storeProvider.overrideWith((ref) async => store),
          syncControllerProvider.overrideWith(
            (ref) => _NoopSyncController(ref),
          ),
          mockApiOverride((request) async {
            if (request.method == 'POST' &&
                request.url.path == '/channels/c1/messages') {
              await sendGate.future;
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              return http.Response(
                jsonEncode({
                  'id': body['id'],
                  'channel_id': 'c1',
                  'author_id': 'bob',
                  'author_display_name': 'Bob',
                  'seq': 4,
                  'content': body['content'],
                  'created_at': now,
                  'edited_at': null,
                }),
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
            if (request.method == 'PUT' &&
                request.url.path == '/channels/c1/read') {
              return http.Response(
                jsonEncode({'last_read_seq': 4, 'unread': 0}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            // Members, pins and extras: not what this test is about.
            return _emptyJsonList();
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
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // Sanity: exactly one divider before anything is sent.
      expect(
        find.byType(DayDivider),
        findsOneWidget,
        reason: 'the fixture itself should start with one real day divider',
      );

      await tester.enterText(
        find.descendant(
          of: find.byType(Composer),
          matching: find.byType(TextField),
        ),
        'hello',
      );
      await tester.pump();

      final composer = tester.widget<Composer>(find.byType(Composer));
      unawaited(composer.onSend(const StagedSend([])));

      // Frame by frame, while the network call is still gated shut.
      final dividerCounts = <int>[];
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        dividerCounts.add(find.byType(DayDivider).evaluate().length);
      }

      sendGate.complete();
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        dividerCounts.add(find.byType(DayDivider).evaluate().length);
      }

      expect(
        dividerCounts.every((count) => count == 1),
        isTrue,
        reason: 'a transient extra day divider appeared: $dividerCounts',
      );

      // Unmount deliberately: drift's cancel timer fires after this test's own teardown would check.
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
    },
  );
}
