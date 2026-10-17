// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A dragged slider reaches the platform on a throttle, newest value last.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/volume_drag_throttle.dart';

void main() {
  test('the first value applies at once, later ones coalesce, newest last', () {
    fakeAsync((async) {
      final applied = <double>[];
      final throttle = TrailingThrottle<double>(
        (v) async => applied.add(v),
        now: () => async.getClock(DateTime(2026)).now(),
      );

      throttle.push(0.1);
      expect(applied, [0.1]);

      throttle.push(0.2);
      throttle.push(0.3);
      throttle.push(0.4);
      expect(applied, [0.1], reason: 'inside the interval nothing more lands');

      async.elapse(kVolumeDragInterval);
      expect(applied, [0.1, 0.4], reason: 'one trailing apply, the latest');
    });
  });

  test('cancel drops the waiting value so a final one is not overtaken', () {
    fakeAsync((async) {
      final applied = <double>[];
      final throttle = TrailingThrottle<double>(
        (v) async => applied.add(v),
        now: () => async.getClock(DateTime(2026)).now(),
      );

      throttle.push(0.1);
      throttle.push(0.2);
      throttle.cancel();
      async.elapse(kVolumeDragInterval * 2);

      expect(applied, [0.1]);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a value after a quiet spell applies immediately again', () {
    fakeAsync((async) {
      final applied = <double>[];
      final throttle = TrailingThrottle<double>(
        (v) async => applied.add(v),
        now: () => async.getClock(DateTime(2026)).now(),
      );

      throttle.push(0.1);
      async.elapse(kVolumeDragInterval * 3);
      throttle.push(0.9);

      expect(applied, [0.1, 0.9]);
    });
  });
}
