// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The activity announcer's live region must be its own semantics node.
///
/// Merged into the pane's focus scope next to the ticking call timer, its
/// label changes every second and a screen reader re-reads it each tick.
library;

import 'dart:ui' show Tristate;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_panel.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  testWidgets('the live region is a standalone node, not merged with the '
      'pane or the call timer', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    final handle = tester.ensureSemantics();

    await pumpCanvasPane(tester, container);

    final node = tester.getSemantics(
      find.byKey(CanvasActivityAnnouncer.liveRegionKey),
    );
    final data = node.getSemanticsData();
    expect(
      data.flagsCollection.isLiveRegion,
      isTrue,
      reason: 'sanity: the finder reached the live region',
    );
    expect(
      data.flagsCollection.isFocused,
      Tristate.none,
      reason:
          'merged into the pane focus scope, so any timer text there '
          'changes this live label every second',
    );
    expect(data.label, isEmpty);
    handle.dispose();
  });
}
