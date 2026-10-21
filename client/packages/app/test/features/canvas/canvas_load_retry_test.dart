// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The backoff of a failed canvas read stays bounded however long the outage
/// lasts, and a channel that no longer exists is not asked for again.
library;

import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_forbidden_message.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_load_retry.dart';

import 'canvas_pane_harness.dart';

void main() {
  test('the wait starts at two seconds and never passes the ceiling', () {
    final retry = CanvasLoadRetry(random: _NoJitter());
    final waits = <int>[];
    for (var i = 0; i < 80; i++) {
      waits.add(retry.nextDelay().inSeconds);
      retry.schedule(() {});
    }
    retry.cancel();

    expect(waits.take(5), [2, 4, 8, 16, 30]);
    expect(waits.reduce(max), 30);
    expect(waits.skip(10), everyElement(30));
  });

  test('a long outage is retried at the ceiling, not every two seconds', () {
    fakeAsync((async) {
      final retry = CanvasLoadRetry(random: _NoJitter());
      var runs = 0;
      void again() {
        runs++;
        retry.schedule(again);
      }

      retry.schedule(again);
      async.elapse(const Duration(minutes: 20));

      expect(runs, lessThan(60));
      retry.cancel();
    });
  });

  testWidgets('a channel that is gone shows the unavailable message once', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture(viewportStatus: 404);
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();
    final reads = fixture.viewportGets;

    await tester.pump(const Duration(minutes: 5));

    expect(find.text(canvasUnavailableMessage), findsOneWidget);
    expect(fixture.viewportGets, reads, reason: 'no retry after a 404');
  });
}

class _NoJitter implements Random {
  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;

  @override
  int nextInt(int max) => 0;
}
