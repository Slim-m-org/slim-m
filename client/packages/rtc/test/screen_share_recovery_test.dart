// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/call_stats.dart';
import 'package:slimm_rtc/src/screen_share_liveness.dart';
import 'package:slimm_rtc/src/screen_share_local.dart';
import 'package:slimm_rtc/src/screen_share_recovery.dart';

const _tick = Duration(seconds: 2);

void main() {
  group('ShareLivenessWatch', () {
    late DateTime now;
    late ShareLivenessWatch watch;
    ShareLiveness see(int? frames,
        {int w = 1280, int h = 720, bool win = true}) {
      final verdict = watch.observe(
        ShareReading(framesSent: frames, width: w, height: h),
        windowShare: win,
        now: now,
      );
      now = now.add(_tick);
      return verdict;
    }

    setUp(() {
      now = DateTime(2026, 10, 27, 12);
      watch = ShareLivenessWatch();
    });

    test('a window share whose frames advance is live', () {
      expect(see(10), ShareLiveness.unknown);
      expect(see(40), ShareLiveness.live);
      expect(see(70), ShareLiveness.live);
    });

    test('a window share whose frames stand still freezes after the grace', () {
      see(10);
      see(40);
      expect(see(40), ShareLiveness.suspect);
      expect(see(40), ShareLiveness.suspect);
      expect(see(40), ShareLiveness.suspect);
      expect(see(40), ShareLiveness.frozen);
    });

    test('frames coming back clear a freeze', () {
      see(10);
      for (var i = 0; i < 5; i++) {
        see(10);
      }
      expect(watch.verdict, ShareLiveness.frozen);
      expect(see(60), ShareLiveness.live);
    });

    test('a collapsed frame size freezes even a screen share', () {
      for (var i = 0; i < 3; i++) {
        expect(see(5, w: 8, h: 8, win: false), ShareLiveness.suspect);
      }
      expect(see(5, w: 8, h: 8, win: false), ShareLiveness.frozen);
    });

    test('a static screen share with no new frames is not frozen', () {
      see(10, win: false);
      for (var i = 0; i < 10; i++) {
        expect(see(10, win: false), isNot(ShareLiveness.frozen));
      }
    });

    test('a platform without a frame counter is never judged by frames', () {
      for (var i = 0; i < 10; i++) {
        expect(see(null), isNot(ShareLiveness.frozen));
      }
    });
  });

  group('ShareRecovery', () {
    late DateTime now;
    late List<ShareReading?> readings;
    late List<String> calls;
    late bool restartFails;
    late ShareRecovery recovery;

    setUp(() {
      now = DateTime(2026, 10, 27, 12);
      readings = [];
      calls = [];
      restartFails = false;
      recovery = ShareRecovery(
        read: () async => readings.isEmpty ? null : readings.removeAt(0),
        pause: (paused) async => calls.add(paused ? 'pause' : 'resume'),
        restart: () async {
          calls.add('restart');
          if (restartFails) throw StateError('window gone');
        },
        clock: () => now,
      );
    });

    tearDown(() => recovery.stop());

    Future<void> feed(FakeAsync async, int frames, {int w = 1280}) async {
      readings.add(ShareReading(framesSent: frames, width: w, height: 720));
      now = now.add(_tick);
      async.elapse(_tick);
      async.flushMicrotasks();
    }

    test('a frozen window is paused, restarted, and resumed once frames flow',
        () {
      fakeAsync((async) {
        recovery.start(windowShare: true);
        feed(async, 10);
        feed(async, 40);
        for (var i = 0; i < 4; i++) {
          feed(async, 40);
        }
        expect(calls, ['pause', 'restart', 'pause']);
        expect(recovery.paused, isTrue);
        feed(async, 5);
        feed(async, 35);
        expect(calls, ['pause', 'restart', 'pause', 'resume']);
        expect(recovery.paused, isFalse);
      });
    });

    test('a restart that fails is retried later, not every poll', () {
      fakeAsync((async) {
        restartFails = true;
        recovery.start(windowShare: true);
        feed(async, 10);
        feed(async, 40);
        for (var i = 0; i < 4; i++) {
          feed(async, 40);
        }
        expect(calls.where((c) => c == 'restart'), hasLength(1));
        for (var i = 0; i < 3; i++) {
          feed(async, 40);
        }
        expect(calls.where((c) => c == 'restart'), hasLength(1));
        for (var i = 0; i < 3; i++) {
          feed(async, 40);
        }
        expect(calls.where((c) => c == 'restart'), hasLength(2));
        expect(recovery.paused, isTrue);
      });
    });

    test('a healthy share is never touched', () {
      fakeAsync((async) {
        recovery.start(windowShare: true);
        for (var i = 0; i < 20; i++) {
          feed(async, i * 40);
        }
        expect(calls, isEmpty);
      });
    });

    test('stopping ends the watch', () {
      fakeAsync((async) {
        recovery.start(windowShare: true);
        recovery.stop();
        for (var i = 0; i < 10; i++) {
          feed(async, 10);
        }
        expect(calls, isEmpty);
      });
    });
  });

  group('shareReadingOf', () {
    StatsEntry out(Map<String, Object?> values,
            {String type = 'outbound-rtp'}) =>
        StatsEntry(type: type, id: 'x', values: values);

    test('sums frames over layers and keeps the largest frame size', () {
      final reading = shareReadingOf([
        out({
          'kind': 'video',
          'framesSent': 100,
          'frameWidth': 1280,
          'frameHeight': 720
        }),
        out({
          'kind': 'video',
          'framesSent': 50,
          'frameWidth': 640,
          'frameHeight': 360
        }),
        out({'kind': 'audio', 'framesSent': 999}),
        out({'framesSent': 7}, type: 'inbound-rtp'),
      ]);
      expect(reading.framesSent, 150);
      expect(reading.width, 1280);
      expect(reading.height, 720);
    });

    test('no outbound video means no reading to judge', () {
      final reading = shareReadingOf([
        out({'kind': 'audio'})
      ]);
      expect(reading.framesSent, isNull);
    });
  });
}
