// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [VoiceCallDock]: the canvas toggle it adds beside [CallControls], its own
/// DM self-gating, and the narrow-width fold that keeps a crowded row from
/// overflowing rather than shrinking any control below its 44dp floor.
///
/// `canvas_call_dock_touch_reach_test.dart` already proves the combined
/// call-and-canvas dock is reachable by a bare tap at 320; this file's job is
/// the dock this repo actually shows *before* the canvas ever opens, since
/// that is the one this task adds a control to.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import 'features/voice/voice_call_controls_harness.dart';

const _connected = VoiceFlags(state: VoiceSessionState.connected);
const _connectedWithCamera = VoiceFlags(
  state: VoiceSessionState.connected,
  cameraEnabled: true,
);

void main() {
  testWidgets('the toggle opens the canvas, then closes it, at desktop width', (
    tester,
  ) async {
    final container = await pumpVoiceCallDock(
      tester,
      _connected,
      canvasChannelId: 'c1',
    );

    expect(container.read(canvasOpenProvider), isNull);

    await tester.tap(find.bySemanticsLabel('Open canvas'));
    await tester.pump();
    expect(container.read(canvasOpenProvider), 'c1');

    await tester.tap(find.bySemanticsLabel('Close canvas'));
    await tester.pump();
    expect(container.read(canvasOpenProvider), isNull);
  });

  testWidgets('the toggle reaches the same provider at phone width', (
    tester,
  ) async {
    final container = await pumpVoiceCallDock(
      tester,
      _connected,
      canvasChannelId: 'c1',
      width: 390,
      touch: true,
    );

    await tester.tap(find.bySemanticsLabel('Open canvas'));
    await tester.pump();
    expect(container.read(canvasOpenProvider), 'c1');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'no toggle at all when canvas is not this call\'s to open - a DM call, '
    'CanvasCallDock passing null for its own reason',
    (tester) async {
      await pumpVoiceCallDock(tester, _connected, canvasChannelId: null);

      expect(find.bySemanticsLabel('Open canvas'), findsNothing);
      expect(
        tester.widget<FloatingDockCard>(find.byType(FloatingDockCard)).rows,
        hasLength(1),
      );
    },
  );

  testWidgets('the row stays one line at 380 when the camera is off, rather than '
      'folding when nothing forced it to', (tester) async {
    await pumpVoiceCallDock(
      tester,
      _connected,
      canvasChannelId: 'c1',
      width: 380,
      touch: true,
    );

    expect(
      tester.widget<FloatingDockCard>(find.byType(FloatingDockCard)).rows,
      hasLength(1),
      reason:
          'mic, deafen, camera, share, leave, the divider and the toggle all fit at 380 '
          'with the camera off; folding here would be needless crowding '
          'in the other direction',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the toggle spills into a row of its own, rather than overflowing the first '
    'one or hiding in the mic menu, once the camera is on at 380',
    (tester) async {
      // A bare-flip platform: this test is about the row's fold width, not the picker platform's async device count.
      await pumpVoiceCallDock(
        tester,
        _connectedWithCamera,
        canvasChannelId: 'c1',
        width: 380,
        touch: true,
        session: InertSession()..canFlipCamera = true,
      );

      expect(
        tester.widget<FloatingDockCard>(find.byType(FloatingDockCard)).rows,
        hasLength(2),
        reason:
            'mic, deafen, camera, switch camera, share, leave and the toggle no '
            'longer fit one line at 380, so the toggle gets a row above',
      );
      expect(find.bySemanticsLabel('Open canvas'), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason: 'a genuine RenderFlex overflow throws during the pump above',
      );

      // Folding the toggle must not have clipped or stolen a neighbor's hit area.
      await tester.tap(find.bySemanticsLabel(RegExp(r'^Mute')));
      await tester.tap(find.bySemanticsLabel('Switch camera'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the fold threshold is exact: one pixel narrower than what the camera-off '
    'row needs spills it, one pixel is not enough to avoid needing to',
    (tester) async {
      // 6 controls at 52dp (44dp plus AppFocusRing's 8dp), 5 gaps of 8dp, plus the card's 24dp padding and 2dp border: 312+40+1+24+2, the 1 being what the divider before leave adds over a plain gap.
      const exact = 379.0;
      await pumpVoiceCallDock(
        tester,
        _connected,
        canvasChannelId: 'c1',
        width: exact,
        touch: true,
      );
      expect(
        tester.widget<FloatingDockCard>(find.byType(FloatingDockCard)).rows,
        hasLength(1),
      );
      expect(find.bySemanticsLabel('Open canvas'), findsOneWidget);

      await pumpVoiceCallDock(
        tester,
        _connected,
        canvasChannelId: 'c1',
        width: exact - 1,
        touch: true,
      );
      expect(
        tester.widget<FloatingDockCard>(find.byType(FloatingDockCard)).rows,
        hasLength(2),
      );
      expect(find.bySemanticsLabel('Open canvas'), findsOneWidget);
    },
  );
}
