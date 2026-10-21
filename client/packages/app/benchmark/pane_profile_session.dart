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

const _spec = BoardSpec(strokes: 1000, notes: 200, images: 50);
const _participants = 25;

Future<List<Map<String, Object>>> runSession() async {
  final seconds = int.parse(Platform.environment['PANE_SESSION_S'] ?? '300');
  final container = makeContainer(_participants);
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
  boardInputs(_spec).forEach(engine.document.applyPlaced);
  for (var i = 0; i < _spec.images; i++) {
    engine.document.setImageBitmap('image-$i', await solidBitmap(800, 600, i));
  }
  engine.document.refresh();
  await nextFrame();
  final session = _Session(engine);
  await session.play(seconds);
  final rows = await session.report();
  host.show(const SizedBox.shrink());
  await nextFrame();
  container.dispose();
  return rows;
}

/// One scripted session: repeated cycles of drawing, erasing, moving and live traffic.
class _Session {
  _Session(this.engine) : doc = engine.document {
    origin = surfaceBox().localToGlobal(Offset.zero);
    center = freeSpot(surfaceBox());
  }

  final CanvasEngine engine;
  final CanvasDocument doc;
  late final Offset origin;
  late final Offset center;
  final samples = <Map<String, Object>>[];
  final timings = <ui.FrameTiming>[];
  final clock = Stopwatch();
  var _seq = 100000;
  var _cycle = 0;

  Offset _screenOf(double wx, double wy) =>
      origin +
      Offset(
        (wx - doc.camera.x) * doc.camera.zoom,
        (wy - doc.camera.y) * doc.camera.zoom,
      );

  void _sample() {
    final row = <String, Object>{
      't_s': clock.elapsed.inSeconds,
      'rss_kb': rssKb(),
      'grid_slots': doc.scene.slotCount,
      'live_objects': doc.objectCount.value,
      'cycle': _cycle,
    };
    samples.add(row);
    debugPrint('session $row');
  }

  Future<void> _drag(
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

  Future<void> play(int seconds) async {
    frameSink = timings;
    clock.start();
    _sample();
    while (clock.elapsed.inSeconds < seconds) {
      _cycle++;
      await _drawAndErase();
      await _moveAnImage();
      await engine.ops.undo();
      await _panAndZoom();
      doc.fitBoard();
      await _liveTraffic();
      await _remoteStrokes();
      doc.refresh();
      await nextFrame();
      _sample();
    }
    frameSink = null;
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }

  Future<void> _drawAndErase() async {
    await selectTool('Pen');
    for (var s = 0; s < 2; s++) {
      final from = origin + Offset(300.0 + s * 200 + _cycle % 7 * 20, 250);
      await _drag(
        from,
        (i) => from + Offset(70 * (i % 30) / 30, i * 3.0),
        60,
        kPrimaryButton,
      );
    }
    await selectTool('Eraser');
    final sweepFrom = origin + const Offset(250, 200);
    await _drag(
      sweepFrom,
      (i) => sweepFrom + Offset(i * 9.0, i * 4.0 + (i.isEven ? 15 : -15)),
      60,
      kPrimaryButton,
    );
  }

  Future<void> _moveAnImage() async {
    await selectTool('Pan');
    final img = doc.objectBounds('image-${_cycle % 50}');
    if (img == null) return;
    final grab = _screenOf(img.x + img.w / 2, img.y + img.h / 2);
    if (!hitsSurface(grab)) return;
    await _drag(
      grab,
      (i) => grab + Offset(i * 1.5, (i % 30).toDouble()),
      40,
      kPrimaryButton,
    );
  }

  Future<void> _panAndZoom() async {
    doc.setCamera(const Camera(x: 700, y: 300, zoom: 2));
    await _drag(
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
  }

  void _moveRemoteCursors(int f) {
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
      objectId: 'remote-$_cycle',
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

  Future<void> _liveTraffic() async {
    for (var f = 0; f < 90; f++) {
      if (f % 5 == 0) _moveRemoteCursors(f);
      if (f % 12 == 0) {
        voice!.set(
          callOf(
            _participants,
            speaking: (f ~/ 12).isEven ? {1 + _cycle % 20} : {},
          ),
        );
      }
      await nextFrame();
    }
    engine.remoteDrafts.end('remote-$_cycle');
  }

  Future<void> _remoteStrokes() async {
    for (var k = 0; k < 3; k++) {
      final remote = boardInputs(
        BoardSpec(strokes: 1, seed: _cycle * 7 + k),
      ).first;
      doc.applyPlaced(
        CanvasStrokeInput(
          id: 'remote-$_cycle-$k',
          seq: ++_seq,
          zIndex: _seq,
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
  }

  Dist _us(Duration Function(ui.FrameTiming) pick) =>
      Dist(timings.map((t) => pick(t).inMicroseconds.toDouble()));

  Future<List<Map<String, Object>>> report() async {
    final total = _us((t) => t.totalSpan);
    final build = _us((t) => t.buildDuration);
    final raster = _us((t) => t.rasterDuration);
    debugPrint(
      'session frames ${timings.length}: total p99 ${(total.p99 / 1000).toStringAsFixed(2)} ms, '
      '>16.7 ${(total.over(budget60Us) * 100).toStringAsFixed(1)}%, >33 ${(total.over(33333) * 100).toStringAsFixed(1)}%, '
      '>50 ${(total.over(50000) * 100).toStringAsFixed(1)}%',
    );
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
}
