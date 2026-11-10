// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The ceilings `parseModuleScene` applies to what a module sends, checked by
/// exceeding each one: text size, field width and count, text count, duplicate
/// field names and the number of controls.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';

ModuleScene _scene(
  List<Map<String, Object?>> ops, {
  num width = 100,
  num height = 100,
  Object? controls,
}) => parseModuleScene(
  jsonEncode({
    r'$slim': 'scene/1',
    'width': width,
    'height': height,
    'ops': ops,
    'controls': ?controls,
  }),
)!;

Map<String, Object?> _text({Object? size, String s = 'hi'}) => {
  'op': 'text',
  'x': 1,
  'y': 1,
  's': s,
  'size': ?size,
};

Map<String, Object?> _input(String submit, {Object? w, String value = ''}) => {
  'op': 'input',
  'x': 1,
  'y': 1,
  'w': ?w,
  'submit': submit,
  'value': value,
};

void main() {
  group('text size', () {
    test('one far larger than the canvas is held to the canvas', () {
      final op = _scene([_text(size: 1e9)]).ops.single as TextOp;
      expect(op.size, 100);
    });

    test('the longer side of the canvas is the ceiling', () {
      final op =
          _scene([_text(size: 1e9)], width: 40, height: 10).ops.single
              as TextOp;
      expect(op.size, 40);
    });

    test('a size that is zero or negative reads as absent', () {
      for (final size in [0, -5]) {
        final op = _scene([_text(size: size)]).ops.single as TextOp;
        expect(op.size, TextOp.defaultSize, reason: '$size');
      }
    });

    test('an ordinary size passes through untouched', () {
      final sizes = _scene([
        _text(size: 1.8),
        _text(size: 16),
        _text(),
      ]).ops.cast<TextOp>().map((op) => op.size);
      expect(sizes, [1.8, 16, TextOp.defaultSize]);
    });
  });

  group('input width', () {
    test('a negative width becomes zero', () {
      final op = _scene([_input('go', w: -50)]).ops.single as InputOp;
      expect(op.w, 0);
    });

    test('a width past the canvas is held to it', () {
      final op = _scene([_input('go', w: 1e300)]).ops.single as InputOp;
      expect(op.w, 100);
    });

    test('a width inside the canvas passes through', () {
      final op = _scene([_input('go', w: 60)]).ops.single as InputOp;
      expect(op.w, 60);
    });
  });

  group('counts', () {
    test('text ops stop at the ceiling', () {
      final scene = _scene([for (var i = 0; i < 3000; i++) _text(s: '$i')]);
      final texts = scene.ops.cast<TextOp>();
      expect(texts, hasLength(TextOp.maxPerScene));
      expect(texts.first.text, '0', reason: 'the earliest are the ones kept');
    });

    test('input ops stop at the ceiling', () {
      final scene = _scene([for (var i = 0; i < 50; i++) _input('field$i')]);
      expect(scene.ops.whereType<InputOp>(), hasLength(InputOp.maxPerScene));
    });

    test('controls stop at the ceiling', () {
      final scene = _scene(
        const [],
        controls: [for (var i = 0; i < 500; i++) 'c$i'],
      );
      expect(scene.controls, hasLength(ModuleScene.maxControls));
      expect(scene.controls.first, 'c0');
    });

    test('a scene within every ceiling loses nothing', () {
      final scene = _scene(
        [_text(), _text(), _input('a'), _input('b')],
        controls: ['play', 'step'],
      );
      expect(scene.ops, hasLength(4));
      expect(scene.controls, ['play', 'step']);
    });
  });

  group('input names', () {
    test('a later field reusing a name is dropped', () {
      final scene = _scene([
        _input('guess', value: 'first'),
        _input('other'),
        _input('guess', value: 'second'),
      ]);
      final inputs = scene.ops.whereType<InputOp>().toList();
      expect(inputs.map((op) => op.submit), ['guess', 'other']);
      expect(inputs.first.value, 'first');
    });

    test('a duplicate does not use up the count', () {
      final scene = _scene([
        for (var i = 0; i < 40; i++) _input('same'),
        _input('another'),
      ]);
      expect(scene.ops.whereType<InputOp>().map((op) => op.submit), [
        'same',
        'another',
      ]);
    });
  });
}
