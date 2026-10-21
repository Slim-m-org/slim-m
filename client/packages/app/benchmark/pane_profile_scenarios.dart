// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The scripted scenarios, one board and call size at a time.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../voice_canvas/benchmark/board_fixture.dart';
import 'perf_voice.dart';
import 'pane_profile_host.dart';
import 'pane_profile_input.dart';
import 'pane_profile_measure.dart';

Future<List<Map<String, Object>>> runScenarios(
  BoardSpec spec,
  int participants,
  ui.Size size,
  double dpr,
) async {
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
  boardInputs(spec).forEach(engine.document.applyPlaced);
  for (var i = 0; i < spec.images; i++) {
    engine.document.setImageBitmap('image-$i', await solidBitmap(800, 600, i));
  }
  engine.document.refresh();
  await nextFrame();
  await nextFrame();

  final run = _Run(spec, participants, engine);
  final rows = <Map<String, Object>>[
    {
      'name': 'press point is on bare canvas, ${run.tag}',
      'value': hitsSurface(run.center) ? 1 : 0,
    },
    await run.pan(),
    await run.zoomSweep(),
    ...await run.drag(),
    await run.remoteCursors(),
    if (participants > 0) await run.speaking(),
    ...await run.draw(),
  ];
  host.show(const SizedBox.shrink());
  await nextFrame();
  container.dispose();
  return rows;
}

/// One board and call size, with the geometry every scenario reads.
class _Run {
  _Run(this.spec, this.participants, this.engine)
    : doc = engine.document,
      box = surfaceBox() {
    origin = box.localToGlobal(Offset.zero);
    center = freeSpot(box);
  }

  final BoardSpec spec;
  final int participants;
  final CanvasEngine engine;
  final CanvasDocument doc;
  final RenderBox box;
  late final Offset origin;
  late final Offset center;

  String get tag => '${spec.label}, $participants on call';

  Offset screenOf(double wx, double wy) =>
      origin +
      Offset(
        (wx - doc.camera.x) * doc.camera.zoom,
        (wy - doc.camera.y) * doc.camera.zoom,
      );

  Future<Map<String, Object>> pan() async {
    doc.setCamera(const Camera(x: 700, y: 300, zoom: 2));
    await nextFrame();
    return measure('pan, $tag', () async {
      sendPointer(pointerDown(center, kMiddleMouseButton));
      var at = center;
      for (var i = 0; i < 300; i++) {
        final delta = Offset(i.isEven ? 3 : -3, 1);
        at += delta;
        timedSend(pointerMove(at, delta, kMiddleMouseButton));
        await nextFrame();
      }
      sendPointer(pointerUp(at));
    });
  }

  Future<Map<String, Object>> zoomSweep() async {
    doc.setCamera(const Camera(x: 400, y: 200, zoom: 1.5));
    await nextFrame();
    return measure('zoom sweep, $tag', () async {
      for (var i = 0; i < 360; i++) {
        timedSend(
          PointerScaleEvent(
            viewId: viewId,
            position: center,
            scale: (i ~/ 45).isEven ? 1.04 : 1 / 1.04,
            kind: PointerDeviceKind.mouse,
            device: 31,
          ),
        );
        await nextFrame();
      }
    });
  }

  /// The topmost image or note that is not covered, else the first stroke.
  String _grabbableId() {
    final order = [
      for (var i = spec.images - 1; i >= 0; i--) 'image-$i',
      for (var i = spec.notes - 1; i >= 0; i--) 'note-$i',
    ];
    final above = <Rect>[];
    for (final candidate in order) {
      final cb = doc.objectBounds(candidate)!;
      final mid = Offset(cb.x + cb.w / 2, cb.y + cb.h / 2);
      if (hitsSurface(screenOf(mid.dx, mid.dy)) &&
          !above.any((r) => r.contains(mid))) {
        return candidate;
      }
      above.add(Rect.fromLTWH(cb.x, cb.y, cb.w, cb.h));
    }
    return 'stroke-0';
  }

  Future<List<Map<String, Object>>> drag() async {
    doc.fitBoard();
    await nextFrame();
    final id = _grabbableId();
    final b = doc.objectBounds(id)!;
    final grab = screenOf(b.x + b.w / 2, b.y + b.h / 2);
    final row = await measure('drag $id, $tag', () async {
      sendPointer(pointerDown(grab, kPrimaryButton));
      var at = grab;
      for (var i = 0; i < 300; i++) {
        final next = grab + Offset(i * 1.0, (i % 40).toDouble());
        timedSend(pointerMove(next, next - at, kPrimaryButton));
        at = next;
        await nextFrame();
      }
      sendPointer(pointerUp(at));
    });
    final moved = doc.objectBounds(id)!;
    debugPrint(
      'drag moved $id by ${(moved.x - b.x).toStringAsFixed(1)} world px',
    );
    return [
      row,
      {'name': 'drag moved $id by world px, $tag', 'value': moved.x - b.x},
    ];
  }

  Future<Map<String, Object>> remoteCursors() =>
      measure('remote cursors (8 moving), $tag', () async {
        for (var i = 0; i < 300; i++) {
          for (var u = 0; u < 8; u++) {
            engine.cursors.upsert(
              id: 'user-${u + 1}',
              x: 200.0 + u * 150 + i,
              y: 300 + (i % 60) * 4,
              label: 'User $u',
              colorIndex: u,
            );
          }
          await nextFrame();
        }
      });

  Future<Map<String, Object>> speaking() =>
      measure('someone starts/stops speaking, $tag', () async {
        for (var i = 0; i < 300; i++) {
          if (i % 6 == 0) {
            voice!.set(
              callOf(
                participants,
                speaking: (i ~/ 6).isEven ? {1 + (i ~/ 12) % 20} : {},
              ),
            );
          }
          await nextFrame();
        }
      });

  Future<List<Map<String, Object>>> draw() async {
    await selectTool('Pen');
    final before = doc.objectCount.value;
    final row = await measure('draw 6 strokes, $tag', () async {
      for (var s = 0; s < 6; s++) {
        var at = origin + Offset(200.0 + s * 140, 200);
        sendPointer(pointerDown(at, kPrimaryButton));
        for (var i = 1; i <= 100; i++) {
          final next =
              origin +
              Offset(200.0 + s * 140 + 90 * (i % 40) / 40, 200 + i * 2.5);
          timedSend(pointerMove(next, next - at, kPrimaryButton));
          at = next;
          await nextFrame();
        }
        sendPointer(pointerUp(at));
        await nextFrame();
      }
    });
    final added = doc.objectCount.value - before;
    debugPrint('draw added $added strokes');
    return [
      row,
      {'name': 'strokes the draw scenario added, $tag', 'value': added},
    ];
  }
}
