// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a pointer does on a call tile: a drag follows the pointer even past a
/// clamp, a mode switch mid-drag cancels it, a drawing tool never meets the
/// controls, a hover still moves this device's cursor for everyone, and a
/// two-finger pinch zooms the canvas instead of being swallowed.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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

const _key = 'camera:user-noor';

class _Rig {
  _Rig() {
    document = CanvasDocument()
      ..setBoard(const Rect.fromLTWH(0, 0, 1000, 800))
      ..setViewport(const Size(1000, 800))
      ..setCamera(const Camera());
    overrides = CanvasPresenceTileOverrides()
      ..board = const Rect.fromLTWH(0, 0, 1000, 800);
    addTearDown(document.dispose);
    addTearDown(overrides.dispose);
  }

  late final CanvasDocument document;
  late final CanvasPresenceTileOverrides overrides;
  final committed = <String>[];
  final pointers = <Offset>[];

  Future<void> pump(
    WidgetTester tester, {
    CanvasTool tool = CanvasTool.pan,
  }) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: PresenceStack(
              document: document,
              participants: const [_noor],
              cameraViewFor: (_) => const SizedBox(),
              screenShareViewFor: (_) => const SizedBox(),
              overrides: overrides,
              tool: tool,
              onCommit: (key, _) => committed.add(key),
              onPointerMoved: pointers.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }
}

void main() {
  testWidgets('a drag past the board edge and back ends under the pointer', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.pump(tester);
    final start = tester.getTopLeft(find.byKey(const ValueKey(_key)));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey(_key))),
    );

    // The first move only wins the drag; the rest is travel the tile follows.
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-370, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(370, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(
      tester.getTopLeft(find.byKey(const ValueKey(_key))),
      start,
      reason: 'the travel lost to the clamp must not be left behind',
    );
  });

  testWidgets('switching to the shared view mid-drag cancels the drag', (
    tester,
  ) async {
    final rig = _Rig();
    rig.overrides.personal = true;
    await rig.pump(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey(_key))),
    );
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    final placed = rig.overrides.stateFor(_key).rect;

    // A summon arrives: the board flips to the shared view under the finger.
    rig.overrides.personal = false;
    await tester.pump();
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(rig.overrides.stateFor(_key).rect, placed);
    expect(rig.committed, isEmpty, reason: 'nothing may be PUT for everyone');
  });

  testWidgets('a drawing tool never reveals the controls under the stroke', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.pump(tester, tool: CanvasTool.pen);

    await tester.tap(find.byKey(const ValueKey(_key)));
    await tester.pump(AppMotion.fast);

    final opacities = tester.widgetList<AnimatedOpacity>(
      find.descendant(
        of: find.byType(CanvasPresenceManipulableTile),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(opacities.map((o) => o.opacity), everyElement(0));
  });

  testWidgets('hovering a tile still moves this device\'s cursor', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.pump(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(900, 700));

    await mouse.moveTo(const Offset(100, 100));
    await tester.pump();

    expect(rig.pointers, isNotEmpty);
    expect(rig.pointers.last, const Offset(100, 100));
  });

  testWidgets('two fingers pinching on a tile zoom the canvas', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    final centre = tester.getCenter(find.byKey(const ValueKey(_key)));
    final a = await tester.startGesture(centre - const Offset(20, 0));
    final b = await tester.startGesture(centre + const Offset(20, 0));

    await a.moveBy(const Offset(-30, 0));
    await b.moveBy(const Offset(30, 0));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pump();

    expect(rig.document.camera.zoom, greaterThan(1));
    expect(rig.overrides.stateFor(_key).rect, isNull, reason: 'not a drag');
  });
}
