// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The toast queue: a confirmation is added, auto-dismisses on its own timer,
/// a burst is capped to the newest few, and a hand dismiss removes exactly one.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  test('show adds a toast carrying its message and severity', () {
    final controller = ToastsController();
    addTearDown(controller.dispose);

    controller.show('Copied', severity: AppToastSeverity.success);

    expect(controller.state, hasLength(1));
    expect(controller.state.single.message, 'Copied');
    expect(controller.state.single.severity, AppToastSeverity.success);
  });

  test('a toast auto-dismisses once its duration elapses', () {
    fakeAsync((async) {
      final controller = ToastsController();
      addTearDown(controller.dispose);

      controller.show('Saved', duration: const Duration(seconds: 4));
      expect(controller.state, hasLength(1));

      async.elapse(const Duration(seconds: 3));
      expect(
        controller.state,
        hasLength(1),
        reason: 'still up before its time',
      );

      async.elapse(const Duration(seconds: 2));
      expect(controller.state, isEmpty, reason: 'gone once the timer fires');
    });
  });

  test('a zero duration stays until dismissed by hand', () {
    fakeAsync((async) {
      final controller = ToastsController();
      addTearDown(controller.dispose);

      final id = controller.show('Pinned', duration: Duration.zero);
      async.elapse(const Duration(minutes: 10));
      expect(controller.state, hasLength(1), reason: 'no timer was armed');

      controller.dismiss(id);
      expect(controller.state, isEmpty);
    });
  });

  test('a burst past the cap drops the oldest and keeps the newest', () {
    final controller = ToastsController();
    addTearDown(controller.dispose);

    for (var i = 0; i < ToastsController.maxVisible + 2; i++) {
      controller.show('toast $i', duration: Duration.zero);
    }

    expect(controller.state, hasLength(ToastsController.maxVisible));
    expect(controller.state.first.message, 'toast 2', reason: 'oldest dropped');
    expect(controller.state.last.message, 'toast 5', reason: 'newest kept');
  });

  test('dismiss removes exactly the named toast and cancels its timer', () {
    fakeAsync((async) {
      final controller = ToastsController();
      addTearDown(controller.dispose);

      final first = controller.show(
        'first',
        duration: const Duration(seconds: 4),
      );
      controller.show('second', duration: Duration.zero);
      controller.dismiss(first);

      expect(controller.state, hasLength(1));
      expect(controller.state.single.message, 'second');

      // The dismissed toast's timer, once it would fire, must not remove the survivor.
      async.elapse(const Duration(seconds: 10));
      expect(controller.state, hasLength(1));
      expect(controller.state.single.message, 'second');
    });
  });
}
