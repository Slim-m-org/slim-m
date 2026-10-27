// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the socket delivers while a connect is still catching up is held and
/// applied after it, and a socket or catch-up that fails in that stretch fails
/// the connect rather than going live.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/providers/sync_failure.dart';
import 'package:slimm_app/src/providers/sync_frame_queue.dart';

import 'support/sync_harness.dart';
import 'support/sync_live_rig.dart';

http.Response _page(List<Map<String, dynamic>> messages) => jsonResponse({
  'scopes': [
    {
      'channel_id': 'c1',
      'messages': messages,
      'has_more': false,
      'reset': false,
    },
  ],
});

/// `/sync` that holds its second request, the closing catch-up of a connect, until [release] completes.
class _Syncs {
  _Syncs({List<Map<String, dynamic>> Function()? messages})
    : _messages = messages ?? (() => const []);

  final List<Map<String, dynamic>> Function() _messages;
  final release = Completer<void>();
  final heldReached = Completer<void>();
  int calls = 0;

  FutureOr<http.Response> handle(http.Request _) async {
    final call = ++calls;
    if (call == 2) {
      heldReached.complete();
      await release.future;
    }
    return _page(_messages());
  }
}

Map<String, dynamic> _created(int seq) => {
  'type': 'message.created',
  'message': rigMessage('m$seq', seq, 'msg $seq'),
};

