// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Closing the canvas from More asks for a refocus only for the frame the dock
/// rebuilds in; an unconsumed request must not wait for some later mount.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_toggle_refocus.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_dock_toggle.dart';
import 'package:slimm_app/src/widgets/control_options_menu.dart';

void main() {
  testWidgets('a close from More is seen by this frame\'s mounts, then gone', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final refocus = container.read(canvasToggleRefocusProvider.notifier);
    var closed = false;
    final entry = canvasToggleItem(
      open: true,
      onPressed: () => closed = true,
      refocus: refocus,
    ).entries.single;

    (entry as ControlOption).onSelected();
    expect(closed, isTrue);
    var seenByMount = false;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => seenByMount = container.read(canvasToggleRefocusProvider),
    );
    await tester.pump();
    expect(seenByMount, isTrue, reason: 'the remounting dock still gets it');

    await tester.pump();
    expect(
      container.read(canvasToggleRefocusProvider),
      isFalse,
      reason: 'a request nobody took must not outlive the close',
    );
  });
}
