// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Voice Canvas reopens where you left it: closing and reopening a
/// channel's canvas, or relaunching, restores that channel's camera, and a
/// channel never opened before starts at the world origin.
library;

import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

const _moved = Camera(x: 500, y: 300, zoom: 1.5);

Future<CanvasEngine> _open(
  ProviderContainer container,
  String channelId,
  List<ProviderSubscription<Object?>> subs,
) async {
  subs.add(container.listen(canvasEngineProvider(channelId), (_, _) {}));
  final engine = container.read(canvasEngineProvider(channelId).notifier);
  engine.document.setViewport(const Size(800, 600));
  await container.pump();
  // The remembered camera may load from disk after the first frame.
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return engine;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('reopening a canvas restores where you left it', () async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    final subs = <ProviderSubscription<Object?>>[];

    final first = await _open(container, 'c1', subs);
    first.document.setCamera(_moved);
    subs.removeLast().close();
    await container.pump();
    expect(first.mounted, isFalse, reason: 'closing disposes the engine');

    final again = await _open(container, 'c1', subs);
    expect(again.document.camera, _moved);

    final other = await _open(container, 'c2', subs);
    expect(other.document.camera, const Camera(), reason: 'per channel');
    for (final s in subs) {
      s.close();
    }
  });

  test('a relaunch restores it too', () async {
    final fixture = CanvasPaneFixture();
    final before = fixture.container();
    addTearDown(fixture.events.close);
    final subs = <ProviderSubscription<Object?>>[];
    final engine = await _open(before, 'c1', subs);
    engine.document.setCamera(_moved);
    subs.removeLast().close();
    await before.pump();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    before.dispose();

    final after = fixture.container();
    addTearDown(after.dispose);
    final reopened = await _open(after, 'c1', subs);
    expect(reopened.document.camera, _moved);
    subs.removeLast().close();
  });

  test(
    'a camera you already moved is never overwritten by a late load',
    () async {
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      SharedPreferences.setMockInitialValues({
        'slimm.canvas.cameras.v1': '{"c1":[500.0,300.0,1.5]}',
      });
      final sub = container.listen(canvasEngineProvider('c1'), (_, _) {});
      addTearDown(sub.close);
      final engine = container.read(canvasEngineProvider('c1').notifier);
      engine.document.setViewport(const Size(800, 600));
      const mine = Camera(x: -200, y: 40);
      engine.document.setCamera(mine);
      await container.pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.document.camera, mine);
    },
  );
}
