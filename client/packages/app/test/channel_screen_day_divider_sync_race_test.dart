// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Chases the first of the two mechanisms docs/BACKLOG.md's "sending a
/// message flashes a day divider" entry names as untried: a real catch-up
/// round landing between an optimistic send and that send's own REST
/// response. (The second, a live socket echo racing the same response, is
/// `channel_screen_day_divider_live_echo_race_test.dart`, which is what
/// needs `support/sync_harness.dart`'s `SyncTestServer` - this one does not:
/// `_catchUp` runs, and can be gated and released, entirely before
/// `SyncController.start` ever reaches `_attach`.)
///
/// Every other test in this suite substitutes `_NoopSyncController` for
/// `SyncController`, which is exactly what stopped this from being driven at
/// all. This one runs the real controller instead, against a
/// [RestRouter]-backed `SlimmApi` with `/auth/ws-ticket` answering an error:
/// `_attach` then fails fast and deterministically once catch-up completes,
/// which is enough to observe the whole catch-up race without needing a
/// socket that actually connects.
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
import 'package:slimm_app/src/widgets/composer_attachments.dart'
    show StagedSend;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/channel_screen.dart';
import 'package:slimm_app/src/widgets/composer.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/sync_harness.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _channelJson() => {
  'id': 'c1',
  'name': 'general',
  'kind': 'text',
  'created_at': 0,
};

Map<String, dynamic> _meJson() => {
  'id': 'bob',
  'username': 'bob',
  'display_name': 'Bob',
  'created_at': 0,
  'permissions': 0,
};

Map<String, dynamic> _messageJson(String id, int seq, int createdAt) => {
  'id': id,
  'channel_id': 'c1',
  'author_id': 'alice',
  'author_display_name': 'Alice',
  'seq': seq,
  'content': 'history $seq',
  'created_at': createdAt,
  'edited_at': null,
};

/// The row rendering the just-sent "hello" message, or null before it has
/// mounted at all. Found by content rather than id: the pending row's id
/// comes from `newMessageId()` inside `_send`, which this test never sees.
MessageRow? _sentRow(WidgetTester tester) {
  for (final row in tester.widgetList<MessageRow>(find.byType(MessageRow))) {
    if (row.message.content == 'hello') return row;
  }
  return null;
}

Future<ProviderContainer> _pumpChannelScreen(
  WidgetTester tester, {
  required SlimmDatabase db,
  required MessageStore store,
  required RestRouter router,
}) async {
  tester.view.physicalSize = const Size(500, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          // Never dialled: REST is intercepted by router, and attach fails at the ticket mint.
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: router.build(),
        );
        ref.onDispose(client.close);
        return client;
      }),
      // Deliberately not overriding syncControllerProvider: this suite drives the real one.
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: ChannelScreen(channelId: 'c1')),
      ),
    ),
  );
  return container;
}

void main() {
  testWidgets('a catch-up round landing after an optimistic send does not flash a '
      'day divider onto the sent message', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);
    // No pre-seeded messages: the local cache starts genuinely empty, like a fresh device.

    final syncGate = Completer<void>();
    final router = RestRouter()
      ..on('GET', '/channels', (_) => jsonResponse([_channelJson()]))
      ..on('GET', '/dms', (_) => jsonResponse(const <dynamic>[]))
      ..on(
        'GET',
        '/channels/c1/read',
        (_) => jsonResponse({'last_read_seq': 0, 'unread': 0}),
      )
      ..on('GET', '/me', (_) => jsonResponse(_meJson()))
      // A refusal, not a ticket: the catch-up race is over before `_attach` runs - see the library doc.
      ..on('POST', '/auth/ws-ticket', (_) => http.Response('', 503))
      ..on('PUT', '/channels/c1/read', (_) {
        return jsonResponse({'last_read_seq': 4, 'unread': 0});
      })
      ..on('POST', '/sync', (request) async {
        await syncGate.future;
        return jsonResponse({
          'scopes': [
            {
              'channel_id': 'c1',
              'messages': [
                _messageJson('h1', 1, now - 5000),
                _messageJson('h2', 2, now - 4000),
              ],
              'has_more': false,
              'reset': false,
            },
          ],
        });
      })
      ..on('POST', '/channels/c1/messages', (request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return jsonResponse({
          'id': body['id'],
          'channel_id': 'c1',
          'author_id': 'bob',
          'author_display_name': 'Bob',
          'seq': 3,
          'content': body['content'],
          'created_at': now,
          'edited_at': null,
        });
      });

    // Disposed in the `finally` below, not via addTearDown: the retry timer `_attach` schedules must be gone before this function returns.
    final container = await _pumpChannelScreen(
      tester,
      db: db,
      store: store,
      router: router,
    );
    try {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // Catch-up is still gated shut: send now, with nothing cached for this channel.
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

      final dividerOnSentMessage = <bool>[];
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final row = _sentRow(tester);
        if (row != null) dividerOnSentMessage.add(row.dayLabel != null);
      }

      // Release catch-up: two same-day messages land, both older than the pending send.
      syncGate.complete();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final row = _sentRow(tester);
        if (row != null) dividerOnSentMessage.add(row.dayLabel != null);
      }

      expect(
        dividerOnSentMessage,
        isNotEmpty,
        reason: 'the sent message must have rendered at least once',
      );
      expect(
        dividerOnSentMessage.toSet(),
        {false},
        reason:
            'a day divider flashed onto the sent message and was then '
            'removed once catch-up revealed an earlier same-day '
            'predecessor: $dividerOnSentMessage',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
    } finally {
      container.dispose();
      await tester.pump();
      // A beat for the composer's slow-mode countdown to close out its channel-row subscription before the pending-timer check runs.
      await tester.pump(const Duration(milliseconds: 50));
    }
  });
}
