// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A send that fails for a reason that is not an API error still ends as a
/// failed row, and one bad row does not stop the reconnect resend of the rest.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/failed_send_retry.dart';
import 'package:slimm_app/src/features/messages/providers/message_actions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';

const _json = {'content-type': 'application/json'};

/// Fails reading the attachments of one message, as a store error would.
class _FlakyStore extends MessageStore {
  _FlakyStore(super.db);

  @override
  Future<List<String>> pendingAttachmentIds(String messageId) async {
    if (messageId == 'm1') throw StateError('store');
    return super.pendingAttachmentIds(messageId);
  }
}

class _Rig {
  _Rig() {
    db = SlimmDatabase(NativeDatabase.memory());
    store = _FlakyStore(db);
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
  bool malformed = true;

  Future<http.Response> _answer(http.Request request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    bodies.add(body);
    if (malformed) {
      return http.Response('{"id": 5}', 200, headers: _json);
    }
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
      headers: _json,
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
    'a reply of the wrong shape marks the send failed, not pending',
    () async {
      await rig.sendWithAttachment('m1', 'hello');

      final failed = await rig.store.failedMessages();
      expect(failed.map((m) => m.id), ['m1']);
    },
  );

  test(
    'one unreadable row does not stop the resend of the later ones',
    () async {
      await rig.sendWithAttachment('m1', 'first');
      await rig.sendWithAttachment('m2', 'second');
      expect(rig.bodies, hasLength(2));

      rig.malformed = false;
      await retryFailedSends(
        rig.container.read,
        rig.store,
        isCurrent: () => true,
      );

      expect(rig.bodies.last['id'], 'm2');
      expect(rig.bodies, hasLength(3));
    },
  );
}
