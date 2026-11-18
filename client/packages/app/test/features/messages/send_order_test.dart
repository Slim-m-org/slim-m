// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A burst of sends in one channel reaches the server one at a time, in the
/// order they were typed, so the seq the server assigns follows that order.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_actions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';

/// A server that numbers a message when its request finishes arriving, with
/// the requests named in [slow] held on the wire for a while.
class _SlowFirstServer {
  _SlowFirstServer(this.slow);

  final Set<String> slow;
  final seqOf = <String, int>{};
  final _seqs = <String, int>{};

  Future<http.Response> handle(http.Request request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final channelId = request.url.pathSegments[1];
    if (slow.contains(body['id'])) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    final seq = _seqs[channelId] = (_seqs[channelId] ?? 0) + 1;
    seqOf[body['id'] as String] = seq;
    return http.Response(
      jsonEncode({
        'id': body['id'],
        'channel_id': channelId,
        'author_id': 'bob',
        'author_display_name': 'Bob',
        'seq': seq,
        'content': body['content'],
        'created_at': 1,
        'edited_at': null,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

ProviderContainer _container(_SlowFirstServer server) {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      storeProvider.overrideWith((ref) async => MessageStore(db)),
      apiProvider.overrideWith(
        (ref) => api.SlimmApi(
          baseUrl: Uri.parse('http://localhost'),
          session: api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'bob',
              accessToken: 'a',
              refreshToken: 'r',
              accessExpiresAt: 99999999999999,
            ),
          ),
          httpClient: MockClient(server.handle),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _send(ProviderContainer c, String channelId, String id) =>
    sendOptimistically(
      c.read,
      id: id,
      channelId: channelId,
      authorId: 'bob',
      content: id,
    );

void main() {
  test('a burst of sends is numbered in the order it was typed', () async {
    final server = _SlowFirstServer({'m1'});
    final container = _container(server);
    await Future.wait([
      for (final id in ['m1', 'm2', 'm3']) _send(container, 'c1', id),
    ]);
    expect(server.seqOf, {'m1': 1, 'm2': 2, 'm3': 3});
  });

  test('a slow send in one channel does not hold up another', () async {
    final server = _SlowFirstServer({'a1'});
    final container = _container(server);
    final slow = _send(container, 'c1', 'a1');
    var otherDone = false;
    final other = _send(container, 'c2', 'b1').then((_) => otherDone = true);
    await other;
    expect(otherDone, isTrue);
    expect(server.seqOf.containsKey('a1'), isFalse);
    await slow;
  });

  test('a failed send does not stop the next one', () async {
    var calls = 0;
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        storeProvider.overrideWith((ref) async => MessageStore(db)),
        apiProvider.overrideWith(
          (ref) => api.SlimmApi(
            baseUrl: Uri.parse('http://localhost'),
            session: api.SessionStore(
              tokens: const api.TokenPair(
                userId: 'bob',
                accessToken: 'a',
                refreshToken: 'r',
                accessExpiresAt: 99999999999999,
              ),
            ),
            httpClient: MockClient((request) async {
              calls++;
              return http.Response('{"error":"no"}', 403);
            }),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await Future.wait([
      _send(container, 'c1', 'x1'),
      _send(container, 'c1', 'x2'),
    ]);
    expect(calls, 2);
    final store = await container.read(storeProvider.future);
    expect((await store.failedMessages()).map((m) => m.id).toSet(), {
      'x1',
      'x2',
    });
  });
}
