// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a full canvas actually costs to hold in memory at the roadmap's soft
/// caps, the one number the spike-era benchmarks in this directory never
/// measured: they time the spatial index and the paint layer, never the
/// `Path`, `Float32List` and `CanvasStroke` objects a real document holds.
///
/// `CanvasDocument` reaches into `dart:ui` for `Path`, which the standalone
/// Dart VM `spatial_grid_benchmark.dart` and `presence_benchmark.dart` use
/// does not provide, so this runs the same way `hot_path_benchmark.dart`
/// and `remote_draft_paint_benchmark.dart` already do.
///
/// Run with `flutter test benchmark/canvas_memory_benchmark.dart`.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// iOS and Linux soft caps, `docs/ROADMAP.md`'s Phase 5 deliverable list.
const _counts = <int>[5000, 20000];

/// A realistic stroke length: `stroke_splitter.dart`'s own module doc names
/// 256 points as roughly where an encoded stroke nears the server's byte
/// ceiling, so most real strokes are shorter than that. 32 points is a short
/// gesture, still far more than a tap.
const _pointsPerStroke = 32;

void main() {
  test('resident memory at the documented soft-cap object counts', () {
    // A cold reading before anything here allocates, this benchmark's own floor
    final baselineKb = _rssKb();
    // ignore: avoid_print
    print('baseline (empty document, engine loaded) ${_fmt(baselineKb)} kB');
    var previousKb = baselineKb;
    for (final count in _counts) {
      final document = CanvasDocument();
      final rng = math.Random(20260813);
      for (var i = 0; i < count; i++) {
        document.applyPlaced(_strokeAt(i, rng));
      }
      final afterKb = _rssKb();
      final deltaKb = _deltaKb(afterKb, previousKb);
      final perObject =
          deltaKb == null ? 'n/a' : (deltaKb * 1024 / count).toStringAsFixed(0);
      // ignore: avoid_print
      print(
        'n=$count  rss ${_fmt(afterKb)} kB '
        '(+${_fmt(deltaKb)} kB, $perObject bytes/object)',
      );
      previousKb = afterKb;
      document.dispose();
    }
  });
}

int? _deltaKb(int? afterKb, int? previousKb) {
  if (afterKb == null || previousKb == null) return null;
  return afterKb - previousKb;
}

CanvasStrokeInput _strokeAt(int i, math.Random rng) {
  final x = (i % 4096).toDouble() * 8 - 16384;
  final y = (i ~/ 4096).toDouble() * 8 - 16384;
  final points = <double>[
    for (var p = 0; p < _pointsPerStroke; p++) ...[
      rng.nextDouble() * 200,
      rng.nextDouble() * 200,
    ],
  ];
  return CanvasStrokeInput(
    id: 'stroke-$i',
    seq: i,
    zIndex: i,
    x: x,
    y: y,
    w: 200,
    h: 200,
    points: points,
    width: 4,
    colorKey: 'ink',
    authorId: 'author-${i % 8}',
  );
}

/// The `flutter_tester` process's own resident memory, in kB. Its own
/// baseline (loaded engine, test binding, nothing from this benchmark yet)
/// is what the first reading above subtracts away.
int? _rssKb() {
  final rss = ProcessInfo.currentRss;
  return rss == 0 ? null : (rss / 1024).round();
}

String _fmt(int? kb) => kb == null ? 'n/a' : kb.toString();
