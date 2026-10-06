import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/failed_send_retry.dart';
import 'package:slimm_app/src/providers/message_actions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';

/// A fake api that answers every send with [failing]'s current verdict and
/// records each request body.
class _Rig {
  _Rig() {
    db = SlimmDatabase(NativeDatabase.memory());
    store = MessageStore(db);
    container = ProviderContainer(
      overrides: [
        storeProvider.overrideWith((ref) async => store),
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
            httpClient: MockClient(_answer),
          ),
        ),
      ],
    );
  }

  late final SlimmDatabase db;
  late final MessageStore store;
  late final ProviderContainer container;
  final bodies = <Map<String, dynamic>>[];
  bool failing = true;

  Future<http.Response> _answer(http.Request request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    bodies.add(body);
    if (failing) return http.Response('{"error":"boom"}', 503);
    return http.Response(
      jsonEncode({
        'id': body['id'],
        'channel_id': 'c1',
        'author_id': 'bob',
        'author_display_name': 'Bob',
        'seq': 1,
        'content': body['content'],
        'created_at': 0,
        'edited_at': null,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  Future<void> sendWithAttachment(String id, String content) =>
      sendOptimistically(
        container.read,
        id: id,
        channelId: 'c1',
        authorId: 'bob',
        content: content,
        attachmentIds: const ['att-1'],
      );

  Future<void> dispose() async {
    container.dispose();
    await db.close();
  }
}

void main() {
  late _Rig rig;

  setUp(() => rig = _Rig());
  tearDown(() => rig.dispose());

  test(
    'the reconnect retry of a failed send carries its attachments',
    () async {
      await rig.sendWithAttachment('m1', '');
      expect(rig.bodies.single['attachment_ids'], ['att-1']);

      rig.failing = false;
      await retryFailedSends(
        rig.container.read,
        rig.store,
        isCurrent: () => true,
      );

      expect(rig.bodies, hasLength(2));
      expect(rig.bodies.last['attachment_ids'], ['att-1']);
    },
  );

  test('the Retry button on a failed send carries its attachments', () async {
    await rig.sendWithAttachment('m1', 'caption');
    final failed = (await rig.store.failedMessages()).single;

    rig.failing = false;
    await retryMessage(rig.container.read, failed);

    expect(rig.bodies.last['attachment_ids'], ['att-1']);
    expect(rig.bodies.last['content'], 'caption');
  });

  test('a retry that lands leaves nothing queued to retry again', () async {
    await rig.sendWithAttachment('m1', '');
    rig.failing = false;
    await retryFailedSends(
      rig.container.read,
      rig.store,
      isCurrent: () => true,
    );

    expect(await rig.store.failedMessages(), isEmpty);
  });

  test('a text-only failed send retries without an attachment list', () async {
    await sendOptimistically(
      rig.container.read,
      id: 'm1',
      channelId: 'c1',
      authorId: 'bob',
      content: 'hello',
    );
    rig.failing = false;
    await retryFailedSends(
      rig.container.read,
      rig.store,
      isCurrent: () => true,
    );

    expect(rig.bodies.last['attachment_ids'] ?? const <String>[], isEmpty);
  });
}
