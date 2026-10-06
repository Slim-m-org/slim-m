// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a scene's images may cost to decode: the cache must settle on a scene
/// that is over its byte budget instead of evicting its own images forever,
/// and a small payload must not be able to declare a huge bitmap.
///
/// Bounds are asserted by counting decode completions and bytes held, never
/// by how long anything took.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/module_scene.dart';
import 'package:slimm_app/src/widgets/module_scene_images.dart';

import 'support/synthetic_png.dart';

ModuleScene _sceneOf(List<Uint8List> pngs) {
  final ops = [
    for (final (i, png) in pngs.indexed)
      '{"op":"image","x":${i * 30},"y":0,"w":30,"h":30,'
          '"b64":"${base64Encode(png)}"}',
  ];
  return parseModuleScene(
    '{"\$slim":"scene/1","width":100,"height":100,"ops":[${ops.join(',')}]}',
  )!;
}

/// Mimics `ModuleSceneView`: every notify re-reads the snapshot.
class _ViewLoop {
  _ViewLoop(this.cache, this.scene) {
    cache.addListener(() {
      decodes++;
      cache.snapshot(scene);
    });
  }

  final SceneImageCache cache;
  ModuleScene scene;
  int decodes = 0;

  int get ready => cache.snapshot(scene).length;

  /// Runs until every image is ready or [decodeBudget] completions have been
  /// spent, so a loop that never settles ends on its own counter.
  Future<void> settle(WidgetTester tester, {int decodeBudget = 12}) =>
      tester.runAsync(() async {
        cache.snapshot(scene);
        final total = scene.ops.whereType<ImageOp>().length;
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (ready < total &&
            decodes < decodeBudget &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
}

void main() {
  testWidgets('a scene over the byte budget settles with every image shown', (
    tester,
  ) async {
    // Three 900x900 bitmaps are 9.7 MB against the 8 MiB default.
    late ModuleScene scene;
    await tester.runAsync(() async {
      scene = _sceneOf([
        for (var i = 0; i < 3; i++) solidPng(900, 900, shade: i * 40 + 1),
      ]);
    });
    final cache = SceneImageCache();
    addTearDown(cache.dispose);
    final loop = _ViewLoop(cache, scene);

    await loop.settle(tester);

    expect(loop.ready, 3, reason: 'every image of the scene on screen at once');
    expect(
      loop.decodes,
      lessThanOrEqualTo(3),
      reason: 'each image decodes once, then the scene stops decoding',
    );
  });

  testWidgets('an image the scene no longer shows is what gets evicted', (
    tester,
  ) async {
    late ModuleScene first;
    late ModuleScene second;
    await tester.runAsync(() async {
      first = _sceneOf([solidPng(900, 900)]);
      second = _sceneOf([solidPng(900, 901)]);
    });
    final cache = SceneImageCache(maxDecodedBytes: 4 * 1024 * 1024);
    addTearDown(cache.dispose);

    final loop = _ViewLoop(cache, first);
    await loop.settle(tester);
    expect(cache.snapshot(first), contains((first.ops.single as ImageOp).key));

    loop.scene = second;
    await loop.settle(tester);

    expect(cache.snapshot(second), hasLength(1));
    expect(
      cache.decodedBytes,
      lessThanOrEqualTo(900 * 901 * 4),
      reason: 'the first scene is gone, so only the second image is held',
    );
  });

  testWidgets('a tiny png declaring a huge bitmap is refused before decoding', (
    tester,
  ) async {
    late ModuleScene scene;
    late Uint8List png;
    await tester.runAsync(() async {
      png = blankBilevelPng(12000, 12000);
      scene = _sceneOf([png]);
    });
    expect(png.length, lessThan(ImageOp.maxEncodedLength));
    final cache = SceneImageCache();
    addTearDown(cache.dispose);
    final op = scene.ops.single as ImageOp;

    await tester.runAsync(() async {
      cache.snapshot(scene);
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!cache.hasFailed(op.key) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });

    expect(cache.hasFailed(op.key), isTrue);
    expect(cache.decodedBytes, 0, reason: 'nothing was decoded or held');
  });

  testWidgets('an image under the pixel ceiling decodes at a bounded size', (
    tester,
  ) async {
    late ModuleScene scene;
    await tester.runAsync(() async {
      scene = _sceneOf([solidPng(2000, 1000)]);
    });
    final cache = SceneImageCache();
    addTearDown(cache.dispose);

    await _ViewLoop(cache, scene).settle(tester);

    final image = cache.snapshot(scene).values.single;
    expect(image.width, lessThanOrEqualTo(sceneImageMaxSide));
    expect(image.height, lessThanOrEqualTo(sceneImageMaxSide));
    expect(image.width / image.height, closeTo(2, 0.01));
  });
}
