// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A small tile shows only the buttons that fit, in priority order, and the tile's own menu keeps every action.
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
  identity: 'noor',
  name: 'Noor',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const _expand = 'Show this tile full screen';
const _lock = 'Lock this tile in place';
const _hide = 'Hide this tile on your canvas; other participants still see it';

Future<void> _pump(WidgetTester tester, Rect rect, {bool touch = false}) async {
  final document = CanvasDocument()..setViewport(const Size(800, 600));
  final overrides = CanvasPresenceTileOverrides()..setRect('camera:noor', rect);
  addTearDown(document.dispose);
  addTearDown(overrides.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: AppTouchTargets(
          enabled: touch,
          child: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: PresenceStack(
                document: document,
                participants: const [_noor],
                cameraViewFor: (_) => const SizedBox(),
                screenShareViewFor: (_) => const SizedBox(),
                overrides: overrides,
                onCommit: (_, _) {},
                onFocus: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(
    tester.getCenter(find.byType(CanvasPresenceManipulableTile)),
  );
  await tester.pump(AppMotion.fast);
}

bool _has(String label) => find.bySemanticsLabel(label).evaluate().isNotEmpty;

void main() {
  test('capacity counts the buttons a width holds and none when too short', () {
    expect(
      canvasPresenceTileControlCapacity(const Size(220, 160), touch: false),
      3,
    );
    expect(
      canvasPresenceTileControlCapacity(const Size(72, 80), touch: false),
      2,
    );
    expect(
      canvasPresenceTileControlCapacity(const Size(72, 54), touch: false),
      0,
    );
    expect(
      canvasPresenceTileControlCapacity(const Size(100, 200), touch: true),
      2,
    );
    expect(
      canvasPresenceTileControlCapacity(const Size(72, 200), touch: true),
      1,
    );
  });

  testWidgets('a roomy tile shows full screen, lock and hide', (tester) async {
    await _pump(tester, const Rect.fromLTWH(100, 100, 220, 160));
    expect([_has(_expand), _has(_lock), _has(_hide)], [true, true, true]);
  });

  testWidgets('a narrow tile drops hide first, then lock', (tester) async {
    await _pump(tester, const Rect.fromLTWH(100, 100, 72, 90));
    expect([_has(_expand), _has(_lock), _has(_hide)], [true, true, false]);
  });

  testWidgets('a tile too small for any button shows none', (tester) async {
    await _pump(tester, const Rect.fromLTWH(100, 100, 72, 54));
    expect([_has(_expand), _has(_lock), _has(_hide)], [false, false, false]);
  });
}
