// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `DockHeightReporter` (`canvas_pane_body.dart`'s wrapper around the call
/// dock) resets its own `bottomDockReservationProvider` entry on unmount.
/// Two real defects sat in that one line, neither visible from reading the
/// class alone: Riverpod refuses a provider write made synchronously inside
/// `dispose` (the tree is still mid-teardown), and deferring that write to
/// a microtask then races the very next thing a real unmount often does -
/// tear down the `ProviderContainer` itself - which a naive deferred write
/// throws into.
///
/// Both were only found by actually unmounting the widget inside a real
/// widget test, never by reading `dock_height_reporter.dart`'s own source;
/// `canvas_collapse_disposal_test.dart` and `channel_rail_drawer_test.dart`
/// are what first surfaced them, as collateral failures in tests that have
/// nothing to do with this file - and stay the sharper mutation guard for
/// the second bug specifically, since reproducing a container disposed out
/// from under a still-mounted `UncontrolledProviderScope` needs a real
/// app-shaped teardown this file's own narrower harness cannot force.
///
/// The `UncontrolledProviderScope` itself must stay mounted across the
/// unmount under test, or Riverpod's own "modify during build" guard never
/// fires: it works by calling `markNeedsBuild` on the *scope element*, and
/// that only throws while the scope is genuinely still locked mid-build,
/// the same shape `home_shell_harness.dart`'s stable root has and a bare
/// `pumpWidget` swap of the whole tree does not.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/dock_reservation.dart';
import 'package:slimm_app/src/widgets/dock_height_reporter.dart';

/// [show] toggles only the reporter itself; the [UncontrolledProviderScope]
/// and the [Directionality]/[Align] around it stay the same widget across
/// both calls, so swapping [show] to false unmounts *only* the reporter.
Widget _harness(ProviderContainer container, {required bool show}) =>
    UncontrolledProviderScope(
      container: container,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: show
              ? const DockHeightReporter(child: SizedBox(width: 10, height: 40))
              : const SizedBox.shrink(),
        ),
      ),
    );

void main() {
  testWidgets(
    'unmounting the reporter does not throw for writing to a provider '
    'mid-teardown',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(_harness(container, show: true));
      await tester.pump();

      await tester.pumpWidget(_harness(container, show: false));

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the deferred reset does not throw when the container is gone before '
    'the microtask runs',
    (tester) async {
      final container = ProviderContainer();

      await tester.pumpWidget(_harness(container, show: true));
      await tester.pump();

      // The exact race a real teardown can produce: the container disposes before the deferred reset's microtask runs.
      await tester.pumpWidget(_harness(container, show: false));
      container.dispose();
      await tester.pump();

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the reservation resets to 0 once the reporter is gone', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(_harness(container, show: true));
    await tester.pump();
    expect(container.read(bottomDockReservationProvider), 40);

    await tester.pumpWidget(_harness(container, show: false));
    // Two pumps: the first pump's own flush point can land before the deferred microtask is scheduled.
    await tester.pump();
    await tester.pump();

    expect(container.read(bottomDockReservationProvider), 0);
  });
}
