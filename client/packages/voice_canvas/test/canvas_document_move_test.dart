// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasDocument.moveObject], [CanvasDocument.objectBounds] and
/// [CanvasDocument.setImageBitmap]: repositioning a placed object, and
/// attaching a decoded bitmap to one.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// A minimal real [ui.Image], built from raw pixels rather than a PNG/JPEG
/// codec: what these tests need is a disposable bitmap the document can
/// hold, never anything about its content.
Future<ui.Image> _fakeImage() {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List(2 * 2 * 4),
    2,
    2,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

CanvasStrokeInput strokeAt(String id, {double x = 0, double y = 0}) =>
    CanvasStrokeInput(
      id: id,
      seq: 1,
      zIndex: 1,
      x: x,
      y: y,
      w: 10,
      h: 5,
      points: const [0, 0, 10, 5],
      width: 3,
      colorKey: 'annotation',
    );

void main() {
  test('moveObject relocates the box and the index follows it', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(strokeAt('a', x: 0, y: 0))
      ..refresh();

    expect(hitTestStroke(document, const Offset(5, 2.5)), 'a');

    expect(document.moveObject('a', 100, 100, 10, 5), isTrue);
    document.refresh();

    expect(hitTestStroke(document, const Offset(5, 2.5)), isNull);
    expect(hitTestStroke(document, const Offset(105, 102.5)), 'a');
  });

  test('moveObject translates a stroke\'s own points, not only its box', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(strokeAt('a', x: 0, y: 0))
      ..refresh();

    document
      ..moveObject('a', 100, 100, 10, 5)
      ..refresh();

    // The drawn line, not merely its box, must have moved: the old end misses.
    expect(hitTestStroke(document, const Offset(10, 5)), isNull);
    expect(hitTestStroke(document, const Offset(110, 105)), 'a');
  });

  test('moveObject preserves zIndex, kind and attachmentId', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(
        const CanvasStrokeInput(
          id: 'pic',
          seq: 3,
          zIndex: 3,
          x: 0,
          y: 0,
          w: 20,
          h: 20,
          points: [],
          width: 0,
          colorKey: '',
          kind: CanvasObjectKind.image,
          attachmentId: 'sha-pic',
        ),
      )
      ..refresh();

    document.moveObject('pic', 50, 50, 20, 20);

    final slot = hitTestBoxAt(document, const Offset(60, 60));
    expect(slot, 'pic');
    final bounds = document.objectBounds('pic')!;
    expect((bounds.x, bounds.y, bounds.w, bounds.h), (50.0, 50.0, 20.0, 20.0));
  });

  test('moveObject on an unknown or removed id returns false', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    expect(document.moveObject('nope', 1, 1, 1, 1), isFalse);

    document
      ..applyPlaced(strokeAt('a'))
      ..removeObject('a');
    expect(document.moveObject('a', 1, 1, 1, 1), isFalse);
  });

  test('objectBounds reports the current box, and null once removed', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document.applyPlaced(strokeAt('a', x: 3, y: 4));

    final bounds = document.objectBounds('a')!;
    expect((bounds.x, bounds.y, bounds.w, bounds.h), (3.0, 4.0, 10.0, 5.0));

    document.removeObject('a');
    expect(document.objectBounds('a'), isNull);
  });

  test('objectBounds is null for an id never placed', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    expect(document.objectBounds('never'), isNull);
  });

  test(
    'markImageLoadFailed sets the flag, and setImageBitmap clears it again',
    () async {
      final document = CanvasDocument()..setViewport(const Size(800, 600));
      document
        ..applyPlaced(
          const CanvasStrokeInput(
            id: 'pic',
            seq: 1,
            zIndex: 1,
            x: 0,
            y: 0,
            w: 20,
            h: 20,
            points: [],
            width: 0,
            colorKey: '',
            kind: CanvasObjectKind.image,
            attachmentId: 'sha-pic',
          ),
        )
        ..refresh();

      document.markImageLoadFailed('pic');
      var slot = document.strokeIfAlive(document.paintOrder.single)!;
      expect(slot.imageLoadFailed, isTrue);

      document.setImageBitmap('pic', await _fakeImage());
      slot = document.strokeIfAlive(document.paintOrder.single)!;
      expect(slot.imageLoadFailed, isFalse);
      expect(slot.image, isNotNull);
    },
  );

  test(
    'markImageLoadFailed never blanks an image that already landed',
    () async {
      final document = CanvasDocument()..setViewport(const Size(800, 600));
      document
        ..applyPlaced(
          const CanvasStrokeInput(
            id: 'pic',
            seq: 1,
            zIndex: 1,
            x: 0,
            y: 0,
            w: 20,
            h: 20,
            points: [],
            width: 0,
            colorKey: '',
            kind: CanvasObjectKind.image,
            attachmentId: 'sha-pic',
          ),
        )
        ..refresh();
      document.setImageBitmap('pic', await _fakeImage());

      document.markImageLoadFailed('pic');

      final slot = document.strokeIfAlive(document.paintOrder.single)!;
      expect(
        slot.imageLoadFailed,
        isFalse,
        reason: 'a late failure racing behind a fetch that already landed '
            'must not blank a real image',
      );
    },
  );

  test('moveObject carries imageLoadFailed forward', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(
        const CanvasStrokeInput(
          id: 'pic',
          seq: 1,
          zIndex: 1,
          x: 0,
          y: 0,
          w: 20,
          h: 20,
          points: [],
          width: 0,
          colorKey: '',
          kind: CanvasObjectKind.image,
          attachmentId: 'sha-pic',
        ),
      )
      ..refresh();
    document.markImageLoadFailed('pic');

    document.moveObject('pic', 50, 50, 20, 20);
    document.refresh();

    final slot = document.strokeIfAlive(document.paintOrder.single)!;
    expect(slot.imageLoadFailed, isTrue);
  });

  test(
    'evictImageBitmap disposes the bitmap without removing the object',
    () async {
      final document = CanvasDocument()..setViewport(const Size(800, 600));
      document
        ..applyPlaced(
          const CanvasStrokeInput(
            id: 'pic',
            seq: 1,
            zIndex: 1,
            x: 0,
            y: 0,
            w: 20,
            h: 20,
            points: [],
            width: 0,
            colorKey: '',
            kind: CanvasObjectKind.image,
            attachmentId: 'sha-pic',
          ),
        )
        ..refresh();
      document.setImageBitmap('pic', await _fakeImage());

      document.evictImageBitmap('pic');

      expect(document.objectBounds('pic'), isNotNull);
      final slot = document.strokeIfAlive(document.paintOrder.single)!;
      expect(slot.image, isNull);
    },
  );

  test('evictImageBitmap on an id with no bitmap is a harmless no-op', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document.applyPlaced(strokeAt('a'));

    document.evictImageBitmap('a');
    document.evictImageBitmap('never-placed');

    expect(document.objectBounds('a'), isNotNull);
  });
}
