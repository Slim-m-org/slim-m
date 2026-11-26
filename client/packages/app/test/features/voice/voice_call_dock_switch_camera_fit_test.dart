// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// More lists Switch camera only when a second camera exists, and holding it
/// never costs the dock its one row.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _cameraOn = VoiceFlags(
  state: VoiceSessionState.connected,
  cameraEnabled: true,
);

// Six 52dp controls (mic, deafen, camera, share, More, leave), no gaps, the leave divider, card padding and border.
const _sixControls = 331.0;

Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('More'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('a lone camera offers no switch row in More, and the dock stays '
      'one row', (tester) async {
    await pumpVoiceCallDock(
      tester,
      _cameraOn,
      canvasChannelId: 'c1',
      width: _sixControls,
      touch: true,
      session: InertSession()
        ..cameraDeviceList = const [CameraDevice(id: 'a', label: 'Cam A')],
    );
    await tester.pump();
    await _openMore(tester);

    expect(find.text('Switch camera'), findsNothing);
    expect(find.text('Open canvas'), findsOneWidget);
    expect(
      tester.widget<FloatingDockCard>(find.bySubtype<FloatingDockCard>()).rows,
      hasLength(1),
    );
  });

  testWidgets('a second camera adds Switch camera to More, still one row', (
    tester,
  ) async {
    await pumpVoiceCallDock(
      tester,
      _cameraOn,
      canvasChannelId: 'c1',
      width: _sixControls,
      touch: true,
      session: InertSession()
        ..cameraDeviceList = const [
          CameraDevice(id: 'a', label: 'Cam A'),
          CameraDevice(id: 'b', label: 'Cam B'),
        ],
    );
    await tester.pump();
    await tester.pump();
    await _openMore(tester);

    expect(find.text('Switch camera'), findsOneWidget);
    expect(find.text('Open canvas'), findsOneWidget);
    expect(
      tester.widget<FloatingDockCard>(find.bySubtype<FloatingDockCard>()).rows,
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });
}
