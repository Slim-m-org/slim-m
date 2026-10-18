// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Watching somebody move an object: throttled sending, easing on receipt,
/// and the committed move settling the exact final box.
library;

import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_cursor_relay.dart'
    show cursorSendInterval;
import 'package:slimm_app/src/features/canvas/screens/canvas_object_preview_relay.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

ObjectBox _box(double x) => (x: x, y: 0, w: 10, h: 10);

CanvasDocument _document() => CanvasDocument()
  ..applyPlaced(
    CanvasStrokeInput(
      id: 'a',
      x: 0,
      y: 0,
      w: 10,
      h: 10,
      points: Float32List.fromList(<double>[0, 0, 10, 10]),
      width: 2,
      colorKey: 'ink',
      zIndex: 0,
      seq: 1,
    ),
  );

void main() {
  late CanvasDocument document;
  late List<(String, ObjectBox, bool)> sent;
  late bool dragging;
  late CanvasObjectPreviewRelay relay;

  setUp(() {
    document = _document();
    sent = [];
    dragging = false;
    relay = CanvasObjectPreviewRelay(
      previews: RemoteObjectPreviews(document),
      send: (id, box, ended) => sent.add((id, box, ended)),
      isBlocked: (user) => user == 'blocked',
      selfId: () => 'me',
      isDraggingLocally: (_) => dragging,
    );
  });

  tearDown(() {
    relay.dispose();
    document.dispose();
  });

  test('local steps are throttled and the end always goes out', () {
    final t0 = DateTime(2026);
    relay.reportLocal('a', _box(1), now: t0);
    relay.reportLocal(
      'a',
      _box(2),
      now: t0.add(const Duration(milliseconds: 10)),
    );
    relay.reportLocal('a', _box(3), now: t0.add(cursorSendInterval));
    relay.endLocal(_box(4));

    expect(sent.map((s) => (s.$2.x, s.$3)), [
      (1.0, false),
      (3.0, false),
      (4.0, true),
    ]);
  });

  test('a remote box eases in over frames rather than jumping', () {
    fakeAsync((async) {
      relay.applyRemote('bob', 'a', _box(100), false);
      expect(document.objectBounds('a')!.x, 0);

      async.elapse(const Duration(milliseconds: 48));
      final midway = document.objectBounds('a')!.x;
      expect(midway, greaterThan(0));
      expect(midway, lessThan(100));

      async.elapse(const Duration(milliseconds: 100));
      expect(document.objectBounds('a')!.x, 100);
    });
  });

  test('the committed move settles the exact final box', () {
    fakeAsync((async) {
      relay.applyRemote('bob', 'a', _box(99.5), true);
      async.elapse(const Duration(milliseconds: 200));
      relay.settle('a');
      document.moveObject('a', 100, 0, 10, 10);

      async.elapse(const Duration(seconds: 10));
      expect(document.objectBounds('a')!.x, 100);
    });
  });

  test(
    'own echoes, blocked users and a local drag of the same object are ignored',
    () {
      fakeAsync((async) {
        relay.applyRemote('me', 'a', _box(100), false);
        relay.applyRemote('blocked', 'a', _box(100), false);
        dragging = true;
        relay.applyRemote('bob', 'a', _box(100), false);
        async.elapse(const Duration(seconds: 1));

        expect(document.objectBounds('a')!.x, 0);
      });
    },
  );
}
