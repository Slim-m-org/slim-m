// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Wiring `CanvasPane` -> `CanvasPresenceLayer`: a bubble shows only for the
/// channel this device has actually joined a call in, and never for a
/// blocked author, matching the filter every other canvas surface applies.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_layer.dart';
import 'package:slimm_rtc/rtc.dart';

import 'canvas_pane_harness.dart';
import 'voice_controller_harness.dart';
import 'support/fake_blocks.dart';

const _here = VoiceParticipant(
  identity: 'user-priya',
  name: 'Priya',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

const _blockedParticipant = VoiceParticipant(
  identity: 'user-blocked',
  name: 'Blocked Author',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

const _local = VoiceParticipant(
  identity: 'me',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);

void main() {
  testWidgets(
    'a participant in this channel\'s call renders a presence bubble',
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

      expect(find.byType(CanvasPresenceBubble), findsOneWidget);
    },
  );

  testWidgets(
    'the caller\'s own entry renders through the same world-space layer as '
    'everyone else\'s, one bubble each',
    (tester) async {
      final fixture = CanvasPaneFixture();
      final container = fixture.container(
        extraOverrides: [
          voiceControllerProvider.overrideWith(
            (ref) => FixedVoiceController(
              ref,
              const VoiceState(channelId: 'c1', participants: [_local, _here]),
            ),
          ),
          blocksProvider.overrideWith(
            (ref) => FixedBlocksController(ref, const BlocksState()),
          ),
        ],
      );
      addTearDown(container.dispose);

      await pumpCanvasPane(tester, container);

      expect(find.byType(CanvasPresenceBubble), findsNWidgets(2));
      expect(
        find.descendant(
          of: find.byType(CanvasPresenceLayer),
          matching: find.byType(CanvasPresenceBubble),
        ),
        findsNWidgets(2),
      );
    },
  );

  testWidgets(
    'a call in some other channel shows no bubble on this one\'s canvas',
    (tester) async {
      final fixture = CanvasPaneFixture();
      final container = fixture.container(
        extraOverrides: [
          voiceControllerProvider.overrideWith(
            (ref) => FixedVoiceController(
              ref,
              const VoiceState(
                channelId: 'a-different-channel',
                participants: [_here],
              ),
            ),
          ),
          blocksProvider.overrideWith(
            (ref) => FixedBlocksController(ref, const BlocksState()),
          ),
        ],
      );
      addTearDown(container.dispose);

      await pumpCanvasPane(tester, container);

      expect(find.byType(CanvasPresenceBubble), findsNothing);
    },
  );

  testWidgets('a blocked participant never renders a presence bubble', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container(
      extraOverrides: [
        voiceControllerProvider.overrideWith(
          (ref) => FixedVoiceController(
            ref,
            const VoiceState(
              channelId: 'c1',
              participants: [_here, _blockedParticipant],
            ),
          ),
        ),
        blocksProvider.overrideWith(
          (ref) => FixedBlocksController(
            ref,
            const BlocksState(ids: {'user-blocked'}),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await pumpCanvasPane(tester, container);

    // Blocking filters one author; it is not a reason to hide the layer.
    expect(find.byType(CanvasPresenceBubble), findsOneWidget);
  });
}
