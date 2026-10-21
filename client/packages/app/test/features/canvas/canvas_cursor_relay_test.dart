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
      expect(
        sent,
        [const Offset(1, 1), const Offset(2, 2)],
        reason:
            'the position the throttle held back goes out as its window ends',
      );

      relay.reportLocalPointer(const Offset(3, 3));
      async.elapse(cursorSendInterval + const Duration(milliseconds: 1));
      expect(sent, [
        const Offset(1, 1),
        const Offset(2, 2),
        const Offset(3, 3),
      ]);
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

  test(
    'holds no timer until a remote cursor exists, nor once none is left',
    () {
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
        expect(async.nonPeriodicTimerCount + async.periodicTimerCount, 0);

        relay.applyRemote('alice', 0, 0);
        expect(async.nonPeriodicTimerCount + async.periodicTimerCount, 1);

        async.elapse(cursorStaleAfter + cursorPruneInterval * 2);
        expect(async.nonPeriodicTimerCount + async.periodicTimerCount, 0);
      });
    },
  );

  CanvasCursorRelay relayWith({
    required CanvasCursors cursors,
    List<Offset>? sent,
    List<Offset>? left,
    bool Function()? canSend,
  }) => CanvasCursorRelay(
    cursors: cursors,
    paletteSize: 6,
    send: (x, y) => sent?.add(Offset(x, y)),
    sendLeft: (x, y) => left?.add(Offset(x, y)),
    resolveLabel: (_) => 'Someone',
    isBlocked: (_) => false,
    selfId: () => 'self',
    canSend: canSend,
  );

  test('a pointer leaving is sent once, from where it last was', () {
    fakeAsync((async) {
      final cursors = CanvasCursors();
      final left = <Offset>[];
      final relay = relayWith(cursors: cursors, left: left);

      relay.reportLocalPointerLeft();
      async.elapse(cursorLeftGrace);
      expect(left, isEmpty, reason: 'nothing was ever sent to retract');

      relay.reportLocalPointer(const Offset(7, 9));
      relay.reportLocalPointerLeft();
      relay.reportLocalPointerLeft();
      async.elapse(cursorLeftGrace);
      expect(left, [const Offset(7, 9)], reason: 'not the (0, 0) corner');

      relay.dispose();
      cursors.dispose();
    });
  });

  test('a pointer that comes straight back never tells anyone it left', () {
    fakeAsync((async) {
      final cursors = CanvasCursors();
      final left = <Offset>[];
      final relay = relayWith(cursors: cursors, left: left);

      relay.reportLocalPointer(const Offset(1, 1));
      relay.reportLocalPointerLeft();
      async.elapse(cursorLeftGrace ~/ 2);
      relay.reportLocalPointer(const Offset(2, 2));
      async.elapse(cursorLeftGrace * 2);

      expect(left, isEmpty);
      relay.dispose();
      cursors.dispose();
    });
  });

  test('a resting pointer is repeated before its cursor goes stale', () {
    fakeAsync((async) {
      final cursors = CanvasCursors();
      final sent = <Offset>[];
      final relay = relayWith(cursors: cursors, sent: sent);

      relay.reportLocalPointer(const Offset(5, 5));
      async.elapse(cursorKeepaliveInterval + const Duration(milliseconds: 1));

      expect(sent, [const Offset(5, 5), const Offset(5, 5)]);
      expect(
        cursorKeepaliveInterval,
        lessThan(cursorStaleAfter),
        reason: 'a repeat later than the prune would be too late',
      );
      relay.dispose();
      cursors.dispose();
    });
  });

  test('closing the canvas retracts a pointer that is still down', () {
    fakeAsync((async) {
      final cursors = CanvasCursors();
      final left = <Offset>[];
      final relay = relayWith(cursors: cursors, left: left);

      relay.reportLocalPointer(const Offset(3, 4));
      relay.dispose();

      expect(left, [const Offset(3, 4)]);
      expect(async.nonPeriodicTimerCount + async.periodicTimerCount, 0);
      cursors.dispose();
    });
  });

  test('a remote leave hides the cursor', () {
    final cursors = CanvasCursors();
    addTearDown(cursors.dispose);
    final relay = relayWith(cursors: cursors);
    addTearDown(relay.dispose);

    relay.applyRemote('alice', 4, 4);
    expect(cursors.all, hasLength(1));
    relay.applyRemote('alice', 0, 0, left: true);
    expect(cursors.all, isEmpty);
  });

  test(
    'reportLocalPointer sends nothing while canSend says nobody listens',
    () {
      var audience = false;
      final cursors = CanvasCursors();
      final sent = <Offset>[];
      final relay = CanvasCursorRelay(
        cursors: cursors,
        paletteSize: 6,
        send: (x, y) => sent.add(Offset(x, y)),
        resolveLabel: (_) => 'Someone',
        isBlocked: (_) => false,
        selfId: () => 'self',
        canSend: () => audience,
      );
      addTearDown(cursors.dispose);
      addTearDown(relay.dispose);

      for (var i = 0; i < 20; i++) {
        relay.reportLocalPointer(
          Offset(i.toDouble(), 0),
          now: DateTime(2026, 1, 1, 0, 0, i),
        );
      }
      expect(sent, isEmpty);

      audience = true;
      relay.reportLocalPointer(
        const Offset(1, 1),
        now: DateTime(2026, 1, 1, 1),
      );
      expect(sent, hasLength(1));
    },
  );

  group('shouldRelayCursor', () {
    bool relay({
      bool focused = true,
      bool inCallHere = true,
      bool othersInCall = false,
      bool remoteCursors = false,
    }) => shouldRelayCursor(
      focused: focused,
      inCallHere: inCallHere,
      othersInCall: othersInCall,
      remoteCursors: remoteCursors,
    );

    test('an unfocused window sends nothing', () {
      expect(relay(focused: false, othersInCall: true), isFalse);
    });

    test('alone in the call and unseen sends nothing', () {
      expect(relay(), isFalse);
    });

    test('another participant, or a cursor seen, turns it on', () {
      expect(relay(othersInCall: true), isTrue);
      expect(relay(remoteCursors: true), isTrue);
    });

    test(
      'a viewer outside the call cannot be counted, so it keeps sending',
      () {
        expect(relay(inCallHere: false), isTrue);
      },
    );
  });
}
