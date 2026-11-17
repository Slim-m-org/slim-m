// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An emoji stamp baked before the emoji font loaded is baked again once a font arrives.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_emoji_hydrator.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

Future<ui.Image> _blank() {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(const ui.Rect.fromLTWH(0, 0, 4, 4), ui.Paint());
  return recorder.endRecording().toImage(4, 4);
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
}
