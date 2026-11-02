// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who keeps the sampler running, and how often a track's line reaches the log.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

CallStatsTarget _target({bool local = false, String identity = 'u1'}) =>
    CallStatsTarget(
      identity: identity,
      name: 'n',
      source: CallStatsSource.camera,
      local: local,
      fetch: () async => const [
        StatsEntry(
          type: 'outbound-rtp',
          id: 'o',
          values: {'kind': 'video', 'frameWidth': 640, 'frameHeight': 360},
        ),
      ],
    );

void main() {
  test('a held sampler samples with nobody listening and stops on release', () {
    fakeAsync((async) {
      var fetched = 0;
      final sampler = CallStatsSampler(
        targets: () => [
          CallStatsTarget(
            identity: 'me',
            name: 'me',
            source: CallStatsSource.screenShare,
            local: true,
            fetch: () async {
              fetched++;
              return const [];
            },
          ),
        ],
      );
      expect(sampler.running, isFalse);

      sampler.setHeld(true);
      async.elapse(const Duration(seconds: 11));
      expect(sampler.running, isTrue);
      expect(fetched, 3);

      sampler.setHeld(false);
      async.elapse(const Duration(seconds: 30));
      expect(sampler.running, isFalse);
      expect(fetched, 3);
      unawaited(sampler.dispose());
    });
  });

  test('a listener leaving does not stop a held sampler', () {
    fakeAsync((async) {
      final sampler = CallStatsSampler(targets: () => [_target(local: true)])
        ..setHeld(true);
      final sub = sampler.snapshots.listen((_) {});
      unawaited(sub.cancel());
      async.flushMicrotasks();

      expect(sampler.running, isTrue);
      sampler.setHeld(false);
      expect(sampler.running, isFalse);
      unawaited(sampler.dispose());
    });
  });

  test('a track is logged once per interval, not once per sample', () {
    fakeAsync((async) {
      final lines = <String>[];
      final start = DateTime(2026);
      final sampler = CallStatsSampler(
        targets: () => [_target()],
        log: lines.add,
        clock: () => start.add(async.elapsed),
      )..setHeld(true);

      async.elapse(const Duration(seconds: 29));
      expect(lines, hasLength(1));
      async.elapse(const Duration(seconds: 2));
      expect(lines, hasLength(2));
      unawaited(sampler.dispose());
    });
  });

  test('logging every sample bypasses the interval', () {
    fakeAsync((async) {
      final lines = <String>[];
      final start = DateTime(2026);
      final sampler = CallStatsSampler(
        targets: () => [_target()],
        log: lines.add,
        clock: () => start.add(async.elapsed),
      )..setLogging(true);

      async.elapse(const Duration(seconds: 6, milliseconds: 100));
      expect(lines, hasLength(4));
      unawaited(sampler.dispose());
    });
  });

  test('every sample reaches onSample whatever the log interval', () {
    fakeAsync((async) {
      final seen = <String>[];
      final sampler = CallStatsSampler(
        targets: () => [_target()],
        onSample: (s) => seen.add(s.key),
      )..setHeld(true);

      async.elapse(const Duration(seconds: 6, milliseconds: 100));
      expect(seen, hasLength(4));
      expect(seen.toSet(), {'in/u1/camera'});
      unawaited(sampler.dispose());
    });
  });
}
