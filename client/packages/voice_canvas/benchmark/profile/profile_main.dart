// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A scripted canvas session for a real, profile-mode window.
///
/// `flutter test` cannot rasterise, so it cannot say what a pan or a stroke
/// commit costs the GPU thread. This runs the same busy boards in an actual
/// window and records `FrameTiming` for every frame: build time, raster time
/// and the span between them. Driven by `run.sh`, which builds it with
/// `flutter build linux --profile` and keeps it inside a nested compositor.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart' show StrokePainter;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../board_fixture.dart';
import '../perf_support.dart';

const _specs = <BoardSpec>[
  BoardSpec(strokes: 1000),
  BoardSpec(strokes: 5000),
  BoardSpec(strokes: 10000),
  BoardSpec(strokes: 1000, notes: 200, images: 50),
  BoardSpec(strokes: 5000, notes: 200, images: 50),
];

List<ui.FrameTiming>? _sink;

class Rig extends ChangeNotifier {
  CanvasDocument? doc;
  final CanvasCursors cursors = CanvasCursors();
  final RemoteStrokeDrafts drafts = RemoteStrokeDrafts();
  CanvasTool tool = CanvasTool.pan;
  int drawn = 0;

  /// When set, committed ink is this bitmap instead of live strokes.
  ui.Image? inkBitmap;

  void showBitmap(ui.Image? image) {
    inkBitmap?.dispose();
    inkBitmap = image;
    notifyListeners();
  }

  void use(CanvasDocument next) {
    doc?.dispose();
    doc = next;
    notifyListeners();
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SchedulerBinding.instance.addTimingsCallback((batch) => _sink?.addAll(batch));
  final rig = Rig();
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: ListenableBuilder(
        listenable: rig,
        builder: (context, _) {
          final doc = rig.doc;
          if (doc == null) return const SizedBox.shrink();
          final bitmap = rig.inkBitmap;
          if (bitmap != null) {
            return Stack(
              children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(painter: _BitmapInk(bitmap)),
                  ),
                ),
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: CursorPainter(
                        cursors: rig.cursors,
                        document: doc,
                        colors: const [Color(0xFFD93025), Color(0xFF1A73E8)],
                      ),
                    ),
                  ),
                ),
              ],
            );
          }
          return Stack(
            children: [
              CanvasGridLayer(
                document: doc,
                line: const Color(0x14000000),
                letterbox: const Color(0x0A000000),
              ),
              CanvasSurface(
                key: ValueKey(doc),
                document: doc,
                ink: const Color(0xFF202124),
                inkColors: benchInkColors,
                tool: rig.tool,
                cursors: rig.cursors,
                remoteDrafts: rig.drafts,
                cursorColors: const [Color(0xFFD93025), Color(0xFF1A73E8)],
                selectionOutline: const Color(0xFF1A73E8),
                onStroke: (points) {
                  var part = 0;
                  for (final s in splitStroke(points)) {
                    doc.applyPlaced(
                      CanvasStrokeInput(
                        id: 'drawn-${rig.drawn}-${part++}',
                        seq: 0,
                        zIndex: provisionalLocalZIndex + rig.drawn,
                        x: s.x,
                        y: s.y,
                        w: s.w,
                        h: s.h,
                        points: s.points,
                        width: 3,
                        colorKey: 'ink',
                      ),
                    );
                  }
                  rig.drawn++;
                  doc.refresh();
                },
              ),
            ],
          );
        },
      ),
    ),
  );
  unawaited(Future<void>.delayed(const Duration(seconds: 2), () => _run(rig)));
}

