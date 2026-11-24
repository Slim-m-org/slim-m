// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A send queued behind a slow one never goes out under another account.
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_actions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';

const _alice = api.TokenPair(
  userId: 'alice',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 99999999999999,
);

const _bob = api.TokenPair(
  userId: 'bob',
  accessToken: 'b',
  refreshToken: 'r',
  accessExpiresAt: 99999999999999,
);

void main() {
  test('a queued send is dropped once another account is signed in', () async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final session = api.SessionStore(tokens: _alice);
    final firstOnWire = Completer<void>();
    final posts = <String>[];
    final container = ProviderContainer(
      overrides: [
        storeProvider.overrideWith((ref) async => MessageStore(db)),
        sessionProvider.overrideWithValue(session),
        apiProvider.overrideWith(
          (ref) => api.SlimmApi(
            baseUrl: Uri.parse('http://localhost'),
            session: session,
            httpClient: MockClient((request) async {
              if (request.method != 'POST') return http.Response('{}', 404);
              posts.add('${request.headers['authorization']} ${request.body}');
              await firstOnWire.future;
              return http.Response('{"error":"no"}', 403);
            }),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    Future<void> send(String id) => sendOptimistically(
      container.read,
      id: id,
      channelId: 'c1',
      authorId: 'alice',
      content: id,
    );
    final first = send('m1');
    await pumpEventQueue();
    final second = send('m2');
    await pumpEventQueue();

    session.set(null);
    session.set(_bob);
    firstOnWire.complete();
    await Future.wait([first, second]);

    expect(posts, hasLength(1));
    expect(posts.single, startsWith('Bearer a '));
    final store = await container.read(storeProvider.future);
    expect(await store.failedMessages(), isEmpty);
  });
}
