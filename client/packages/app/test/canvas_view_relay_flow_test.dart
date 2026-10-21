// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The view relay's pacing and its follow state: one send per interval while a
/// view moves, nothing lost to a closed audience, and a person who left can no
/// longer be followed.
library;

import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_view_relay.dart';

const _board = Rect.fromLTWH(0, 0, 1000, 1000);

CanvasViewRelay _relay({
  required List<Rect> sent,
  bool Function()? canSend,
  List<Rect>? shown,
}) => CanvasViewRelay(
  board: _board,
  send: (view, {required summon}) => sent.add(view),
  showView: (view) => shown?.add(view),
  isBlocked: (_) => false,
  selfId: () => 'me',
  canSend: canSend,
);

Rect _view(double i) => Rect.fromLTWH(i, i, 100, 100);

void main() {
  test('a view that keeps moving goes out once per interval, not twice', () {
    fakeAsync((async) {
      final sent = <Rect>[];
      final relay = _relay(sent: sent);

      for (var ms = 0; ms < 1000; ms += 16) {
        relay.reportLocal(_view(ms.toDouble()));
        async.elapse(const Duration(milliseconds: 16));
      }

      final perSecond = sent.length;
      expect(perSecond, lessThanOrEqualTo(11), reason: 'sent $perSecond');
      expect(perSecond, greaterThanOrEqualTo(8));
      relay.dispose();
    });
  });

  test(
    'a view reported while nobody can receive it is sent once someone can',
    () {
      fakeAsync((async) {
        var audience = false;
        final sent = <Rect>[];
        final relay = _relay(sent: sent, canSend: () => audience);

        relay.reportLocal(_view(1));
        async.elapse(viewSendInterval * 3);
        expect(sent, isEmpty);

        audience = true;
        async.elapse(viewRepeatInterval);

        expect(sent, [_view(1)], reason: 'the pending view survived the gate');
        relay.dispose();
      });
    },
  );

  test('the repeat sends the latest view, not the one before it', () {
    fakeAsync((async) {
      final sent = <Rect>[];
      final relay = _relay(sent: sent);

      relay.reportLocal(_view(1));
      async.elapse(viewSendInterval);
      relay.reportLocal(_view(2));
      async.elapse(viewSendInterval);
      sent.clear();
      async.elapse(viewRepeatInterval + const Duration(milliseconds: 1));

      expect(sent, [_view(2)]);
      relay.dispose();
    });
  });

  test('forgetting the followed person stops following them', () {
    final shown = <Rect>[];
    final relay = _relay(sent: [], shown: shown);
    addTearDown(relay.dispose);

    relay.applyRemote('amy', _view(5), summon: false);
    relay.follow('amy');
    expect(relay.following.value, 'amy');
    expect(shown, [_view(5)]);

    relay.forget('amy');
    expect(relay.following.value, isNull);

    relay.applyRemote('amy', _view(9), summon: false);
    expect(shown, [_view(5)], reason: 'a return must not pull the camera');
  });
}
