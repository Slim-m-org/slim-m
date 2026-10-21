// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A wheel event landing on a manipulable presence tile, not on bare
/// canvas - the owner's actual report, per a screenshot from the same
/// session showing camera and screen-share tiles covering a large part of
/// the board: ctrl plus the scroll wheel "does not zoom the canvas", which
/// was only ever true wherever a tile happened to sit under the cursor.
///
/// [CanvasPresenceManipulableTile]'s own outer `Listener` is
/// `HitTestBehavior.opaque` with nothing wired for `onPointerSignal`, so a
/// `PointerScrollEvent` landing inside its bounds never reached
/// [CanvasSurface] underneath at all - not "handled differently", dropped,
/// since an opaque hit test stops the enclosing `Stack` from ever adding
/// the surface's own `Listener` to the event's hit-test path. Ctrl+wheel
/// over bare canvas already worked (`canvas_surface_wheel_test.dart`), which
/// is what made this read as "sometimes zoom does nothing" rather than a
/// clean failure - exactly the shape a person on a call, where a tile is
/// almost always on screen, would describe as "it does not zoom".
///
/// A locked tile is now transparent to a pointer (report: "I cannot touch
/// the rectangle again" once a tile is locked and sent to back), so a
/// wheel notch over one reaches `CanvasSurface` directly rather than
/// through this tile's own replicated math - the locked case below mounts
/// one so there is something underneath to reach.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';
import 'presence_stack.dart';

const _noor = VoiceParticipant(
  identity: 'user-noor',
  name: 'Noor',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

// Well inside the default, untouched layout for a lone camera-off tile.
const _pointOnTile = Offset(60, 60);

Widget _wrap(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(body: SizedBox(width: 1000, height: 800, child: child)),
  ),
);

Widget _layer(CanvasDocument document, CanvasPresenceTileOverrides overrides) =>
    PresenceStack(
      document: document,
      participants: const [_noor],
      cameraViewFor: (_) => const SizedBox(),
      screenShareViewFor: (_) => const SizedBox(),
      overrides: overrides,
      onCommit: (_, __) {},
    );

/// [_layer] over a real [CanvasSurface], the same stacking
/// `canvas_pane_body.dart` uses - needed only where a tile is meant to pass
/// a pointer through to whatever is beneath it.
Widget _stack(CanvasDocument document, CanvasPresenceTileOverrides overrides) =>
    Stack(
      children: [
        CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          onStroke: (_) {},
        ),
        _layer(document, overrides),
      ],
    );

void main() {
  testWidgets(
    'ctrl+wheel over an unlocked tile zooms the shared camera, keeping the '
    'point under the cursor fixed - not only over bare canvas',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);

      await tester.pumpWidget(_wrap(_layer(document, overrides)));
      await tester.pump();

      Offset worldUnder(Camera camera) => Offset(
        camera.x + _pointOnTile.dx / camera.zoom,
        camera.y + _pointOnTile.dy / camera.zoom,
      );
      final before = worldUnder(document.camera);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(_pointOnTile));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -40)));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(
        document.camera.zoom,
        greaterThan(1),
        reason:
            'a wheel notch over the tile must zoom the shared camera '
            'exactly as one over bare canvas would',
      );
      final after = worldUnder(document.camera);
      expect(after.dx, closeTo(before.dx, 1e-9));
      expect(after.dy, closeTo(before.dy, 1e-9));
    },
  );

  testWidgets(
    'a plain wheel notch over a tile pans the camera, matching bare canvas',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);

      await tester.pumpWidget(_wrap(_layer(document, overrides)));
      await tester.pump();

      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(_pointOnTile));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40)));
      await tester.pump();

      expect(document.camera.x, 0);
      expect(document.camera.y, 40);
    },
  );

  testWidgets(
    'ctrl+wheel over a locked tile still zooms - a lock only stops drawing '
    'or dragging the tile itself, never the shared camera',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides()
        ..setLocked('camera:user-noor', true);
      addTearDown(overrides.dispose);

      await tester.pumpWidget(_wrap(_stack(document, overrides)));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(_pointOnTile));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -40)));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(document.camera.zoom, greaterThan(1));
    },
  );

  testWidgets(
    'a two-finger trackpad scroll over a tile pans the camera and leaves the '
    'tile where it was',
    (tester) async {
      final document = CanvasDocument()..setViewport(const Size(1000, 800));
      addTearDown(document.dispose);
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      await tester.pumpWidget(_wrap(_layer(document, overrides)));
      await tester.pump();
      final tile = find.byType(CanvasPresenceManipulableTile);
      final before = tester.getTopLeft(tile);

      final pad = TestPointer(1, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(pad.panZoomStart(_pointOnTile));
      for (var i = 1; i <= 5; i++) {
        await tester.sendEventToBinding(
          pad.panZoomUpdate(_pointOnTile, pan: Offset(-10.0 * i, 0)),
        );
        await tester.pump();
      }
      await tester.sendEventToBinding(pad.panZoomEnd());
      await tester.pump();

      expect(document.camera.x, closeTo(50, 1e-9));
      expect(
        tester.getTopLeft(tile) - before,
        const Offset(-50, 0),
        reason: 'the tile moved only because the camera did',
      );
    },
  );
}
