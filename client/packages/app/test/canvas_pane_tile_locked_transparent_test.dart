// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A locked tile must not swallow pointers: a select-tool click meant for a shape under a locked tile has to reach `CanvasSurface`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

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

const _tileKey = ValueKey('camera:user-noor');

void main() {
  testWidgets('a shape dragged over a locked tile can still be '
      'selected and dragged again', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container(
      extraOverrides: [
        voiceControllerProvider.overrideWith(
          (ref) => FixedVoiceController(
            ref,
            const VoiceState(channelId: 'c1', participants: [_cameraOn]),
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

    // Well clear of the tile's own default (24, 24) 220x160 slot.
    await tester.tap(find.bySemanticsLabel('Shape'));
    await tester.pump();
    var gesture = await tester.startGesture(
      screenFor(tester, const Offset(500, 380)),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    final shapeId = fixture.posted.single['id'] as String;
    // Placing leaves it selected, already on the Move tool.
    expect(surfaceDocument(tester).selectedObjectId.value, shapeId);

    // Drag the shape from its own centre onto the tile's own centre.
    final tileCenter = tester.getCenter(find.byKey(_tileKey));
    gesture = await tester.startGesture(
      screenFor(tester, const Offset(500, 380)),
    );
    await gesture.moveTo(tileCenter);
    await gesture.up();
    await tester.pumpAndSettle();

    // A shape is hit on its outline, so the clicks below land on its left edge.
    final moved = surfaceDocument(tester).objectBounds(shapeId)!;
    final onShape = screenFor(tester, Offset(moved.x, moved.y + moved.h / 2));

    // Deselect, well clear of both and still inside the default test viewport.
    gesture = await tester.startGesture(
      screenFor(tester, const Offset(10, 400)),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(surfaceDocument(tester).selectedObjectId.value, isNull);

    // Lock the tile - the two-tap reveal-then-operate sequence a real touch does.
    await tester.tap(find.byKey(_tileKey));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Lock this tile in place'));
    await tester.pump();

    // The shape's outline at its new position, now covered by the locked tile.
    gesture = await tester.startGesture(onShape);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      surfaceDocument(tester).selectedObjectId.value,
      shapeId,
      reason:
          'a locked tile must not swallow a select click '
          'meant for a shape moved over it',
    );

    // And it can be dragged again from there, not just re-selected.
    final before = surfaceDocument(tester).objectBounds(shapeId)!;
    gesture = await tester.startGesture(onShape);
    await gesture.moveTo(onShape + const Offset(60, 40));
    await gesture.up();
    await tester.pumpAndSettle();

    final after = surfaceDocument(tester).objectBounds(shapeId)!;
    expect(
      after.x,
      closeTo(before.x + 60, 0.5),
      reason: 'a locked tile must not swallow a drag either',
    );
  });
}
