// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Three delivery patterns for a canonical op log
/// (`canvas_convergence_model.dart`), each driving real production code -
/// `CanvasDocument`, `CanvasSync`, and `dispatchCanvasLiveEvent`, the exact
/// three pieces `CanvasPane` wires together - for
/// `canvas_convergence_property_test.dart` to compare against the
/// independent oracle. Wire encoding lives in `canvas_convergence_wire.dart`,
/// split out once this file neared the review budget.
library;

import 'dart:math' as math;

import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/screens/canvas/canvas_live_event_dispatch.dart';
import 'package:slimm_app/src/screens/canvas/canvas_media_slot_sync.dart';
import 'package:slimm_app/src/screens/canvas/canvas_object_locks.dart';
import 'package:slimm_app/src/screens/canvas/canvas_sync.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_convergence_model.dart';
import 'canvas_convergence_wire.dart';

/// A fake `SlimmApi` whose `/canvas/ops` route always answers the full tail
/// of [log] past `after_seq` in one page - the simplification
/// `canvas_sync_test.dart`'s own fakes already make, since paging itself is
/// covered there and is not this harness's concern.
api.SlimmApi fakeClientFor(List<CanonOp> log) => api.SlimmApi(
  baseUrl: Uri.parse('http://localhost:8080'),
  session: api.SessionStore(
    tokens: const api.TokenPair(
      userId: 'me',
      accessToken: 'access',
      refreshToken: 'refresh',
      accessExpiresAt: 0,
    ),
  ),
  httpClient: MockClient((request) async {
    if (!request.url.path.endsWith('/canvas/ops')) {
      return jsonResponse(<Object>[]);
    }
    final afterSeq = int.parse(request.url.queryParameters['after_seq']!);
    final ops = log.where((o) => o.seq > afterSeq).map(wireOp).toList();
    final latest = log.isEmpty ? 0 : log.last.seq;
    return jsonResponse({
      'ops': ops,
      'latest_seq': latest,
      'has_more': false,
      'reset': false,
    });
  }),
);

/// One simulated client: a real [CanvasDocument] and [CanvasSync] pair, fed
/// through the same [dispatchCanvasLiveEvent] switch `CanvasPane` uses.
class CanvasReceiver {
  CanvasReceiver(String channelId, List<CanonOp> log)
    : document = CanvasDocument(),
      _channelId = channelId {
    sync = CanvasSync(
      channelId: channelId,
      client: fakeClientFor(log),
      document: document,
      coldFetch: () async {},
      forgetFetchedRegion: () {},
    );
  }

  final CanvasDocument document;
  final String _channelId;
  late final CanvasSync sync;

  // Never actually asked anything - present only because dispatchCanvasLiveEvent requires one.
  late final CanvasMediaSlotSync _mediaSlotSync = CanvasMediaSlotSync(
    channelId: _channelId,
    client: fakeClientFor(const []),
    overrides: CanvasPresenceTileOverrides(),
  );

  late final CanvasObjectLocks _objectLocks = CanvasObjectLocks(
    channelId: _channelId,
    client: fakeClientFor(const []),
  );

  void deliver(CanonOp op) {
    dispatchCanvasLiveEvent(
      eventFor(op, _channelId),
      paneChannelId: _channelId,
      sync: sync,
      document: document,
      relay: () =>
          throw UnimplementedError('this model never generates a cursor event'),
      strokePreviewRelay: () => throw UnimplementedError(
        'this model never generates a stroke preview event',
      ),
      applyPlacedObject: (object) {
        final input = canvasStrokeInputFrom(object);
        if (input != null) document.applyPlaced(input);
      },
      forgetFetchedRegion: () {},
      mediaSlotSync: _mediaSlotSync,
      objectLocks: _objectLocks,
    );
  }
}

/// Lets a mocked HTTP round trip and any catch-up it triggers actually
/// resolve before the next event is delivered, without pulling in
/// `fake_async` for what is, throughout this harness, real (if instant) I/O.
Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Delivers every op in [log], in order, as a live frame.
Future<CanvasDocument> liveInOrder(String channelId, List<CanonOp> log) async {
  final receiver = CanvasReceiver(channelId, log);
  receiver.sync.seedFromViewport(0);
  for (final op in log) {
    receiver.deliver(op);
    await settle();
  }
  await receiver.sync.catchUp();
  return receiver.document;
}

/// Delivers [log] in a random order, plus one duplicate redelivery, as a
/// scrambled or retransmitting socket would - the gaps this produces are
/// closed by [CanvasSync]'s own catch-up.
Future<CanvasDocument> liveScrambled(
  String channelId,
  List<CanonOp> log,
  math.Random rng,
) async {
  final receiver = CanvasReceiver(channelId, log);
  receiver.sync.seedFromViewport(0);
  final shuffled = [...log]..shuffle(rng);
  for (final op in shuffled) {
    receiver.deliver(op);
    await settle();
  }
  if (log.isNotEmpty) {
    receiver.deliver(log[rng.nextInt(log.length)]);
    await settle();
  }
  await receiver.sync.catchUp();
  return receiver.document;
}

/// What [lateJoiner] produced: the document it converged to, and which ids
/// this simulated client had any way of learning about at all.
class LateJoinerResult {
  const LateJoinerResult(this.document, this.reachableIds);

  final CanvasDocument document;
  final Set<String> reachableIds;
}

/// Seeds from a mid-log snapshot at a random cut point, replays the tail
/// through catch-up, then redelivers one already-covered tail op live - the
/// late-joiner double-apply case by name.
///
/// [LateJoinerResult.reachableIds] is the other half of modelling a real
/// late joiner honestly: a viewport read only ever returns objects alive
/// *at* the cut, and catch-up only ever plays the tail, so an object both
/// placed and permanently removed strictly before the cut is never
/// mentioned to this client at all - not a bug, the same as a real client
/// that opened the pane after the fact. The convergence check has nothing
/// to converge on for such an id and must not assert against it.
Future<LateJoinerResult> lateJoiner(
  String channelId,
  List<CanonOp> log,
  math.Random rng,
) async {
  final receiver = CanvasReceiver(channelId, log);
  final cut = log.isEmpty ? 0 : log[rng.nextInt(log.length)].seq;
  final snapshot = CanvasLogOracle.replay(
    log.where((o) => o.seq <= cut).toList(),
  );
  for (final entry in snapshot.alive.entries) {
    final seq = snapshot.placementSeq[entry.key]!;
    receiver.document.applyPlaced(
      CanvasStrokeInput(
        id: entry.key,
        seq: seq,
        zIndex: seq,
        x: entry.value.x,
        y: entry.value.y,
        w: entry.value.w,
        h: entry.value.h,
        points: [0, 0, entry.value.w, entry.value.h],
        width: 3,
        colorKey: 'annotation',
      ),
    );
  }
  receiver.sync.seedFromViewport(cut);
  await receiver.sync.catchUp();
  final tail = log.where((o) => o.seq > cut).toList();
  if (tail.isNotEmpty) {
    receiver.deliver(tail[rng.nextInt(tail.length)]);
    await settle();
  }
  final reachable = snapshot.alive.keys.toSet();
  for (final op in tail) {
    if (op is CanonPlace) reachable.add(op.id);
  }
  return LateJoinerResult(receiver.document, reachable);
}
