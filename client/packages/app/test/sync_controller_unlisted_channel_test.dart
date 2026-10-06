// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A live message in a channel the channel list never names (a thread) costs
/// one channel refresh rather than one per message, and a refresh that fails
/// on its way does not take the socket down with it.
///
/// On build 1134 a busy thread spent four requests per message, the server
/// rate-limited the account, and the failed refresh failed every connect: the
/// phone sat offline with its own profile unable to load.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/sync_harness.dart';
import 'support/sync_live_rig.dart';

http.Response _emptyPage() => jsonResponse({
  'scopes': [
    {
      'channel_id': 'c1',
      'messages': <dynamic>[],
      'has_more': false,
      'reset': false,
    },
  ],
});

final _rateLimited = http.Response(
  '{"error":"rate limited"}',
  429,
  headers: {'content-type': 'application/json', 'retry-after': '1'},
);

Map<String, dynamic> _threadMessage(int seq) => {
  'type': 'message.created',
  'message': {
    ...rigMessage('t$seq', seq, 'reply $seq'),
    'channel_id': 'thread-1',
  },
};

/// Counts `GET /dms`, one of the three reads every channel refresh makes, and
/// answers it with a 429 once [limited] is set.
class _ChannelList {
  int calls = 0;
  bool limited = false;

  void install(RestRouter router) {
    router.on('GET', '/dms', (request) {
      calls++;
      return limited ? _rateLimited : jsonResponse(const <dynamic>[]);
    });
  }
}

/// `/sync` that holds its second request, a connect's closing catch-up, until [release] completes.
class _HeldSync {
  final release = Completer<void>();
  final heldReached = Completer<void>();
  int calls = 0;

  FutureOr<http.Response> handle(http.Request _) async {
    if (++calls == 2) {
      heldReached.complete();
      await release.future;
    }
    return _emptyPage();
  }
}

void main() {
  test('a burst of thread replies refreshes the channel list once', () async {
    final channels = _ChannelList();
    final rig = await SyncLiveRig.build((r) {
      channels.install(r);
      r.on('POST', '/sync', (_) => _emptyPage());
    }, seeded: [rigMessage('m1', 1, 'msg 1')]);
    rig.signIn();
    await rig.waitFor(() => rig.status.name == 'live');
    final before = channels.calls;

    for (var seq = 1; seq <= 5; seq++) {
      rig.server.pushEvent(_threadMessage(seq));
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(rig.status.name, 'live');
    expect(channels.calls - before, 1);
  });

  test(
    'a rate-limited refresh for a thread reply leaves the socket live',
    () async {
      final channels = _ChannelList();
      var tickets = 0;
      final rig = await SyncLiveRig.build((r) {
        channels.install(r);
        r.on('POST', '/sync', (_) => _emptyPage());
        r.on('POST', '/auth/ws-ticket', (_) {
          tickets++;
          return jsonResponse({'ticket': 'tix', 'expires_at': 0});
        });
      }, seeded: [rigMessage('m1', 1, 'msg 1')]);
      rig.signIn();
      await rig.waitFor(() => rig.status.name == 'live');
      channels.limited = true;

      rig.server.pushEvent(_threadMessage(1));
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(rig.status.name, 'live');
      expect(tickets, 1, reason: 'no reconnect');
    },
  );

  test(
    'a thread reply held during a connect cannot fail that connect',
    () async {
      final channels = _ChannelList();
      final syncs = _HeldSync();
      final rig = await SyncLiveRig.build((r) {
        channels.install(r);
        r.on('POST', '/sync', syncs.handle);
      }, seeded: [rigMessage('m1', 1, 'msg 1')]);
      rig.signIn();
      await syncs.heldReached.future.timeout(const Duration(seconds: 5));

      channels.limited = true;
      rig.server.pushEvent(_threadMessage(1));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      syncs.release.complete();
      await rig.waitFor(() => rig.status.name == 'live', ms: 1500);

      expect(rig.status.name, 'live');
    },
  );
}
