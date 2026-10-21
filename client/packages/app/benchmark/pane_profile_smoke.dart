// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A short diagnostic of the profile run's own input: where the surface sits,
/// whether a press on it reaches it, and whether strokes land.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../voice_canvas/benchmark/board_fixture.dart';
import 'pane_profile_host.dart';
import 'pane_profile_input.dart';

Future<List<Map<String, Object>>> runSmoke(int participants) async {
  final container = makeContainer(participants);
  host.show(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(body: CanvasPane(channelId: 'c1')),
      ),
    ),
  );
  await Future<void>.delayed(const Duration(seconds: 1));
  await nextFrame();
  final doc = container.read(canvasEngineProvider('c1').notifier).document;
  boardInputs(const BoardSpec(strokes: 50)).forEach(doc.applyPlaced);
  doc.refresh();
  await nextFrame();
  doc.fitBoard();
  await nextFrame();
  final box = surfaceBox();
  final origin = box.localToGlobal(Offset.zero);
  void say(String text) => debugPrint('smoke[$participants] $text');
  say(
    'surface at $origin size ${box.size}, zoom ${doc.camera.zoom}, '
    'viewport ${doc.viewport}, board ${doc.board}, tiles ${tileRects().length}',
  );
  await selectTool('Pen');
  for (var s = 0; s < 6; s++) {
    final start = origin + Offset(200.0 + s * 140, 200);
    final before = doc.objectCount.value;
    say('stroke $s starts at $start on surface ${hitsSurface(start)}');
    var at = start;
    sendPointer(pointerDown(at, kPrimaryButton));
    for (var i = 1; i <= 100; i++) {
      final next = start + Offset(90 * (i % 40) / 40, i * 2.5);
      sendPointer(pointerMove(next, next - at, kPrimaryButton));
      at = next;
      await nextFrame();
    }
    sendPointer(pointerUp(at));
    await nextFrame();
    await nextFrame();
    say('stroke $s: objects $before -> ${doc.objectCount.value}');
  }
  host.show(const SizedBox.shrink());
  await nextFrame();
  container.dispose();
  return const [];
}
