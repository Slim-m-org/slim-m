// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Cost of a pointer move and a frame in the whole `CanvasPane` on a busy board with a 25-person call.
/// Run `flutter test benchmark/canvas_pane_benchmark.dart` in `client/packages/app`; `CANVAS_PERF_OUT` keeps the JSON.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../voice_canvas/benchmark/board_fixture.dart';
import '../../voice_canvas/benchmark/build_counter.dart';
import '../../voice_canvas/benchmark/perf_support.dart';
import 'pane_rig.dart';
import 'perf_voice.dart';

const _busy = BoardSpec(strokes: 1000, notes: 200, images: 50);
const _huge = BoardSpec(strokes: 5000, notes: 200, images: 50);
const _moves = 150;

/// Runs [step] [n] times with counters on and reports the per-step averages.
Future<void> _count(
  PerfLog log,
  PaneRig rig,
  String name,
  int n,
  Future<void> Function(int i) step,
) async {
  final counter = BuildCounter()..start();
  for (var i = 0; i < n; i++) {
    await step(i);
    await rig.frame();
  }
  counter.stop();
  log
    ..value('$name: widget builds per step', counter.totalBuilds / n)
    ..value('$name: render repaints per step', counter.totalPaints / n);
  // ignore: avoid_print
  print('  builds: ${BuildCounter.top(counter.builds, n: 10, per: n)}');
  // ignore: avoid_print
  print('  repaints: ${BuildCounter.top(counter.paints, n: 8, per: n)}');
}

void main() {
  final log = PerfLog('canvas_pane');
  setUpAll(loadProductFont);
  tearDownAll(log.flush);

  for (final spec in [_busy, _huge]) {
    final tag = spec.label;
    testWidgets(
      'drag a selection, $tag, 25 on the call',
      (tester) => _dragSelection(tester, log, spec),
    );
    testWidgets(
      'draw, $tag, 25 on the call',
      (tester) => _draw(tester, log, spec),
    );
    testWidgets(
      'erase, $tag, 25 on the call',
      (tester) => _erase(tester, log, spec),
    );
    testWidgets(
      'pan and zoom, $tag, 25 on the call',
      (tester) => _panAndZoom(tester, log, spec),
    );
    testWidgets(
      'speaking and remote cursors, $tag',
      (tester) => _speakingAndCursors(tester, log, spec),
    );
  }

  for (final call in [0, 5, 25]) {
    testWidgets(
      'rebuilds per pan move with $call on the call',
      (tester) => _rebuildsPerPan(tester, log, call),
    );
  }
}

Future<void> _dragSelection(
  WidgetTester tester,
  PerfLog log,
  BoardSpec spec,
) async {
  final tag = spec.label;
  final rig = PaneRig(tester);
  await rig.mount(spec);
  await rig.pressKey(LogicalKeyboardKey.keyH);
  final dragged = rig.pickDraggable();
  final b = rig.doc.objectBounds(dragged)!;
  final start = rig.screenOf(b.x + b.w / 2, b.y + b.h / 2);
  final gesture = await rig.mouse(start);
  final handler = <double>[];
  final frames = <double>[];
  for (var i = 0; i < _moves; i++) {
    handler.add(
      await rig.timed(() => gesture.moveTo(start + Offset(i * 2.0, i % 30))),
    );
    frames.add(await rig.frame());
  }
  final moved = rig.doc.objectBounds(dragged)!;
  log.value('drag: image moved by (world px) $tag', moved.x - b.x);
  log
    ..add('drag/handler $tag', Dist(handler.skip(15)))
    ..add('drag/frame $tag', Dist(frames.skip(15)));
  await _count(log, rig, 'drag $tag', 30, (i) async {
    await gesture.moveTo(start + Offset(300 + i * 2.0, i % 30));
  });
  await gesture.up();
  await rig.close();
}

Future<void> _draw(WidgetTester tester, PerfLog log, BoardSpec spec) async {
  final tag = spec.label;
  final rig = PaneRig(tester);
  await rig.mount(spec);
  await rig.pressKey(LogicalKeyboardKey.keyP);
  final handler = <double>[];
  final frames = <double>[];
  final commit = <double>[];
  for (var s = 0; s < 8; s++) {
    final start = rig.origin + Offset(200.0 + s * 120, 200);
    final gesture = await rig.mouse(start);
    for (var i = 1; i <= 80; i++) {
      final at = start + Offset(60 * (i % 20) / 20, i * 3.0);
      handler.add(await rig.timed(() => gesture.moveTo(at)));
      frames.add(await rig.frame());
    }
    commit.add(await rig.timed(gesture.up));
    await rig.frame();
  }
  log
    ..add('draw/handler $tag', Dist(handler))
    ..add('draw/frame $tag', Dist(frames))
    ..add('draw/commit (pointer up) $tag', Dist(commit));
  final start = rig.origin + const Offset(1300, 200);
  final gesture = await rig.mouse(start);
  await _count(log, rig, 'draw $tag', 30, (i) async {
    await gesture.moveTo(start + Offset(i * 3.0, i * 3.0));
  });
  await gesture.up();
  await rig.close();
}

