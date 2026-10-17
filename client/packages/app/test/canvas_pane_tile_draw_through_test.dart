// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Report 2 in the backlog channel, in the owner's own words: "unable to
/// start drawing on attachments, but can draw off a picture and if I go
/// over it, then I can draw on an image" - a pen stroke that begins over a
/// call participant's own camera or screen-share tile never started, since
/// `CanvasPresenceManipulableTile`'s outer `Listener` claimed the
/// pointer-down opaquely regardless of which canvas tool was active.
///
/// `canvas_presence_layer_test.dart` already proves the tile's own content
/// `IgnorePointer` flips; this proves the fix reaches all the way through
/// to `CanvasSurface`, via the full real pane, with a real pen drag that
/// begins squarely on the tile.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/canvas/canvas_pane_harness.dart';
import 'features/voice/voice_controller_harness.dart';
import 'support/fake_blocks.dart';

const _cameraOn = VoiceParticipant(
  identity: 'user-noor',
  name: 'Noor',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const _sharingScreen = VoiceParticipant(
  identity: 'user-avery',
  name: 'Avery',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);

Future<void> _expectPenDrawsThrough(
  WidgetTester tester, {
  required VoiceParticipant participant,
  required String tileKey,
}) async {
  final fixture = CanvasPaneFixture();
  final container = fixture.container(
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => FixedVoiceController(
          ref,
          VoiceState(channelId: 'c1', participants: [participant]),
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

  // The pen tool is the pane's own default - no tool switch needed.
  final start = tester.getCenter(find.byKey(ValueKey(tileKey)));
  final gesture = await tester.startGesture(start);
  await gesture.moveTo(start + const Offset(40, 30));
  await gesture.up();
  await tester.pumpAndSettle();

  expect(
    fixture.posted,
    hasLength(1),
    reason:
        'a pen stroke that begins over the tile must still commit, the '
        'same as one that begins on bare canvas',
  );
  expect(fixture.posted.single['kind'], 'stroke');
}

void main() {
  testWidgets(
    'a pen stroke starting over an unlocked camera tile still draws',
    (tester) => _expectPenDrawsThrough(
      tester,
      participant: _cameraOn,
      tileKey: 'camera:user-noor',
    ),
  );

  testWidgets(
    'a pen stroke starting over an unlocked screen-share tile still draws',
    (tester) => _expectPenDrawsThrough(
      tester,
      participant: _sharingScreen,
      tileKey: 'screen:user-avery',
    ),
  );
}
