// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Property tests for [ReconnectBackoff]: the delay `SyncController` waits
/// between reconnect attempts, so a server restart does not bring every
/// client back in the same instant. Before this, the jitter came straight
/// from `Random()` inside `SyncController` with no seam for a test to pin
/// the draw, and PR #877 (which replaced a jitter source that was always
/// zero on web with this one) shipped without coverage for that reason.
library;

import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/reconnect_backoff.dart';

/// A [Random] stub that always draws [value] and records the `max` it was
/// last asked for, so a test can pin the jitter draw without depending on
/// any particular RNG algorithm or seed.
class _FixedRandom implements Random {
  _FixedRandom(this.value);

  final int value;
  int? lastMax;

  @override
  int nextInt(int max) {
    lastMax = max;
    return value;
  }

  @override
  double nextDouble() => 0;

  @override
  bool nextBool() => false;
}

void main() {
  group('ReconnectBackoff', () {
    test('grows exponentially across successive attempts', () {
      final backoff = ReconnectBackoff(random: _FixedRandom(0));
      final seconds = List.generate(6, (_) => backoff.next().inSeconds);
      expect(seconds, [1, 2, 4, 8, 16, 32]);
    });

    test('jitter stays within its bound, never negative', () {
      final zero = _FixedRandom(0);
      expect(
        ReconnectBackoff(random: zero).next(),
        const Duration(seconds: 1),
        reason: 'a zero draw must add no jitter at all, not go negative',
      );
      expect(zero.lastMax, 1000, reason: 'the draw is for [0, 1000) ms');

      final maxDraw = _FixedRandom(999);
      expect(
        ReconnectBackoff(random: maxDraw).next(),
        const Duration(seconds: 1, milliseconds: 999),
        reason:
            'the highest possible draw must still land under the next second',
      );
    });

    test(
      'the ceiling holds so a long outage never grows the delay further',
      () {
        final backoff = ReconnectBackoff(random: _FixedRandom(0));
        late Duration last;
        for (var i = 0; i < 20; i++) {
          last = backoff.next();
        }
        expect(last, const Duration(seconds: 32));
      },
    );

    test('two clients with different draws get different delays', () {
      final a = ReconnectBackoff(random: _FixedRandom(0));
      final b = ReconnectBackoff(random: _FixedRandom(500));
      expect(a.next(), isNot(equals(b.next())));
    });

    test('a successful connection resets the sequence', () {
      final backoff = ReconnectBackoff(random: _FixedRandom(0));
      expect(backoff.next(), const Duration(seconds: 1));
      expect(backoff.next(), const Duration(seconds: 2));
      backoff.reset();
      expect(
        backoff.next(),
        const Duration(seconds: 1),
        reason: 'reset must restart from attempt one, not continue climbing',
      );
    });
  });

  group('ReconnectBackoff stability', () {
    test('a connection that drops within the window keeps the backoff', () {
      fakeAsync((async) {
        final backoff = ReconnectBackoff(random: _FixedRandom(0));
        expect(backoff.next(), const Duration(seconds: 1));
        backoff.connected();
        async.elapse(const Duration(seconds: 5));
        backoff.dropped();
        async.elapse(const Duration(minutes: 5));
        expect(backoff.stable, isFalse);
        expect(backoff.next(), const Duration(seconds: 2));
        backoff.connected();
        async.elapse(const Duration(seconds: 5));
        backoff.dropped();
        expect(backoff.next(), const Duration(seconds: 4));
      });
    });

    test('a connection that stays live resets the backoff', () {
      fakeAsync((async) {
        final backoff = ReconnectBackoff(random: _FixedRandom(0));
        backoff.next();
        backoff.next();
        backoff.connected();
        async.elapse(connectionStableAfter);
        expect(backoff.stable, isTrue);
        backoff.dropped();
        expect(backoff.next(), const Duration(seconds: 1));
      });
    });
  });
}
