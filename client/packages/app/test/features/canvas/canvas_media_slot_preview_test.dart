// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tile drag streams to other viewers before it commits, and a received stream moves only what it should.
library;

import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_media_slot_sync.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

typedef _Sent = ({String key, Rect rect, bool ended});

({
  CanvasMediaSlotSync sync,
  CanvasPresenceTileOverrides overrides,
  List<_Sent> sent,
})
_rig({bool Function(String)? blocked}) {
  final overrides = CanvasPresenceTileOverrides();
  addTearDown(overrides.dispose);
  final sent = <_Sent>[];
  final sync = CanvasMediaSlotSync(
    channelId: 'c1',
    client: testApi((_) async => throw StateError('no http expected')),
    overrides: overrides,
    sendPreview: (key, rect, {required ended}) =>
        sent.add((key: key, rect: rect, ended: ended)),
    selfId: () => 'me',
    isBlocked: blocked,
  );
  addTearDown(sync.dispose);
  return (sync: sync, overrides: overrides, sent: sent);
}

api.CanvasMediaSlotPreview _event({
  String user = 'bob',
  String slotUser = 'bob',
  String channel = 'c1',
  bool ended = false,
  double x = 300,
}) => api.CanvasMediaSlotPreview(
  channelId: channel,
  userId: user,
  kind: 'camera',
  slotUserId: slotUser,
  x: x,
  y: 40,
  w: 220,
  h: 160,
  ended: ended,
);

void main() {
  test('a drag step is streamed, throttled, from the shared view only', () {
    final r = _rig();
    final t = DateTime(2026);
    r.overrides.onSharedRectDragged!(
      'camera:me',
      const Rect.fromLTWH(1, 2, 220, 160),
    );
    r.sync.reportDrag('camera:me', const Rect.fromLTWH(1, 2, 220, 160), now: t);
    r.sync.reportDrag(
      'camera:me',
      const Rect.fromLTWH(5, 2, 220, 160),
      now: t.add(const Duration(milliseconds: 10)),
    );
    expect(r.sent.where((s) => !s.ended).length, 2);
  });

  test(
    'setRect on the shared view reports, in the personal view it does not',
    () {
      final r = _rig();
      r.overrides.setRect('camera:me', const Rect.fromLTWH(10, 10, 220, 160));
      expect(r.sent, hasLength(1));
      r.overrides.personal = true;
      r.overrides.setRect('camera:me', const Rect.fromLTWH(30, 10, 220, 160));
      expect(r.sent, hasLength(1));
    },
  );

  test('a drag nobody commits is announced as abandoned', () {
    fakeAsync((async) {
      final r = _rig();
      r.overrides.setRect('camera:me', const Rect.fromLTWH(10, 10, 220, 160));
      async.elapse(const Duration(seconds: 4));
      expect(r.sent.last.ended, isTrue);
    });
  });

  test('a commit cancels the abandon announcement', () {
    fakeAsync((async) {
      final r = _rig();
      r.overrides.setRect('camera:me', const Rect.fromLTWH(10, 10, 220, 160));
      r.sync.commit('camera:me', const Rect.fromLTWH(10, 10, 220, 160));
      async.elapse(const Duration(seconds: 4));
      expect(r.sent.where((s) => s.ended), isEmpty);
    });
  });

  test("another member's stream moves the tile; their end puts it back", () {
    final r = _rig();
    r.overrides.applyServer(
      'camera:bob',
      rect: const Rect.fromLTWH(10, 40, 220, 160),
      locked: false,
      sentToBack: false,
    );
    r.sync.applyRemotePreview(_event());
    expect(r.overrides.stateFor('camera:bob').rect!.left, 300);
    r.sync.applyRemotePreview(_event(ended: true));
    expect(r.overrides.stateFor('camera:bob').rect!.left, 10);
  });

  test(
    'own frames, blocked senders, other channels and locked tiles are ignored',
    () {
      final r = _rig(blocked: (id) => id == 'mallory');
      r.overrides.applyServer(
        'camera:bob',
        rect: const Rect.fromLTWH(10, 40, 220, 160),
        locked: false,
        sentToBack: false,
      );
      r.sync.applyRemotePreview(_event(user: 'me'));
      r.sync.applyRemotePreview(_event(user: 'mallory'));
      r.sync.applyRemotePreview(_event(channel: 'other'));
      expect(r.overrides.stateFor('camera:bob').rect!.left, 10);

      r.overrides.applyServer(
        'camera:bob',
        rect: const Rect.fromLTWH(10, 40, 220, 160),
        locked: true,
        sentToBack: false,
      );
      r.sync.applyRemotePreview(_event());
      expect(r.overrides.stateFor('camera:bob').rect!.left, 10);
    },
  );
}
