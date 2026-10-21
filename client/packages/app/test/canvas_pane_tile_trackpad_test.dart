// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// C-019: a trackpad two-finger pan with the cursor over an unlocked tile
/// arrives as PointerPanZoom, which the tile's pan recognizer accepts, so it
/// drags the tile (and saves the slot for everyone) instead of leaving it put.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
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
    final before = tester.getTopLeft(tile);

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

    expect(
      tester.getTopLeft(tile),
      before,
      reason: 'trackpad pan must not move the tile',
    );
  });
}
