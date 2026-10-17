// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas pane's own header title, dumped against the real semantics
/// tree rather than reasoned about, per this project's own established
/// technique (see CLAUDE.md's AppBar-title and resize-bar findings, both
/// only found this way).
///
/// `CanvasPane` wraps its whole body in one `Focus(autofocus: true)` for its
/// keyboard shortcuts. A bare `Text('Canvas')` sitting anywhere under a
/// focus scope with no semantics boundary of its own merges upward into
/// that scope's own node rather than staying a distinct header - the same
/// trap already found and fixed for a thread's `AppBar` title.
library;

import 'package:flutter_test/flutter_test.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  testWidgets(
    'the header title is its own semantics node, not merged into the pane\'s '
    'focus scope',
    (tester) async {
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      final handle = tester.ensureSemantics();

      await pumpCanvasPane(tester, container);

      // A node merged into the focus scope would carry isFocused and isLiveRegion too (the always-mounted activity announcer merges into that same scope); matchesSemantics defaults those false, so this fails as it did before the fix.
      expect(
        tester.getSemantics(find.text('Canvas')),
        matchesSemantics(label: 'Canvas', isHeader: true),
      );
      handle.dispose();
    },
  );
}
