// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `cells` grid has a stated ceiling, like every other unbounded thing in
/// the scene contract.
///
/// It was the one op without one. `data` bounds the painter's work in
/// practice - it draws no more cells than characters it was sent - so this
/// guards robustness rather than a live hang, and that distinction is the
/// reason it is worth a test: "bounded by the module output size limit" is a
/// guarantee that quietly stops holding the moment that unrelated limit moves.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';

ModuleScene? _sceneWith({required Object? cols, required Object? rows}) =>
    parseModuleScene(
      jsonEncode({
        r'$slim': 'scene/1',
        'width': 100,
        'height': 100,
        'ops': [
          {
            'op': 'cells',
            'cols': cols,
            'rows': rows,
            'data': '01',
            'palette': ['sunken', 'accent'],
          },
        ],
      }),
    );

CellsOp _cells(ModuleScene? scene) => scene!.ops.whereType<CellsOp>().single;

void main() {
  // Fails: parsing cols/rows straight through with .toInt().
  test('a grid past the ceiling is clamped to it, on both axes', () {
    final op = _cells(_sceneWith(cols: 5000, rows: 9000));
    expect(op.cols, CellsOp.maxPerAxis);
    expect(op.rows, CellsOp.maxPerAxis);
  });

  test('a grid inside the ceiling is left exactly as asked', () {
    // 48x48 is game-of-life's real grid: the ceiling must not reshape it.
    final op = _cells(_sceneWith(cols: 48, rows: 48));
    expect(op.cols, 48);
    expect(op.rows, 48);
  });

  test('the ceiling itself passes through unchanged', () {
    final op = _cells(
      _sceneWith(cols: CellsOp.maxPerAxis, rows: CellsOp.maxPerAxis),
    );
    expect(op.cols, CellsOp.maxPerAxis);
    expect(op.rows, CellsOp.maxPerAxis);
  });

  // The painter already refuses a negative axis; this stops it arriving as one.
  test('a negative axis reads as zero rather than staying negative', () {
    final op = _cells(_sceneWith(cols: -5, rows: -1));
    expect(op.cols, 0);
    expect(op.rows, 0);
  });

  test('a non-numeric axis still falls back to zero', () {
    final op = _cells(_sceneWith(cols: 'lots', rows: null));
    expect(op.cols, 0);
    expect(op.rows, 0);
  });

  test('the ceiling is well clear of what shipped modules ask for', () {
    // game-of-life 48x48, music-box 16x8, connect-four 7x6 as of 2026-09-22.
    expect(
      CellsOp.maxPerAxis,
      greaterThan(48),
      reason: 'a ceiling at or below real use would be a behaviour change',
    );
  });

  test('a non-finite number is treated as absent, not the scene', () {
    // Literal JSON: jsonEncode cannot emit an infinity, and a module sends text.
    final scene = parseModuleScene(
      '{"\$slim":"scene/1","width":100,"height":100,'
      '"ops":[{"op":"cells","cols":1e999,"rows":4,'
      '"data":"....","tap":"toggle"}]}',
    );

    expect(
      scene,
      isNotNull,
      reason:
          'a module emitting an infinity must not take the whole scene '
          "down; a module is somebody else's code",
    );
    final cells = scene!.ops.whereType<CellsOp>().single;
    expect(cells.cols, 0, reason: 'absent, not clamped to the ceiling');
    expect(cells.rows, 4);
  });

  test('an infinite offset never reaches the painter', () {
    final scene = parseModuleScene(
      '{"\$slim":"scene/1","width":100,"height":100,'
      '"ops":[{"op":"rect","x":1e999,"y":0,"w":10,"h":10}]}',
    );

    expect(scene, isNotNull);
    final rect = scene!.ops.whereType<RectOp>().single;
    expect(rect.x.isFinite, isTrue);
  });
}
