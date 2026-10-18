// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasStrokePreviewRelay]: outgoing buffering, capping and throttling,
/// the explicit end signal, and applying an incoming frame (self-echo
/// dropped, a blocked author dropped, accumulation, and staleness pruning as
/// the mid-stroke-disconnect backstop) - the same coverage
/// `canvas_cursor_relay_test.dart` gives the pair this extends.
library;

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_stroke_preview_relay.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

typedef _Sent = (String objectId, List<double> points, bool ended);

void main() {
  test('the first point starts a draft but sends nothing until the timer', () {
    fakeAsync((async) {
      final drafts = RemoteStrokeDrafts();
      final sent = <_Sent>[];
      final relay = CanvasStrokePreviewRelay(
        drafts: drafts,
        paletteSize: 6,
        send: (id, points, ended) => sent.add((id, points, ended)),
        isBlocked: (_) => false,
        selfId: () => 'self',
      );
      addTearDown(drafts.dispose);
      addTearDown(relay.dispose);

      relay.reportLocalDraftPoint(const Offset(1, 1));
      expect(sent, isEmpty);

      async.elapse(strokePreviewSendInterval + const Duration(milliseconds: 1));
      expect(sent.length, 1);
      expect(sent.single.$1, isA<String>());
      expect(sent.single.$2, [1.0, 1.0]);
      expect(sent.single.$3, isFalse);
    });
  });

  test('several points buffered inside one interval flush as one frame', () {
    fakeAsync((async) {
      final drafts = RemoteStrokeDrafts();
      final sent = <_Sent>[];
      final relay = CanvasStrokePreviewRelay(
        drafts: drafts,
        paletteSize: 6,
        send: (id, points, ended) => sent.add((id, points, ended)),
        isBlocked: (_) => false,
        selfId: () => 'self',
      );
      addTearDown(drafts.dispose);
      addTearDown(relay.dispose);

      relay.reportLocalDraftPoint(const Offset(1, 1));
      relay.reportLocalDraftPoint(const Offset(2, 2));
      relay.reportLocalDraftPoint(const Offset(3, 3));
      async.elapse(strokePreviewSendInterval + const Duration(milliseconds: 1));

      expect(sent.length, 1);
      expect(sent.single.$2, [1.0, 1.0, 2.0, 2.0, 3.0, 3.0]);
      expect(sent.single.$3, isFalse);
    });
  });

  test('every point in a burst carries the same object id across frames', () {
    fakeAsync((async) {
      final drafts = RemoteStrokeDrafts();
      final sent = <_Sent>[];
      final relay = CanvasStrokePreviewRelay(
        drafts: drafts,
        paletteSize: 6,
        send: (id, points, ended) => sent.add((id, points, ended)),
        isBlocked: (_) => false,
        selfId: () => 'self',
      );
      addTearDown(drafts.dispose);
      addTearDown(relay.dispose);

      relay.reportLocalDraftPoint(const Offset(1, 1));
      async.elapse(strokePreviewSendInterval + const Duration(milliseconds: 1));
      relay.reportLocalDraftPoint(const Offset(2, 2));
      async.elapse(strokePreviewSendInterval + const Duration(milliseconds: 1));

      expect(sent.length, 2);
      expect(sent[0].$1, sent[1].$1, reason: 'one gesture, one draft id');
    });
  });

  test(
    'a frame carries at most maxStrokePreviewPointsPerFrame points, thinned evenly, keeping the newest',
    () {
      fakeAsync((async) {
        final drafts = RemoteStrokeDrafts();
        final sent = <_Sent>[];
        final relay = CanvasStrokePreviewRelay(
          drafts: drafts,
          paletteSize: 6,
          send: (id, points, ended) => sent.add((id, points, ended)),
          isBlocked: (_) => false,
          selfId: () => 'self',
        );
        addTearDown(drafts.dispose);
        addTearDown(relay.dispose);

        for (var i = 0; i < maxStrokePreviewPointsPerFrame + 5; i++) {
          relay.reportLocalDraftPoint(Offset(i.toDouble(), i.toDouble()));
        }
        async.elapse(
          strokePreviewSendInterval + const Duration(milliseconds: 1),
        );

        final points = sent.single.$2;
        expect(points.length, maxStrokePreviewPointsPerFrame * 2);
        expect(points.first, 0.0);
        expect(points.last, (maxStrokePreviewPointsPerFrame + 4).toDouble());
      });
    },
  );

  test('a 1000 Hz stroke stays inside the server byte budget', () {
    // Class::CanvasStrokePreview: burst 24576 bytes, refill 12288 a second.
    const burst = 24576.0;
    const refill = 12288.0;
    fakeAsync((async) {
      final drafts = RemoteStrokeDrafts();
      var tokens = burst;
      var frames = 0;
      var refused = 0;
      final relay = CanvasStrokePreviewRelay(
        drafts: drafts,
        paletteSize: 6,
        send: (id, points, ended) {
          final wire = jsonEncode({
            'type': 'canvas.stroke_preview',
            'channel_id': '0192f0c0-0000-7000-8000-000000000001',
            'object_id': id,
            'points': points,
            'ended': ended,
          }).length;
          tokens = (tokens + refill * 0.05).clamp(0.0, burst);
          frames++;
          if (wire > tokens) {
            refused++;
          } else {
            tokens -= wire;
          }
        },
        isBlocked: (_) => false,
        selfId: () => 'self',
      );
      addTearDown(drafts.dispose);
      addTearDown(relay.dispose);

      for (var ms = 0; ms < 8000; ms++) {
        relay.reportLocalDraftPoint(
          Offset(ms / 3.7 + 0.123456789, 200 + 90 * (ms % 97) / 7.3),
        );
        async.elapse(const Duration(milliseconds: 1));
      }

      expect(frames, greaterThan(100));
      expect(refused, 0);
    });
  });

  test(
    'endLocalDraft flushes what remains, marked ended, and stops the timer',
    () {
      fakeAsync((async) {
        final drafts = RemoteStrokeDrafts();
        final sent = <_Sent>[];
        final relay = CanvasStrokePreviewRelay(
          drafts: drafts,
          paletteSize: 6,
          send: (id, points, ended) => sent.add((id, points, ended)),
          isBlocked: (_) => false,
          selfId: () => 'self',
        );
        addTearDown(drafts.dispose);
        addTearDown(relay.dispose);

        relay.reportLocalDraftPoint(const Offset(1, 1));
        relay.endLocalDraft();

        expect(sent.length, 1);
        expect(sent.single.$1, isA<String>());
        expect(sent.single.$2, [1.0, 1.0]);
        expect(sent.single.$3, isTrue);

        // The timer this draft started must be gone, or a stray flush follows.
        async.elapse(strokePreviewSendInterval * 3);
        expect(sent.length, 1);
      });
    },
  );

  test('endLocalDraft with nothing in progress is a silent no-op', () {
    final drafts = RemoteStrokeDrafts();
    final sent = <_Sent>[];
    final relay = CanvasStrokePreviewRelay(
      drafts: drafts,
      paletteSize: 6,
      send: (id, points, ended) => sent.add((id, points, ended)),
      isBlocked: (_) => false,
      selfId: () => 'self',
    );
    addTearDown(drafts.dispose);
    addTearDown(relay.dispose);

    relay.endLocalDraft();

    expect(sent, isEmpty);
  });

  test('a new gesture after ending the last one mints a fresh object id', () {
    fakeAsync((async) {
      final drafts = RemoteStrokeDrafts();
      final sent = <_Sent>[];
      final relay = CanvasStrokePreviewRelay(
        drafts: drafts,
        paletteSize: 6,
        send: (id, points, ended) => sent.add((id, points, ended)),
        isBlocked: (_) => false,
        selfId: () => 'self',
      );
      addTearDown(drafts.dispose);
      addTearDown(relay.dispose);

      relay.reportLocalDraftPoint(const Offset(1, 1));
      relay.endLocalDraft();
      relay.reportLocalDraftPoint(const Offset(2, 2));
      relay.endLocalDraft();

      expect(sent.length, 2);
      expect(
        sent[0].$1 == sent[1].$1,
        isFalse,
        reason: 'two separate gestures must not share a draft id',
      );
    });
  });

  test("applyRemote drops this device's own echo", () {
    final drafts = RemoteStrokeDrafts();
    addTearDown(drafts.dispose);
    final relay = CanvasStrokePreviewRelay(
      drafts: drafts,
      paletteSize: 6,
      send: (_, _, _) {},
      isBlocked: (_) => false,
      selfId: () => 'self',
    );
    addTearDown(relay.dispose);

    relay.applyRemote('self', 'd1', const [1.0, 1.0], false);

    expect(drafts.all, isEmpty);
  });

  test('applyRemote drops a blocked author', () {
    final drafts = RemoteStrokeDrafts();
    addTearDown(drafts.dispose);
    final relay = CanvasStrokePreviewRelay(
      drafts: drafts,
      paletteSize: 6,
      send: (_, _, _) {},
      isBlocked: (id) => id == 'blocked',
      selfId: () => 'self',
    );
    addTearDown(relay.dispose);

    relay.applyRemote('blocked', 'd1', const [1.0, 1.0], false);

    expect(drafts.all, isEmpty);
  });

  test('applyRemote accumulates points across frames for the same draft', () {
    final drafts = RemoteStrokeDrafts();
    addTearDown(drafts.dispose);
    final relay = CanvasStrokePreviewRelay(
      drafts: drafts,
      paletteSize: 6,
      send: (_, _, _) {},
      isBlocked: (_) => false,
      selfId: () => 'self',
    );
    addTearDown(relay.dispose);

    relay.applyRemote('alice', 'd1', const [1.0, 1.0], false);
    relay.applyRemote('alice', 'd1', const [2.0, 2.0], false);

    expect(drafts.all.single.points, [1.0, 1.0, 2.0, 2.0]);
  });

  test(
    'applyRemote with ended true keeps the ink until the committed stroke settles it',
    () {
      final drafts = RemoteStrokeDrafts();
      addTearDown(drafts.dispose);
      final relay = CanvasStrokePreviewRelay(
        drafts: drafts,
        paletteSize: 6,
        send: (_, _, _) {},
        isBlocked: (_) => false,
        selfId: () => 'self',
      );
      addTearDown(relay.dispose);

      relay.applyRemote('alice', 'd1', const [1.0, 1.0], false);
      expect(drafts.all, isNotEmpty);

      relay.applyRemote('alice', 'd1', const [], true);

      expect(drafts.all.single.ended, isTrue);
      drafts.settleAuthor('alice');
      expect(drafts.all, isEmpty);
    },
  );

  test(
    'prunes stale drafts on its own schedule - the mid-stroke-disconnect backstop',
    () {
      fakeAsync((async) {
        final drafts = RemoteStrokeDrafts();
        final relay = CanvasStrokePreviewRelay(
          drafts: drafts,
          paletteSize: 6,
          send: (_, _, _) {},
          isBlocked: (_) => false,
          selfId: () => 'self',
        );
        addTearDown(drafts.dispose);
        addTearDown(relay.dispose);

        relay.applyRemote('alice', 'd1', const [0.0, 0.0], false);
        expect(drafts.all, isNotEmpty);

        async.elapse(strokePreviewStaleAfter + strokePreviewPruneInterval * 2);

        expect(
          drafts.all,
          isEmpty,
          reason: 'a draft with no ended signal and no refresh must age out',
        );
      });
    },
  );

  test(
    'dispose ends an in-progress local draft, so a disconnect is not a silent ghost',
    () {
      final drafts = RemoteStrokeDrafts();
      final sent = <_Sent>[];
      final relay = CanvasStrokePreviewRelay(
        drafts: drafts,
        paletteSize: 6,
        send: (id, points, ended) => sent.add((id, points, ended)),
        isBlocked: (_) => false,
        selfId: () => 'self',
      );
      addTearDown(drafts.dispose);

      relay.reportLocalDraftPoint(const Offset(1, 1));
      relay.dispose();

      expect(sent.length, 1);
      expect(sent.single.$1, isA<String>());
      expect(sent.single.$2, [1.0, 1.0]);
      expect(sent.single.$3, isTrue);
    },
  );
}
