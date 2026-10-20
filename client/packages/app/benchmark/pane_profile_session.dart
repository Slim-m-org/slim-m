// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A scripted collaborative session in real time, sampled for memory.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../voice_canvas/benchmark/board_fixture.dart';
import '../../voice_canvas/benchmark/perf_support.dart';
import 'perf_voice.dart';
import 'pane_profile_host.dart';
import 'pane_profile_input.dart';
import 'pane_profile_measure.dart';

Future<List<Map<String, Object>>> runSession() async {
  final seconds = int.parse(Platform.environment['PANE_SESSION_S'] ?? '300');
  const spec = BoardSpec(strokes: 1000, notes: 200, images: 50);
  const participants = 25;
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
  final engine = container.read(canvasEngineProvider('c1').notifier);
  final doc = engine.document;
  boardInputs(spec).forEach(doc.applyPlaced);
  for (var i = 0; i < spec.images; i++) {
    doc.setImageBitmap('image-$i', await solidBitmap(800, 600, i));
  }
  doc.refresh();
  await nextFrame();
  final box = surfaceBox();
  final origin = box.localToGlobal(Offset.zero);
  Offset screenOf(double wx, double wy) =>
      origin +
      Offset(
        (wx - doc.camera.x) * doc.camera.zoom,
        (wy - doc.camera.y) * doc.camera.zoom,
      );
  final center = freeSpot(box);
  final samples = <Map<String, Object>>[];
  final timings = <ui.FrameTiming>[];
  frameSink = timings;
  final clock = Stopwatch()..start();
  var seq = 100000;
  var cycle = 0;

  void sample() {
    final row = <String, Object>{
      't_s': clock.elapsed.inSeconds,
      'rss_kb': rssKb(),
      'grid_slots': doc.scene.slotCount,
      'live_objects': doc.objectCount.value,
      'cycle': cycle,
    };
    samples.add(row);
    debugPrint('session $row');
  }

  Future<void> drag(
    Offset from,
    Offset Function(int) at,
    int n,
    int buttons,
  ) async {
    sendPointer(pointerDown(from, buttons));
    var last = from;
    for (var i = 1; i <= n; i++) {
      final next = at(i);
      timedSend(pointerMove(next, next - last, buttons));
      last = next;
      await nextFrame();
    }
    sendPointer(pointerUp(last));
    await nextFrame();
  }

  sample();
  while (clock.elapsed.inSeconds < seconds) {
    cycle++;
    await selectTool('Pen');
    for (var s = 0; s < 2; s++) {
      final from = origin + Offset(300.0 + s * 200 + cycle % 7 * 20, 250);
      await drag(
        from,
        (i) => from + Offset(70 * (i % 30) / 30, i * 3.0),
        60,
        kPrimaryButton,
      );
    }
    await selectTool('Eraser');
    final sweepFrom = origin + const Offset(250, 200);
    await drag(
      sweepFrom,
      (i) => sweepFrom + Offset(i * 9.0, i * 4.0 + (i.isEven ? 15 : -15)),
      60,
      kPrimaryButton,
    );
    await selectTool('Pan');
    final img = doc.objectBounds('image-${cycle % 50}');
    if (img != null) {
      final grab = screenOf(img.x + img.w / 2, img.y + img.h / 2);
      if (hitsSurface(grab)) {
        await drag(
          grab,
          (i) => grab + Offset(i * 1.5, (i % 30).toDouble()),
          40,
          kPrimaryButton,
        );
      }
    }
    await engine.ops.undo();
    doc.setCamera(const Camera(x: 700, y: 300, zoom: 2));
    await drag(
      center,
      (i) => center + Offset(i.isEven ? 3 : -3, 1) * (i / 2),
      40,
      kMiddleMouseButton,
    );
    for (var i = 0; i < 40; i++) {
      timedSend(
        PointerScaleEvent(
          viewId: viewId,
          position: center,
          scale: i < 20 ? 1.04 : 1 / 1.04,
          kind: PointerDeviceKind.mouse,
          device: 31,
        ),
      );
      await nextFrame();
    }
    doc.fitBoard();
    for (var f = 0; f < 90; f++) {
      if (f % 5 == 0) {
        for (var u = 0; u < 8; u++) {
          engine.cursors.upsert(
            id: 'user-${u + 1}',
            x: 200.0 + u * 150 + f * 3,
            y: 300 + (f % 60) * 4,
            label: 'User $u',
            colorIndex: u,
          );
        }
        engine.remoteDrafts.appendOrCreate(
          objectId: 'remote-$cycle',
          authorId: 'user-2',
          points: [
            100.0 + f * 4,
            500.0 + (f % 30) * 3,
            104.0 + f * 4,
            503.0 + (f % 30) * 3,
          ],
          colorIndex: 2,
        );
      }
      if (f % 12 == 0) {
        voice!.set(
          callOf(
            participants,
            speaking: (f ~/ 12).isEven ? {1 + cycle % 20} : {},
          ),
        );
      }
      await nextFrame();
    }
    engine.remoteDrafts.end('remote-$cycle');
    for (var k = 0; k < 3; k++) {
      final remote = boardInputs(
        BoardSpec(strokes: 1, seed: cycle * 7 + k),
      ).first;
      doc.applyPlaced(
        CanvasStrokeInput(
          id: 'remote-$cycle-$k',
          seq: ++seq,
          zIndex: seq,
          x: remote.x,
          y: remote.y,
          w: remote.w,
          h: remote.h,
          points: remote.points,
          width: 3,
          colorKey: 'blue',
          authorId: 'user-2',
        ),
      );
    }
    doc.refresh();
    await nextFrame();
    sample();
  }
  frameSink = null;
  await Future<void>.delayed(const Duration(milliseconds: 800));
  Dist us(Duration Function(ui.FrameTiming) pick) =>
      Dist(timings.map((t) => pick(t).inMicroseconds.toDouble()));
  final total = us((t) => t.totalSpan);
  final build = us((t) => t.buildDuration);
  final raster = us((t) => t.rasterDuration);
  debugPrint(
    'session frames ${timings.length}: total p99 ${(total.p99 / 1000).toStringAsFixed(2)} ms, '
    '>16.7 ${(total.over(budget60Us) * 100).toStringAsFixed(1)}%, >33 ${(total.over(33333) * 100).toStringAsFixed(1)}%, '
    '>50 ${(total.over(50000) * 100).toStringAsFixed(1)}%',
  );
  host.show(const SizedBox.shrink());
  await nextFrame();
  container.dispose();
  return [
    for (final row in samples) {'name': 'session sample', ...row},
    {
      'name': 'session frame timings',
      'frames': timings.length,
      'build': build.toJson(),
      'raster': raster.toJson(),
      'total': total.toJson(),
      'over_33ms': total.over(33333),
      'over_50ms': total.over(50000),
    },
  ];
}
