// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasCursorRelay]: outgoing throttle, and applying an incoming frame
/// (self-echo dropped, a blocked author dropped, the label resolved).
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_cursor_relay.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  test('reportLocalPointer sends immediately, then throttles', () {
    fakeAsync((async) {
      final cursors = CanvasCursors();
      final sent = <Offset>[];
      final relay = CanvasCursorRelay(
        cursors: cursors,
        paletteSize: 6,
        send: (x, y) => sent.add(Offset(x, y)),
        resolveLabel: (_) => 'Someone',
        isBlocked: (_) => false,
        selfId: () => 'self',
      );
      addTearDown(cursors.dispose);
      addTearDown(relay.dispose);

      relay.reportLocalPointer(const Offset(1, 1));
      expect(sent, [
        const Offset(1, 1),
      ], reason: 'the first report always sends');

      relay.reportLocalPointer(const Offset(2, 2));
      expect(sent, [
        const Offset(1, 1),
      ], reason: 'a report inside the throttle window must be dropped');

      async.elapse(cursorSendInterval + const Duration(milliseconds: 1));
      relay.reportLocalPointer(const Offset(3, 3));
      expect(sent, [const Offset(1, 1), const Offset(3, 3)]);
    });
  });

  test('applyRemote drops this device\'s own echo', () {
    final cursors = CanvasCursors();
    addTearDown(cursors.dispose);
    final relay = CanvasCursorRelay(
      cursors: cursors,
      paletteSize: 6,
      send: (_, _) {},
      resolveLabel: (_) => 'Someone',
      isBlocked: (_) => false,
      selfId: () => 'self',
    );
    addTearDown(relay.dispose);

    relay.applyRemote('self', 1, 1);

    expect(cursors.all, isEmpty);
  });

  test('applyRemote drops a blocked author', () {
    final cursors = CanvasCursors();
    addTearDown(cursors.dispose);
    final relay = CanvasCursorRelay(
      cursors: cursors,
      paletteSize: 6,
      send: (_, _) {},
      resolveLabel: (_) => 'Blocked Person',
      isBlocked: (id) => id == 'blocked',
      selfId: () => 'self',
    );
    addTearDown(relay.dispose);

    relay.applyRemote('blocked', 1, 1);

    expect(cursors.all, isEmpty);
  });

  test('applyRemote resolves a label and a stable colour index', () {
    final cursors = CanvasCursors();
    addTearDown(cursors.dispose);
    final relay = CanvasCursorRelay(
      cursors: cursors,
      paletteSize: 6,
      send: (_, _) {},
      resolveLabel: (id) => 'Name for $id',
      isBlocked: (_) => false,
      selfId: () => 'self',
    );
    addTearDown(relay.dispose);

    relay.applyRemote('alice', 5, 9);
    relay.applyRemote('alice', 6, 10);

    expect(cursors.all.length, 1);
    final cursor = cursors.all.single;
    expect(cursor.x, 6);
    expect(cursor.y, 10);
    expect(cursor.label, 'Name for alice');
    expect(cursor.colorIndex, inInclusiveRange(0, 5));
  });

  test('prunes stale cursors on its own schedule', () {
    fakeAsync((async) {
      final cursors = CanvasCursors();
      final relay = CanvasCursorRelay(
        cursors: cursors,
        paletteSize: 6,
        send: (_, _) {},
        resolveLabel: (_) => 'Someone',
        isBlocked: (_) => false,
        selfId: () => 'self',
      );
      addTearDown(cursors.dispose);
      addTearDown(relay.dispose);

      relay.applyRemote('alice', 0, 0);
      expect(cursors.all, isNotEmpty);

      async.elapse(cursorStaleAfter + cursorPruneInterval * 2);

      expect(
        cursors.all,
        isEmpty,
        reason: 'a cursor with nothing refreshed since must age out',
      );
    });
  });

  test('a pointer leaving hides the remote cursor and is sent once', () {
    final cursors = CanvasCursors();
    addTearDown(cursors.dispose);
    var left = 0;
    final relay = CanvasCursorRelay(
      cursors: cursors,
      paletteSize: 6,
      send: (_, _) {},
      sendLeft: () => left++,
      resolveLabel: (_) => 'Someone',
      isBlocked: (_) => false,
      selfId: () => 'self',
    );
    addTearDown(relay.dispose);

    relay.reportLocalPointerLeft();
    expect(left, 0, reason: 'nothing was ever sent, so nothing to retract');
    relay.reportLocalPointer(const Offset(1, 1));
    relay.reportLocalPointerLeft();
    relay.reportLocalPointerLeft();
    expect(left, 1);

    relay.applyRemote('alice', 4, 4);
    expect(cursors.all, hasLength(1));
    relay.applyRemote('alice', 0, 0, left: true);
    expect(cursors.all, isEmpty);
  });
}
