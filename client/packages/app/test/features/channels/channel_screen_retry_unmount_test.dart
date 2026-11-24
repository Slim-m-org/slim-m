// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Retrying a failed send still finishes when the transcript is gone before
/// the server answers: the sent message is kept and the row stops failing.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';
import '../../support/fake_sync.dart';
import '../composer/composer_harness.dart' show sendButton;

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _json = {'content-type': 'application/json'};

void main() {
  testWidgets('a retry answered after the transcript left is still kept', (
    tester,
  ) async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    final sends = <Map<String, dynamic>>[];
    Completer<void>? hold;
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async => store),
        syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
        mockApiOverride((request) async {
          final path = request.url.path;
          if (request.method == 'POST' && path == '/channels/c1/messages') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            sends.add(body);
            if (sends.length == 1) {
              return http.Response(
                jsonEncode({'error': 'message is too long'}),
                400,
                headers: _json,
              );
            }
            await hold?.future;
            return http.Response(
              jsonEncode({
                'id': body['id'],
                'channel_id': 'c1',
                'author_id': 'bob',
                'author_display_name': 'Bob',
                'seq': 1,
                'content': body['content'],
                'created_at': 1000,
              }),
              200,
              headers: _json,
            );
          }
          if (path == '/me') {
            return http.Response(
              jsonEncode({
                'id': 'bob',
                'username': 'bob',
                'display_name': 'Bob',
                'created_at': 0,
                'permissions': 0,
              }),
              200,
              headers: _json,
            );
          }
          if (request.method == 'PUT' && path == '/channels/c1/read') {
            return http.Response(
              jsonEncode({'last_read_seq': 1, 'unread': 0}),
              200,
              headers: _json,
            );
          }
          return http.Response(jsonEncode([]), 200, headers: _json);
        }),
      ],
    );
    addTearDown(container.dispose);
    final shown = ValueNotifier(true);
    addTearDown(shown.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: shown,
              builder: (context, on, _) =>
                  on ? const ChannelScreen(channelId: 'c1') : const SizedBox(),
            ),
          ),
        ),
      ),
    );
    await pumpFrames(tester);
    await tester.enterText(
      find.byWidgetPredicate((w) => w is TextField),
      'a message',
    );
    await pumpFrames(tester);
    await tester.tap(sendButton);
    await pumpFrames(tester);
    expect(find.text('Retry'), findsOneWidget);
    hold = Completer<void>();

    await tester.tap(find.text('Retry'));
    await tester.runAsync(() async {
      while (sends.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    shown.value = false;
    await pumpFrames(tester);
    hold.complete();
    var kept = false;
    await tester.runAsync(() async {
      for (var i = 0; i < 400 && !kept; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        kept = (await store.failedMessages()).isEmpty;
      }
    });

    expect(tester.takeException(), isNull);
    expect(kept, isTrue, reason: 'the retried message stopped failing');
    expect(sends[1]['id'], sends[0]['id'], reason: 'the same message');
  });
}
