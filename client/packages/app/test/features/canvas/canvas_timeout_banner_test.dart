// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The timed-out banner is what keeps drawing disabled, so it has to go when the timeout does.
library;

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_forbidden_message.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_timeout_banner.dart';

class _Rig {
  _Rig({required this.until, required this.error});

  int? until;
  String? error;
  int cleared = 0;

  late final banner = CanvasTimeoutBanner(
    timedOutUntil: () => until,
    error: () => error,
    clear: () {
      cleared++;
      error = null;
    },
    now: () => clock.now(),
  );
}

void main() {
  final timedOut = canvasDrawForbiddenMessage(
    DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch,
  );

  test('the banner clears when the timeout lapses', () {
    fakeAsync((async) {
      final rig = _Rig(
        until: clock
            .now()
            .add(const Duration(seconds: 30))
            .millisecondsSinceEpoch,
        error: timedOut,
      )..banner.watch();

      async.elapse(const Duration(seconds: 29));
      expect(rig.cleared, 0);
      async.elapse(const Duration(seconds: 2));
      expect(rig.cleared, 1);
      expect(canvasErrorBlocksDrawing(rig.error), isFalse);
    });
  });

  test('a timeout that already lapsed clears at once', () {
    fakeAsync((async) {
      final rig = _Rig(
        until: clock
            .now()
            .subtract(const Duration(seconds: 1))
            .millisecondsSinceEpoch,
        error: timedOut,
      )..banner.watch();

      expect(rig.cleared, 1);
    });
  });

  test('a longer timeout that replaced it keeps the banner', () {
    fakeAsync((async) {
      final rig = _Rig(
        until: clock
            .now()
            .add(const Duration(seconds: 30))
            .millisecondsSinceEpoch,
        error: timedOut,
      )..banner.watch();

      rig.until = clock
          .now()
          .add(const Duration(minutes: 5))
          .millisecondsSinceEpoch;
      async.elapse(const Duration(seconds: 31));
      expect(rig.cleared, 0);
      async.elapse(const Duration(minutes: 5));
      expect(rig.cleared, 1);
    });
  });

  test('a refusal that is not a timeout is never cleared by the clock', () {
    fakeAsync((async) {
      final rig = _Rig(until: null, error: canvasDrawForbiddenMessage(null))
        ..banner.watch();

      async.elapse(const Duration(hours: 1));
      expect(rig.cleared, 0);
      expect(canvasErrorBlocksDrawing(rig.error), isTrue);
    });
  });
}
