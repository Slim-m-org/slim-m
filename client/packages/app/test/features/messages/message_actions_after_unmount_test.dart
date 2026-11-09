// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Leaving the channel while an edit or a delete is in flight must not throw,
/// and the answer must still reach the local store.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/screens/channel_message_actions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';
import '../../support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _message = Message(
  id: 'm1',
  channelId: 'c1',
  authorId: 'self',
  seq: 1,
  content: 'hello',
  createdAt: 0,
  pending: false,
  failed: false,
);

api.Message _served(String content) => api.Message(
  id: 'm1',
  channelId: 'c1',
  authorId: 'self',
  authorDisplayName: 'self',
  seq: 1,
  content: content,
  createdAt: 0,
  editedAt: null,
);

Future<(MessageStore, Completer<void>)> _mount(
  WidgetTester tester,
  Future<void> Function(BuildContext context) onPressed,
) async {
  final gate = Completer<void>();
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  final container = ProviderContainer(
    overrides: [
      storeProvider.overrideWith((ref) async => store),
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        await gate.future;
        if (request.method == 'PATCH') {
          return http.Response(
            jsonEncode({
              'id': 'm1',
              'channel_id': 'c1',
              'author_id': 'self',
              'author_display_name': 'self',
              'seq': 1,
              'content': 'edited',
              'created_at': 0,
              'edited_at': 1,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 204);
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.runAsync(() => store.applyMessage(_served('hello')));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => onPressed(context),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  );
  return (store, gate);
}

Future<void> _leaveAndAnswer(WidgetTester tester, Completer<void> gate) async {
  await tester.pumpWidget(const SizedBox.shrink());
  gate.complete();
  // runAsync: drift's futures never complete under testWidgets' FakeAsync.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await pumpFrames(tester, frames: 2);
}

void main() {
  testWidgets(
    'a delete answered after the channel closed still drops the row',
    (tester) async {
      final (store, gate) = await _mount(
        tester,
        (context) => confirmAndDeleteMessage(context, _message),
      );
      await tester.tap(find.text('go'));
      await pumpFrames(tester, frames: 20);
      await tester.tap(find.text('Delete'));
      await tester.pump();

      await _leaveAndAnswer(tester, gate);

      expect(tester.takeException(), isNull);
      expect(
        await tester.runAsync(() => store.hasMessage('c1', 'm1')),
        isFalse,
      );
    },
  );

  testWidgets('an edit answered after the channel closed still lands locally', (
    tester,
  ) async {
    final (store, gate) = await _mount(
      tester,
      (context) => submitMessageEdit(context, _message, 'edited'),
    );
    await tester.tap(find.text('go'));
    await tester.pump();

    await _leaveAndAnswer(tester, gate);

    final rows = await tester.runAsync(() => store.watchChannel('c1').first);
    expect(tester.takeException(), isNull);
    expect(rows!.single.content, 'edited');
  });
}
