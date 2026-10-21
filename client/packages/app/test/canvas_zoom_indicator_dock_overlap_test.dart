// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "outside the board - bring in" pill must never sit under the centred
/// dock, at any pane width where the zoom readout stays in the bottom-left.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_call_dock.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_zoom_indicator.dart';
import 'package:slimm_app/src/features/members/providers/bot_ui_uses.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'features/voice/voice_controller_harness.dart';
import 'support/canvas_call_dock_fixtures.dart';

void main() {
  for (final pane in [900.0, 1000.0, 1100.0]) {
    testWidgets('bring-in pill clears the dock in a $pane wide pane', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final document = CanvasDocument();
      addTearDown(document.dispose);
      document.outsideBoardCount.value = 12;
      final session = FakeSession();
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          channelBotUiProvider.overrideWith((ref, _) async => const []),
          voiceControllerProvider.overrideWith(
            (ref) => VoiceController(ref, session: session),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(channelBotUiProvider('c1'), (_, _) {});
      final dock = CanvasCallDock(
        call: CallDockData(
          voice: connectedVoiceState,
          controller: container.read(voiceControllerProvider.notifier),
          channelId: 'c1',
        ),
        canvas: buildCanvasDockData(canUndo: true),
        compact: false,
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: pane,
                  height: 600,
                  child: Stack(
                    children: [
                      CanvasZoomIndicator(
                        document: document,
                        tokens: AppTokens.dark,
                        onFit: () {},
                        onBringIn: () {},
                      ),
                      Align(alignment: Alignment.bottomCenter, child: dock),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final pill = tester.getRect(find.textContaining('bring in'));
      final card = tester.getRect(find.byType(FloatingDockCard));
      final readout = tester.getRect(find.byType(InkWell).first);
      final row = pill.expandToInclude(readout);
      expect(
        row.overlaps(card),
        isFalse,
        reason: 'bring-in row $row is under the dock card $card at pane $pane',
      );
    });
  }
}
