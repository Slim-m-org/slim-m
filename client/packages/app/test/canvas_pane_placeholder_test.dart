// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A design review found the canvas's unloaded-image placeholder painted as
/// a flat, opaque fill (`AppTokens.surfaceRaised`) rather than reusing
/// `AppTokens.stripe`, the token this design system already reserves for
/// exactly that state - and already uses correctly for a message attachment
/// still in flight (`AttachmentPlaceholder`) and one that failed to load
/// (`attachment_view.dart`). `stripe`'s own doc: "a placeholder never gets
/// drawn as a flat grey block that reads like a real, empty surface" - which
/// an opaque fill is precisely.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  testWidgets(
    "an unloaded image's placeholder reuses the app's own stripe token",
    (tester) async {
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);

      await pumpCanvasPane(tester, container);

      final surface = tester.widget<CanvasSurface>(find.byType(CanvasSurface));
      expect(surface.placeholderFill, AppTokens.dark.stripe);
    },
  );
}
