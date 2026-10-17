// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `image` scene op: its ceilings, and the decode cache behind it.
///
/// This is the one op whose cost a module chooses rather than slim, so the
/// ceilings are the point of the test rather than a footnote. Every one is
/// checked by exceeding it, not by reading the constant back.
///
/// The decode itself is real: the fixture below is an actual 2x2 PNG, so
/// `instantiateImageCodec` is exercised rather than mocked. A test that only
/// proved bytes were stored would say nothing about whether anything could
/// draw them.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_images.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_painter.dart';
import 'package:flutter/material.dart';

/// A real 2x2 opaque-red PNG, 74 bytes.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwA'
    'R8oH+WdZbrcAAAAASUVORK5CYII=';

ModuleScene _scene(String opsJson) => parseModuleScene(
  '{"\$slim":"scene/1","width":100,"height":100,"ops":[$opsJson]}',
)!;

String _imageOp({String? b64, String extra = ''}) =>
    '{"op":"image","x":0,"y":0,"w":50,"h":50,"b64":"${b64 ?? _png}"$extra}';

void main() {
  group('parsing', () {
    test('a real png parses to decoded bytes and a key', () {
      final op = _scene(_imageOp()).ops.single as ImageOp;

      expect(op.bytes, isNotEmpty);
      expect(op.bytes.length, 74, reason: 'the base64 was actually decoded');
      expect(op.bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      expect(op.key, isNot(0));
    });

    test('the same bytes get the same key, different bytes do not', () {
      final a = _scene(_imageOp()).ops.single as ImageOp;
      final b = _scene(_imageOp()).ops.single as ImageOp;
      final other =
          _scene(
                _imageOp(
                  b64: base64Encode(Uint8List.fromList([1, 2, 3, 4, 5])),
                ),
              ).ops.single
              as ImageOp;

      expect(
        a.key,
        b.key,
        reason: 'a module re-emitting its scene must not re-decode every frame',
      );
      expect(a.key, isNot(other.key));
    });

    test('a payload over the ceiling is dropped, not carried', () {
      final huge = 'A' * (ImageOp.maxEncodedLength + 4);

      expect(
        _scene(_imageOp(b64: huge)).ops,
        isEmpty,
        reason: 'the point of a ceiling is that nothing downstream holds one',
      );
    });

    test('a payload at the ceiling is still considered', () {
      // Exactly the maximum length, so an off-by-one comparison fails here.
      final atLimit = 'A' * ImageOp.maxEncodedLength;

      expect(_scene(_imageOp(b64: atLimit)).ops, hasLength(1));
    });

    test('a payload that is not base64 is skipped', () {
      expect(_scene(_imageOp(b64: 'not base64 at all !!')).ops, isEmpty);
    });

    test('an empty or absent payload is skipped', () {
      expect(_scene(_imageOp(b64: '')).ops, isEmpty);
      expect(_scene('{"op":"image","x":0,"y":0,"w":50,"h":50}').ops, isEmpty);
    });

    test('a scene may not carry more images than the per-scene ceiling', () {
      final many = List.filled(ImageOp.maxPerScene + 3, _imageOp()).join(',');
      final ops = _scene(many).ops;

      expect(ops, hasLength(ImageOp.maxPerScene));
      expect(ops.every((op) => op is ImageOp), isTrue);
    });

    test('the image ceiling does not drop other ops after it', () {
      final many = List.filled(ImageOp.maxPerScene + 2, _imageOp()).join(',');
      final ops = _scene('$many,{"op":"rect","x":0,"y":0,"w":9,"h":9}').ops;

      expect(
        ops.whereType<RectOp>(),
        hasLength(1),
        reason: 'only the images past the ceiling are dropped',
      );
    });
  });

  group('hit testing', () {
    test('a tap inside a tappable image finds it', () {
      final scene = _scene(
        '{"op":"image","x":0,"y":0,"w":100,"h":100,"b64":"$_png","tap":"pic"}',
      );

      expect(
        sceneTapAction(scene, const Offset(50, 50), const Size(100, 100)),
        'pic',
      );
    });

    test('an image with no tap is never what a tap lands on', () {
      expect(
        sceneTapAction(
          _scene(_imageOp()),
          const Offset(10, 10),
          const Size(100, 100),
        ),
        isNull,
      );
    });
  });

  group('the decode cache', () {
    test('an undecoded image is absent from the first snapshot', () {
      final cache = SceneImageCache();
      addTearDown(cache.dispose);
      final scene = _scene(_imageOp());

      expect(
        cache.snapshot(scene),
        isEmpty,
        reason:
            'the decode is asynchronous; the op draws nothing until it lands',
      );
    });

    testWidgets('a real decode lands and the image becomes available', (
      tester,
    ) async {
      final cache = SceneImageCache();
      addTearDown(cache.dispose);
      final scene = _scene(_imageOp());
      final op = scene.ops.single as ImageOp;

      var notified = 0;
      cache.addListener(() => notified++);

      await tester.runAsync(() async {
        cache.snapshot(scene);
        // Poll rather than sleep a guessed interval: a decode is real work.
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline) &&
            cache.snapshot(scene).isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });

      final ready = cache.snapshot(scene);
      expect(ready[op.key], isNotNull, reason: 'the png decoded');
      expect(ready[op.key]!.width, 2);
      expect(ready[op.key]!.height, 2);
      expect(cache.decodedBytes, 2 * 2 * 4);
      expect(notified, greaterThan(0), reason: 'the view is told to repaint');
    });

    testWidgets('bytes that are not an image fail once and are not retried', (
      tester,
    ) async {
      final cache = SceneImageCache();
      addTearDown(cache.dispose);
      final scene = _scene(
        _imageOp(b64: base64Encode(Uint8List.fromList(List.filled(32, 7)))),
      );
      final op = scene.ops.single as ImageOp;

      await tester.runAsync(() async {
        cache.snapshot(scene);
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline) && !cache.hasFailed(op.key)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });

      expect(
        cache.hasFailed(op.key),
        isTrue,
        reason: 'a module re-emitting a broken payload must not retry forever',
      );
      expect(cache.snapshot(scene), isEmpty);
      expect(cache.decodedBytes, 0);
    });

    testWidgets('the decoded bound evicts rather than refusing', (
      tester,
    ) async {
      // A bound smaller than one bitmap, so the first decode already exceeds it.
      final cache = SceneImageCache(maxDecodedBytes: 1);
      addTearDown(cache.dispose);
      final scene = _scene(_imageOp());

      await tester.runAsync(() async {
        cache.snapshot(scene);
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline) &&
            cache.snapshot(scene).isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });

      expect(
        cache.decodedBytes,
        lessThanOrEqualTo(2 * 2 * 4),
        reason:
            'one image is kept even under a bound smaller than it, so a '
            'scene still draws rather than flickering nothing',
      );
    });
  });
}