/// The ink as one texture: the shape of fix the sweep below prices.
class _BitmapInk extends CustomPainter {
  _BitmapInk(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawImage(image, Offset.zero, Paint());

  @override
  bool shouldRepaint(_BitmapInk old) => old.image != image;
}

Future<void> _frame() => SchedulerBinding.instance.endOfFrame;

int get _view => ui.PlatformDispatcher.instance.implicitView!.viewId;

void _send(PointerEvent event) =>
    GestureBinding.instance.handlePointerEvent(event);

PointerDownEvent _down(Offset at, int buttons) => PointerDownEvent(
      viewId: _view,
      pointer: 31,
      device: 31,
      kind: PointerDeviceKind.mouse,
      position: at,
      buttons: buttons,
    );

PointerMoveEvent _move(Offset at, Offset delta, int buttons) =>
    PointerMoveEvent(
      viewId: _view,
      pointer: 31,
      device: 31,
      kind: PointerDeviceKind.mouse,
      position: at,
      delta: delta,
      buttons: buttons,
    );

PointerUpEvent _up(Offset at) => PointerUpEvent(
      viewId: _view,
      pointer: 31,
      device: 31,
      kind: PointerDeviceKind.mouse,
      position: at,
    );

Future<Map<String, Object>> _measure(
  String name,
  Future<void> Function() body,
) async {
  _sink = <ui.FrameTiming>[];
  final handler = <double>[];
  _handlerSamples = handler;
  await body();
  await Future<void>.delayed(const Duration(milliseconds: 800));
  final frames = _sink!;
  _sink = null;
  _handlerSamples = null;
  final skip = frames.length > 30 ? 10 : 0;
  final usable = frames.skip(skip).toList();
  Dist us(Duration Function(ui.FrameTiming) pick) =>
      Dist(usable.map((t) => pick(t).inMicroseconds.toDouble()));
  final build = us((t) => t.buildDuration);
  final raster = us((t) => t.rasterDuration);
  final total = us((t) => t.totalSpan);
  debugPrint(
    '${name.padRight(46)} frames ${usable.length.toString().padLeft(4)}  '
    'build med ${(build.median / 1000).toStringAsFixed(2)} p99 '
    '${(build.p99 / 1000).toStringAsFixed(2)}  raster med '
    '${(raster.median / 1000).toStringAsFixed(2)} p99 '
    '${(raster.p99 / 1000).toStringAsFixed(2)} max '
    '${(raster.max / 1000).toStringAsFixed(2)}  total p99 '
    '${(total.p99 / 1000).toStringAsFixed(2)}  >16.7 raster '
    '${(raster.over(budget60Us) * 100).toStringAsFixed(1)}%',
  );
  return <String, Object>{
    'name': name,
    'frames': usable.length,
    'build': build.toJson(),
    'raster': raster.toJson(),
    'total': total.toJson(),
    if (handler.isNotEmpty) 'handler': Dist(handler.skip(10)).toJson(),
  };
}

List<double>? _handlerSamples;

void _timedSend(PointerEvent event) {
  final sw = Stopwatch()..start();
  _send(event);
  _handlerSamples?.add(sw.elapsedMicroseconds.toDouble());
}

Future<void> _run(Rig rig) async {
  final size = ui.PlatformDispatcher.instance.implicitView!.physicalSize;
  final dpr = ui.PlatformDispatcher.instance.implicitView!.devicePixelRatio;
  final rows = <Map<String, Object>>[];
  final meta = <String, Object>{
    'window_px': '${size.width}x${size.height}',
    'dpr': dpr,
    'mode': 'profile',
    'dart': Platform.version.split(' ').first,
  };
  final phases = Platform.environment['PROFILE_PHASES'] ?? 'specs,sweep';
  for (final spec in phases.contains('specs') ? _specs : const <BoardSpec>[]) {
    final doc =
        buildBoard(spec, viewport: Size(size.width / dpr, size.height / dpr));
    await attachBitmaps(doc, spec.images);
    rig.use(doc);
    await _frame();
    await _frame();
    final center = Offset(size.width / dpr / 2, size.height / dpr / 2);
    final tag = spec.label;

    doc.setCamera(const Camera(x: 700, y: 300, zoom: 2));
    rig.tool = CanvasTool.pan;
    await _frame();
    rows.add(await _measure('pan $tag', () async {
      _send(_down(center, kMiddleMouseButton));
      var at = center;
      for (var i = 0; i < 300; i++) {
        final delta = Offset(i.isEven ? 3 : -3, 1);
        at += delta;
        _timedSend(_move(at, delta, kMiddleMouseButton));
        await _frame();
      }
      _send(_up(at));
    }));

    doc.setCamera(const Camera(x: 400, y: 200, zoom: 1.5));
    await _frame();
    rows.add(await _measure('zoom sweep $tag', () async {
      for (var i = 0; i < 360; i++) {
        final scale = (i ~/ 45).isEven ? 1.04 : 1 / 1.04;
        _timedSend(PointerScaleEvent(
          viewId: _view,
          position: center,
          scale: scale,
          kind: PointerDeviceKind.mouse,
          device: 31,
        ));
        await _frame();
      }
    }));

    doc.fitBoard();
    await _frame();
    final fit = doc.camera.zoom;
    meta['fit_zoom_$tag'] = double.parse(fit.toStringAsFixed(3));
    rows.add(await _measure('repaint at fit (drag a note) $tag', () async {
      final id = spec.notes > 0 ? 'note-0' : 'stroke-0';
      final b = doc.objectBounds(id)!;
      doc.elevatedObjectId.value = id;
      for (var i = 0; i < 300; i++) {
        doc.moveObject(id, b.x + i, b.y + (i % 40), b.w, b.h);
        doc.refresh();
        await _frame();
      }
      doc.elevatedObjectId.value = null;
    }));

    rig.tool = CanvasTool.pen;
    await _frame();
    rows.add(await _measure('draw 6 strokes $tag', () async {
      for (var s = 0; s < 6; s++) {
        var at = Offset(200.0 + s * 140, 200);
        _send(_down(at, kPrimaryButton));
        for (var i = 1; i <= 100; i++) {
          final next = Offset(
            200.0 + s * 140 + 90 * (i % 40) / 40,
            200 + i * 2.5,
          );
          _timedSend(_move(next, next - at, kPrimaryButton));
          at = next;
          await _frame();
        }
        _send(_up(at));
        await _frame();
      }
    }));

    rows.add(await _measure('remote cursors+drafts $tag', () async {
      for (var i = 0; i < 300; i++) {
        for (var u = 0; u < 8; u++) {
          rig.cursors.upsert(
            id: 'u$u',
            x: 200.0 + u * 150 + i,
            y: 300 + (i % 60) * 4,
            label: 'User $u',
            colorIndex: u,
          );
        }
        rig.drafts.appendOrCreate(
          objectId: 'draft',
          authorId: 'u1',
          points: [100.0 + i, 100.0 + (i % 50), 104.0 + i, 104.0 + (i % 50)],
          colorIndex: 1,
        );
        await _frame();
      }
      rig.drafts.clear();
    }));
    meta['rss_kb_after_$tag'] = rssKb();
  }
  if (phases.contains('sweep')) rows.addAll(await _sweep(rig, size, dpr));
  if (phases.contains('objects')) {
    rows.addAll(await _objectSweep(rig, size, dpr));
  }
  if (phases.contains('bitmap')) {
    rows.addAll(await _bitmapSweep(rig, size, dpr));
  }
  final out = Platform.environment['CANVAS_PERF_OUT'];
  if (out != null && out.isNotEmpty) {
    Directory(out).createSync(recursive: true);
    File('$out/profile_${phases.replaceAll(',', '_')}.json').writeAsStringSync(
      const JsonEncoder.withIndent(' ').convert({'meta': meta, 'rows': rows}),
    );
  }
  debugPrint('DONE');
  exit(0);
}

/// Idle frames (one remote cursor moving) at fit, which is the cost of
/// any frame at all once the board is busy.
Future<void> _cursorFrames(Rig rig) async {
  for (var i = 0; i < 150; i++) {
    rig.cursors.upsert(
      id: 'u0',
      x: 200.0 + i * 4,
      y: 300 + (i % 60) * 4,
      label: 'User',
      colorIndex: 0,
    );
    await _frame();
  }
}

Future<List<Map<String, Object>>> _sweep(
  Rig rig,
  ui.Size size,
  double dpr,
) async {
  final rows = <Map<String, Object>>[];
  final view = Size(size.width / dpr, size.height / dpr);
  rig.tool = CanvasTool.pan;
  Future<CanvasDocument> board(BoardSpec spec) async {
    final doc = buildBoard(spec, viewport: view);
    rig.use(doc);
    await _frame();
    doc.fitBoard();
    await _frame();
    return doc;
  }

  for (final count in <int>[500, 1000, 2000, 3000, 5000, 7500, 10000, 20000]) {
    await board(BoardSpec(strokes: count));
    rows.add(await _measure(
        'sweep idle frame ${count}s pts48', () => _cursorFrames(rig)));
  }
  for (final points in <int>[16, 128]) {
    await board(BoardSpec(strokes: 5000, pointsPerStroke: points));
    rows.add(await _measure(
        'sweep idle frame 5000s pts$points', () => _cursorFrames(rig)));
  }
  return rows;
}

/// The same idle frames with committed ink drawn from one realised texture.
Future<List<Map<String, Object>>> _bitmapSweep(
  Rig rig,
  ui.Size size,
  double dpr,
) async {
  final rows = <Map<String, Object>>[];
  final view = Size(size.width / dpr, size.height / dpr);
  rig.tool = CanvasTool.pan;
  for (final count in <int>[5000, 10000, 20000]) {
    final doc = buildBoard(BoardSpec(strokes: count), viewport: view);
    rig.use(doc);
    await _frame();
    doc.fitBoard();
    await _frame();
    final recorder = ui.PictureRecorder();
    StrokePainter(
      document: doc,
      ink: const Color(0xFF202124),
      inkColors: benchInkColors,
    ).paint(Canvas(recorder), view * dpr);
    final started = Stopwatch()..start();
    final w = (view.width * dpr).round();
    final h = (view.height * dpr).round();
    final rendered = await recorder.endRecording().toImage(w, h);
    final raw = await rendered.toByteData();
    rendered.dispose();
    final uploaded = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      raw!.buffer.asUint8List(),
      w,
      h,
      ui.PixelFormat.rgba8888,
      uploaded.complete,
    );
    rig.showBitmap(await uploaded.future);
    debugPrint(
        'bitmap ${count}s uploaded in ${started.elapsedMilliseconds} ms');
    await _frame();
    rows.add(
      await _measure(
        'sweep ink as one uploaded bitmap, idle frame ${count}s',
        () => _cursorFrames(rig),
      ),
    );
    rig.showBitmap(null);
  }
  return rows;
}

