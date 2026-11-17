// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An emoji stamp baked before the emoji font loaded is baked again once a font arrives.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_emoji_hydrator.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

Future<ui.Image> _blank([int side = 4]) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    ui.Paint(),
  );
  return recorder.endRecording().toImage(side, side);
}

CanvasDocument _oneStamp() {
  final document = CanvasDocument()..setViewport(const Size(400, 400));
  document
    ..applyPlaced(
      const CanvasStrokeInput(
        id: 's',
        seq: 1,
        zIndex: 1,
        x: 10,
        y: 10,
        w: 64,
        h: 64,
        points: [],
        width: 0,
        colorKey: 'ink',
        kind: CanvasObjectKind.emoji,
        text: '\u{1F600}',
      ),
    )
    ..refresh();
  return document;
}

class _Fonts extends ChangeNotifier {
  void loaded() => notifyListeners();
}

void main() {
  testWidgets('a font that loads late bakes every visible emoji stamp again', (
    tester,
  ) async {
    final document = CanvasDocument()..setViewport(const Size(400, 400));
    addTearDown(document.dispose);
    document
      ..applyPlaced(
        const CanvasStrokeInput(
          id: 's',
          seq: 1,
          zIndex: 1,
          x: 10,
          y: 10,
          w: 64,
          h: 64,
          points: [],
          width: 0,
          colorKey: 'ink',
          kind: CanvasObjectKind.emoji,
          text: '\u{1F600}',
        ),
      )
      ..refresh();
    final fonts = _Fonts();
    addTearDown(fonts.dispose);
    var bakes = 0;
    var dropped = 0;
    final hydrator = CanvasEmojiHydrator(
      document: document,
      bake: (key) async {
        bakes++;
        return _blank();
      },
      fontsChanged: fonts,
      dropGlyphBitmaps: () => dropped++,
    );
    addTearDown(hydrator.dispose);

    await tester.runAsync(() async {
      hydrator.hydrateVisible();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bakes, 1);

      fonts.loaded();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bakes, 2);
      expect(dropped, 1);
    });
  });

  testWidgets('a bake still running when the font loads does not win', (
    tester,
  ) async {
    final document = _oneStamp();
    addTearDown(document.dispose);
    final fonts = _Fonts();
    addTearDown(fonts.dispose);
    final bakes = <Completer<ui.Image?>>[];
    final hydrator = CanvasEmojiHydrator(
      document: document,
      bake: (key) {
        bakes.add(Completer<ui.Image?>());
        return bakes.last.future;
      },
      fontsChanged: fonts,
    );
    addTearDown(hydrator.dispose);

    await tester.runAsync(() async {
      hydrator.hydrateVisible();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      fonts.loaded();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      bakes.first.complete(await _blank());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bakes, hasLength(2), reason: 'the font load bakes it again');
      bakes.last.complete(await _blank(8));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    final stamp = document.strokeIfAlive(document.paintOrder.single)!;
    expect(stamp.image?.width, 8, reason: 'the bake after the font is kept');
  });
}
