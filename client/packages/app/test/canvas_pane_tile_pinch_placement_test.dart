// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `canvas_surface_gestures_test.dart`'s own pinch-cancellation guard
/// (`_resolvePendingPlacement`, gated on this surface's own `_pointers`
/// dropping to zero) only ever sees a second finger that lands on bare
/// canvas. `CanvasPresenceLayer` paints an unlocked tile's opaque
/// `GestureDetector` above `CanvasSurface`, so a second finger landing on a
/// tile instead is absorbed there and never reaches `CanvasSurface._down`
/// at all - this asks whether that leaves the surface's own pointer count
/// one short of the real gesture, placing on the first finger's lone point
/// as though no second finger had ever come down. The shape tool is used
/// rather than note, which needs a follow-up text sheet before it posts at
/// all and so cannot tell a real cancellation from one that never reached
/// the sheet.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import 'canvas_pane_harness.dart';
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
  testWidgets(
    'a second finger landing on an unlocked tile still cancels a shape '
    'placement, the same as one landing on bare canvas',
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

      await tester.tap(find.bySemanticsLabel('Shape'));
      await tester.pump();

      // Well clear of Noor's default tile at world (24, 24) 140x140.
      final firstFinger = screenFor(tester, const Offset(250, 50));
      // Inside it.
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
            'a two-finger touch must never place, wherever the second '
            'finger happened to land',
      );
    },
  );
}