Future<void> _erase(WidgetTester tester, PerfLog log, BoardSpec spec) async {
  final tag = spec.label;
  final rig = PaneRig(tester);
  await rig.mount(spec);
  await rig.pressKey(LogicalKeyboardKey.keyE);
  final start = rig.origin + const Offset(150, 150);
  final gesture = await rig.mouse(start);
  final handler = <double>[];
  final frames = <double>[];
  for (var i = 1; i <= _moves; i++) {
    final at = start + Offset(i * 8.0, i * 4.0 + (i.isEven ? 20 : -20));
    handler.add(await rig.timed(() => gesture.moveTo(at)));
    frames.add(await rig.frame());
  }
  log
    ..add('erase/handler $tag', Dist(handler.skip(10)))
    ..add('erase/frame $tag', Dist(frames.skip(10)));
  log.value('erase: objects left $tag', rig.doc.objectCount.value);
  await _count(log, rig, 'erase $tag', 30, (i) async {
    await gesture.moveTo(
      start + Offset(900 + i * 8.0, 400 + (i.isEven ? 20 : -20)),
    );
  });
  final up = await rig.timed(gesture.up);
  log.value('erase/pointer up (ms) $tag', up / 1000);
  await rig.close();
}

Future<void> _panAndZoom(
  WidgetTester tester,
  PerfLog log,
  BoardSpec spec,
) async {
  final tag = spec.label;
  final rig = PaneRig(tester);
  await rig.mount(spec);
  rig.doc.setCamera(const Camera(x: 700, y: 300, zoom: 2));
  await rig.frame();
  final center = rig.origin + const Offset(800, 450);
  final gesture = await rig.mouse(center, buttons: kMiddleMouseButton);
  final panHandler = <double>[];
  final panFrames = <double>[];
  for (var i = 0; i < _moves; i++) {
    panHandler.add(
      await rig.timed(
        () => gesture.moveTo(center + Offset(i.isEven ? 3 : -3, 1) * (i / 2)),
      ),
    );
    panFrames.add(await rig.frame());
  }
  log
    ..add('pan/handler $tag', Dist(panHandler.skip(15)))
    ..add('pan/frame $tag', Dist(panFrames.skip(15)));
  await _count(log, rig, 'pan $tag', 30, (i) async {
    await gesture.moveTo(center + Offset(i.isEven ? 3 : -3, 1) * (i / 2));
  });
  await gesture.up();

  final zoomFrames = <double>[];
  for (var i = 0; i < 200; i++) {
    rig.pinch(center, (i ~/ 40).isEven ? 1.04 : 1 / 1.04);
    zoomFrames.add(await rig.frame());
  }
  log.add('zoom/frame $tag', Dist(zoomFrames.skip(15)));
  await _count(log, rig, 'zoom $tag', 30, (i) async {
    rig.pinch(center, i.isEven ? 1.03 : 1 / 1.03);
  });
  await rig.close();
}

void _moveCursors(CanvasCursors cursors, double x, double y, double step) {
  for (var u = 0; u < 8; u++) {
    cursors.upsert(
      id: 'u$u',
      x: x + u * step,
      y: y + u * 20,
      label: 'User $u',
      colorIndex: u,
    );
  }
}

Future<void> _speakingAndCursors(
  WidgetTester tester,
  PerfLog log,
  BoardSpec spec,
) async {
  final tag = spec.label;
  final rig = PaneRig(tester);
  await rig.mount(spec);
  await _count(log, rig, 'someone starts or stops speaking $tag', 40, (
    i,
  ) async {
    final speaking = i.isEven ? {1 + i % 20} : <int>{};
    rig.voice!.set(
      VoiceState(
        channelId: 'c1',
        state: VoiceSessionState.connected,
        participants: roster(25, speaking: speaking),
      ),
    );
  });
  final cursors = _cursorsOf(tester);
  final frames = <double>[];
  for (var i = 0; i < 150; i++) {
    for (var u = 0; u < 8; u++) {
      cursors.upsert(
        id: 'u$u',
        x: 200.0 + u * 150 + i,
        y: 300 + (i % 60) * 4,
        label: 'User $u',
        colorIndex: u,
      );
    }
    frames.add(await rig.frame());
  }
  log.add('8 remote cursors/frame $tag', Dist(frames.skip(10)));
  await _count(log, rig, '8 remote cursors $tag', 30, (i) async {
    _moveCursors(cursors, 300.0 + i, 350.0, 100);
  });
  await rig.close();
}

Future<void> _rebuildsPerPan(WidgetTester tester, PerfLog log, int call) async {
  final rig = PaneRig(tester);
  await rig.mount(_busy, participants: call);
  rig.doc.setCamera(const Camera(x: 700, y: 300, zoom: 2));
  await rig.frame();
  final center = rig.origin + const Offset(800, 450);
  final gesture = await rig.mouse(center, buttons: kMiddleMouseButton);
  await _count(log, rig, 'pan, $call on the call', 30, (i) async {
    await gesture.moveTo(center + Offset(i.isEven ? 3 : -3, 1) * (i / 2));
  });
  await gesture.up();
  await rig.close();
}

CanvasCursors _cursorsOf(WidgetTester tester) {
  final surface = tester.widget<CanvasSurface>(find.byType(CanvasSurface));
  return surface.cursors!;
}
