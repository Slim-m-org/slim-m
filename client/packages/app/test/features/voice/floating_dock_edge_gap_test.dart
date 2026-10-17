// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The exact case that fooled a review pass into nearly filing a false
/// layout bug: the floating dock (`canvas_pane_body.dart`'s canvas dock, and
/// `voice_screen.dart`'s in-call dock) reads, in every capture harness
/// image, as sitting flush against the viewport edge - an artifact of the
/// offscreen rasteriser not blurring `FloatingDockCard`'s own `BoxShadow`
/// (see `ui_snapshot_support.dart`'s doc comment), not a real gap. Both
/// files plainly ask for `AppSpacing.s12` of clearance in their own source;
/// this is `support/geometry.dart`'s answer to whether that ask actually
/// reaches the screen, read from the real `RenderBox` tree rather than a
/// PNG a shadow has already lied about.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../canvas/canvas_pane_harness.dart';
import '../../support/geometry.dart';
import 'voice_controller_harness.dart';

Widget _voiceHarness(Widget child, ProviderContainer container) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets(
    "the canvas dock's real position clears the viewport by AppSpacing.s12 "
    'on every side the Align+Padding touches, not merely against a hard '
    'shadow edge a PNG cannot be trusted about',
    (tester) async {
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pump();

      final dock = find.byType(FloatingDockCard);
      expectEdgeGap(
        tester,
        dock,
        GeometryEdge.bottom,
        AppSpacing.s12,
        reason: 'canvas_pane_body.dart wraps the dock in Padding.all(s12)',
      );
      // Left and right are not checked here: the dock hugs its content and is centred (decision 0047), so only the bottom gap is fixed.
    },
  );

  testWidgets(
    "the in-call dock's SafeArea(minimum) reaches the same s12 gap once "
    'there is no larger system inset to widen it past that minimum',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final harness = VoiceHarness();
      final session = FakeSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(),
        extraOverrides: [
          voiceRosterProvider.overrideWith(
            (ref, channelId) =>
                const Stream<List<api.VoiceRosterParticipant>>.empty(),
          ),
        ],
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _voiceHarness(
          const VoiceScreen(channelId: 'channel-1'),
          harness.container,
        ),
      );
      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);
      await tester.pump();
      await tester.pumpAndSettle();

      expectEdgeGap(
        tester,
        find.byType(FloatingDockCard),
        GeometryEdge.bottom,
        AppSpacing.s12,
        reason:
            'voice_screen.dart wraps the dock in '
            'SafeArea(minimum: EdgeInsets.all(s12))',
      );

      await controller.leave();
    },
  );
}
