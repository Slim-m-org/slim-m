// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Switching the thread a docked pane shows while the previous thread's
/// parent lookup is still in flight must not write the old thread's parent
/// under the new thread's channel id.
library;

import 'dart:async';
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
import 'package:slimm_app/src/screens/thread_screen.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

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

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets('a thread switch mid-lookup keeps each row under its own id', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);
    final c1Gate = Completer<void>();

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async => store),
        syncControllerProvider.overrideWith((ref) => _NoopSyncController(ref)),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              final path = request.url.path;
              if (path == '/me') {
                return _json({
                  'id': 'bob',
                  'username': 'bob',
                  'display_name': 'Bob',
                  'created_at': 0,
                  'permissions': 0,
                });
              }
              if (path == '/channels/c1/thread-parent') {
                await c1Gate.future;
                return _json({
                  'parent_channel_id': 'pc',
                  'parent_message_id': 'parent-1',
                });
              }
              if (path == '/channels/c2/thread-parent') {
                return _json({
                  'parent_channel_id': 'pc',
                  'parent_message_id': 'parent-2',
                });
              }
              return _json([]);
            }),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
    addTearDown(container.dispose);

    final shown = ValueNotifier('c1');
    addTearDown(shown.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: ValueListenableBuilder<String>(
            valueListenable: shown,
            builder: (_, id, _) => ThreadScreen(channelId: id, onClose: () {}),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));

    shown.value = 'c2';
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    c1Gate.complete();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect((await store.channelRow('c2'))?.parentMessageId, 'parent-2');
    expect((await store.channelRow('c1'))?.parentMessageId, 'parent-1');

    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  });
}
