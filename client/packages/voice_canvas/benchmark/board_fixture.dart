// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Synthetic busy boards for the canvas interaction benchmarks.
///
/// The shared board is one fixed 1920x1080 frame (decision 0073), so a large
/// canvas is not spread over a big world: every object lands in the same
/// frame and all of them are on screen at the fit zoom. That is the case
/// these boards model, and it is why culling buys nothing here.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:slimm_voice_canvas/voice_canvas.dart';

/// What a board holds.
class BoardSpec {
  const BoardSpec({
    this.strokes = 0,
    this.notes = 0,
    this.images = 0,
    this.pointsPerStroke = 48,
    this.seed = 20261020,
  });

  final int strokes;
  final int notes;
  final int images;
  final int pointsPerStroke;
  final int seed;

  String get label => '${strokes}s+${notes}n+${images}i';
}

/// Pen colour keys the benchmark painters resolve, so strokes are not all one paint.
const Map<String, ui.Color> benchInkColors = <String, ui.Color>{
  'ink': ui.Color(0xFF202124),
  'red': ui.Color(0xFFD93025),
  'blue': ui.Color(0xFF1A73E8),
  'green': ui.Color(0xFF188038),
  'amber': ui.Color(0xFFF9AB00),
  'violet': ui.Color(0xFF8430CE),
};

final List<String> _inkKeys = benchInkColors.keys.toList(growable: false);

const List<String> _words = <String>[
  'sprint',
  'review',
  'ship',
  'design',
  'notes',
  'agenda',
  'blocked',
  'idea',
  'retro',
  'launch',
  'owner',
  'demo',
  'risk',
  'next',
  'steps',
];

String _noteText(math.Random rng, int index) {
  final count = 5 + rng.nextInt(22);
  final words = <String>[
    for (var i = 0; i < count; i++) _words[rng.nextInt(_words.length)],
  ];
  return 'Note $index: ${words.join(' ')}';
}

/// Two decimals, which is how the pen quantises a stroke before it is sent.
double _round2(double v) => (v * 100).round() / 100;

CanvasStrokeInput _stroke(math.Random rng, int index, int points) {
  var heading = rng.nextDouble() * math.pi * 2;
  var px = 0.0;
  var py = 0.0;
  final flat = <double>[0, 0];
  for (var i = 1; i < points; i++) {
    heading += (rng.nextDouble() - 0.5) * 0.6;
    px += math.cos(heading) * 5;
    py += math.sin(heading) * 5;
    flat
      ..add(px)
      ..add(py);
  }
  var minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0;
  for (var i = 0; i < flat.length; i += 2) {
    minX = math.min(minX, flat[i]);
    maxX = math.max(maxX, flat[i]);
    minY = math.min(minY, flat[i + 1]);
    maxY = math.max(maxY, flat[i + 1]);
  }
  final w = maxX - minX;
  final h = maxY - minY;
  final x = 40 + rng.nextDouble() * (1920 - 80 - w);
  final y = 40 + rng.nextDouble() * (1080 - 80 - h);
  return CanvasStrokeInput(
    id: 'stroke-$index',
    seq: index + 1,
    zIndex: index + 1,
    x: x,
    y: y,
    w: w,
    h: h,
    points: <double>[
      for (var i = 0; i < flat.length; i += 2) ...[
        _round2(flat[i] - minX),
        _round2(flat[i + 1] - minY),
      ],
    ],
    width: 3,
    colorKey: _inkKeys[index % _inkKeys.length],
    authorId: 'u${index % 8}',
  );
}

/// Every object [spec] describes, in placement order.
List<CanvasStrokeInput> boardInputs(BoardSpec spec) {
  final rng = math.Random(spec.seed);
  final inputs = <CanvasStrokeInput>[
    for (var i = 0; i < spec.strokes; i++)
      _stroke(rng, i, spec.pointsPerStroke),
  ];
  var z = spec.strokes;
  for (var i = 0; i < spec.notes; i++) {
    inputs.add(
      CanvasStrokeInput(
        id: 'note-$i',
        seq: ++z,
        zIndex: z,
        x: 20 + rng.nextDouble() * (1920 - 280),
        y: 20 + rng.nextDouble() * (1080 - 180),
        w: 240,
        h: 140,
        points: const <double>[],
        width: 0,
        colorKey: 'ink',
        kind: CanvasObjectKind.note,
        text: _noteText(rng, i),
        authorId: 'u${i % 8}',
      ),
    );
  }
  for (var i = 0; i < spec.images; i++) {
    inputs.add(
      CanvasStrokeInput(
        id: 'image-$i',
        seq: ++z,
        zIndex: z,
        x: 20 + rng.nextDouble() * (1920 - 360),
        y: 20 + rng.nextDouble() * (1080 - 280),
        w: 320,
        h: 240,
        points: const <double>[],
        width: 0,
        colorKey: 'ink',
        kind: CanvasObjectKind.image,
        attachmentId: 'att-$i',
        authorId: 'u${i % 8}',
      ),
    );
  }
  return inputs;
}

/// Builds the document for [spec] and fits the camera to the board.
///
/// Images are placed without bitmaps; [attachBitmaps] gives them pixels,
/// which needs an async engine call a plain synchronous builder cannot make.
CanvasDocument buildBoard(BoardSpec spec, {ui.Size viewport = _pane}) {
  final doc = CanvasDocument()..setBoard(canvasBoard);
  boardInputs(spec).forEach(doc.applyPlaced);
  doc
    ..setViewport(viewport)
    ..refresh();
  return doc;
}

const ui.Size _pane = ui.Size(1600, 900);

/// A patterned RGBA bitmap, built through the engine's real decode path.
Future<ui.Image> solidBitmap(int width, int height, int seed) {
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = (seed * 37) & 0xFF;
    pixels[i + 1] = ((i >> 9) + seed) & 0xFF;
    pixels[i + 2] = 180;
    pixels[i + 3] = 255;
  }
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  return done.future;
}

/// Gives every image object in [doc] a decoded bitmap of [width] x [height].
Future<void> attachBitmaps(
  CanvasDocument doc,
  int count, {
  int width = 800,
  int height = 600,
}) async {
  for (var i = 0; i < count; i++) {
    doc.setImageBitmap('image-$i', await solidBitmap(width, height, i));
  }
}
