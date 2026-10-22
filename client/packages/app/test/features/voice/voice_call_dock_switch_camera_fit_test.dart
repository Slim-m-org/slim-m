// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dock's one-row fit counts the switch camera button only when it is
/// actually drawn, not whenever the camera is on.
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

// Six 52dp controls (mic, deafen, camera, share, leave, toggle), five 8dp gaps, the leave divider, card padding and border.
const _sixControls = 379.0;

void main() {
  testWidgets(
    'a lone camera keeps the toggle on the row with no switch button',
    (tester) async {
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

      expect(find.bySemanticsLabel('Switch camera'), findsNothing);
      expect(
        tester.widget<FloatingDockCard>(find.byType(FloatingDockCard)).rows,
        hasLength(1),
      );
    },
  );

  testWidgets(
    'a second camera shows the switch button and spills the toggle into a row above',
    (tester) async {
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

      expect(find.bySemanticsLabel('Switch camera'), findsOneWidget);
      expect(
        tester.widget<FloatingDockCard>(find.byType(FloatingDockCard)).rows,
        hasLength(2),
      );
      expect(find.bySemanticsLabel('Open canvas'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
