// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The real `CanvasPane` on a busy board with a full call, in a profile-mode window; driven by `pane_profile.sh`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';
import 'package:window_manager/window_manager.dart';

import '../../voice_canvas/benchmark/board_fixture.dart';
import '../../voice_canvas/benchmark/perf_support.dart';
import 'pane_profile_host.dart';
import 'pane_profile_measure.dart';
import 'pane_profile_scenarios.dart';
import 'pane_profile_session.dart';
import 'pane_profile_smoke.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setSize(const Size(1600, 1000));
  SchedulerBinding.instance.addTimingsCallback(
    (batch) => frameSink?.addAll(batch),
  );
  runApp(
    ListenableBuilder(
      listenable: host,
      builder: (context, _) => host.child ?? const SizedBox.shrink(),
    ),
  );
  unawaited(Future<void>.delayed(const Duration(seconds: 2), runAll));
}

Future<void> runAll() async {
  final view = ui.PlatformDispatcher.instance.implicitView!;
  final size = view.physicalSize;
  debugPrint(
    'smoke window ${size.width}x${size.height} at dpr ${view.devicePixelRatio}',
  );
  final dpr = view.devicePixelRatio;
  final rows = <Map<String, Object>>[];
  final phases = Platform.environment['PANE_PHASES'] ?? 'scenarios';
  if (phases.contains('smoke')) {
    rows
      ..addAll(await runSmoke(0))
      ..addAll(await runSmoke(25));
  }
  if (phases.contains('open')) rows.addAll(runOpen());
  if (phases.contains('scenarios')) {
    final plan = <(BoardSpec, int)>[
      (const BoardSpec(strokes: 1000, notes: 200, images: 50), 0),
      (const BoardSpec(strokes: 1000, notes: 200, images: 50), 25),
      (const BoardSpec(strokes: 5000, notes: 200, images: 50), 25),
    ];
    for (final (spec, participants) in plan) {
      rows.addAll(await runScenarios(spec, participants, size, dpr));
    }
  }
  if (phases.contains('session')) rows.addAll(await runSession());
  final out = Platform.environment['CANVAS_PERF_OUT'];
  if (out != null && out.isNotEmpty) {
    Directory(out).createSync(recursive: true);
    File(
      '$out/pane_profile_${phases.replaceAll(',', '_')}.json',
    ).writeAsStringSync(
      const JsonEncoder.withIndent(' ').convert({
        'meta': {
          'window_px': '${size.width}x${size.height}',
          'dpr': dpr,
          'mode': 'profile',
          'rss_kb': rssKb(),
        },
        'rows': rows,
      }),
    );
  }
  debugPrint('DONE');
  exit(0);
}

/// Opening a canvas that holds a full page of strokes: the bytes the server
/// sends, then decode, model and document build, each on the UI isolate.
List<Map<String, Object>> runOpen() {
  final rows = <Map<String, Object>>[];
  for (final count in [500, 2000]) {
    final inputs = boardInputs(BoardSpec(strokes: count));
    final body = jsonEncode({
      'objects': [
        for (final i in inputs)
          {
            'id': i.id,
            'kind': 'stroke',
            'z_index': i.zIndex,
            'x': i.x,
            'y': i.y,
            'w': i.w,
            'h': i.h,
            'props': {'points': i.points, 'width': 3.0, 'color': i.colorKey},
            'author_id': i.authorId,
            'seq': i.seq,
            'created_at': 0,
          },
      ],
      'has_more': count >= 2000,
      'latest_seq': count,
    });
    final decode = Stopwatch()..start();
    final json = jsonDecode(body) as Map<String, dynamic>;
    final decoded = decode.elapsedMicroseconds / 1000;
    final model = Stopwatch()..start();
    final page = api.CanvasViewport.fromJson(json);
    final modelled = model.elapsedMicroseconds / 1000;
    final doc = CanvasDocument()..setBoard(canvasBoard);
    final apply = Stopwatch()..start();
    for (final object in page.objects) {
      final input = canvasStrokeInputFrom(object);
      if (input != null) doc.applyPlaced(input);
    }
    doc.refresh();
    final applied = apply.elapsedMicroseconds / 1000;
    doc.dispose();
    for (final (name, value) in [
      ('open $count strokes: payload (KiB)', body.length / 1024),
      ('open $count strokes: jsonDecode (ms)', decoded),
      ('open $count strokes: CanvasViewport.fromJson (ms)', modelled),
      ('open $count strokes: build the document (ms)', applied),
    ]) {
      rows.add({'name': name, 'value': value});
      debugPrint('$name ${value.toStringAsFixed(2)}');
    }
  }
  return rows;
}

/// A scripted collaborative session in real time, sampled for memory.
