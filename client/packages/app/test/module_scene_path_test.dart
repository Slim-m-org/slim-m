// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `path` scene op: its `d` grammar, its ceiling, and the ways a malformed
/// string has to fail safely.
///
/// The parser is the interesting half. A module hands over a string, so every
/// case here is a string slim did not write, and the rule the whole op rests on
/// is that none of them throws: whatever parsed before the nonsense is kept and
/// the rest is dropped.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_painter.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_path.dart';

/// The single path op in a scene built around [d], or null if it was skipped.
PathOp? _pathOp(String d) {
  final scene = parseModuleScene(
    '{"\$slim":"scene/1","width":100,"height":100,'
    '"ops":[{"op":"path","d":"$d","fill":"accent"}]}',
  );
  final ops = scene?.ops ?? const [];
  return ops.length == 1 && ops.first is PathOp ? ops.first as PathOp : null;
}

void main() {
  group('the d grammar', () {
    test('absolute moves, lines and closes parse in order', () {
      final steps = parseScenePathData('M 10 10 L 50 10 L 50 50 Z');

      expect(steps.map((s) => s.kind), [
        ScenePathKind.move,
        ScenePathKind.line,
        ScenePathKind.line,
        ScenePathKind.close,
      ]);
      expect(steps[1].points, [50.0, 10.0]);
    });

    test('a lowercase command is relative to where the pen is', () {
      final steps = parseScenePathData('M 10 10 l 5 5');

      expect(steps[1].points, [15.0, 15.0]);
    });

    test('H and V each move one axis and hold the other', () {
      final steps = parseScenePathData('M 10 20 H 80 V 90');

      expect(steps[1].points, [80.0, 20.0], reason: 'H holds y');
      expect(steps[2].points, [80.0, 90.0], reason: 'V holds x');
    });

    test('close returns the pen to the start of the subpath', () {
      final steps = parseScenePathData('M 10 10 L 90 90 Z l 5 5');

      expect(
        steps.last.points,
        [15.0, 15.0],
        reason: 'the relative line after Z is relative to the M, not to 90,90',
      );
    });

    test('a repeated pair after M is an implicit line, as in SVG', () {
      final steps = parseScenePathData('M 0 0 10 10 20 20');

      expect(steps.map((s) => s.kind), [
        ScenePathKind.move,
        ScenePathKind.line,
        ScenePathKind.line,
      ]);
    });

    test('both bezier kinds carry their control points', () {
      final quad = parseScenePathData('M 0 0 Q 10 20 30 40');
      final cubic = parseScenePathData('M 0 0 C 1 2 3 4 5 6');

      expect(quad[1].kind, ScenePathKind.quad);
      expect(quad[1].points, [10.0, 20.0, 30.0, 40.0]);
      expect(cubic[1].kind, ScenePathKind.cubic);
      expect(cubic[1].points, [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]);
    });

    test('separators are insignificant: commas, minus signs and no spaces', () {
      final spaced = parseScenePathData('M 10 10 L -5 20');
      final packed = parseScenePathData('M10,10L-5,20');

      expect(packed.length, spaced.length);
      expect(packed[1].points, [-5.0, 20.0]);
    });

    test('a decimal point starts a new number when one is already running', () {
      final steps = parseScenePathData('M .5.5 L 1.5 2');

      expect(steps.first.points, [0.5, 0.5]);
    });
  });

  group('malformed input is truncated, never thrown', () {
    test('a command with too few numbers keeps what came before it', () {
      final steps = parseScenePathData('M 10 10 L 50 50 L 70');

      expect(steps.map((s) => s.kind), [
        ScenePathKind.move,
        ScenePathKind.line,
      ], reason: 'the trailing L had one number, so it is dropped whole');
    });

    test('numbers before any command parse to nothing', () {
      expect(parseScenePathData('10 20 30'), isEmpty);
    });

    test('a command this grammar does not draw with stops the walk', () {
      final steps = parseScenePathData('M 0 0 L 10 10 A 5 5 0 0 1 20 20');

      expect(steps.length, 2, reason: 'A is not admitted, so parsing stops');
    });

    test('junk between numbers does not throw', () {
      expect(
        () => parseScenePathData('M 0 0 L ?? 10 nonsense'),
        returnsNormally,
      );
    });

    test('an empty or whitespace d parses to nothing', () {
      expect(parseScenePathData(''), isEmpty);
      expect(parseScenePathData('   '), isEmpty);
    });
  });

  test('a path is bounded, so a huge d cannot run away', () {
    final d = 'M 0 0 ${'L 1 1 ' * (sceneMaxPathSteps + 200)}';

    expect(parseScenePathData(d).length, sceneMaxPathSteps);
  });

  group('the op in a scene', () {
    test('a well-formed path op reaches the scene', () {
      final op = _pathOp('M 10 10 L 90 90 Z');

      expect(op, isNotNull);
      expect(op!.fill, 'accent');
      expect(op.steps, hasLength(3));
    });

    test('a path whose d parses to nothing is skipped, not drawn empty', () {
      final scene = parseModuleScene(
        '{"\$slim":"scene/1","width":100,"height":100,'
        '"ops":[{"op":"path","d":"nonsense"}]}',
      );

      expect(scene, isNotNull, reason: 'the scene itself still parses');
      expect(scene!.ops, isEmpty, reason: 'but the unusable op is dropped');
    });

    test('a path op with no d at all is skipped', () {
      final scene = parseModuleScene(
        '{"\$slim":"scene/1","width":100,"height":100,'
        '"ops":[{"op":"path","fill":"accent"}]}',
      );

      expect(scene!.ops, isEmpty);
    });

    test('stroke width defaults to 1 and tap is optional', () {
      final op = _pathOp('M 0 0 L 10 10');

      expect(op!.strokeWidth, 1);
      expect(op.tap, isNull);
    });
  });

  group('painting and hit-testing', () {
    test('steps scale into the painted path by the same factors as any op', () {
      final steps = parseScenePathData('M 0 0 L 10 10');
      final bounds = buildScenePath(steps, 2, 3).getBounds();

      expect(bounds.right, 20, reason: 'x scaled by sx');
      expect(bounds.bottom, 30, reason: 'y scaled by sy');
    });

    test('a tap inside a filled path finds it, outside finds nothing', () {
      final scene = parseModuleScene(
        '{"\$slim":"scene/1","width":100,"height":100,"ops":[{"op":"path",'
        '"d":"M 0 0 L 100 0 L 100 100 L 0 100 Z","fill":"accent",'
        '"tap":"shape"}]}',
      )!;

      expect(
        sceneTapAction(scene, const Offset(50, 50), const Size(100, 100)),
        'shape',
      );
      expect(
        sceneTapAction(scene, const Offset(150, 150), const Size(100, 100)),
        isNull,
      );
    });

    test('a path with no tap is never what a tap lands on', () {
      final scene = parseModuleScene(
        '{"\$slim":"scene/1","width":100,"height":100,"ops":[{"op":"path",'
        '"d":"M 0 0 L 100 0 L 100 100 Z","fill":"accent"}]}',
      )!;

      expect(
        sceneTapAction(scene, const Offset(50, 50), const Size(100, 100)),
        isNull,
      );
    });
  });
}
