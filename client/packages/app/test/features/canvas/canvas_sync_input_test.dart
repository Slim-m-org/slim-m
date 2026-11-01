// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [canvasStrokeInputFrom]'s dispatch: a wire object's `kind` decides which
/// of `points`, `attachment`, `text` or `shape` this client reads out of an
/// otherwise opaque `props`, and an unparseable or unrecognised one answers
/// null rather than guessing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

api.CanvasObject _object({
  required String kind,
  Map<String, dynamic> props = const {},
}) => api.CanvasObject(
  id: 'obj-1',
  kind: kind,
  zIndex: 1,
  x: 10,
  y: 20,
  w: 100,
  h: 60,
  props: props,
  authorId: 'alice',
  seq: 1,
  createdAt: 0,
);

void main() {
  test(
    'a note reads its stored text size, clamped, and falls back without one',
    () {
      double? sizeOf(Object? raw) => canvasStrokeInputFrom(
        _object(kind: 'note', props: {'text': 'hi', 'font_size': ?raw}),
      )!.fontSize;

      expect(sizeOf(null), isNull);
      expect(sizeOf(18), 18);
      expect(sizeOf(1e6), maxNoteFontSize);
      expect(sizeOf(0.5), minNoteFontSize);
      expect(sizeOf('big'), isNull);
      expect(sizeOf(double.nan), isNull);
    },
  );

  test('a forged stroke width is clamped, and a sane one is kept', () {
    double widthOf(Object? width) => canvasStrokeInputFrom(
      _object(
        kind: 'stroke',
        props: {
          'points': [0.0, 0.0, 1.0, 1.0],
          'width': width,
        },
      ),
    )!.width;

    expect(widthOf(1e5), maxWireStrokeWidth);
    expect(widthOf(12.5), 12.5);
    expect(widthOf(double.infinity), 3);
    expect(widthOf(-4), 3);
  });

  test('a note carries its own kind and text through', () {
    final input = canvasStrokeInputFrom(
      _object(kind: 'note', props: {'text': 'buy milk'}),
    );
    expect(input, isNotNull);
    expect(input!.kind, CanvasObjectKind.note);
    expect(input.text, 'buy milk');
    expect(input.colorKey, 'note');
  });

  test('a note with no text, or a non-string one, does not parse', () {
    expect(canvasStrokeInputFrom(_object(kind: 'note')), isNull);
    expect(
      canvasStrokeInputFrom(_object(kind: 'note', props: {'text': 7})),
      isNull,
    );
  });

  test('a shape carries its own kind and shapeKind through', () {
    final input = canvasStrokeInputFrom(
      _object(kind: 'shape', props: {'shape': 'ellipse'}),
    );
    expect(input, isNotNull);
    expect(input!.kind, CanvasObjectKind.shape);
    expect(input.shapeKind, CanvasShapeKind.ellipse);
    expect(input.colorKey, 'shape');
  });

  test('an arrow carries the way it points', () {
    final input = canvasStrokeInputFrom(
      _object(
        kind: 'shape',
        props: {'shape': 'arrow', 'flip_x': true, 'flip_y': true},
      ),
    );
    expect(input!.flipX, isTrue);
    expect(input.flipY, isTrue);

    final plain = canvasStrokeInputFrom(
      _object(kind: 'shape', props: {'shape': 'arrow'}),
    );
    expect(plain!.flipX, isFalse);
    expect(plain.flipY, isFalse);
  });

  test('a shape naming an unrecognised primitive does not parse', () {
    expect(
      canvasStrokeInputFrom(_object(kind: 'shape', props: {'shape': 'star'})),
      isNull,
    );
    expect(canvasStrokeInputFrom(_object(kind: 'shape')), isNull);
  });

  test('every wire shape kind round-trips through canvasShapeKindToWire', () {
    for (final kind in CanvasShapeKind.values) {
      expect(canvasShapeKindFromWire(canvasShapeKindToWire(kind)), kind);
    }
  });

  test('an unrecognised top-level kind is null, not a default stroke', () {
    expect(canvasStrokeInputFrom(_object(kind: 'window')), isNull);
  });

  group('a stroke whose props carry the wrong types', () {
    // A hostile or buggy poster can store any json object as props, and rows already stored are served back as is.
    final poisoned = <String, (Map<String, dynamic>, List<double>?)>{
      'non-string color': (
        {
          'points': [0, 0, 1, 1],
          'color': 5,
        },
        [0, 0, 1, 1],
      ),
      'non-number width': (
        {
          'points': [0, 0, 1, 1],
          'width': 'x',
        },
        [0, 0, 1, 1],
      ),
      'non-list points': ({'points': 'abc'}, null),
      'mixed points': (
        {
          'points': [0, 'a', null, 1, 2],
        },
        [0, 1, 2],
      ),
    };
    for (final entry in poisoned.entries) {
      test('${entry.key} reads as the numbers it holds, or nothing', () {
        final input = canvasStrokeInputFrom(
          _object(kind: 'stroke', props: entry.value.$1),
        );

        expect(input?.points, entry.value.$2);
      });
    }

    test('a bad width and color fall back to the defaults', () {
      final input = canvasStrokeInputFrom(
        _object(
          kind: 'stroke',
          props: {
            'points': [0, 0, 1, 1],
            'width': 'x',
            'color': 5,
          },
        ),
      );
      expect(input, isNotNull);
      expect(input!.width, 3);
      expect(input.colorKey, 'annotation');
    });

    test('a non-finite or negative width falls back to the default', () {
      for (final width in [double.infinity, double.nan, -2, 0]) {
        final input = canvasStrokeInputFrom(
          _object(
            kind: 'stroke',
            props: {
              'points': [0, 0, 1, 1],
              'width': width,
            },
          ),
        );
        expect(input!.width, 3, reason: 'width $width');
      }
    });
  });
}
