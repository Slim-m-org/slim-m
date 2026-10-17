// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether sending a tile to the back changes anything about the two
/// pointer fixes in `canvas_presence_tile.dart` - it must not, and this is
/// what proves it rather than assumes it.
///
/// `CanvasPresenceBackdrop` never carries a gesture of its own (it is
/// wrapped in `IgnorePointer` unconditionally), and the manipulable shell -
/// the one `Listener` that counts a pointer and the one `GestureDetector`
/// that answers a middle-click pan - stays in front of `CanvasSurface` at
/// every depth. So both fixes should reach a sent-to-back tile exactly as
/// they reach one still in front, and the external-pointer count should be
/// touched in exactly one place regardless of which side of the drawing
/// surface a tile's own content is currently painting on.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_layer.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';
import 'voice_controller_harness.dart';
import 'support/fake_blocks.dart';

/// Camera on: this suite drives the depth control, which an avatar-only
/// tile no longer exposes - see `canvas_presence_tile_kind_test.dart`.
const _here = VoiceParticipant(
  identity: 'user-noor',
  name: 'Noor',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

/// Sends Noor's tile to the back through its own corner control, the same
/// tap a person would make - not by reaching into overrides directly, so
/// this exercises the real toggle wired into the full pane.
///
/// A first tap reveals the control row (report 3: it no longer sits
/// permanently on screen), so this taps the tile itself once before the
/// control - the same two-tap sequence a real touch does.
Future<void> _sendToBack(WidgetTester tester) async {
  // Tile controls only answer under the select tool; under the pen the tile lets ink through.
  await tester.tap(find.bySemanticsLabel('Pan'));
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('camera:user-noor')));
  await tester.pump();
  await tester.tap(find.bySemanticsLabel('Send this tile to the back'));
  await tester.pump();
}

Widget _wrapLayer(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(body: SizedBox(width: 1000, height: 800, child: child)),
  ),
);

void main() {
  testWidgets(
    'a second finger landing on a sent-to-back tile still cancels a shape '
    'placement, the same as one landing on a tile still in front',
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
      await _sendToBack(tester);

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
            'a two-finger touch must never place, whether the second '
            'finger landed on a tile in front or one sent to the back',
      );
    },
  );

  testWidgets(
    'a middle-button drag starting on a sent-to-back tile still pans the '
    'canvas underneath it',
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
      await _sendToBack(tester);

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
            'sending the tile to the back never moves its interactive '
            'shell, so the surface beneath it still never sees this pointer',
      );
    },
  );

  testWidgets(
    'sending a tile to the back mid-gesture does not lose or double-count '
    'the pointer already down on it',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);

      await tester.pumpWidget(
        _wrapLayer(
          CanvasPresenceLayer(
            document: document,
            participants: const [_here],
            cameraViewFor: (_) => const SizedBox(),
            screenShareViewFor: (_) => const SizedBox(),
            overrides: overrides,
            onCommit: (_, __) {},
          ),
        ),
      );
      await tester.pump();

      final tileFinder = find.byKey(const ValueKey('camera:user-noor'));
      final pointer = TestPointer(7, PointerDeviceKind.touch);
      await tester.sendEventToBinding(
        pointer.down(tester.getCenter(tileFinder)),
      );
      expect(document.externalPointers.count, 1);

      // Sent to back mid-gesture: same key, same shell, same State instance.
      overrides.setSentToBack('camera:user-noor', true);
      await tester.pump();
      expect(document.externalPointers.count, 1);

      await tester.sendEventToBinding(pointer.up());
      expect(
        document.externalPointers.count,
        0,
        reason:
            'a pointer that started before the toggle must still balance '
            'after it lifts, or every future placement blocks on a stuck '
            'count nothing will ever clear',
      );
    },
  );
}
