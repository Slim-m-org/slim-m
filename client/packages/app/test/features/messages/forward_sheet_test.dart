// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The forward sheet end to end: forwarding into the message's own channel,
/// the preview and sections it draws, and picking by keyboard on a pointer.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/widgets/forward_message.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' as data;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';
import '../../support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _source = data.Message(
  id: 'm1',
  channelId: 'c1',
  authorId: 'alice',
  authorDisplayName: 'Alice',
  seq: 1,
  content: 'the release is out',
  createdAt: 1000,
  pending: false,
  failed: false,
);

Map<String, dynamic> _channel(String id, String name) => {
  'id': id,
  'name': name,
  'kind': 'text',
  'created_at': 0,
  'permissions': 1 << 2 | 1 << 10,
};

Map<String, dynamic> _dm(String channelId, String userId, String name) => {
  'channel_id': channelId,
  'user': {
    'id': userId,
    'username': userId,
    'display_name': name,
    'created_at': 0,
  },
  'unread': 0,
  'created_at': 0,
};

class _Harness {
  _Harness() {
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async => store),
        syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
        mockApiOverride(_respond),
      ],
    );
  }

  final db = data.SlimmDatabase(NativeDatabase.memory());
  late final store = data.MessageStore(db);
  late final ProviderContainer container;
  final posted = <({String channelId, Map<String, dynamic> body})>[];
  var listed = false;

  http.Response _json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );

  Future<http.Response> _respond(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path == '/channels') {
      return _json([_channel('c1', 'general'), _channel('c2', 'random')]);
    }
    if (request.method == 'GET' && path == '/dms') {
      listed = true;
      return _json([_dm('n1', 'bob', 'Bob'), _dm('d1', 'priya', 'Priya')]);
    }
    if (request.method == 'GET' && path == '/blocks') return _json([]);
    final send = RegExp(r'^/channels/(\w+)/messages$').firstMatch(path);
    if (request.method == 'POST' && send != null) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      posted.add((channelId: send.group(1)!, body: body));
      return _json({
        'id': body['id'],
        'channel_id': send.group(1),
        'author_id': 'bob',
        'author_display_name': 'Bob',
        'seq': 2,
        'content': body['content'],
        'created_at': 2000,
        'edited_at': null,
        'attachment_ids': body['attachment_ids'],
      });
    }
    return http.Response('{}', 404);
  }

  Future<void> dispose() async {
    container.dispose();
    await db.close();
  }
}

Future<_Harness> _open(WidgetTester tester) async {
  final harness = _Harness();
  addTearDown(harness.dispose);
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
            builder: (context, ref, _) => TextButton(
              onPressed: () => forwardMessage(context, ref, _source),
              child: const Text('Forward'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Forward'));
  await pumpFrames(tester);
  await waitUntil(tester, () => harness.listed);
  return harness;
}

Future<void> _waitForSend(WidgetTester tester, _Harness harness) async {
  await waitUntil(tester, () => harness.posted.isNotEmpty);
  // Flushes the success toast's auto-dismiss timer so it never outlives the tree.
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  testWidgets('forwarding into the channel the message sits in posts a new '
      'forward there', (tester) async {
    final harness = await _open(tester);

    await tester.tap(find.text('general'));
    await _waitForSend(tester, harness);

    final sent = harness.posted.single;
    expect(sent.channelId, 'c1');
    expect(sent.body['forwarded_from_id'], 'm1');
    final landed = await tester.runAsync(
      () => harness.store.hasMessage('c1', sent.body['id'] as String),
    );
    expect(landed, isTrue);
  });

  testWidgets('the sheet previews the message and groups where it can go', (
    tester,
  ) async {
    await _open(tester);

    final preview = find.byKey(const Key('forward-preview'));
    expect(
      find.descendant(of: preview, matching: find.text('Alice')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: preview, matching: find.text('the release is out')),
      findsOneWidget,
    );
    expect(find.text('SUGGESTED'), findsOneWidget);
    expect(find.text('CHANNELS'), findsOneWidget);
    expect(find.text('This channel'), findsOneWidget);
    expect(find.text('Notes'), findsOneWidget);
    expect(find.byIcon(AppIcons.notebook), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('general')).dy,
      lessThan(tester.getTopLeft(find.text('Notes')).dy),
      reason: 'the message\'s own channel leads the suggestions',
    );
    expect(
      tester.getTopLeft(find.text('Priya')).dy,
      lessThan(tester.getTopLeft(find.text('random')).dy),
      reason: 'recent conversations are suggested before the channel list',
    );
  });

  testWidgets('arrows move the highlight and Enter forwards to it', (
    tester,
  ) async {
    final harness = await _open(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _waitForSend(tester, harness);

    expect(harness.posted.single.channelId, 'n1');
  });

  testWidgets('Enter after a search forwards to the first match', (
    tester,
  ) async {
    final harness = await _open(tester);

    await tester.enterText(find.byKey(forwardSearchKey), 'rand');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _waitForSend(tester, harness);

    expect(harness.posted.single.channelId, 'c2');
  });
}
