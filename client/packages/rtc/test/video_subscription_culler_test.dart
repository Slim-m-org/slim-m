// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [VideoSubscriptionCuller]: the dwell before an unwanted track is
/// unsubscribed, the immediate resubscribe when it is wanted again, and the
/// two things that must never happen - a track thrashing at the boundary,
/// and audio being touched at all.
///
/// Every assertion here reads the fake room's own resulting subscription
/// set rather than counting calls, because a test that only proves a method
/// was invoked would pass just as happily against a culler that invoked it
/// on the wrong track.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

/// A room's worth of publications, all subscribed to begin with, that
/// really do change state when the culler acts on them.
class _FakeRoom {
  _FakeRoom(this.keys) : subscribed = keys.toSet();

  final List<String> keys;
  final Set<String> subscribed;
  int subscribeCalls = 0;
  int unsubscribeCalls = 0;

  /// Keys whose next subscribe/unsubscribe rejects instead of succeeding,
  /// the same shape a participant leaving mid-cull produces - consumed on
  /// first use so a test can assert exactly one rejection happened.
  final Set<String> failSubscribe = {};
  final Set<String> failUnsubscribe = {};

  /// Rebuilt lazily on every read, so each [VideoSubscriptionCuller.apply]
  /// sees the state the previous one actually left behind.
  Iterable<VideoSubscriptionRef> get refs => keys.map(
        (key) => (
          key: key,
          subscribed: subscribed.contains(key),
          subscribe: () async {
            subscribeCalls++;
            if (failSubscribe.remove(key)) {
              throw StateError('participant left mid-cull');
            }
            subscribed.add(key);
          },
          unsubscribe: () async {
            unsubscribeCalls++;
            if (failUnsubscribe.remove(key)) {
              throw StateError('participant left mid-cull');
            }
            subscribed.remove(key);
          },
        ),
      );

  void drop(String key) {
    keys.remove(key);
    subscribed.remove(key);
  }
}

/// A culler wired the way [VoiceSession] wires it: a due dwell asks the
/// owner to walk the room again, and the owner calls back into [apply].
({VideoSubscriptionCuller culler, int Function() dueCount}) _wire(
  _FakeRoom room, {
  Duration dwell = videoSubscriptionDwell,
}) {
  var due = 0;
  late final VideoSubscriptionCuller culler;
  culler = VideoSubscriptionCuller(
    dwell: dwell,
    onDue: () {
      due++;
      culler.apply(room.refs);
    },
  );
  return (culler: culler, dueCount: () => due);
}

