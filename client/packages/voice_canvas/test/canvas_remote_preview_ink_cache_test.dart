// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Another participant's drag must not cost every viewer the whole board's ink on every frame.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';
import 'package:slimm_voice_canvas/src/canvas_object_previews.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';

import 'support/canvas_painter_fixtures.dart';

const _size = Size(1000, 1000);
final _t0 = DateTime(2026, 1, 1);

DateTime _ms(int ms) => _t0.add(Duration(milliseconds: ms));

CanvasDocument _board() {
  final document = CanvasDocument()..setViewport(_size);
  for (var i = 0; i < 400; i++) {
    document.applyPlaced(
      CanvasStrokeInput(
        id: 's$i',
        seq: i + 1,
        zIndex: i,
        x: (i % 20) * 30.0,
        y: (i ~/ 20) * 30.0,
        w: 16,
        h: 16,
        points: Float32List.fromList(<double>[0, 0, 16, 16]),
        width: 2,
        colorKey: 'ink',
      ),
    );
  }
  document.setCamera(const Camera(x: 100, y: 100));
  return document;
}

ObjectBox _at(double x) => (x: x, y: 300, w: 16, h: 16);

void main() {
  late CanvasDocument document;
  late StrokePainter painter;
  late RemoteObjectPreviews previews;

  int drawn() {
    final canvas = RecordingCanvas();
    painter.paint(canvas, _size);
    return canvas.deviceStrokeWidths.length;
  }

  setUp(() {
    document = _board();
    painter = StrokePainter(document: document, ink: ink);
    previews = RemoteObjectPreviews(document);
    drawn();
    drawn();
  });
  tearDown(() {
    painter.dispose();
    document.dispose();
  });

  test('a remote drag redraws only the dragged object once the texture is set',
      () {
    previews.apply('s3', _at(200), now: _t0);
    int frame(int ms) {
      previews.tick(_ms(ms));
      return drawn();
    }

    frame(20);
    frame(40);

    for (var ms = 60; ms <= 120; ms += 20) {
      expect(
        frame(ms),
        1,
        reason: 'a remote move bumped the content revision, so the whole '
            'board was replayed live instead of the one object that moves',
      );
    }
    expect(document.objectBounds('s3')!.x, greaterThan(0));
  });

  test('moving a held object leaves the content revision alone', () {
    document.holdLive('s3');
    final held = document.contentRevision;

    document.moveObject('s3', 250, 250, 16, 16);

    expect(document.contentRevision, held);
    document.moveObject('s4', 250, 250, 16, 16);
    expect(document.contentRevision, isNot(held));
  });

  test('releasing a held object puts it back in the cached ink', () {
    previews.apply('s3', _at(200), now: _t0);
    for (var ms = 20; ms <= 160; ms += 20) {
      previews.tick(_ms(ms));
      drawn();
    }
    expect(drawn(), 1);

    previews.settle('s3', now: _ms(200));
    document.refresh();
    drawn();

    expect(drawn(), 0, reason: 'settled, the object belongs to the texture');
  });

  test('an abandoned preview returns the object to its place and the cache',
      () {
    previews.apply('s3', _at(200), now: _t0);
    previews.tick(_ms(100));
    expect(document.isHeldLive('s3'), isTrue);

    previews.expire(_ms(100).add(objectPreviewStaleAfter * 2));

    expect(document.isHeldLive('s3'), isFalse);
    expect(document.objectBounds('s3')!.y, 0);
  });

  test('clearing the previews releases every object they held', () {
    previews
      ..apply('s3', _at(200), now: _t0)
      ..apply('s4', _at(260), now: _t0);

    previews.clear();

    expect(document.isHeldLive('s3'), isFalse);
    expect(document.isHeldLive('s4'), isFalse);
  });

  testWidgets('a held object leaves no copy behind in the texture', (
    tester,
  ) async {
    painter.devicePixelRatio = 1;
    await tester.runAsync(() async {
      Future<Uint8List> frame(StrokePainter from) async {
        final recorder = ui.PictureRecorder();
        from.paint(Canvas(recorder), _size);
        final image = await recorder.endRecording().toImage(1000, 1000);
        final bytes = (await image.toByteData())!.buffer.asUint8List();
        image.dispose();
        return bytes;
      }

      await frame(painter);
      await frame(painter);
      for (var ms = 0; ms <= 400; ms += 100) {
        previews.apply('s3', _at(200.0 + ms), now: _ms(ms));
        previews.tick(_ms(ms + 50));
        await frame(painter);
      }
      final cached = await frame(painter);
      expect(painter.debugHasInkTexture, isTrue);

      final reference = StrokePainter(document: document, ink: ink)
        ..devicePixelRatio = 1;
      final live = await frame(reference);
      reference.dispose();

      var worst = 0;
      for (var i = 0; i < cached.length; i++) {
        worst = worst > (cached[i] - live[i]).abs()
            ? worst
            : (cached[i] - live[i]).abs();
      }
      expect(worst, lessThan(24), reason: 'a ghost at the old place differs');
    });
  });
}
