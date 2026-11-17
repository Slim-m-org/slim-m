// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An emoji stamp on the board (decision 0121) is an item like an image: it
/// waits for a baked bitmap, is hit across its box, and counts with images.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _emoji(String id, String key) => CanvasStrokeInput(
      id: id,
      seq: 1,
      zIndex: 1,
      x: 100,
      y: 100,
      w: 130,
      h: 130,
      points: const [],
      width: 0,
      colorKey: '',
      kind: CanvasObjectKind.emoji,
      text: key,
    );

void main() {
  late CanvasDocument document;

  setUp(() {
    document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(_emoji('e1', '\u{1F389}'))
      ..refresh();
  });

  tearDown(() => document.dispose());

  test('it waits for a bitmap, named by its emoji', () {
    expect(document.kindOf('e1'), CanvasObjectKind.emoji);
    expect(document.visibleEmojiAwaitingBitmap, [
      (id: 'e1', emoji: '\u{1F389}'),
    ]);
    expect(document.visibleImagesAwaitingBitmap, isEmpty);
  });

  testWidgets('once baked it waits no more', (tester) async {
    final image = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 4, 4),
        Paint()..color = const Color(0xFFFF0000),
      );
      return recorder.endRecording().toImage(4, 4);
    });
    document.setImageBitmap('e1', image!);
    expect(document.visibleEmojiAwaitingBitmap, isEmpty);
  });

  test('a press anywhere in its box hits it', () {
    expect(hitTestTopmost(document, const Offset(200, 220)), 'e1');
    expect(hitTestTopmost(document, const Offset(240, 240)), isNull);
  });

  test('it counts with the images', () {
    expect(document.liveCountsByKind.images, 1);
  });
}