void main() {
  test('a tile leaving the interest set survives right up to the dwell', () {
    fakeAsync((async) {
      final room = _FakeRoom(['camera:a', 'camera:b']);
      final wired = _wire(room);
      wired.culler.setInterest({'camera:a', 'camera:b'});
      wired.culler.apply(room.refs);
      expect(room.subscribed, {'camera:a', 'camera:b'});

      wired.culler.setInterest({'camera:a'});
      wired.culler.apply(room.refs);
      expect(
        room.subscribed,
        {'camera:a', 'camera:b'},
        reason: 'nothing may be torn down before the dwell has run',
      );

      async.elapse(videoSubscriptionDwell - const Duration(milliseconds: 1));
      wired.culler.apply(room.refs);
      expect(room.subscribed, {'camera:a', 'camera:b'});

      async.elapse(const Duration(milliseconds: 1));
      expect(wired.dueCount(), 1);
      expect(room.subscribed, {'camera:a'});
      wired.culler.dispose();
    });
  });

  test('a tile that comes back inside the dwell never thrashes', () {
    fakeAsync((async) {
      final room = _FakeRoom(['camera:a', 'camera:b']);
      final wired = _wire(room);
      wired.culler.setInterest({'camera:a', 'camera:b'});
      wired.culler.apply(room.refs);
      room.subscribeCalls = 0;

      // Out of the band, back inside it well before the dwell, three times.
      for (var i = 0; i < 3; i++) {
        wired.culler.setInterest({'camera:a'});
        wired.culler.apply(room.refs);
        async.elapse(const Duration(seconds: 1));
        wired.culler.setInterest({'camera:a', 'camera:b'});
        wired.culler.apply(room.refs);
        async.elapse(const Duration(seconds: 1));
      }
      async.elapse(const Duration(minutes: 1));

      expect(room.subscribed, {'camera:a', 'camera:b'});
      expect(room.unsubscribeCalls, 0);
      expect(room.subscribeCalls, 0, reason: 'nothing was ever torn down');
      expect(wired.dueCount(), 0);
      wired.culler.dispose();
    });
  });

  test('a tile wanted again after a cull is resubscribed with no dwell', () {
    fakeAsync((async) {
      final room = _FakeRoom(['camera:a', 'camera:b']);
      final wired = _wire(room);
      wired.culler.setInterest({'camera:a'});
      wired.culler.apply(room.refs);
      async.elapse(videoSubscriptionDwell);
      expect(room.subscribed, {'camera:a'});

      wired.culler.setInterest({'camera:a', 'camera:b'});
      wired.culler.apply(room.refs);
      expect(
        room.subscribed,
        {'camera:a', 'camera:b'},
        reason: 'resubscribing is immediate, with no elapsed time at all',
      );
      wired.culler.dispose();
    });
  });

  test('a screen share is culled exactly as a camera is', () {
    fakeAsync((async) {
      final room = _FakeRoom(['camera:a', 'screen:a']);
      final wired = _wire(room);
      wired.culler.setInterest({'camera:a'});
      wired.culler.apply(room.refs);
      async.elapse(videoSubscriptionDwell);
      expect(room.subscribed, {'camera:a'});
      wired.culler.dispose();
    });
  });

  test('audio is never unsubscribed, whatever the interest set says', () {
    fakeAsync((async) {
      final room = _FakeRoom(['camera:a', 'audio:a', 'microphone:b']);
      final wired = _wire(room);
      wired.culler.setInterest(const <String>{});
      wired.culler.apply(room.refs);
      async.elapse(const Duration(minutes: 5));

      expect(
        room.subscribed,
        {'audio:a', 'microphone:b'},
        reason: 'only the camera was ever a candidate',
      );
      expect(room.unsubscribeCalls, 1);
      wired.culler.dispose();
    });
  });

  test('a null interest is not an empty one: everything stays subscribed', () {
    fakeAsync((async) {
      final room = _FakeRoom(['camera:a', 'camera:b']);
      final wired = _wire(room);
      wired.culler.setInterest(null);
      wired.culler.apply(room.refs);
      async.elapse(const Duration(minutes: 5));

      expect(room.subscribed, {'camera:a', 'camera:b'});
      expect(room.unsubscribeCalls, 0);
      wired.culler.dispose();
    });
  });

  test('handing the decision back mid-dwell cancels it', () {
    fakeAsync((async) {
      final room = _FakeRoom(['camera:a', 'camera:b']);
      final wired = _wire(room);
      wired.culler.setInterest({'camera:a'});
      wired.culler.apply(room.refs);
      async.elapse(const Duration(seconds: 1));

      // The canvas unmounting, with no further apply to reconcile through.
      wired.culler.setInterest(null);
      async.elapse(const Duration(minutes: 5));

      expect(room.subscribed, {'camera:a', 'camera:b'});
      expect(wired.dueCount(), 0);
      wired.culler.dispose();
    });
  });

  test('a participant who leaves mid-dwell drops their pending cull', () {
    fakeAsync((async) {
      final room = _FakeRoom(['camera:a', 'camera:b']);
      final wired = _wire(room);
      wired.culler.setInterest({'camera:a'});
      wired.culler.apply(room.refs);
      async.elapse(const Duration(seconds: 1));

      room.drop('camera:b');
      wired.culler.apply(room.refs);
      async.elapse(const Duration(minutes: 5));

      expect(wired.dueCount(), 0, reason: 'no timer survived the departure');
      expect(room.subscribed, {'camera:a'});
      wired.culler.dispose();
    });
  });

  test('disposing leaves no timer running', () {
    fakeAsync((async) {
      final room = _FakeRoom(['camera:a', 'camera:b']);
      final wired = _wire(room);
      wired.culler.setInterest({'camera:a'});
      wired.culler.apply(room.refs);
      wired.culler.dispose();
      async.elapse(const Duration(minutes: 5));

      expect(wired.dueCount(), 0);
      expect(room.subscribed, {'camera:a', 'camera:b'});
    });
  });

  test('a rejected subscribe is dropped, not crashed on', () {
    fakeAsync((async) {
      final room = _FakeRoom(['camera:a']);
      final wired = _wire(room);

      // Cull it out first, so the next interest change actually attempts a real subscribe() rather than finding it already subscribed.
      wired.culler.setInterest(const <String>{});
      wired.culler.apply(room.refs);
      async.elapse(videoSubscriptionDwell);
      expect(room.subscribed, isEmpty);

      room.failSubscribe.add('camera:a');
      wired.culler.setInterest({'camera:a'});
      wired.culler.apply(room.refs);
      async.flushMicrotasks();

      expect(room.subscribeCalls, 1);
      expect(
        room.subscribed,
        isEmpty,
        reason: 'the rejected subscribe never actually landed',
      );

      // Nothing about the rejection wedges a later reconcile.
      wired.culler.apply(room.refs);
      async.flushMicrotasks();
      expect(room.subscribeCalls, 2);
      expect(room.subscribed, {'camera:a'});
      wired.culler.dispose();
    });
  });

  test('a rejected unsubscribe is dropped, not crashed on', () {
    fakeAsync((async) {
      final room = _FakeRoom(['camera:a', 'camera:b']);
      final wired = _wire(room);
      wired.culler.setInterest({'camera:a', 'camera:b'});
      wired.culler.apply(room.refs);

      room.failUnsubscribe.add('camera:b');
      wired.culler.setInterest({'camera:a'});
      wired.culler.apply(room.refs);
      async.elapse(videoSubscriptionDwell);
      async.flushMicrotasks();

      expect(wired.dueCount(), 1);
      expect(room.unsubscribeCalls, 1);
      expect(
        room.subscribed,
        {'camera:a', 'camera:b'},
        reason: 'the rejected unsubscribe left the track exactly as it was',
      );

      // A rejection this cycle must not block the next one from trying again.
      wired.culler.apply(room.refs);
      async.elapse(videoSubscriptionDwell);
      async.flushMicrotasks();
      expect(wired.dueCount(), 2);
      expect(room.unsubscribeCalls, 2);
      expect(room.subscribed, {'camera:a'});
      wired.culler.dispose();
    });
  });

  test('the kind of a tile key is its prefix, and a bare key has none', () {
    expect(videoSubscriptionKind('camera:019f-abc'), 'camera');
    expect(videoSubscriptionKind('screen:019f-abc'), 'screen');
    expect(videoSubscriptionKind('nonsense'), 'nonsense');
    expect(cullableTrackKinds, {'camera', 'screen'});
  });

  test('a blocked key unsubscribes at once and stays out under null interest',
      () {
    fakeAsync((async) {
      final room = _FakeRoom(['screen:a', 'camera:a']);
      final wired = _wire(room);
      wired.culler.setBlocked({'screen:a'});
      wired.culler.apply(room.refs);
      expect(room.subscribed, {'camera:a'}, reason: 'no dwell for a block');

      wired.culler.setInterest(null);
      wired.culler.apply(room.refs);
      expect(room.subscribed, {'camera:a'},
          reason: 'null interest keeps it out');
      expect(wired.culler.wants('screen:a'), isFalse);

      wired.culler.setBlocked(const {});
      wired.culler.apply(room.refs);
      expect(room.subscribed, {'screen:a', 'camera:a'});
      wired.culler.dispose();
    });
  });
}
