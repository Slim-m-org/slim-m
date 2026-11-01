// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A dock leaving must not zero the reservation another dock now holds (the
/// outgoing canvas pane unmounts after the incoming one has measured).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/dock_reservation.dart';
import 'package:slimm_app/src/features/modules/widgets/dock_height_reporter.dart';

Widget _docks(List<(Key, double)> docks) => MaterialApp(
  home: Column(
    children: [
      for (final (key, height) in docks)
        DockHeightReporter(
          key: key,
          child: SizedBox(height: height, width: 50),
        ),
    ],
  ),
);

void main() {
  testWidgets('the last dock to measure keeps the reservation when another '
      'leaves', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const outgoing = ValueKey('outgoing');
    const incoming = ValueKey('incoming');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _docks(const [(outgoing, 100)]),
      ),
    );
    await tester.pump();
    expect(container.read(bottomDockReservationProvider), 100);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _docks(const [(outgoing, 100), (incoming, 60)]),
      ),
    );
    await tester.pump();
    expect(container.read(bottomDockReservationProvider), 60);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _docks(const [(incoming, 60)]),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(container.read(bottomDockReservationProvider), 60);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: _docks(const [])),
    );
    await tester.pump();
    await tester.pump();

    expect(container.read(bottomDockReservationProvider), 0);
  });
}
