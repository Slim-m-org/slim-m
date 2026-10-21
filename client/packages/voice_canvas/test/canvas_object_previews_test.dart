// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A remote drag eases between reported boxes instead of teleporting, and an
/// abandoned one returns to where it started.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

final _t0 = DateTime(2026, 1, 1);

CanvasDocument _documentWithBox() => CanvasDocument()
  ..applyPlaced(
    CanvasStrokeInput(
      id: 'a',
      x: 0,
      y: 0,
      w: 10,
      h: 10,
      points: Float32List.fromList(<double>[0, 0, 10, 10]),
      width: 2,
      colorKey: 'ink',
      zIndex: 0,
      seq: 1,
    ),
  );

ObjectBox _at(double x) => (x: x, y: 0, w: 10, h: 10);

DateTime _ms(int ms) => _t0.add(Duration(milliseconds: ms));

void main() {
  late CanvasDocument document;
  late RemoteObjectPreviews previews;

  setUp(() {
    document = _documentWithBox();
    previews = RemoteObjectPreviews(document);
  });
  tearDown(() => document.dispose());

  test('the object is midway through the glide midway through the window', () {
    previews.apply('a', _at(100), now: _t0);
    previews.tick(_ms(50));

    expect(document.objectBounds('a')!.x, 50);
    previews.tick(_ms(100));
    expect(document.objectBounds('a')!.x, 100);
  });

  test('a new frame retargets from the in-flight position, not the old one',
      () {
    previews.apply('a', _at(100), now: _t0);
    previews.apply('a', _at(200), now: _ms(50));
    previews.tick(_ms(50));

    expect(document.objectBounds('a')!.x, 50);
    previews.tick(_ms(150));
    expect(document.objectBounds('a')!.x, 200);
  });

  test('reduce-motion jumps straight to the reported box', () {
    previews.glide = Duration.zero;
    previews.apply('a', _at(100), now: _t0);
    previews.tick(_t0);

    expect(document.objectBounds('a')!.x, 100);
  });

  test('an ended preview holds its box until the commit settles it', () {
    previews.apply('a', _at(100), now: _t0);
    previews.end('a', now: _ms(200));
    previews.tick(_ms(1000));

    expect(document.objectBounds('a')!.x, 100);
    previews.settle('a', now: _ms(1000));
    expect(previews.isActive, isFalse);
    expect(document.objectBounds('a')!.x, 100);
  });

  test('a move that never commits puts the object back', () {
    previews.apply('a', _at(100), now: _t0);
    previews.end('a', now: _ms(200));
    final more = previews.tick(_ms(200).add(objectPreviewSettleGrace * 2));

    expect(more, isFalse);
    expect(document.objectBounds('a')!.x, 0);
  });

  test('a preview whose sender vanished mid-drag is abandoned', () {
    previews.apply('a', _at(100), now: _t0);
    previews.tick(_ms(100));
    previews.tick(_t0.add(objectPreviewStaleAfter * 2));

    expect(document.objectBounds('a')!.x, 0);
    expect(previews.isActive, isFalse);
  });

  test('a preview for an unknown object is ignored', () {
    previews.apply('nope', _at(100), now: _t0);

    expect(previews.isActive, isFalse);
  });

  test('once the glide has landed, further ticks leave the document alone', () {
    previews.apply('a', _at(100), now: _t0);
    expect(previews.tick(_ms(50)), isTrue);
    expect(previews.tick(_ms(100)), isFalse);
    expect(previews.isActive, isFalse);

    var notified = 0;
    document.addListener(() => notified++);
    for (var ms = 116; ms < 3000; ms += 16) {
      previews.tick(_ms(ms));
    }

    expect(notified, 0);
    expect(document.objectBounds('a')!.x, 100);
  });

  test('a frame after the hold retargets and wakes the glide again', () {
    previews.apply('a', _at(100), now: _t0);
    previews.tick(_ms(100));
    previews.apply('a', _at(160), now: _ms(2000));

    expect(previews.isActive, isTrue);
    previews.tick(_ms(2100));
    expect(document.objectBounds('a')!.x, 160);
  });

  test('a repeated box neither moves the object nor notifies', () {
    previews.apply('a', _at(100), now: _t0);
    previews.tick(_ms(100));
    previews.apply('a', _at(100), now: _ms(200));

    var notified = 0;
    document.addListener(() => notified++);
    previews.tick(_ms(220));

    expect(notified, 0);
  });

  test('the deadline is the sooner of the settle grace and the stale limit',
      () {
    expect(previews.nextDeadline, isNull);
    previews.apply('a', _at(100), now: _t0);
    expect(previews.nextDeadline, _t0.add(objectPreviewStaleAfter));

    previews.end('a', now: _ms(200));
    expect(previews.nextDeadline, _ms(200).add(objectPreviewSettleGrace));
  });

  test('expire puts an abandoned object back and tells the document', () {
    previews.apply('a', _at(100), now: _t0);
    previews.tick(_ms(100));
    var notified = 0;
    document.addListener(() => notified++);

    expect(previews.expire(_ms(100)), isFalse);
    expect(notified, 0);
    expect(previews.expire(_t0.add(objectPreviewStaleAfter * 2)), isTrue);
    expect(notified, 1);
    expect(document.objectBounds('a')!.x, 0);
    expect(previews.nextDeadline, isNull);
  });
  test('a frame naming a box no object may have is ignored', () {
    previews.apply(
      'a',
      (x: 0, y: 0, w: maxObjectExtent + 1, h: 10),
      now: _t0,
    );
    previews.apply('a', (x: 0, y: 0, w: double.nan, h: 10), now: _t0);
    previews.tick(_ms(200));

    expect(document.objectBounds('a')!.w, 10);
    expect(document.scene.slotCount, 1);
  });
}
