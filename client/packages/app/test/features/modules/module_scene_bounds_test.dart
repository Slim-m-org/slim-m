// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What `sceneContentBounds` keeps and when it refuses to crop at all, since a
/// wrong crop clips drawing and a missing one brings back the empty fill.
library;

import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_bounds.dart';

ModuleScene _scene(
  List<Map<String, Object?>> ops, {
  double w = 100,
  double h = 100,
}) => parseModuleScene(
  jsonEncode({r'$slim': 'scene/1', 'width': w, 'height': h, 'ops': ops}),
)!;

Rect? _crop(List<Map<String, Object?>> ops, {double w = 100, double h = 100}) =>
    _scene(ops, w: w, h: h).crop;

Map<String, Object?> _rect(double x, double y, double w, double h) => {
  'op': 'rect',
  'x': x,
  'y': y,
  'w': w,
  'h': h,
  'fill': 'accent',
};

void main() {
  group('no tighter crop', () {
    test('an op with a sweep moves, so the whole canvas stays', () {
      final op = {
        ..._rect(40, 40, 10, 10),
        'sweep': {'dx': 30, 'secs': 1},
      };
      expect(_crop([op]), isNull);
    });

    test('an empty canvas has nothing to frame', () {
      expect(_crop([]), isNull);
    });

    test('content more elongated than the aspect clamp stays whole', () {
      expect(_crop([_rect(10, 40, 80, 2)]), isNull);
      expect(_crop([_rect(40, 10, 2, 80)]), isNull);
    });

    test('a cells op without a box keeps the whole canvas in view', () {
      final op = {
        'op': 'cells',
        'cols': 2,
        'rows': 2,
        'data': '0000',
        'palette': ['sunken'],
      };
      expect(
        _crop([op, _rect(40, 40, 10, 10)]),
        const Rect.fromLTWH(0, 0, 100, 100),
      );
    });
  });

  group('per-op bounds', () {
    Rect only(Map<String, Object?> op) =>
        sceneContentBounds(_scene([op, _rect(0, 0, 0, 0)], w: 200, h: 200))!;

    test('a rect is its box plus half its stroke', () {
      final crop = _crop([
        {..._rect(30, 30, 20, 20), 'stroke': 'border', 'sw': 4},
      ])!;
      expect(crop.left, lessThanOrEqualTo(28));
      expect(crop.right, greaterThanOrEqualTo(52));
    });

    test('text bounds follow the alignment', () {
      Rect text(String align) => _crop(
        [
          {
            'op': 'text',
            'x': 50,
            'y': 50,
            's': 'abcdefghij',
            'size': 10,
            'align': align,
          },
          _rect(49, 10, 2, 90),
        ],
        w: 200,
        h: 200,
      )!;
      final left = text('left');
      expect(left.left, inInclusiveRange(45, 50));
      expect(left.right, greaterThanOrEqualTo(110));
      final center = text('center');
      expect(center.left, lessThanOrEqualTo(20));
      expect(center.right, greaterThanOrEqualTo(80));
      final right = text('right');
      expect(right.left, 0, reason: 'clipped to the canvas, not past it');
      expect(right.right, inInclusiveRange(50, 56));
    });

    test('a path is its own bounds plus stroke', () {
      final crop = _crop([
        {
          'op': 'path',
          'd': 'M20 30 L80 30 L80 70 L20 70 Z',
          'stroke': 'accent',
          'sw': 2,
        },
      ])!;
      expect(crop.left, lessThanOrEqualTo(19));
      expect(crop.right, greaterThanOrEqualTo(81));
      expect(crop.top, lessThanOrEqualTo(29));
      expect(crop.bottom, greaterThanOrEqualTo(71));
      expect(crop.left, greaterThan(10));
    });

    test('a circle covers its radius and stroke', () {
      final crop = _crop([
        {
          'op': 'circle',
          'cx': 50,
          'cy': 50,
          'r': 10,
          'stroke': 'text',
          'sw': 4,
        },
      ])!;
      expect(crop.left, lessThanOrEqualTo(38));
      expect(crop.right, greaterThanOrEqualTo(62));
      expect(crop.top, lessThanOrEqualTo(38));
      expect(crop.bottom, greaterThanOrEqualTo(62));
    });

    test('a line covers both ends and its stroke', () {
      final crop = _crop([
        {
          'op': 'line',
          'x1': 20,
          'y1': 30,
          'x2': 70,
          'y2': 60,
          'stroke': 'text',
          'sw': 6,
        },
      ])!;
      expect(crop.left, lessThanOrEqualTo(17));
      expect(crop.right, greaterThanOrEqualTo(73));
      expect(crop.top, lessThanOrEqualTo(27));
      expect(crop.bottom, greaterThanOrEqualTo(63));
    });

    test('an image covers its box', () {
      final crop = _crop([
        {'op': 'image', 'x': 30, 'y': 20, 'w': 40, 'h': 50, 'b64': 'AQID'},
      ]);
      expect(crop, isNotNull);
      expect(crop!.left, lessThanOrEqualTo(30));
      expect(crop.right, greaterThanOrEqualTo(70));
      expect(crop.top, lessThanOrEqualTo(20));
      expect(crop.bottom, greaterThanOrEqualTo(70));
    });

    test('the crop never leaves the declared canvas', () {
      final crop = only(_rect(0, 0, 150, 150));
      expect(crop.left, greaterThanOrEqualTo(0));
      expect(crop.right, lessThanOrEqualTo(200));
    });
  });

  test('the crop contains every op it measured, with a thin margin', () {
    final ops = [_rect(25, 10, 30, 40), _rect(60, 55, 10, 10)];
    final crop = _crop(ops)!;
    for (final rect in [
      const Rect.fromLTWH(25, 10, 30, 40),
      const Rect.fromLTWH(60, 55, 10, 10),
    ]) {
      expect(crop.contains(rect.topLeft), isTrue);
      expect(crop.contains(rect.bottomRight), isTrue);
    }
    expect(crop.left, greaterThan(25 - 3));
    expect(crop.bottom, lessThan(65 + 3));
  });

  group('keepCropStable', () {
    test('only grows while the canvas is the same', () {
      final big = _scene([_rect(20, 20, 60, 60)]);
      final small = _scene([_rect(40, 40, 10, 10)]);
      final kept = keepCropStable(big, small);
      expect(kept.crop, big.crop);
      final grown = keepCropStable(small, big);
      expect(grown.crop, big.crop);
    });

    test('a new canvas starts over', () {
      final a = _scene([_rect(20, 20, 60, 60)]);
      final b = _scene([_rect(40, 40, 10, 10)], w: 50, h: 50);
      expect(keepCropStable(a, b).crop, b.crop);
    });

    test('a whole-canvas scene stays whole', () {
      final whole = _scene([]);
      final small = _scene([_rect(40, 40, 10, 10)]);
      expect(keepCropStable(whole, small).crop, isNull);
    });
  });
}
