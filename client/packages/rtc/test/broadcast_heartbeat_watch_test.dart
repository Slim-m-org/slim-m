// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/broadcast_heartbeat_watch.dart';

void main() {
  late Duration? reported;
  late int lost;

  BroadcastHeartbeatWatch build(FakeAsync async) => BroadcastHeartbeatWatch(
        silence: () async => reported,
        onLost: () => lost++,
        clock: async.getClock(DateTime(2026)).now,
      );

  setUp(() {
    reported = Duration.zero;
    lost = 0;
  });

  test('a beating extension is never declared lost', () {
    fakeAsync((async) {
      final watch = build(async)..broadcastChanged(broadcasting: true);
      async.elapse(const Duration(minutes: 2));
      expect(lost, 0);
      watch.dispose();
    });
  });

  test('an extension that stops beating is declared lost once', () {
    fakeAsync((async) {
      final watch = build(async)..broadcastChanged(broadcasting: true);
      async.elapse(const Duration(seconds: 30));
      reported = null;
      async.elapse(const Duration(seconds: 30));
      expect(lost, 1);
      watch.dispose();
    });
  });

  test('an extension that never beats is lost after the grace period', () {
    fakeAsync((async) {
      reported = null;
      final watch = build(async)..broadcastChanged(broadcasting: true);
      async.elapse(const Duration(seconds: 9));
      expect(lost, 0);
      async.elapse(const Duration(seconds: 6));
      expect(lost, 1);
      watch.dispose();
    });
  });

  test('a beat left over from an earlier broadcast does not count', () {
    fakeAsync((async) {
      reported = const Duration(minutes: 5);
      final watch = build(async)..broadcastChanged(broadcasting: true);
      async.elapse(const Duration(seconds: 15));
      expect(lost, 1);
      watch.dispose();
    });
  });

  test('a stopped broadcast is not watched', () {
    fakeAsync((async) {
      reported = null;
      final watch = build(async)
        ..broadcastChanged(broadcasting: true)
        ..broadcastChanged(broadcasting: false);
      async.elapse(const Duration(minutes: 1));
      expect(lost, 0);
      watch.dispose();
    });
  });
}
