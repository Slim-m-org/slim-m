// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// audit F0105: unmount ChannelScreen mid-send.
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
import 'package:slimm_app/src/screens/channel_screen.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'package:slimm_app/src/providers/slow_mode_controller.dart'
    show slowModeLastSentProvider;
import 'dart:async';

import 'composer_harness.dart' show sendButton;

/// The real controller opens a websocket to a server that is not there. See
/// `channel_screen_test.dart`, which needs the same seam for the same reason.
class _NoopSyncController extends SyncController {
  _NoopSyncController(super.ref);

  @override
  Future<void> start() async {}
}

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// A frame count rather than `pumpAndSettle`: `AppIconButton`'s hover
/// machinery keeps a frame scheduled forever in this environment, so settling
/// never returns.
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets(
    'sending then leaving the channel still records the send (no StateError)',
    (tester) async {
      final gate = Completer<void>();
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

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          storeProvider.overrideWith((ref) async => store),
          syncControllerProvider.overrideWith(
            (ref) => _NoopSyncController(ref),
          ),
          apiProvider.overrideWith((ref) {
            final client = api.SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient((request) async {
                if (request.method == 'POST' &&
                    request.url.path == '/channels/c1/messages') {
                  final b = jsonDecode(request.body) as Map<String, dynamic>;
                  await gate.future;
                  return http.Response(
                    jsonEncode({
                      'id': b['id'],
                      'channel_id': 'c1',
                      'author_id': 'bob',
                      'author_display_name': 'Bob',
                      'seq': 1,
                      'content': b['content'],
                      'created_at': 1000,
                      'edited_at': null,
                    }),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                if (request.method == 'GET' && request.url.path == '/me') {
                  return http.Response(
                    jsonEncode({
                      'id': 'bob',
                      'username': 'bob',
                      'display_name': 'Bob',
                      'created_at': 0,
                      'permissions': 0,
                    }),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                if (request.method == 'PUT' &&
                    request.url.path == '/channels/c1/read') {
                  return http.Response(
                    jsonEncode({'last_read_seq': 1, 'unread': 0}),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                // Members, pins and the extras fetch: an empty list answers all of them.
                return http.Response(
                  jsonEncode([]),
                  200,
                  headers: {'content-type': 'application/json'},
                );
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

      await tester.enterText(find.byType(TextField), 'a very long message');
      await _flush(tester);
      await tester.tap(sendButton);
      await _flush(tester);

      await tester.pumpWidget(const SizedBox.shrink());
      gate.complete();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      final err = tester.takeException();
      // ignore: avoid_print
      print('uncaught after unmount: $err');
      expect(err, isNull);
      expect(container.read(slowModeLastSentProvider), contains('c1'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
    },
  );
}
