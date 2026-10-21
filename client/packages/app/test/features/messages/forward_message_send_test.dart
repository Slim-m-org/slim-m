// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The forward picker driven end to end: opening it, picking a target, and
/// what actually leaves for the server.
///
/// A forward is a wire field now, not composed text, so what leaves has to
/// be checked here rather than against a pure function: the id of the
/// original goes up as `forwarded_from_id` and the sender's own note is the
/// `content`, which is empty whenever they wrote none.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/messages/widgets/forward_message.dart';
import 'package:slimm_data/data.dart' as data;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_sync.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _sourceMessage = data.Message(
  id: 'm1',
  channelId: 'c1',
  authorId: 'alice',
  authorDisplayName: 'Alice',
  seq: 1,
  content: 'hello\nworld',
  createdAt: 1000,
  pending: false,
  failed: false,
);

/// Everything a test here needs: a real local store and a mocked API whose
/// `/channels/c2/messages` POST is captured rather than actually sent
/// anywhere, plus whatever attachments [attachments] stages on
/// [_sourceMessage] before the picker ever opens.
class _Harness {
  _Harness({List<api.Attachment> attachments = const [], int sendStatus = 200})
    : postedBodies = [] {
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async => store),
        syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
        mockApiOverride((request) async {
          if (request.method == 'GET' && request.url.path == '/channels') {
            return http.Response(
              jsonEncode([
                {
                  'id': 'c2',
                  'name': 'general',
                  'kind': 'text',
                  'created_at': 0,
                  'permissions': 1 << 2 | 1 << 10,
                },
              ]),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.method == 'GET' && request.url.path == '/dms') {
            return http.Response(
              '[]',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.method == 'GET' && request.url.path == '/blocks') {
            return http.Response(
              '[]',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.method == 'POST' &&
              request.url.path == '/channels/c2/messages') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            postedBodies.add(body);
            if (sendStatus != 200) {
              return http.Response('{"error":"nope"}', sendStatus);
            }
            return http.Response(
              jsonEncode({
                'id': body['id'],
                'channel_id': 'c2',
                'author_id': 'bob',
                'author_display_name': 'Bob',
                'seq': 2,
                'content': body['content'],
                'created_at': 2000,
                'edited_at': null,
                'attachment_ids': body['attachment_ids'],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 404);
        }),
      ],
    );
    container
        .read(messageExtrasProvider.notifier)
        .applyMessage(
          api.Message(
            id: 'm1',
            channelId: 'c1',
            authorId: 'alice',
            authorDisplayName: 'Alice',
            seq: 1,
            content: 'hello\nworld',
            createdAt: 1000,
            editedAt: null,
            attachments: attachments,
          ),
        );
  }

  final db = data.SlimmDatabase(NativeDatabase.memory());
  late final store = data.MessageStore(db);
  final List<Map<String, dynamic>> postedBodies;
  late final ProviderContainer container;

  Future<void> dispose() async {
    container.dispose();
    await db.close();
  }
}

Future<void> _pump(WidgetTester tester, _Harness harness) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ElevatedButton(
              onPressed: () => forwardMessage(context, ref, _sourceMessage),
              child: const Text('Forward'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Forward'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('forwarding a message with attachments carries the same '
      'attachment ids', (tester) async {
    final harness = _Harness(
      attachments: const [
        api.Attachment(
          id: 'aaaa',
          filename: 'holiday.png',
          contentType: 'image/png',
          size: 4,
        ),
        api.Attachment(
          id: 'bbbb',
          filename: 'notes.txt',
          contentType: 'text/plain',
          size: 2,
        ),
      ],
    );
    addTearDown(harness.dispose);
    await _pump(tester, harness);

    await tester.tap(find.text('general'));
    await tester.pumpAndSettle();
    // Flushes the success toast's auto-dismiss timer so it never outlives the widget tree.
    await tester.pump(const Duration(seconds: 5));

    expect(harness.postedBodies, hasLength(1));
    expect(harness.postedBodies.single['attachment_ids'], ['aaaa', 'bbbb']);
  });

  testWidgets('a forward names the original and quotes nothing into its own '
      'content', (tester) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await _pump(tester, harness);

    await tester.tap(find.text('general'));
    await tester.pumpAndSettle();
    // Flushes the success toast's auto-dismiss timer so it never outlives the widget tree.
    await tester.pump(const Duration(seconds: 5));

    final body = harness.postedBodies.single;
    expect(body['forwarded_from_id'], 'm1');
    expect(
      body['content'],
      '',
      reason: 'the note is the sender\'s own, and they wrote none',
    );
  });

  testWidgets('a note typed in the picker is sent as the message content, '
      'with the forward still named', (tester) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await _pump(tester, harness);

    await tester.enterText(
      find.ancestor(
        of: find.text('Say something about it (optional)'),
        matching: find.byType(TextField),
      ),
      '  look at this  ',
    );
    await tester.tap(find.text('general'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));

    final body = harness.postedBodies.single;
    expect(body['content'], 'look at this');
    expect(body['forwarded_from_id'], 'm1');
  });

  testWidgets('a forward that fails shows an AppErrorState, never a '
      'SnackBar, and the picker stays open', (tester) async {
    final harness = _Harness(sendStatus: 403);
    addTearDown(harness.dispose);
    await _pump(tester, harness);

    await tester.tap(find.text('general'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Could not forward the message: you are not allowed to do that.',
      ),
      findsOneWidget,
    );
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    // The picker never popped: the target row is still there to retry.
    expect(find.text('general'), findsOneWidget);
  });
}
