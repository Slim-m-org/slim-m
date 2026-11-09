// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sending a poll again after a reply was lost: the retry carries the id the
/// first attempt did, so the server returns the poll it made, and an edited
/// poll is a new one.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/poll_composer_sheet.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' as data;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';
import '../../support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _Rig {
  _Rig() {
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async => data.MessageStore(db)),
        syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
        mockApiOverride(_handle),
      ],
    );
  }

  final db = data.SlimmDatabase(NativeDatabase.memory());
  late final ProviderContainer container;
  final posts = <Map<String, dynamic>>[];

  /// The server takes the next poll but its reply never arrives.
  bool dropNextReply = true;

  List<Object?> get ids => [for (final p in posts) p['id']];

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path != '/channels/c1/messages/polls') {
      return http.Response('{}', 404);
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    posts.add(body);
    if (dropNextReply) {
      dropNextReply = false;
      throw http.ClientException('connection closed');
    }
    return http.Response(
      jsonEncode({
        'id': body['id'],
        'channel_id': 'c1',
        'author_id': 'me',
        'author_display_name': 'Me',
        'seq': 1,
        'content': '',
        'created_at': 1000,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  Future<void> dispose() async {
    container.dispose();
    await db.close();
  }
}

Finder _field(String placeholder) => find.byWidgetPredicate(
  (w) => w is AppInput && w.placeholder == placeholder,
);

const _unreachable =
    'Could not send the poll: the server could not be reached. '
    'Nothing was changed.';

Future<void> _open(WidgetTester tester, _Rig rig) async {
  tester.view.physicalSize = const Size(1000, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: rig.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPollComposerSheet(context, 'c1'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump(const Duration(seconds: 1));
  await tester.enterText(_field('Ask a question'), 'Board game night?');
  await tester.enterText(_field('Option 1'), 'Catan');
  await tester.enterText(_field('Option 2'), 'Wingspan');
  await tester.pump();
}

/// Taps Send poll and waits for the request to reach the server.
Future<void> _send(WidgetTester tester, _Rig rig) async {
  final before = rig.posts.length;
  await tester.ensureVisible(find.text('Send poll'));
  await tester.tap(find.text('Send poll'));
  await waitUntil(tester, () => rig.posts.length > before);
}

void main() {
  testWidgets('a retry after a lost reply sends the same id', (tester) async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    await _open(tester, rig);

    await _send(tester, rig);
    expect(find.text(_unreachable), findsOneWidget);
    await _send(tester, rig);

    expect(rig.ids, hasLength(2));
    expect(rig.ids[1], rig.ids[0], reason: 'the server replays the first poll');
    expect(find.text('Send poll'), findsNothing, reason: 'the sheet closed');
  });

  testWidgets('an option edited after a failure is a new poll', (tester) async {
    final rig = _Rig();
    addTearDown(rig.dispose);
    await _open(tester, rig);

    await _send(tester, rig);
    await tester.enterText(_field('Option 2'), 'Azul');
    await tester.pump();
    await _send(tester, rig);

    expect(rig.ids, hasLength(2));
    expect(
      rig.ids[1],
      isNot(rig.ids[0]),
      reason: 'a replayed id would send the old options',
    );
    expect(rig.posts[1]['options'], ['Catan', 'Azul']);
  });
}
