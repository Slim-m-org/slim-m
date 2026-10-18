// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A failed viewport read, say one that landed on a deploy or a rate limit,
/// heals itself and never takes the pen away.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_forbidden_message.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';

import '../../support/fake_sync.dart';
import 'canvas_pane_harness.dart';

const _failed = 'The canvas could not be loaded.';

void main() {
  test('a failed load does not block drawing', () {
    expect(canvasErrorBlocksDrawing(canvasLoadFailedMessage), isFalse);
  });

  testWidgets('a failed load retries by itself and clears the banner', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture(viewportStatus: 500);
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();
    expect(find.text(_failed), findsOneWidget);

    fixture.viewportStatus = 200;
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();

    expect(find.text(_failed), findsNothing);
  });

  testWidgets('reconnecting reloads a canvas that failed to load', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture(viewportStatus: 500);
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();
    expect(find.text(_failed), findsOneWidget);

    fixture.viewportStatus = 200;
    (container.read(syncControllerProvider.notifier) as NoopSyncController)
        .report(SyncStatus.live);
    await tester.pumpAndSettle();

    expect(find.text(_failed), findsNothing);
  });
}
