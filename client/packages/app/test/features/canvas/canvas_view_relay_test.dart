// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sharing the viewed part of the board, following someone, and bringing
/// everyone to one view.
library;

import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_view_relay.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

class _Harness {
  final sent = <(Rect, bool)>[];
  final shown = <Rect>[];
  var blocked = <String>{};
  var audience = true;

  late final relay = CanvasViewRelay(
    board: canvasSharedArea,
    send: (view, {required summon, tile}) => sent.add((view, summon)),
    showView: shown.add,
    isBlocked: blocked.contains,
    selfId: () => 'me',
    canSend: () => audience,
  );
}

void main() {
  const view = Rect.fromLTWH(100, 100, 400, 300);

  test('following someone shows their last view, then every new one', () {
    final h = _Harness();
    h.relay.applyRemote('amy', view, summon: false);
    expect(h.shown, isEmpty, reason: 'not following yet');

    h.relay.follow('amy');
    expect(h.shown, [view]);

    const next = Rect.fromLTWH(0, 0, 200, 100);
    h.relay.applyRemote('amy', next, summon: false);
    expect(h.shown.last, next);
    expect(h.relay.following.value, 'amy');
  });

  test('following someone who never moved shows the whole board', () {
    final h = _Harness();
    h.relay.follow('amy');
    expect(h.shown, [canvasSharedArea]);
  });

  test('a view from somebody else is ignored while following another', () {
    final h = _Harness();
    h.relay.follow('amy');
    h.shown.clear();
    h.relay.applyRemote('bob', view, summon: false);
    expect(h.shown, isEmpty);
  });

  test('a summon moves nobody until they accept, and then only once', () async {
    final h = _Harness();
    h.relay.applyRemote('amy', view, summon: true);
    expect(h.shown, isEmpty, reason: 'a request, not a jump');
    expect(h.relay.summonRequest.value, (userId: 'amy', view: view));

    await h.relay.acceptSummon();
    expect(h.shown, [view]);
    expect(h.relay.summonRequest.value, isNull);
    expect(h.relay.following.value, isNull);
    h.relay.applyRemote(
      'amy',
      const Rect.fromLTWH(0, 0, 10, 10),
      summon: false,
    );
    expect(h.shown, hasLength(1));
  });

  test('declining a summon moves nobody and clears the request', () {
    final h = _Harness();
    h.relay.applyRemote('amy', view, summon: true);
    h.relay.declineSummon();
    expect(h.relay.summonRequest.value, isNull);
    expect(h.shown, isEmpty);
  });

  test('an unanswered summon lapses quietly after the timeout', () {
    fakeAsync((async) {
      final h = _Harness();
      h.relay.applyRemote('amy', view, summon: true);
      async.elapse(summonRequestTimeout - const Duration(seconds: 1));
      expect(h.relay.summonRequest.value, isNotNull);
      async.elapse(const Duration(seconds: 2));
      expect(h.relay.summonRequest.value, isNull);
      expect(h.shown, isEmpty);
    });
  });

  test('accepting runs the leave step before the move', () async {
    final h = _Harness();
    final order = <String>[];
    h.relay.applyRemote('amy', view, summon: true);
    await h.relay.acceptSummon(beforeMoving: () async => order.add('leave'));
    expect(order, ['leave']);
    expect(h.shown, [view]);
  });

  test('a summon from the person you follow is not asked again', () {
    final h = _Harness();
    h.relay.follow('amy');
    h.shown.clear();
    h.relay.applyRemote('amy', view, summon: true);
    expect(h.relay.summonRequest.value, isNull);
    expect(h.shown, [view]);
  });

  test('the summoner leaving withdraws the request', () {
    final h = _Harness();
    h.relay.applyRemote('amy', view, summon: true);
    h.relay.forget('amy');
    expect(h.relay.summonRequest.value, isNull);
  });

  test('the followed full screen tile reaches the follower, and clears', () {
    final h = _Harness();
    h.relay.follow('amy');
    h.relay.applyRemote('amy', view, summon: false, tile: 'screen:amy');
    expect(h.relay.followedTile.value, 'screen:amy');
    h.relay.applyRemote('amy', view, summon: false);
    expect(h.relay.followedTile.value, isNull);
  });

  test('following someone already full screen opens their tile at once', () {
    final h = _Harness();
    h.relay.applyRemote('amy', view, summon: false, tile: 'screen:amy');
    h.relay.follow('amy');
    expect(h.relay.followedTile.value, 'screen:amy');
    h.relay.stopFollowing();
    expect(h.relay.followedTile.value, isNull);
  });

  test('this device reports its own full screen tile with its view', () {
    fakeAsync((async) {
      String? current;
      final sentTiles = <String?>[];
      final relay = CanvasViewRelay(
        board: canvasSharedArea,
        send: (view, {required summon, tile}) => sentTiles.add(tile),
        showView: (_) {},
        isBlocked: (_) => false,
        selfId: () => 'me',
        focusedTile: () => current,
      );
      relay.reportLocal(view);
      async.elapse(viewSendInterval * 2);
      current = 'screen:me';
      relay.reportLocal(view);
      async.elapse(viewSendInterval * 2);
      expect(sentTiles, [null, 'screen:me']);
      relay.dispose();
    });
  });

  test('the own echo and a blocked sender are ignored', () {
    final h = _Harness()..blocked = {'troll'};
    h.relay.applyRemote('me', view, summon: true);
    h.relay.applyRemote('troll', view, summon: true);
    expect(h.shown, isEmpty);
  });

  test('stopping, or the person leaving, ends the follow', () {
    final h = _Harness();
    h.relay.follow('amy');
    h.relay.stopFollowing();
    expect(h.relay.following.value, isNull);
    h.relay.follow('amy');
    h.relay.forget('amy');
    expect(h.relay.following.value, isNull);
  });

  test('bring everyone sends the view with the summon flag', () {
    final h = _Harness();
    h.relay.summonEveryone(view);
    expect(h.sent, [(view, true)]);
  });

  test('a moving view is throttled but its last position is delivered', () {
    fakeAsync((async) {
      final h = _Harness();
      h.relay.reportLocal(view);
      h.relay.reportLocal(view.shift(const Offset(10, 0)));
      h.relay.reportLocal(view.shift(const Offset(20, 0)));
      expect(h.sent, hasLength(1), reason: 'only the first goes at once');

      async.elapse(viewSendInterval + const Duration(milliseconds: 1));
      expect(h.sent.last.$1, view.shift(const Offset(20, 0)));
      expect(h.sent.every((s) => !s.$2), isTrue);
    });
  });

  test('nothing is sent while nobody is listening', () {
    final h = _Harness()..audience = false;
    h.relay.reportLocal(view);
    expect(h.sent, isEmpty);
  });
}
