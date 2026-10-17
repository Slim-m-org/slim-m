// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A `cells` grid placed somewhere in a scene rather than filling it.
///
/// Until this, a grid *was* the scene: the painter divided the whole canvas by
/// `cols` and `rows`, and so did the hit test. That made a grid and anything
/// else mutually exclusive, which is why `music-box` had to signal its beats by
/// shading every fourth column instead of drawing a line between them.
///
/// The assertions here are geometric rather than visual on purpose. A grid
/// whose cells paint in one place and answer taps in another looks perfectly
/// fine in a screenshot, so `sceneTapAction` is the thing worth pinning: it is
/// the half a person actually feels when they miss a cell they aimed at.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_painter.dart';

/// A 100x100 scene holding one 4x4 grid, optionally boxed, over a tappable
/// backdrop. The backdrop is what proves a tap outside the box falls through
/// rather than being swallowed by a grid that is not drawn there.
ModuleScene _scene({Map<String, Object?>? box}) => parseModuleScene(
  jsonEncode({
    r'$slim': 'scene/1',
    'width': 100,
    'height': 100,
    'ops': [
      {
        'op': 'rect',
        'x': 0,
        'y': 0,
        'w': 100,
        'h': 100,
        'fill': 'sunken',
        'tap': 'backdrop',
      },
      {
        'op': 'cells',
        'cols': 4,
        'rows': 4,
        'data': '0' * 16,
        'palette': ['sunken', 'accent'],
        'tap': 'cell',
        ...?box,
      },
    ],
  }),
)!;

void main() {
  const size = Size(100, 100);

  group('a grid with no box', () {
    test('still fills the whole scene, which every older module relies on', () {
      final scene = _scene();
      final op = scene.ops.whereType<CellsOp>().single;
      expect(op.box, isNull);
      expect(
        cellsGridRect(op, scene, 1, 1),
        const Rect.fromLTWH(0, 0, 100, 100),
      );
      // 4 columns across 100px: each is 25 wide, so (60, 30) is col 2, row 1.
      expect(sceneTapAction(scene, const Offset(60, 30), size), 'cell:1,2');
    });
  });

  group('a grid given a box', () {
    // A 4x4 grid in a 40x40 box at (20, 20): each cell is 10 across.
    final boxed = {'x': 20, 'y': 20, 'w': 40, 'h': 40};

    test('occupies exactly that box', () {
      final scene = _scene(box: boxed);
      final op = scene.ops.whereType<CellsOp>().single;
      expect(op.box?.x, 20);
      expect(op.box?.y, 20);
      expect(
        cellsGridRect(op, scene, 1, 1),
        const Rect.fromLTWH(20, 20, 40, 40),
      );
    });

    test('reads a tap against the box, not the canvas', () {
      final scene = _scene(box: boxed);
      expect(
        sceneTapAction(scene, const Offset(25, 25), size),
        'cell:0,0',
        reason: 'the top-left cell is at the box corner, not the scene corner',
      );
      expect(sceneTapAction(scene, const Offset(55, 55), size), 'cell:3,3');
      expect(
        sceneTapAction(scene, const Offset(35, 25), size),
        'cell:0,1',
        reason: '15px into a 40px-wide grid of 4 is the second column',
      );
    });

    test('lets a tap outside it reach the op underneath', () {
      final scene = _scene(box: boxed);
      for (final outside in [
        const Offset(5, 5),
        const Offset(95, 50),
        const Offset(50, 95),
      ]) {
        expect(
          sceneTapAction(scene, outside, size),
          'backdrop',
          reason:
              'a boxed grid must not claim taps it does not cover: $outside',
        );
      }
    });

    test('scales with the widget the way the rest of the scene does', () {
      final scene = _scene(box: boxed);
      // The same scene painted at 200x200: every coordinate doubles.
      expect(
        sceneTapAction(scene, const Offset(50, 50), const Size(200, 200)),
        'cell:0,0',
      );
      expect(
        sceneTapAction(scene, const Offset(110, 110), const Size(200, 200)),
        'cell:3,3',
      );
    });
  });

  group('a box that describes nothing', () {
    test('falls back to the whole scene rather than vanishing', () {
      for (final broken in [
        {'x': 20, 'y': 20, 'w': 0, 'h': 40},
        {'x': 20, 'y': 20, 'w': 40, 'h': -1},
        {'x': 20, 'y': 20},
        {'w': 'wide', 'h': 'tall'},
      ]) {
        final scene = _scene(box: broken);
        expect(
          scene.ops.whereType<CellsOp>().single.box,
          isNull,
          reason:
              'a box without a positive width and height is no box: $broken',
        );
        expect(sceneTapAction(scene, const Offset(60, 30), size), 'cell:1,2');
      }
    });

    test('a width and height alone put the grid at the origin', () {
      final scene = _scene(box: {'w': 50, 'h': 50});
      final op = scene.ops.whereType<CellsOp>().single;
      expect(op.box?.x, 0);
      expect(op.box?.y, 0);
      expect(sceneTapAction(scene, const Offset(60, 30), size), 'backdrop');
      expect(sceneTapAction(scene, const Offset(6, 6), size), 'cell:0,0');
    });
  });
}
