// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Regression test for the dead read-state feature: `SlimmApi.markRead` and
/// `MessageStore.setReadMarker` were both implemented and unit-tested in
/// isolation, but nothing in the running UI ever called either, so the
/// unread dot never cleared no matter how long a channel sat open and fully
/// read. This drives the actual screen rather than the two methods in
/// isolation, since the bug was never in either method.
library;

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
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_sync.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.Message _message(String id, int seq) => api.Message(
  id: id,
  channelId: 'c1',
  authorId: 'alice',
  authorDisplayName: 'Alice',
  seq: seq,
  content: 'message $seq',
  createdAt: seq * 1000,
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

Map<String, dynamic> _sentJson(String id, String content) => {
  'id': id,
  'channel_id': 'c1',
  'author_id': 'bob',
  'author_display_name': 'Bob',
  'seq': 3,
  'content': content,
  'created_at': 3000,
  'edited_at': null,
};

void main() {
  testWidgets(
    'opening a channel and seeing its newest message clears the unread '
    'marker, locally and on the server',
    (tester) async {
      // Compact, so the header (and everything it pulls in) never builds; the
      // read-marking path under test does not need it.
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final markReadSeqs = <int>[];
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MessageStore(db);

      /// Seed the repro directly: unread activity already sitting in the local
      /// store (as if from a prior sync while a different tab had focus), with
      /// no read marker recorded for it, exactly the state the bug report
      /// starts from.
      await store.upsertChannels([
        const api.Channel(
          id: 'c1',
          name: 'general',
          kind: 'text',
          createdAt: 0,
        ),
      ]);
      await store.applyMessages([_message('m1', 1), _message('m2', 2)]);

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          storeProvider.overrideWith((ref) async => store),

          /// Avoids constructing the real SyncController (and the websocket it
          /// would try, and fail, to open) purely to satisfy the pins/typing
          /// seams ChannelScreen builds alongside the message list.
          syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
          mockApiOverride((request) async {
            if (request.method == 'PUT' &&
                request.url.path == '/channels/c1/read') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              final seq = body['seq'] as int;
              markReadSeqs.add(seq);
              return http.Response(
                jsonEncode({'last_read_seq': seq, 'unread': 0}),
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
            // Members, pins, and the extras-hydration message fetch: none
            // of them are what this test is about, so they all answer empty.
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

      /// A bounded pump count, not pumpAndSettle: `pumpAndSettle` loops until a
      /// frame goes by with nothing scheduled, and it never sees one here,
      /// because `AppIconButton`'s ripple/hover machinery keeps requesting a
      /// frame on every empty repaint in this environment. A fixed number of
      /// pumps is more than enough to flush the drift stream's first emission
      /// and the two read-marking calls this test is actually about.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(
        markReadSeqs,
        contains(2),
        reason:
            'the newest message rendered on screen must be reported to '
            'PUT /channels/{id}/read, or the server never learns the '
            'channel was read',
      );

      final row = await (db.select(
        db.channels,
      )..where((c) => c.id.equals('c1'))).getSingle();
      expect(
        row.lastReadSeq,
        2,
        reason:
            'the local marker must advance immediately so the unread '
            'dot clears without waiting on the network call',
      );

      /// Unmount deliberately, with one more pump, rather than letting
      /// flutter_test's own end-of-test teardown do it: `ChannelScreen`'s
      /// `StreamBuilder`s cancel their drift query streams on dispose, and
      /// drift defers that cleanup by one event loop turn on a zero-duration
      /// `Timer`. Left to the framework's own teardown, the "no pending timers"
      /// check runs before that timer gets its turn and fails the test on a
      /// false positive that has nothing to do with what this test covers.
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
    },
  );

  // One return key can reach the composer twice (an iPad's hardware Enter is
  // both a key event and the field's send action), so one turn must post once.
  testWidgets('two sends in one turn post the message once', (tester) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final posted = <String>[];
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
    ]);

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async => store),
        syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
        mockApiOverride((request) async {
          if (request.method == 'POST' &&
              request.url.path == '/channels/c1/messages') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            posted.add(body['id'] as String);
            return http.Response(
              jsonEncode(
                _sentJson(body['id'] as String, body['content'] as String),
              ),
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
              jsonEncode({'last_read_seq': 3, 'unread': 0}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
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

    await tester.enterText(
      find.descendant(
        of: find.byType(Composer),
        matching: find.byType(TextField),
      ),
      'hello twice',
    );
    await tester.pump();

    // Both calls made before either is awaited, which is what one key press
    // producing two send paths does; awaiting between them would not repro.
    final composer = tester.widget<Composer>(find.byType(Composer));
    final first = composer.onSend(const StagedSend([]));
    final second = composer.onSend(const StagedSend([]));
    await Future.wait<void>([first, second]);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(
      posted,
      hasLength(1),
      reason:
          'a second send in the same turn must find an empty composer, '
          'not post the text again under a new id',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  });
}
