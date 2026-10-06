// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Back-to-back edit frames on the live socket must each find the op cursor
/// where the previous one left it, not race the read-decide-write on it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

import 'support/sync_harness.dart';
import 'support/sync_live_rig.dart';

Future<(SyncLiveRig, int Function())> _liveRig() async {
  var syncCalls = 0;
  final rig = await SyncLiveRig.build(
    (router) => router.on('POST', '/sync', (_) {
      syncCalls++;
      return jsonResponse({
        'scopes': [
          {
            'channel_id': 'c1',
            'messages': <dynamic>[],
            'has_more': false,
            'reset': false,
          },
        ],
      });
    }),
    seeded: [for (var i = 1; i <= 5; i++) rigMessage('m$i', i, 'm$i')],
    opCursor: 5,
  );
  rig.signIn();
  await rig.waitFor(() => rig.status.name == 'live');
  expect(rig.status.name, 'live');
  return (rig, () => syncCalls);
}

Map<String, dynamic> _edit(int opSeq) => {
  'type': 'message.edited',
  'op_seq': opSeq,
  'message': rigMessage('m${opSeq - 5}', opSeq - 5, 'm${opSeq - 5} edited'),
};

class _FailingStore extends MessageStore {
  _FailingStore(super.db);

  @override
  Future<void> applyMessage(api.Message message) async {
    if (message.content == 'boom') throw StateError('disk full');
    return super.applyMessage(message);
  }
}

void main() {
  test(
    'two edit frames pushed back to back are both applied with no /sync',
    () async {
      final (rig, syncCalls) = await _liveRig();
      final before = syncCalls();

      rig.server.pushEvent(_edit(6));
      rig.server.pushEvent(_edit(7));
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(
        syncCalls() - before,
        0,
        reason: 'op 7 directly follows op 6, so it is not a gap',
      );
      final contents = await rig.contents();
      expect(contents['m1'], 'm1 edited');
      expect(contents['m2'], 'm2 edited');
      expect(await rig.store.opCursorFor('c1'), 7);
    },
  );

  test('a burst of five edit frames costs no /sync round at all', () async {
    final (rig, syncCalls) = await _liveRig();
    final before = syncCalls();

    for (var op = 6; op <= 10; op++) {
      rig.server.pushEvent(_edit(op));
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));

    expect(syncCalls() - before, 0, reason: 'ops 6..10 are consecutive');
    expect(await rig.store.opCursorFor('c1'), 10);
  });

  test('control: the same two edit frames 300ms apart need no /sync', () async {
    final (rig, syncCalls) = await _liveRig();
    final before = syncCalls();

    rig.server.pushEvent(_edit(6));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    rig.server.pushEvent(_edit(7));
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(syncCalls() - before, 0);
    final contents = await rig.contents();
    expect(contents['m1'], 'm1 edited');
    expect(contents['m2'], 'm2 edited');
    expect(await rig.store.opCursorFor('c1'), 7);
  });

  test('a store failure while applying one frame does not escape as an '
      'uncaught error', () async {
    final rig = await SyncLiveRig.build(
      (router) => router.on(
        'POST',
        '/sync',
        (_) => jsonResponse({
          'scopes': [
            {
              'channel_id': 'c1',
              'messages': <dynamic>[],
              'has_more': false,
              'reset': false,
            },
          ],
        }),
      ),
      seeded: [rigMessage('m1', 1, 'm1')],
      makeStore: _FailingStore.new,
    );
    rig.signIn();
    await rig.waitFor(() => rig.status.name == 'live');

    rig.server.pushEvent({
      'type': 'message.created',
      'message': rigMessage('m2', 2, 'boom'),
    });
    await Future<void>.delayed(const Duration(milliseconds: 500));
  });
}
