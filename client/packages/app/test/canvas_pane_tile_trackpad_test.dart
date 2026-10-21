// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A trackpad two-finger pan with the cursor over an unlocked tile
/// arrives as PointerPanZoom, which the tile's pan recognizer accepted, so it
/// dragged the tile (and saved the slot for everyone) instead of the camera.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile.dart';
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

void main() {
  testWidgets('a trackpad pan over an unlocked tile does not drag the tile', (
    tester,
  ) async {
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
    final tile = find.byType(CanvasPresenceManipulableTile);
    expect(tile, findsOneWidget);
    final cameraBefore = surfaceDocument(tester).camera;

    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(
      pointer.panZoomStart(screenFor(tester, const Offset(60, 60))),
    );
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(
        screenFor(tester, const Offset(60, 60)),
        pan: const Offset(-40, 30),
      ),
    );
    await tester.sendEventToBinding(pointer.panZoomEnd());
    await tester.pump();

    final overrides = container
        .read(canvasEngineProvider('c1').notifier)
        .tileOverrides;
    expect(
      overrides.stateFor('camera:user-noor').rect,
      isNull,
      reason: 'trackpad pan must not drag the tile or save its slot',
    );
    expect(
      surfaceDocument(tester).camera,
      isNot(cameraBefore),
      reason: 'the pan moves the camera, as it does over bare canvas',
    );
  });
}
