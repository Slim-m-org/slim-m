// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A second finger on a tile still cancels a shape placement, and a middle-button drag on a tile still pans, with video under the surface and only the control shell above it.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/canvas/canvas_pane_harness.dart';
import 'features/voice/voice_controller_harness.dart';
import 'support/fake_blocks.dart';

const _here = VoiceParticipant(
  identity: 'user-noor',
  name: 'Noor',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

/// Tile controls only answer under the pan tool; under the pen the tile lets ink through.
Future<void> _selectPan(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Pan'));
  await tester.pump();
}

void main() {
  testWidgets(
    'a second finger landing on a tile still cancels a shape placement',
    (tester) async {
      final fixture = CanvasPaneFixture();
      final container = fixture.container(
        extraOverrides: [
          voiceControllerProvider.overrideWith(
            (ref) => FixedVoiceController(
              ref,
              const VoiceState(channelId: 'c1', participants: [_here]),
            ),
          ),
          blocksProvider.overrideWith(
            (ref) => FixedBlocksController(ref, const BlocksState()),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);

      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();
      await _selectPan(tester);

      await tester.tap(find.bySemanticsLabel('Shape'));
      await tester.pump();

      final firstFinger = screenFor(tester, const Offset(250, 50));
      final secondFinger = screenFor(tester, const Offset(60, 60));

      final first = await tester.startGesture(firstFinger);
      final second = await tester.startGesture(secondFinger);
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pumpAndSettle();

      expect(
        fixture.posted,
        isEmpty,
        reason:
            'a two-finger touch must never place, whichever layer the second '
            'finger landed on',
      );
    },
  );

  testWidgets(
    'a middle-button drag starting on a tile still pans the canvas underneath it',
    (tester) async {
      final fixture = CanvasPaneFixture();
      final container = fixture.container(
        extraOverrides: [
          voiceControllerProvider.overrideWith(
            (ref) => FixedVoiceController(
              ref,
              const VoiceState(channelId: 'c1', participants: [_here]),
            ),
          ),
          blocksProvider.overrideWith(
            (ref) => FixedBlocksController(ref, const BlocksState()),
          ),
        ],
      );
      addTearDown(container.dispose);

      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();
      await _selectPan(tester);

      final document = surfaceDocument(tester);
      expect(document.camera.x, 0);
      expect(document.camera.y, 0);

      final start = screenFor(tester, const Offset(60, 60));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.down(start, buttons: kMiddleMouseButton),
      );
      await tester.sendEventToBinding(
        pointer.move(start + const Offset(-40, 30)),
      );
      await tester.sendEventToBinding(pointer.up());
      await tester.pump();

      expect(
        document.camera.x,
        isNot(0),
        reason:
            'the tile shell forwards the grab to the camera, since the '
            'surface beneath it never sees this pointer',
      );
    },
  );
}
