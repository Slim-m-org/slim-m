// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A peer's ghost stroke is drawn in their real pen, so it does not change
/// colour or thickness when the committed ink lands.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart'
    show minInkScreenPx;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'support/canvas_painter_fixtures.dart';

void main() {
  late CanvasDocument document;
  late RemoteStrokeDrafts drafts;

  setUp(() {
    document = CanvasDocument()
      ..setViewport(const Size(400, 400))
      ..setCamera(const Camera(zoom: 2));
    drafts = RemoteStrokeDrafts();
  });
  tearDown(() {
    drafts.dispose();
    document.dispose();
  });

  RecordingCanvas paintGhost({String? color, double? width}) {
    drafts.appendOrCreate(
      objectId: 'd',
      authorId: 'alice',
      points: const [0.0, 0.0, 10.0, 10.0],
      colorIndex: 1,
      colorKey: color,
      width: width,
    );
    final canvas = RecordingCanvas();
    RemoteDraftPainter(
      drafts: drafts,
      document: document,
      colors: const [Color(0xFFFF0000), Color(0xFF00FF00)],
      ink: const Color(0xFF123456),
      inkColors: const {'blue': Color(0xFF0000FF)},
    ).paint(canvas, const Size(400, 400));
    return canvas;
  }

  test('a ghost with a pen paints its colour and world width', () {
    final canvas = paintGhost(color: 'blue', width: 6);
    expect(canvas.pathColors.single, const Color(0xFF0000FF));
    expect(canvas.deviceStrokeWidths.single, 12);
  });

  test('a ghost with no pen keeps the identity colour at a fixed width', () {
    final canvas = paintGhost();
    expect(canvas.pathColors.single.toARGB32() & 0xFFFFFF, 0x00FF00);
    expect(canvas.deviceStrokeWidths.single, 6);
  });

  test('a hairline pen is still drawn at the least visible width', () {
    final canvas = paintGhost(color: 'blue', width: 0.1);
    expect(canvas.deviceStrokeWidths.single, minInkScreenPx);
  });
}
