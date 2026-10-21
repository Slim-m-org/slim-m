// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A local "database is locked" must not lose or fail a send: the message
/// still reaches the server and the store write is retried.
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

class _LockedStore extends MessageStore {
  _LockedStore(super.db, {required this.failApply, required this.failAdd});

  int failApply;
  int failAdd;

  @override
  Future<void> addPending({
    required String id,
    required String channelId,
    required String authorId,
    required String content,
    String? replyToId,
    bool mentionReply = true,
    List<String> attachmentIds = const [],
    List<String> spoilerIds = const [],
  }) async {
    if (failAdd-- > 0) throw StateError('database is locked');
    return super.addPending(
      id: id,
      channelId: channelId,
      authorId: authorId,
      content: content,
      replyToId: replyToId,
      mentionReply: mentionReply,
      attachmentIds: attachmentIds,
      spoilerIds: spoilerIds,
    );
  }

  @override
  Future<void> applyMessage(api.Message message) async {
    if (failApply-- > 0) throw StateError('database is locked');
    return super.applyMessage(message);
  }
}

Future<int> _sendWith(_LockedStore Function(SlimmDatabase) make) async {
  var posts = 0;
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      storeProvider.overrideWith((ref) async => make(db)),
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
            posts++;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'id': body['id'],
                'channel_id': 'c1',
                'author_id': 'bob',
                'author_display_name': 'Bob',
                'seq': 1,
                'content': body['content'],
                'created_at': 1,
                'edited_at': null,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await sendOptimistically(
    container.read,
    id: 'm1',
    channelId: 'c1',
    authorId: 'bob',
    content: 'hi',
  );
  return posts;
}

void main() {
  test('a locked store when queueing still sends the message', () async {
    final posts = await _sendWith(
      (db) => _LockedStore(db, failApply: 0, failAdd: 5),
    );
    expect(posts, 1);
  });

  test('a lock error storing the reply is retried, not thrown', () async {
    late _LockedStore store;
    final posts = await _sendWith(
      (db) => store = _LockedStore(db, failApply: 1, failAdd: 0),
    );
    expect(posts, 1);
    expect(store.failApply, lessThan(0));
  });
}
