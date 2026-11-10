// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What painting a scene costs per frame: a text op must not leave its laid-out
/// paragraph behind, and a rebuild that decoded nothing new must not repaint.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_painter.dart';
import 'package:slimm_design_system/design_system.dart';

ModuleScene _texts(int count) => parseModuleScene(
  '{"\$slim":"scene/1","width":100,"height":100,"ops":['
  '${List.generate(count, (i) => '{"op":"text","x":10,"y":${10 + i * 10},"s":"row $i"}').join(',')}'
  ']}',
)!;

ModuleScenePainter _painter(ModuleScene scene, Map<int, ui.Image> images) =>
    ModuleScenePainter(scene: scene, tokens: AppTokens.light, images: images);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every TextPainter a paint lays out is disposed', () {
    final created = <TextPainter>{};
    final disposed = <TextPainter>{};
    void listen(ObjectEvent event) {
      final object = event.object;
      if (object is! TextPainter) return;
      (event is ObjectCreated ? created : disposed).add(object);
    }

    FlutterMemoryAllocations.instance.addListener(listen);
    addTearDown(() => FlutterMemoryAllocations.instance.removeListener(listen));

    _painter(
      _texts(3),
      const {},
    ).paint(ui.Canvas(ui.PictureRecorder()), const ui.Size(100, 100));

    expect(created, hasLength(3));
    expect(disposed, created);
  });

  test('text still reaches the canvas once its painter is disposed', () async {
    final recorder = ui.PictureRecorder();
    const size = ui.Size(100, 100);
    _painter(_texts(1), const {}).paint(ui.Canvas(recorder), size);
    final image = await recorder.endRecording().toImage(100, 100);
    final bytes = (await image.toByteData())!;
    image.dispose();

    final background = bytes.getUint32(0);
    var differing = 0;
    for (var i = 0; i < bytes.lengthInBytes; i += 4) {
      if (bytes.getUint32(i) != background) differing++;
    }
    expect(differing, greaterThan(0));
  });

  group('shouldRepaint', () {
    late ui.Image a;
    late ui.Image b;
    final scene = _texts(1);

    setUp(() async {
      a = await createTestImage(width: 1, height: 1);
      b = await createTestImage(width: 1, height: 1);
    });

    tearDown(() {
      a.dispose();
      b.dispose();
    });

    test('a fresh map holding the same decoded images does not repaint', () {
      expect(
        _painter(scene, {1: a}).shouldRepaint(_painter(scene, {1: a})),
        isFalse,
      );
    });

    test('a newly decoded image repaints', () {
      expect(
        _painter(scene, {1: a, 2: b}).shouldRepaint(_painter(scene, {1: a})),
        isTrue,
      );
    });

    test('an image replaced under the same key repaints', () {
      expect(
        _painter(scene, {1: b}).shouldRepaint(_painter(scene, {1: a})),
        isTrue,
      );
    });

    test('an evicted image repaints', () {
      expect(
        _painter(scene, const {}).shouldRepaint(_painter(scene, {1: a})),
        isTrue,
      );
    });
  });
}
