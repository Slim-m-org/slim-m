// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Gradient fills on `rect` and `circle`: how they parse, and the ways a
/// half-stated one has to fail safely.
///
/// The rule everything here rests on is that a gradient must never be able to
/// take a shape down with it. A module that half-states one gets the shape with
/// its flat fill, not a missing shape and not a crash.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';

ModuleScene _scene(String opsJson) => parseModuleScene(
  '{"\$slim":"scene/1","width":100,"height":100,"ops":[$opsJson]}',
)!;

RectOp _rect(String extra) =>
    _scene('{"op":"rect","x":0,"y":0,"w":50,"h":50$extra}').ops.single
        as RectOp;

void main() {
  test('both stops and a direction parse', () {
    final op = _rect(',"grad":{"from":"accent","to":"bg","dir":"h"}');

    expect(op.gradient, isNotNull);
    expect(op.gradient!.from, 'accent');
    expect(op.gradient!.to, 'bg');
    expect(op.gradient!.direction, 'h');
  });

  test('a missing direction defaults to vertical', () {
    expect(
      _rect(',"grad":{"from":"accent","to":"bg"}').gradient!.direction,
      'v',
    );
  });

  test('an unknown direction is read as vertical, not refused', () {
    // The painter is what treats an unknown direction as vertical, not this.
    expect(
      _rect(
        ',"grad":{"from":"accent","to":"bg","dir":"sideways"}',
      ).gradient!.direction,
      'sideways',
      reason: 'kept as sent; the painter is what treats it as vertical',
    );
  });

  group('a half-stated gradient is no gradient, and the shape survives', () {
    test('only one stop', () {
      final op = _rect(',"fill":"accent","grad":{"from":"accent"}');

      expect(op.gradient, isNull);
      expect(op.fill, 'accent', reason: 'it falls back to the flat fill');
    });

    test('neither stop', () {
      expect(_rect(',"grad":{"dir":"h"}').gradient, isNull);
    });

    test('grad is not an object at all', () {
      expect(_rect(',"grad":"accent"').gradient, isNull);
      expect(_rect(',"grad":42').gradient, isNull);
      expect(_rect(',"grad":[]').gradient, isNull);
    });

    test('the rect itself still parses in every one of those cases', () {
      for (final bad in ['{"from":"accent"}', '{}', '"accent"', '42', '[]']) {
        final scene = _scene(
          '{"op":"rect","x":0,"y":0,"w":50,"h":50,"grad":$bad}',
        );
        expect(scene.ops, hasLength(1), reason: 'grad $bad dropped the shape');
      }
    });
  });

  test('a circle takes one too', () {
    final op =
        _scene(
              '{"op":"circle","cx":50,"cy":50,"r":20,'
              '"grad":{"from":"accent","to":"muted","dir":"d"}}',
            ).ops.single
            as CircleOp;

    expect(op.gradient!.direction, 'd');
    expect(op.gradient!.from, 'accent');
  });

  test('a hex stop is carried through like any other colour', () {
    final op = _rect(',"grad":{"from":"#ff0000","to":"#00ff00"}');

    expect(op.gradient!.from, '#ff0000');
    expect(
      op.gradient!.to,
      '#00ff00',
      reason: 'resolveSceneColor handles hex, so the parser need not',
    );
  });

  test('a shape with no gradient is unaffected', () {
    expect(_rect(',"fill":"accent"').gradient, isNull);
    expect(_rect('').gradient, isNull);
  });
}
