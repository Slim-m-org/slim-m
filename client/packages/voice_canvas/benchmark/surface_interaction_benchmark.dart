// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What one pointer event and one frame cost on a busy board: drawing, panning and zooming a mounted `CanvasSurface` at 1k, 5k and 10k strokes, and with 200 notes and 50 images.
/// A debug JIT build under `flutter test` with no GPU, so read it as an upper bound on the UI-thread half of a frame; `CANVAS_PERF_OUT` keeps the JSON.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'board_fixture.dart';
import 'build_counter.dart';
import 'perf_support.dart';
import 'surface_rig.dart';

const _specs = <BoardSpec>[
  BoardSpec(strokes: 1000),
  BoardSpec(strokes: 5000),
  BoardSpec(strokes: 10000),
  BoardSpec(strokes: 1000, notes: 200, images: 50),
  BoardSpec(strokes: 5000, notes: 200, images: 50),
];

const _moves = 240;

void main() {
  final log = PerfLog('surface_interaction');
  setUpAll(loadBenchFont);
  tearDownAll(log.flush);

  testWidgets('one long scribble keeps the draft layer cheap', (tester) async {
    final doc = buildBoard(const BoardSpec(strokes: 1000));
    final rig = SurfaceRig(tester, doc);
    await rig.mount();
    final gesture = await tester.startGesture(
      const Offset(300, 300),
      kind: PointerDeviceKind.mouse,
    );
    final byWindow = <int, List<double>>{};
    for (var i = 1; i <= 4000; i++) {
      final at = Offset(300.0 + 600 * ((i % 80) / 80), 300.0 + 3 * (i % 160));
      final cost = await rig.timed(() async {
        await gesture.moveTo(at);
        await rig.frame();
      });
      byWindow.putIfAbsent(i ~/ 1000, () => []).add(cost);
    }
    await gesture.up();
    for (final entry in byWindow.entries) {
      log.add(
        'draw one scribble: move+frame, points ${entry.key * 1000}-${entry.key * 1000 + 999}',
        Dist(entry.value),
      );
    }
    doc.dispose();
  });

  for (final spec in _specs) {
    final tag = spec.label;

    testWidgets('pan $tag', (tester) async {
      final doc = buildBoard(spec);
      final rig = SurfaceRig(tester, doc);
      await tester.runAsync(() => attachBitmaps(doc, spec.images));
      await rig.mount(tool: CanvasTool.pan);
      doc.setCamera(const Camera(x: 700, y: 300, zoom: 2));
      await rig.frame();
      final handler = <double>[];
      final frames = <double>[];
      final gesture = await tester.startGesture(
        const Offset(800, 450),
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      for (var i = 0; i < _moves; i++) {
        handler.add(
          await rig.timed(() => gesture.moveBy(Offset(i.isEven ? 3 : -3, 1))),
        );
        frames.add(await rig.frame());
      }
      await gesture.up();
      log
        ..add('pan/handler $tag', Dist(handler.skip(20)))
        ..add('pan/frame $tag', Dist(frames.skip(20)));
      final counter = BuildCounter()..start();
      await gesture.down(const Offset(800, 450));
      for (var i = 0; i < 20; i++) {
        await gesture.moveBy(Offset(i.isEven ? 3 : -3, 1));
        await tester.pump();
      }
      counter.stop();
      log.value('pan/rebuilds per move $tag', counter.totalBuilds / 20);
      log.value('pan/repaints per move $tag', counter.totalPaints / 20);
      // ignore: avoid_print
      print('  repaints: ${BuildCounter.top(counter.paints, per: 20)}');
      doc.dispose();
    });

    testWidgets('zoom $tag', (tester) async {
      final doc = buildBoard(spec);
      final rig = SurfaceRig(tester, doc);
      await tester.runAsync(() => attachBitmaps(doc, spec.images));
      await rig.mount(tool: CanvasTool.pan);
      doc.setCamera(const Camera(x: 400, y: 200, zoom: 1.5));
      await rig.frame();
      const focal = Offset(800, 450);
      final handler = <double>[];
      final frames = <double>[];
      for (var i = 0; i < _moves; i++) {
        final scale = (i ~/ 40).isEven ? 1.04 : 1 / 1.04;
        handler.add(await rig.timed(() => rig.pinch(focal, scale)));
        frames.add(await rig.frame());
      }
      log
        ..add('zoom/handler $tag', Dist(handler.skip(20)))
        ..add('zoom/frame $tag', Dist(frames.skip(20)));
      doc.dispose();
    });

    testWidgets('draw $tag', (tester) async {
      final doc = buildBoard(spec);
      final rig = SurfaceRig(tester, doc);
      await tester.runAsync(() => attachBitmaps(doc, spec.images));
      await rig.mount();
      final handler = <double>[];
      final frames = <double>[];
      final commits = <double>[];
      final commitFrames = <double>[];
      for (var stroke = 0; stroke < 6; stroke++) {
        final gesture = await tester.startGesture(
          Offset(200.0 + stroke * 150, 200),
          kind: PointerDeviceKind.mouse,
        );
        for (var i = 1; i <= _moves ~/ 2; i++) {
          final at = Offset(
            200.0 + stroke * 150 + 90 * (i % 40) / 40,
            200 + i * 2.5,
          );
          handler.add(await rig.timed(() => gesture.moveTo(at)));
          frames.add(await rig.frame());
        }
        commits.add(await rig.timed(gesture.up));
        commitFrames.add(await rig.frame());
      }
      log
        ..add('draw/move handler $tag', Dist(handler))
        ..add('draw/move frame $tag', Dist(frames))
        ..add('draw/commit handler $tag', Dist(commits))
        ..add('draw/commit frame $tag', Dist(commitFrames));
      final counter = BuildCounter()..start();
      final gesture = await tester.startGesture(
        const Offset(1300, 200),
        kind: PointerDeviceKind.mouse,
      );
      for (var i = 1; i <= 20; i++) {
        await gesture.moveTo(Offset(1300 + i * 3.0, 200 + i * 3.0));
        await tester.pump();
      }
      counter.stop();
      await gesture.up();
      log.value('draw/rebuilds per move $tag', counter.totalBuilds / 20);
      // ignore: avoid_print
      print('  repaints: ${BuildCounter.top(counter.paints, per: 20)}');
      doc.dispose();
    });
  }
}
