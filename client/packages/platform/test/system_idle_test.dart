// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/src/system_idle_io.dart';
import 'package:slimm_platform/src/system_idle_linux.dart';

void main() {
  test('Windows idle time survives the 49.7 day tick wrap', () {
    expect(windowsIdleSince(5000, 2000), const Duration(milliseconds: 3000));
    expect(
      windowsIdleSince(1000, 0xFFFFFFFF - 999),
      const Duration(milliseconds: 2000),
    );
  });

  test('Linux idle ages its last sample between polls', () {
    fakeAsync((async) {
      final idle = LinuxSystemIdle(
        probes: [() async => const Duration(seconds: 4)],
        pollInterval: const Duration(minutes: 1),
      );
      expect(idle.idleTime(), isNull, reason: 'nothing sampled yet');
      async.flushMicrotasks();
      expect(idle.idleTime(), const Duration(seconds: 4));
      async.elapse(const Duration(seconds: 30));
      expect(idle.idleTime(), const Duration(seconds: 34));
      idle.dispose();
    });
  });

  test('Linux idle falls through unsupported sources to the next', () {
    fakeAsync((async) {
      final idle = LinuxSystemIdle(
        probes: [
          () async => throw StateError('NotSupported'),
          () async => null,
          () async => const Duration(minutes: 12),
        ],
      );
      async.flushMicrotasks();
      expect(idle.idleTime(), const Duration(minutes: 12));
      idle.dispose();
    });
  });

  test('Linux idle asks a source again once it starts answering', () {
    fakeAsync((async) {
      var up = false;
      final idle = LinuxSystemIdle(
        probes: [
          () async => up ? const Duration(seconds: 3) : throw StateError('x'),
        ],
        pollInterval: const Duration(seconds: 10),
      );
      async.flushMicrotasks();
      expect(idle.idleTime(), isNull);
      up = true;
      async.elapse(const Duration(seconds: 10));
      expect(idle.idleTime(), const Duration(seconds: 3));
      idle.dispose();
    });
  });

  test('Linux idle is unknown when no source answers', () {
    fakeAsync((async) {
      final idle = LinuxSystemIdle(probes: [() async => null]);
      async.flushMicrotasks();
      expect(idle.idleTime(), isNull);
      idle.dispose();
    });
  });

  test('Linux idle prefers the first source that answers, even with zero', () {
    fakeAsync((async) {
      var laterAsked = false;
      final idle = LinuxSystemIdle(
        probes: [
          () async => Duration.zero,
          () async {
            laterAsked = true;
            return const Duration(hours: 1);
          },
        ],
      );
      async.flushMicrotasks();
      expect(idle.idleTime(), Duration.zero);
      expect(laterAsked, isFalse);
      idle.dispose();
    });
  });
}