void main() {
  test('a frame delivered during the closing catch-up is applied once, with '
      'no extra /sync', () async {
    final syncs = _Syncs(messages: () => [rigMessage('m2', 2, 'msg 2')]);
    final rig = await SyncLiveRig.build(
      (r) => r.on('POST', '/sync', syncs.handle),
      seeded: [rigMessage('m1', 1, 'msg 1')],
    );
    rig.signIn();
    await syncs.heldReached.future.timeout(const Duration(seconds: 5));

    rig.server.pushEvent(_created(2));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    syncs.release.complete();
    await rig.waitFor(() => rig.status.name == 'live');

    expect(rig.status.name, 'live');
    expect((await rig.contents()).keys, containsAll(['m1', 'm2']));
    expect(await rig.store.cursorFor('c1'), 2);
    expect(syncs.calls, 2, reason: 'the overlap is a no-op, not a gap');
  });

  test('an edit delivered during the closing catch-up is applied after it, '
      'in order', () async {
    final syncs = _Syncs();
    final rig = await SyncLiveRig.build(
      (r) => r.on('POST', '/sync', syncs.handle),
      seeded: [rigMessage('m1', 1, 'msg 1')],
      opCursor: 5,
    );
    rig.signIn();
    await syncs.heldReached.future.timeout(const Duration(seconds: 5));

    rig.server.pushEvent({
      'type': 'message.edited',
      'op_seq': 6,
      'message': rigMessage('m1', 1, 'msg 1 edited'),
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect((await rig.contents())['m1'], 'msg 1');
    syncs.release.complete();
    await rig.waitFor(() => rig.status.name == 'live');

    expect((await rig.contents())['m1'], 'msg 1 edited');
    expect(await rig.store.opCursorFor('c1'), 6);
    expect(syncs.calls, 2);
  });

  test('a socket that closes during the closing catch-up fails the connect '
      'instead of going live', () async {
    final syncs = _Syncs();
    final rig = await SyncLiveRig.build(
      (r) => r.on('POST', '/sync', syncs.handle),
      seeded: [rigMessage('m1', 1, 'msg 1')],
    );
    rig.signIn();
    await syncs.heldReached.future.timeout(const Duration(seconds: 5));

    await rig.server.dropSockets();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    syncs.release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(rig.status.name, 'offline');
    await rig.waitFor(() => rig.status.name == 'live', ms: 6000);
    expect(rig.status.name, 'live', reason: 'the retry reconnects');
  });

  test('a backlog past the held-frame cap restarts at once with no offline '
      'status and resyncs over REST', () async {
    final previous = heldFrameCap;
    heldFrameCap = 2;
    addTearDown(() => heldFrameCap = previous);
    final syncs = _Syncs(
      messages: () => [for (var s = 2; s <= 6; s++) rigMessage('m$s', s, 'm')],
    );
    final rig = await SyncLiveRig.build(
      (r) => r.on('POST', '/sync', syncs.handle),
      seeded: [rigMessage('m1', 1, 'msg 1')],
    );
    final statuses = <String>[];
    rig.container.listen(
      syncControllerProvider,
      (_, next) => statuses.add(next.name),
    );
    rig.signIn();
    await syncs.heldReached.future.timeout(const Duration(seconds: 5));

    for (var s = 2; s <= 6; s++) {
      rig.server.pushEvent(_created(s));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    syncs.release.complete();
    await rig.waitFor(() => rig.status.name == 'live', ms: 6000);

    expect(statuses, isNot(contains('offline')));
    expect(rig.container.read(syncFailureProvider), isNull);
    expect((await rig.contents()).keys, containsAll(['m1', 'm6']));
  });

  test('a backlog that overflows on every attempt stops restarting quietly '
      'and goes offline', () async {
    final previous = heldFrameCap;
    heldFrameCap = 0;
    addTearDown(() => heldFrameCap = previous);
    var syncCalls = 0;
    final rig = await SyncLiveRig.build(
      (r) => r.on('POST', '/sync', (_) async {
        syncCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return _page(const []);
      }),
      seeded: [rigMessage('m1', 1, 'msg 1')],
    );
    final statuses = <String>[];
    rig.container.listen(
      syncControllerProvider,
      (_, next) => statuses.add(next.name),
    );
    final flood = Timer.periodic(
      const Duration(milliseconds: 20),
      (_) => rig.server.pushEvent(_created(2)),
    );
    addTearDown(flood.cancel);
    rig.signIn();

    await rig.waitFor(
      () =>
          syncCalls > maxQuickOverflowRestarts * 2 &&
          rig.status.name == 'offline',
      ms: 15000,
    );

    expect(rig.container.read(syncFailureProvider), isNotNull);
    expect(syncCalls, greaterThan(maxQuickOverflowRestarts));
  });

  test('a live message that skips a seq is not applied, and a reconcile '
      'fetches the whole run', () async {
    var served = <Map<String, dynamic>>[];
    var syncCalls = 0;
    final rig = await SyncLiveRig.build(
      (r) => r.on('POST', '/sync', (_) {
        syncCalls++;
        return _page(served);
      }),
      seeded: [rigMessage('m1', 1, 'msg 1')],
    );
    rig.signIn();
    await rig.waitFor(() => rig.status.name == 'live');
    final before = syncCalls;
    served = [for (var s = 2; s <= 4; s++) rigMessage('m$s', s, 'msg $s')];

    rig.server.pushEvent(_created(4));
    await rig.waitFor(() => syncCalls > before);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect((await rig.contents()).keys, containsAll(['m1', 'm2', 'm3', 'm4']));
    expect(await rig.store.cursorFor('c1'), 4);
    expect(syncCalls - before, 1);
  });

  test('control: the next seq is applied straight from the frame', () async {
    var syncCalls = 0;
    final rig = await SyncLiveRig.build(
      (r) => r.on('POST', '/sync', (_) {
        syncCalls++;
        return _page(const []);
      }),
      seeded: [rigMessage('m1', 1, 'msg 1')],
    );
    rig.signIn();
    await rig.waitFor(() => rig.status.name == 'live');
    final before = syncCalls;

    rig.server.pushEvent(_created(2));
    await rig.waitFor(() => rig.status.name == 'live');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect((await rig.contents()).keys, containsAll(['m1', 'm2']));
    expect(syncCalls, before);
  });

  test('disposing the controller mid-connect leaves nothing running', () async {
    final syncs = _Syncs();
    final rig = await SyncLiveRig.build(
      (r) => r.on('POST', '/sync', syncs.handle),
      seeded: [rigMessage('m1', 1, 'msg 1')],
    );
    rig.signIn();
    await syncs.heldReached.future.timeout(const Duration(seconds: 5));
    rig.server.pushEvent(_created(2));

    rig.container.dispose();
    syncs.release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect((await rig.contents()).keys, ['m1']);
  });
}
