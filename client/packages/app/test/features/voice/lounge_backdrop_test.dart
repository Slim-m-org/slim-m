// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call view's backdrop: a blurred glimpse of the canvas when it has
/// anything on it, colour from the people in the call when it is empty.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/lounge_canvas_glow.dart';
import 'package:slimm_app/src/features/voice/widgets/lounge_backdrop.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

VoiceParticipant _p(String id, {bool speaking = false}) => VoiceParticipant(
  identity: id,
  name: id,
  isSpeaking: speaking,
  isMuted: false,
  isLocal: id == 'me',
  isScreenSharing: false,
);

Future<void> _pump(
  WidgetTester tester, {
  required ui.Image? glow,
  bool canvas = true,
  List<Override> overrides = const [],
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        loungeCanvasGlowProvider('c1').overrideWith((ref) async => glow),
        ...overrides,
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: LoungeBackdrop(
            channelId: 'c1',
            canvas: canvas,
            participants: [_p('me', speaking: true), _p('alice')],
          ),
        ),
      ),
    ),
  );
}

Future<ui.Image> _solidImage() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 4, 4),
    Paint()..color = const Color(0xFFE86A5C),
  );
  return recorder.endRecording().toImage(4, 4);
}

void main() {
  testWidgets('a canvas with anything on it shows as the backdrop', (
    tester,
  ) async {
    final image = await tester.runAsync(_solidImage);
    await _pump(tester, glow: image);
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsOneWidget);
  });

  testWidgets('an empty canvas falls back to the people in the call', (
    tester,
  ) async {
    await _pump(tester, glow: null);
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsNothing);
    expect(
      find.descendant(
        of: find.byType(LoungeBackdrop),
        matching: find.byType(CustomPaint),
      ),
      findsWidgets,
    );
  });

  testWidgets('a call with no canvas never reads one', (tester) async {
    var reads = 0;
    await _pump(
      tester,
      glow: null,
      canvas: false,
      overrides: [
        loungeCanvasGlowProvider('c1').overrideWith((ref) async {
          reads++;
          return null;
        }),
      ],
    );
    await tester.pumpAndSettle();
    expect(reads, 0);
  });

  test('a board with ink paints a picture that is not blank', () async {
    final document = CanvasDocument()..setBoard(canvasBoard);
    addTearDown(document.dispose);
    document.applyPlaced(
      const CanvasStrokeInput(
        id: 's1',
        seq: 1,
        zIndex: 1,
        x: 400,
        y: 300,
        w: 800,
        h: 400,
        points: [0, 0, 400, 200, 800, 400],
        width: 40,
        colorKey: 'annotation',
      ),
      overwrite: true,
    );
    final image = await paintLoungeGlow(document);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final pixels = bytes!.buffer.asUint8List();
    var lit = 0;
    for (var i = 3; i < pixels.length; i += 4) {
      if (pixels[i] > 0) lit++;
    }
    expect(image.width, loungeGlowSize.width.toInt());
    expect(lit, greaterThan(500), reason: 'the stroke shows through the blur');
  });
}
