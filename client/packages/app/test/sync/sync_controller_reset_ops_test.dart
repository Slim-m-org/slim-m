// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A reset refetches a channel's newest page and starts its op cursor over.
/// An edit or a delete that lands after that page was read must still arrive,
/// so the cursor restarts from the head `/sync` reported with the reset, not
/// from whatever the head is by the next catch-up.
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

/// A channel far enough ahead of a new client that its first `/sync` resets.
class _BusyServer {
  late final HttpServer http;
  final live = <int>{2001, 2002};
  final ops = <Map<String, dynamic>>[];
  void Function()? afterPage;
  final opCursorsAsked = <int?>[];

  Future<void> start() async {
    http = await HttpServer.bind('127.0.0.1', 0);
    http.listen(_handle);
  }

  void delete(int seq) {
    live.remove(seq);
    ops.add({
      'seq': ops.length + 1,
      'kind': 'delete',
      'message_id': 'm$seq',
      'created_at': 5000,
    });
  }

  Map<String, dynamic> _delta(Map<String, dynamic> scope) {
    final after = scope['after_seq'] as int;
    final afterOp = scope['after_op_seq'] as int?;
    opCursorsAsked.add(afterOp);
    return {
      'channel_id': scope['channel_id'],
      'messages': [
        if (after >= 2000)
          for (final seq in live)
            if (seq > after) _msg(seq),
      ],
      'has_more': false,
      'reset': after < 2000,
      'ops': [
        if (afterOp != null)
          for (final op in ops)
            if ((op['seq'] as int) > afterOp) op,
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
        ws.add(jsonEncode({'type': 'hello', 'protocol': protocolVersion}));
      });
      return;
    }
    Object body = <Object>[];
    void Function()? then;
    if (path == '/channels') {
      body = [
        {
          'id': 'c1',
          'name': 'busy',
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
    } else if (path == '/channels/c1/messages') {
      body = [for (final seq in live.toList().reversed) _msg(seq)];
      then = afterPage;
    } else if (path == '/auth/ws-ticket') {
      body = {'ticket': 't', 'expires_at': 9999999999};
    }
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
    then?.call();
  }
}

void main() {
  test('a delete landing after a reset read its page still arrives', () async {
    final server = _BusyServer();
    await server.start();
    addTearDown(() => server.http.close(force: true));
    // Once only: the page that carried m2002 was read before this delete.
    server.afterPage = () {
      server.afterPage = null;
      server.delete(2002);
    };
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

    container.read(syncControllerProvider.notifier);
    await pollUntil(
      () => container.read(syncControllerProvider) == SyncStatus.live,
      timeout: const Duration(seconds: 20),
      interval: const Duration(milliseconds: 25),
      reason: 'never went live',
    );

    expect(await store.hasMessage('c1', 'm2001'), isTrue);
    expect(
      await store.hasMessage('c1', 'm2002'),
      isFalse,
      reason:
          'the op cursor was adopted past the delete; asked: '
          '${server.opCursorsAsked}',
    );
  });
}
