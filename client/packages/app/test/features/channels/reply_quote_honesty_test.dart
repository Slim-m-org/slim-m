// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A reply's compact quote, driven through a real channel screen: it must
/// not become a second way to read a blocked author's message, and it must
/// not resurrect a deleted one.
///
/// Both collapse to the same code path - the transcript can only quote a
/// parent it can find in the exact list it is about to render, and a
/// blocked author's row and a deleted one are both simply absent from that
/// list - but each is tested by name here, mirroring `blocking_test.dart`'s
/// own reasoning: the bug this class of defect takes is never in a shared
/// filter, it is a second render site that forgot to go through it.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_sync.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.Message _message({
  required String id,
  required String authorId,
  required int seq,
  required String content,
  String? replyToId,
}) => api.Message(
  id: id,
  channelId: 'c1',
  authorId: authorId,
  authorDisplayName: authorId,
  seq: seq,
  content: content,
  createdAt: seq * 1000,
  editedAt: null,
  replyToId: replyToId,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// A container wired at a channel holding [messages], with [blocked] as the
/// server's answer to `GET /blocks`.
Future<ProviderContainer> _wire(
  WidgetTester tester, {
  required List<api.Message> messages,
  List<String> blocked = const [],
}) async {
  tester.view.physicalSize = const Size(500, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);

  await store.upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
  ]);
  await store.applyMessages(messages);

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      mockApiOverride((request) async {
        if (request.url.path == '/blocks') {
          final own = request.headers['authorization'] == 'Bearer access';
          return _json(own ? blocked : const <String>[]);
        }
        if (request.method == 'PUT' &&
            request.url.path == '/channels/c1/read') {
          final seq =
              (jsonDecode(request.body) as Map<String, dynamic>)['seq'] as int;
          return _json({'last_read_seq': seq, 'unread': 0});
        }
        if (request.url.path == '/me') {
          return _json({
            'id': 'me',
            'username': 'me',
            'display_name': 'Me',
            'created_at': 0,
            'permissions': 0,
          });
        }
        return _json(const <Object>[]);
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
  // Bounded, not pumpAndSettle: AppIconButton never stops asking for frames.
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  return container;
}

/// See `blocking_test.dart`'s own copy of this note: drift defers a
/// cancelled query stream's cleanup by one turn, which flutter_test's own
/// pending-timer check runs ahead of unless this drains it first.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  testWidgets(
    'a reply to a blocked author\'s message quotes neither their name nor '
    'their words',
    (tester) async {
      await _wire(
        tester,
        blocked: ['pest'],
        messages: [
          _message(id: 'm1', authorId: 'friend', seq: 1, content: 'hello'),
          _message(
            id: 'm2',
            authorId: 'pest',
            seq: 2,
            content: 'something a pest said',
          ),
          _message(
            id: 'm3',
            authorId: 'friend',
            seq: 3,
            content: 'replying to it',
            replyToId: 'm2',
          ),
        ],
      );

      // The row itself is gone (`blocking_test.dart` pins that); the new claim is the quote is not a second way to read it.
      expect(find.text('something a pest said'), findsNothing);
      expect(
        find.text('pest'),
        findsNothing,
        reason: 'their name must not surface through the quote either',
      );
      expect(find.text('replying to it'), findsOneWidget);
      expect(
        find.text('Message unavailable'),
        findsOneWidget,
        reason: 'the reply still says something rather than nothing at all',
      );
      await _unmount(tester);
    },
  );

  testWidgets(
    'a reply to a message this client never has locally renders honestly, '
    'not blank or broken',
    (tester) async {
      await _wire(
        tester,
        messages: [
          _message(
            id: 'm1',
            authorId: 'friend',
            seq: 1,
            content: 'replying to something gone',
            replyToId: 'never-synced',
          ),
        ],
      );

      expect(find.text('replying to something gone'), findsOneWidget);
      expect(find.text('Message unavailable'), findsOneWidget);
      await _unmount(tester);
    },
  );

  testWidgets('a reply to a since-deleted message renders honestly once the delete '
      'is applied', (tester) async {
    final container = await _wire(
      tester,
      messages: [
        _message(id: 'm1', authorId: 'friend', seq: 1, content: 'original'),
        _message(
          id: 'm2',
          authorId: 'friend',
          seq: 2,
          content: 'a reply to it',
          replyToId: 'm1',
        ),
      ],
    );

    // m1's own body, plus the quote's own snippet Text beside its author label.
    expect(find.text('original'), findsNWidgets(2));
    expect(find.text('Message unavailable'), findsNothing);

    // A delete, own or a live `message.deleted` frame, always lands as `MessageStore.discard`.
    final store = await container.read(storeProvider.future);
    await store.discard('m1');
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(
      find.text('original'),
      findsNothing,
      reason: 'the deleted message itself is gone',
    );
    expect(find.text('a reply to it'), findsOneWidget);
    expect(
      find.text('Message unavailable'),
      findsOneWidget,
      reason: 'the reply now honestly says its parent cannot be shown',
    );
    await _unmount(tester);
  });
}
