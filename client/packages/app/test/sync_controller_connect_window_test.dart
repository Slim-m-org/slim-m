// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message committed after the catch-up response and before the server
/// subscribes the new socket to the hub must still reach the client.
///
/// The fake server keeps the real server's order (`crates/slimm-server/src/
/// http/ws.rs` `serve`): a durable log answers `/sync`, and the socket only
/// joins the fan-out once its hello has been read.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _msg(int seq) => {
  'id': 'm$seq',
  'channel_id': 'c1',
  'author_id': 'alice',
  'author_display_name': 'Alice',
  'seq': seq,
  'content': 'msg $seq',
  'created_at': 1000 + seq,
  'edited_at': null,
};

class _OrderedServer {
  late final HttpServer http;
  final log = <Map<String, dynamic>>[_msg(1)];
  final subscribers = <WebSocket>[];
  void Function()? onTicket;

  Future<void> start() async {
    http = await HttpServer.bind('127.0.0.1', 0);
    http.listen(_handle);
  }

  void commit(int seq) {
    final m = _msg(seq);
    log.add(m);
    for (final s in subscribers) {
      s.add(jsonEncode({'type': 'message.created', 'message': m}));
    }
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
      final scopes = (asked['scopes'] as List).cast<Map<String, dynamic>>();
      body = {
        'scopes': [
          for (final s in scopes)
            {
              'channel_id': s['channel_id'],
              'messages': log
                  .where((m) => (m['seq'] as int) > (s['after_seq'] as int))
                  .toList(),
              'has_more': false,
              'reset': false,
            },
        ],
      };
    } else if (path == '/auth/ws-ticket') {
      onTicket?.call();
      body = {'ticket': 't', 'expires_at': 9999999999};
    }
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }
}

class _Rig {
  _Rig(this.server, this.store, this.container);
  final _OrderedServer server;
  final MessageStore store;
  final ProviderContainer container;

  SyncController get controller =>
      container.read(syncControllerProvider.notifier);

  Future<void> untilLive() async {
    for (var i = 0; i < 800; i++) {
      if (container.read(syncControllerProvider) == SyncStatus.live) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    fail('never went live');
  }

  Future<Set<int>> heldSeqs() async =>
      (await store.watchChannel('c1').first).map((m) => m.seq).toSet();
}

Future<_Rig> _rig() async {
  final server = _OrderedServer();
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
  return _Rig(server, store, container);
}

void main() {
  test('a message committed between /sync and the socket subscribing is held '
      'once the connection is live', () async {
    final rig = await _rig();
    rig.server.onTicket = () => rig.server.commit(2);
    rig.controller;
    await rig.untilLive();

    rig.server.commit(3);
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(await rig.heldSeqs(), containsAll([1, 2, 3]));
  });

  test('a message committed in the window is held once live, with nothing '
      'sent after it', () async {
    final rig = await _rig();
    rig.server.onTicket = () => rig.server.commit(2);
    rig.controller;
    await rig.untilLive();

    expect(await rig.heldSeqs(), containsAll([1, 2]));
  });

  test(
    'a reconnect does not heal the message the connect window lost',
    () async {
      final rig = await _rig();
      rig.server.onTicket = () => rig.server.commit(2);
      rig.controller;
      await rig.untilLive();
      rig.server.onTicket = null;
      rig.server.commit(3);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      unawaited(rig.controller.start());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await rig.untilLive();

      expect(await rig.heldSeqs(), containsAll([1, 2, 3]));
    },
  );

  test('control: a message committed before /sync is held', () async {
    final rig = await _rig();
    rig.server.commit(2);
    rig.controller;
    await rig.untilLive();

    rig.server.commit(3);
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(await rig.heldSeqs(), containsAll([1, 2, 3]));
  });
}
