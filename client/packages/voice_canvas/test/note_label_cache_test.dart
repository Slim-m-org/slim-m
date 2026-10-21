// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// CP9: a note's body text must be laid out once and reused across the frames
/// `StrokePainter` paints on every camera move, not re-shaped each time. A
/// note's layout depends only on its text and its projected size, so a pan
/// (zoom and box fixed) reuses it, while a zoom or a resize rebuilds it.
///
/// A rendered frame looks identical whether or not the text was re-laid-out, so
/// these count layouts through [debugNoteLabelLayoutCounts], the same way the
/// cursor-label and member-row tests do.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';
import 'package:slimm_voice_canvas/src/note_label_cache.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

class _RecordingCanvas implements Canvas {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

CanvasStrokeInput _note(String id, {double w = 220, double h = 140}) =>
    CanvasStrokeInput(
      id: id,
      seq: 0,
      zIndex: 0,
      x: 0,
      y: 0,
      w: w,
      h: h,
      points: const [],
      width: 0,
      colorKey: 'annotation',
      kind: CanvasObjectKind.note,
      text: 'a sticky note with enough words to wrap across a few lines',
    );

StrokePainter _painter(CanvasDocument document) =>
    StrokePainter(document: document, ink: const Color(0xFF1A1A1A));

TextPainter _build() => TextPainter(
      text: const TextSpan(text: 'x'),
      textDirection: TextDirection.ltr,
    )..layout();

void main() {
  test('a note lays its text out once while the canvas pans', () {
    debugResetNoteLabelLayoutCounts();
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    addTearDown(document.dispose);
    document
      ..applyPlaced(_note('n1'))
      ..refresh();

    final painter = _painter(document);
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(800, 600));
    for (var i = 1; i <= 4; i++) {
      document.setCamera(Camera(x: i * 8.0, y: i * 6.0));
      painter.paint(canvas, const Size(800, 600));
    }
    expect(
      document.camera.x,
      greaterThan(0),
      reason: 'the pans must actually move the camera or the test is vacuous',
    );
    expect(
      debugNoteLabelLayoutCounts['n1'],
      1,
      reason: 'a pan changes neither the text nor its projected size',
    );
  });

  test('a zoom change keeps the world-unit layout', () {
    debugResetNoteLabelLayoutCounts();
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    addTearDown(document.dispose);
    document
      ..applyPlaced(_note('n1'))
      ..refresh();

    final painter = _painter(document);
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(800, 600));
    document.setCamera(const Camera(zoom: 1.5));
    painter.paint(canvas, const Size(800, 600));
    expect(
      debugNoteLabelLayoutCounts['n1'],
      1,
      reason: 'the layout is in world units, so zoom only scales it',
    );
  });

  test('resizing a note re-lays-out its text', () {
    debugResetNoteLabelLayoutCounts();
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    addTearDown(document.dispose);
    document
      ..applyPlaced(_note('n1'))
      ..refresh();

    final painter = _painter(document);
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(800, 600));
    expect(debugNoteLabelLayoutCounts['n1'], 1);

    document
      ..moveObject('n1', 0, 0, 340, 220)
      ..refresh();
    painter.paint(canvas, const Size(800, 600));
    expect(
      debugNoteLabelLayoutCounts['n1'],
      2,
      reason: 'a wider box wraps the text differently, so it must re-shape',
    );
  });

  test('a note culled off-screen drops from the cache', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    addTearDown(document.dispose);
    document
      ..applyPlaced(_note('n1'))
      ..refresh();

    final painter = _painter(document);
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(800, 600));
    expect(painter.debugNoteLabelCacheSize, 1);

    // Move the note far outside the viewport so it leaves the culled set.
    document
      ..moveObject('n1', 5000, 5000, 220, 140)
      ..refresh();
    painter.paint(canvas, const Size(800, 600));
    expect(
      painter.debugNoteLabelCacheSize,
      0,
      reason: 'a culled note is not painted, so its cached text is dropped',
    );
  });

  test('a note removed from the scene stops being cached', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    addTearDown(document.dispose);
    document
      ..applyPlaced(_note('n1'))
      ..refresh();

    final painter = _painter(document);
    final canvas = _RecordingCanvas();
    painter.paint(canvas, const Size(800, 600));
    expect(painter.debugNoteLabelCacheSize, 1);

    document
      ..removeObject('n1')
      ..refresh();
    painter.paint(canvas, const Size(800, 600));
    expect(
      painter.debugNoteLabelCacheSize,
      0,
      reason: 'the note is gone, so its cached text is dropped',
    );
  });

  test('the cache reuses by key and rebuilds when text, size or spans change',
      () {
    debugResetNoteLabelLayoutCounts();
    final cache = NoteLabelCache();

    cache.painterFor('n', ('hi', 10, 10, 0), _build);
    cache.painterFor('n', ('hi', 10, 10, 0), _build);
    expect(debugNoteLabelLayoutCounts['n'], 1, reason: 'same key, one layout');

    cache.painterFor('n', ('hi', 20, 10, 0), _build);
    expect(debugNoteLabelLayoutCounts['n'], 2, reason: 'width changed');

    cache.painterFor('n', ('bye', 20, 10, 0), _build);
    expect(debugNoteLabelLayoutCounts['n'], 3, reason: 'text changed');

    cache.painterFor('n', ('bye', 20, 10, 1), _build);
    expect(debugNoteLabelLayoutCounts['n'], 4, reason: 'spans revision bumped');
  });

  test('retain drops cached text for notes no longer present', () {
    final cache = NoteLabelCache();
    cache.painterFor('a', ('a', 10, 10, 0), _build);
    cache.painterFor('b', ('b', 10, 10, 0), _build);
    expect(cache.size, 2);

    cache.retain({'a'});
    expect(cache.size, 1, reason: 'b is gone, so its text is dropped');
  });
}
