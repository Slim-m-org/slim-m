// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A middle-mouse-button grab-pan started on top of an unlocked presence
/// tile: `canvas_surface_pan_test.dart` proves it works over bare canvas,
/// but `CanvasPresenceLayer` paints its own opaque `GestureDetector` above
/// `CanvasSurface` for every unlocked tile, and Flutter's hit test stops at
/// the first opaque hit in paint order - so the question this asks is
/// whether that hit-test claim also swallows a gesture the tile itself does
/// not implement, rather than only the drag/right-click it does.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/canvas/canvas_pane_harness.dart';
import 'voice_controller_harness.dart';
import 'support/fake_blocks.dart';

const _here = VoiceParticipant(
  identity: 'user-noor',
  name: 'Noor',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

void main() {
  testWidgets('a middle-button drag starting on an unlocked tile still pans the '
      'canvas underneath it', (tester) async {
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
    final document = surfaceDocument(tester);
    expect(document.camera.x, 0);
    expect(document.camera.y, 0);

    // Noor's default camera-off tile is world (24, 24) 140x140; camera starts at (0, 0) zoom 1, so (60, 60) sits well inside it.
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
          'a grab-pan started over a tile should still move the '
          'camera, the same as one started over bare canvas',
    );
  });
}
