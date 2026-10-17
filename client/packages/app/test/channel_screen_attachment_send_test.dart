// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The attachment-only send, driven end to end through the real screen.
///
/// Every other test of this feature stops one layer short: the composer suite
/// asserts its `onSend` fired, and the server suite asserts an empty body is
/// accepted. `ChannelScreen._send` sits between them and is the only
/// production consumer of that callback, so its own empty-text guard could
/// drop the send on the floor with all of them still green. That is exactly
/// what it used to do.
///
/// So this stages a real file through the real picker, presses the real send
/// button with the field untouched, and asserts a POST actually left for the
/// server carrying the attachment.
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

import 'composer_harness.dart' show pickedFile, sendButton, usePicker;
import 'support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// A frame count rather than `pumpAndSettle`: `AppIconButton`'s hover
/// machinery keeps a frame scheduled forever in this environment, so settling
/// never returns. Long enough for the sheet's animation either way.
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets('a staged file with no caption reaches the server', (
    tester,
  ) async {
    // Compact, so the composer's secondary actions sit behind the add button
    // in a sheet: the phone path, and the one a photo is actually sent from.
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    usePicker(pickedFile());
    final posted = <Map<String, dynamic>>[];

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
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              if (request.method == 'POST' &&
                  request.url.path == '/attachments') {
                return http.Response(
                  jsonEncode({
                    'id': 'a1',
                    'filename': 'holiday.png',
                    'content_type': 'image/png',
                    'size': 4,
                  }),
                  201,
                  headers: {'content-type': 'application/json'},
                );
              }
              if (request.method == 'POST' &&
                  request.url.path == '/channels/c1/messages') {
                final body = jsonDecode(request.body) as Map<String, dynamic>;
                posted.add(body);
                return http.Response(
                  jsonEncode({
                    'id': body['id'],
                    'channel_id': 'c1',
                    'author_id': 'bob',
                    'author_display_name': 'Bob',
                    'seq': 1,
                    'content': body['content'],
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
              // Members, pins and the extras fetch: none of them are what
              // this is about, so an empty list answers all of them.
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

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is AppIconButton && w.semanticLabel == 'More actions',
      ),
    );
    await _flush(tester);
    await tester.tap(find.text('Browse files'));
    await _flush(tester);

    expect(
      find.text('holiday.png'),
      findsOneWidget,
      reason: 'the pick must be staged before the send means anything',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
      reason: 'nothing typed: the whole point of this test',
    );

    await tester.tap(sendButton);
    await _flush(tester);

    expect(
      posted,
      hasLength(1),
      reason:
          'the screen dropped the send when the field was empty, so a '
          'photo with no caption went nowhere however staged it looked',
    );
    expect(posted.single['content'], '');
    expect(posted.single['attachment_ids'], ['a1']);

    // Unmount deliberately: the drift query streams cancel on a zero-duration
    // timer, and the framework's own teardown checks for pending ones first.
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  });
}
