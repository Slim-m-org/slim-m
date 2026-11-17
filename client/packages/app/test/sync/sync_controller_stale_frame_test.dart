// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A frame held during a connect is older than the catch-up that ran after it
/// was sent, so replaying it must not undo what that catch-up applied.
///
/// The fake keeps the real server's order: the socket joins the fan-out when
/// its hello is read, and `/sync` answers from the durable log and op stream.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart' show pollUntil;

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _Server {
  late final HttpServer http;
  final messages = <String, Map<String, dynamic>>{};
  final ops = <Map<String, dynamic>>[];
  final subscribers = <WebSocket>[];
  void Function()? onSubscribed;

  Future<void> start() async {
    http = await HttpServer.bind('127.0.0.1', 0);
    http.listen(_handle);
  }

  void _send(Map<String, dynamic> frame) {
    for (final s in subscribers) {
      s.add(jsonEncode(frame));
    }
  }

  void create(int seq) {
    final message = {
      'id': 'm$seq',
      'channel_id': 'c1',
      'author_id': 'alice',
      'author_display_name': 'Alice',
      'seq': seq,
      'content': 'first draft',
      'created_at': 1000 + seq,
      'edited_at': null,
    };
    messages['m$seq'] = message;
    _send({'type': 'message.created', 'message': message});
  }

  void edit(int seq, String content) {
    final message = {
      ...messages['m$seq']!,
      'content': content,
      'edited_at': 5000 + ops.length,
    };
    messages['m$seq'] = message;
    ops.add({
      'seq': ops.length + 1,
      'kind': 'edit',
      'message_id': 'm$seq',
      'created_at': 5000,
    });
    _send({'type': 'message.edited', 'op_seq': ops.length, 'message': message});
  }

  void delete(int seq) {
    messages.remove('m$seq');
    ops.add({
      'seq': ops.length + 1,
      'kind': 'delete',
      'message_id': 'm$seq',
      'created_at': 5000,
    });
    _send({
      'type': 'message.deleted',
      'channel_id': 'c1',
      'message_id': 'm$seq',
      'op_seq': ops.length,
    });
  }

  Map<String, dynamic> _delta(Map<String, dynamic> scope) {
    final afterOp = scope['after_op_seq'] as int?;
    return {
      'channel_id': scope['channel_id'],
      'messages': [
        for (final m in messages.values)
          if ((m['seq'] as int) > (scope['after_seq'] as int)) m,
      ],
      'has_more': false,
      'reset': false,
      'ops': [
        if (afterOp != null)
          for (final op in ops)
            if ((op['seq'] as int) > afterOp)
              {
                ...op,
                if (op['kind'] == 'edit') ...{
                  'content': messages[op['message_id']]?['content'],
                  'edited_at': messages[op['message_id']]?['edited_at'],
                },
              },
      ],
      'op_latest_seq': ops.length,
      'ops_has_more': false,
    };
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (path == '/ws') {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['type'] != 'hello') return;
        subscribers.add(ws);
        ws.add(jsonEncode({'type': 'hello', 'protocol': protocolVersion}));
        onSubscribed?.call();
      }, onDone: () => subscribers.remove(ws));
      return;
    }
    Object body = <Object>[];
    if (path == '/channels') {
      body = [
        {
          'id': 'c1',
          'name': 'general',
          'kind': 'text',
          'created_at': 0,
          'position': 0,
        },
      ];
    } else if (path == '/sync') {
      final asked =
          jsonDecode(await utf8.decoder.bind(req).join())
              as Map<String, dynamic>;
      body = {
        'scopes': [
          for (final s
              in (asked['scopes'] as List).cast<Map<String, dynamic>>())
            _delta(s),
        ],
      };
    } else if (path == '/auth/ws-ticket') {
      body = {'ticket': 't', 'expires_at': 9999999999};
    }
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }
}

Future<(_Server, MessageStore, ProviderContainer)> _rig() async {
  final server = _Server();
  await server.start();
  addTearDown(() => server.http.close(force: true));
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  final session = SessionStore(tokens: _tokens);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(session),
      storeProvider.overrideWith((ref) async => store),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://127.0.0.1:${server.http.port}'),
          session: session,
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  return (server, store, container);
}

Future<void> _untilLive(ProviderContainer container) => pollUntil(
  () => container.read(syncControllerProvider) == SyncStatus.live,
  timeout: const Duration(seconds: 20),
  interval: const Duration(milliseconds: 25),
  reason: 'never went live',
);

void main() {
  test('a message created and deleted while connecting stays deleted', () async {
    final (server, store, container) = await _rig();
    server.create(1);
    server.onSubscribed = () {
      server.create(2);
      server.delete(2);
    };

    container.read(syncControllerProvider.notifier);
    await _untilLive(container);
    // One more frame through the queue, so the held ones are known to be applied.
    server.onSubscribed = null;
    server.create(3);
    await pollUntil(
      () async => await store.hasMessage('c1', 'm3'),
      reason: 'm3 was never held',
    );

    expect(
      await store.hasMessage('c1', 'm2'),
      isFalse,
      reason: 'the held message.created frame brought a deleted message back',
    );
  });

  test(
    'a message created and edited while connecting keeps the edit',
    () async {
      final (server, store, container) = await _rig();
      server.create(1);
      server.onSubscribed = () {
        server.create(2);
        server.edit(2, 'second draft');
      };

      container.read(syncControllerProvider.notifier);
      await _untilLive(container);
      server.onSubscribed = null;
      server.create(3);
      await pollUntil(
        () async => await store.hasMessage('c1', 'm3'),
        reason: 'm3 was never held',
      );

      final held = await store.channelSnapshot('c1');
      expect(
        held.singleWhere((m) => m.id == 'm2').content,
        'second draft',
        reason: 'the held message.created frame overwrote the newer edit',
      );
    },
  );

  test(
    'a live edit of a message this client does not hold adds no row',
    () async {
      final (server, store, container) = await _rig();
      server.create(5);
      container.read(syncControllerProvider.notifier);
      await _untilLive(container);

      server.messages['m2'] = {...server.messages['m5']!, 'id': 'm2', 'seq': 2};
      server.edit(2, 'second draft');
      server.create(6);
      await pollUntil(
        () async => await store.hasMessage('c1', 'm6'),
        reason: 'm6 was never held',
      );

      expect(
        await store.oldestLocalSeq('c1'),
        5,
        reason:
            'history pages back from the oldest row, so a lone old one hides the rest',
      );
    },
  );
}
