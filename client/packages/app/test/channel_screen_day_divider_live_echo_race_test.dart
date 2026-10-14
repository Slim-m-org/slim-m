// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Chases the second of the two mechanisms docs/BACKLOG.md's "sending a
/// message flashes a day divider" entry names as untried: a live
/// `message.created` echo of the sender's own message, arriving over a real
/// socket, racing that same send's own REST response.
///
/// Uses `support/sync_harness.dart`'s `SyncTestServer`, which is what makes
/// this reachable at all: it accepts the real WebSocket handshake
/// `SyncController._attach` performs, and lets the test push a frame down it
/// at a chosen moment.
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

/// The row rendering the just-sent "hello" message, or null before it has
/// mounted at all.
MessageRow? _sentRow(WidgetTester tester) {
  for (final row in tester.widgetList<MessageRow>(find.byType(MessageRow))) {
    if (row.message.content == 'hello') return row;
  }
  return null;
}

void main() {
  testWidgets('a live echo of the sent message over a real socket, racing that '
      "message's own REST response, does not flash a day divider", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final now = DateTime.now().millisecondsSinceEpoch;
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);
    // No pre-seeded messages: catch-up finds nothing, so the sent message is genuinely first.

    // `runAsync` avoids the shutdown hang `SyncTestServer`'s own doc comment explains.
    final server = (await tester.runAsync(SyncTestServer.start))!;
    await tester.pump();

    final sendGate = Completer<void>();
    String? sentId;
    final router = RestRouter()
      ..on('GET', '/channels', (_) => jsonResponse([_channelJson()]))
      ..on('GET', '/dms', (_) => jsonResponse(const <dynamic>[]))
      ..on(
        'GET',
        '/channels/c1/read',
        (_) => jsonResponse({'last_read_seq': 0, 'unread': 0}),
      )
      ..on('GET', '/me', (_) => jsonResponse(_meJson()))
      ..on(
        'POST',
        '/auth/ws-ticket',
        (_) => jsonResponse({'ticket': 'tix', 'expires_at': 0}),
      )
      ..on(
        'PUT',
        '/channels/c1/read',
        (_) => jsonResponse({'last_read_seq': 3, 'unread': 0}),
      )
      // Answered immediately: this test's race is the echo versus the send's own REST response.
      ..on(
        'POST',
        '/sync',
        (_) => jsonResponse({
          'scopes': [
            {
              'channel_id': 'c1',
              'messages': <dynamic>[],
              'has_more': false,
              'reset': false,
            },
          ],
        }),
      )
      ..on('POST', '/channels/c1/messages', (request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        sentId = body['id'] as String;
        await sendGate.future;
        return jsonResponse({
          'id': body['id'],
          'channel_id': 'c1',
          'author_id': 'bob',
          'author_display_name': 'Bob',
          'seq': 1,
          'content': body['content'],
          'created_at': now,
          'edited_at': null,
        });
      });

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async => store),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: server.baseUrl,
            session: ref.watch(sessionProvider),
            httpClient: router.build(),
          );
          ref.onDispose(client.close);
          return client;
        }),
        // Not overriding syncControllerProvider: this test needs the real one to reach a socket.
      ],
    );
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(body: ChannelScreen(channelId: 'c1')),
          ),
        ),
      );
      // Long enough for the empty catch-up and the real WS handshake to both land.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

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

      // The REST response is still gated: push the server's own echo down the live socket first.
      expect(
        sentId,
        isNotNull,
        reason:
            'the send must have reached the server before its echo '
            'can be pushed',
      );
      server.pushEvent({
        'type': 'message.created',
        'message': {
          'id': sentId,
          'channel_id': 'c1',
          'author_id': 'bob',
          'author_display_name': 'Bob',
          'seq': 1,
          'content': 'hello',
          'created_at': now,
          'edited_at': null,
        },
      });
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final row = _sentRow(tester);
        if (row != null) dividerOnSentMessage.add(row.dayLabel != null);
      }

      sendGate.complete();
      for (var i = 0; i < 15; i++) {
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
        {true},
        reason:
            'the sent message is genuinely the channel'
            "'s first, so its divider must never disappear: "
            '$dividerOnSentMessage',
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
      // `runAsync` again, for the same reason `SyncTestServer.start` needed it above.
      await tester.runAsync(server.close);
    }
  });
}
