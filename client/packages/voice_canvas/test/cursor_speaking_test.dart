// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A speaker's cursor label glows (decision 0086): the cursors hold who is
/// talking, and the painter draws a halo behind just that label.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

class _RecordingCanvas implements Canvas {
  final List<({RRect rrect, Paint paint})> rrects = [];

  @override
  void drawRRect(RRect rrect, Paint paint) =>
      rrects.add((rrect: rrect, paint: paint));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

CanvasCursors _two() {
  final cursors = CanvasCursors();
  cursors.upsert(id: 'ada', x: 0, y: 0, label: 'Ada', colorIndex: 0);
  cursors.upsert(id: 'bob', x: 200, y: 0, label: 'Bob', colorIndex: 1);
  return cursors;
}

List<({RRect rrect, Paint paint})> _paint(CanvasCursors cursors) {
  final document = CanvasDocument();
  addTearDown(document.dispose);
  final canvas = _RecordingCanvas();
  CursorPainter(
    cursors: cursors,
    document: document,
    colors: const [Color(0xFFE0699A), Color(0xFF3B82F6)],
  ).paint(canvas, const Size(600, 400));
  return canvas.rrects;
}

void main() {
  test('setSpeaking tells listeners only when who is talking changed', () {
    final cursors = _two();
    addTearDown(cursors.dispose);
    var notified = 0;
    cursors.addListener(() => notified++);

    cursors.setSpeaking({'ada'});
    cursors.setSpeaking({'ada'});
    expect(notified, 1);
    expect(cursors.isSpeaking('ada'), isTrue);
    expect(cursors.isSpeaking('bob'), isFalse);

    cursors.setSpeaking({});
    expect(notified, 2);
    expect(cursors.isSpeaking('ada'), isFalse);
  });

  test('nobody talking paints one chip per label and no halo', () {
    final cursors = _two();
    addTearDown(cursors.dispose);

    expect(_paint(cursors), hasLength(2));
  });

  test('a speaker gets a blurred halo and a rim behind only their label', () {
    final cursors = _two();
    addTearDown(cursors.dispose);
    cursors.setSpeaking({'ada'});

    final drawn = _paint(cursors);

    expect(drawn, hasLength(4),
        reason: 'halo, rim and chip for Ada, chip for Bob');
    expect(drawn.first.paint.maskFilter, isNotNull,
        reason: 'the glow is blurred');
    expect(drawn.first.rrect.width, greaterThan(drawn[2].rrect.width));
    expect(drawn.last.rrect.left, greaterThan(100),
        reason: 'Bob is the plain chip');
  });
}