/// What notes and images cost on their own, in the same idle frames.
Future<List<Map<String, Object>>> _objectSweep(
  Rig rig,
  ui.Size size,
  double dpr,
) async {
  final rows = <Map<String, Object>>[];
  final view = Size(size.width / dpr, size.height / dpr);
  rig.tool = CanvasTool.pan;
  final cases = <(String, BoardSpec, int, int)>[
    ('50 notes', const BoardSpec(notes: 50), 0, 0),
    ('200 notes', const BoardSpec(notes: 200), 0, 0),
    ('25 images 800x600', const BoardSpec(images: 25), 25, 800),
    ('50 images 800x600', const BoardSpec(images: 50), 50, 800),
    ('50 images 2048x1536', const BoardSpec(images: 50), 50, 2048),
  ];
  for (final (name, spec, images, width) in cases) {
    final doc = buildBoard(spec, viewport: view);
    final before = rssKb();
    for (var i = 0; i < images; i++) {
      doc.setImageBitmap(
        'image-$i',
        await solidBitmap(width, width * 3 ~/ 4, i),
      );
    }
    rig.use(doc);
    await _frame();
    doc.fitBoard();
    await _frame();
    rows.add(
        await _measure('objects idle frame, $name', () => _cursorFrames(rig)));
    rows.add({
      'name': 'objects rss growth (MiB), $name',
      'value': (rssKb() - before) / 1024
    });
    debugPrint(
        'objects rss growth for $name: ${((rssKb() - before) / 1024).toStringAsFixed(0)} MiB');
  }
  return rows;
}
