// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [VoiceCallDock]: the canvas toggle it adds to More beside [CallControls], its own
/// DM self-gating, and the narrow-width fold that keeps a crowded row from
/// overflowing rather than shrinking any control below its 44dp floor.
///
/// `canvas_call_dock_touch_reach_test.dart` already proves the combined
/// call-and-canvas dock is reachable by a bare tap at 320; this file's job is
/// the dock this repo actually shows *before* the canvas ever opens, since
/// that is the one this task adds a control to.
library;

import 'package:flutter/widgets.dart';
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

Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('More'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _pick(WidgetTester tester, String row) async {
  await _openMore(tester);
  await tester.tap(find.text(row));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

int _rows(WidgetTester tester) => tester
    .widget<FloatingDockCard>(find.bySubtype<FloatingDockCard>())
    .rows
    .length;

void main() {
  testWidgets('More opens the canvas, then closes it, at desktop width', (
    tester,
  ) async {
    final container = await pumpVoiceCallDock(
      tester,
      _connected,
      canvasChannelId: 'c1',
    );

    expect(container.read(canvasOpenProvider), isNull);
    await _pick(tester, 'Open canvas');
    expect(container.read(canvasOpenProvider), 'c1');

    await tester.pump();
    await _pick(tester, 'Close canvas');
    expect(container.read(canvasOpenProvider), isNull);
  });

  testWidgets('More reaches the same provider at phone width', (tester) async {
    final container = await pumpVoiceCallDock(
      tester,
      _connected,
      canvasChannelId: 'c1',
      width: 390,
      touch: true,
    );

    await _pick(tester, 'Open canvas');
    expect(container.read(canvasOpenProvider), 'c1');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'no toggle and no More when canvas is not this call\'s to open - a DM '
    'call, CanvasCallDock passing null for its own reason',
    (tester) async {
      await pumpVoiceCallDock(tester, _connected, canvasChannelId: null);

      expect(find.bySemanticsLabel('Open canvas'), findsNothing);
      expect(find.bySemanticsLabel('More'), findsNothing);
      expect(_rows(tester), 1);
    },
  );

  testWidgets('the row stays one line at 380 with the camera on and a second '
      'camera to switch to', (tester) async {
    await pumpVoiceCallDock(
      tester,
      _connectedWithCamera,
      canvasChannelId: 'c1',
      width: 380,
      touch: true,
      session: InertSession()..canFlipCamera = true,
    );

    expect(_rows(tester), 1, reason: 'Switch camera lives in More');
    expect(tester.takeException(), isNull);
    await _openMore(tester);
    expect(find.text('Switch camera'), findsOneWidget);
    expect(find.text('Open canvas'), findsOneWidget);
  });

  testWidgets(
    'the fold threshold is exact: one pixel narrower than what the row with '
    'More needs puts More in a row above, still reachable',
    (tester) async {
      // 6 controls at 52dp, no gaps, the leave divider (4+1+4) and the card's 8dp side padding and 2dp border.
      const exact = 331.0;
      await pumpVoiceCallDock(
        tester,
        _connected,
        canvasChannelId: 'c1',
        width: exact,
        touch: true,
      );
      expect(_rows(tester), 1);
      final onRow = tester.getRect(find.bySemanticsLabel('More'));
      expect(
        onRow.center.dy,
        tester.getRect(find.bySemanticsLabel('Mute')).center.dy,
      );

      await pumpVoiceCallDock(
        tester,
        _connected,
        canvasChannelId: 'c1',
        width: exact - 1,
        touch: true,
      );
      expect(_rows(tester), 2);
      expect(
        tester.getRect(find.bySemanticsLabel('More')).bottom,
        lessThanOrEqualTo(tester.getRect(find.bySemanticsLabel('Mute')).top),
      );
      expect(tester.takeException(), isNull);

      // The dock watches an autodispose provider; unmounting it here lets its dispose timer run before the test ends.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}
