// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A thread this device holds no row for is caught up after a reconnect like a channel: what it missed is handed to alerts once, and what it already announced or never saw is not.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';

import '../support/sync_harness.dart';
import '../support/sync_live_rig.dart';

Map<String, dynamic> _threadMessage(int seq) => {
  ...rigMessage('t$seq', seq, 'reply $seq'),
  'channel_id': 'thread-1',
};

Map<String, dynamic> _live(int seq) => {
  'type': 'message.created',
  'message': _threadMessage(seq),
};

/// Answers `/sync` with whatever [thread] holds past the cursor the client sent for `thread-1`.
class _Server {
  final thread = <int>[];
  final asked = <int>[];

  http.Response sync(http.Request request) {
    final scopes = (jsonDecode(request.body) as Map)['scopes'] as List;
    final scopeList = [
      for (final s in scopes.cast<Map<String, dynamic>>())
        if (s['channel_id'] == 'thread-1')
          () {
            final after = s['after_seq'] as int;
            asked.add(after);
            return {
              'channel_id': 'thread-1',
              'messages': [
                for (final seq in thread)
                  if (seq > after) _threadMessage(seq),
              ],
              'has_more': false,
              'reset': false,
              'latest_seq': thread.isEmpty ? after : thread.last,
            };
          }()
        else
          {
            'channel_id': s['channel_id'],
            'messages': <dynamic>[],
            'has_more': false,
            'reset': false,
          },
    ];
    return jsonResponse({'scopes': scopeList});
  }
}

Future<(SyncLiveRig, List<List<api.Message>>)> _liveRig(_Server server) async {
  final rig = await SyncLiveRig.build((r) {
    r.on('POST', '/sync', (request) => server.sync(request));
    r.on('GET', '/dms', (_) => jsonResponse(const <dynamic>[]));
  }, seeded: [rigMessage('m1', 1, 'msg 1')]);
  final batches = <List<api.Message>>[];
  rig.container.read(caughtUpMessagesProvider).listen(batches.add);
  rig.signIn();
  await rig.waitFor(() => rig.status.name == 'live');
  return (rig, batches);
}

Future<void> _reconnect(SyncLiveRig rig) async {
  await rig.server.dropSockets();
  await rig.waitFor(() => rig.status.name != 'live', reason: 'never dropped');
  await rig.waitFor(() => rig.status.name == 'live', reason: 'no reconnect');
  await Future<void>.delayed(const Duration(milliseconds: 100));
}

List<String> _ids(List<List<api.Message>> batches) => [
  for (final batch in batches)
    for (final m in batch) m.id,
];

void main() {
  test(
    'a thread reply missed while the socket was down is handed over',
    () async {
      final server = _Server();
      final (rig, batches) = await _liveRig(server);
      rig.server.pushEvent(_live(1));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      server.thread.addAll([1, 2, 3]);
      await _reconnect(rig);

      expect(_ids(batches), ['t2', 't3']);
    },
  );

  test('a thread never seen live is not asked for', () async {
    final server = _Server()..thread.addAll([1, 2]);
    final (rig, batches) = await _liveRig(server);

    await _reconnect(rig);

    expect(server.asked, isEmpty);
    expect(batches, isEmpty);
  });

  test('a reply announced live is not announced again by catch-up', () async {
    final server = _Server();
    final (rig, batches) = await _liveRig(server);
    rig.server.pushEvent(_live(1));
    rig.server.pushEvent(_live(3));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    server.thread.addAll([1, 2, 3]);
    await _reconnect(rig);

    expect(_ids(batches), ['t2']);
  });

  test('a second reconnect asks from where the first stopped', () async {
    final server = _Server();
    final (rig, batches) = await _liveRig(server);
    rig.server.pushEvent(_live(1));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    server.thread.addAll([1, 2]);
    await _reconnect(rig);
    server.asked.clear();

    await _reconnect(rig);

    expect(server.asked.first, 2);
    expect(_ids(batches), ['t2']);
  });
}
