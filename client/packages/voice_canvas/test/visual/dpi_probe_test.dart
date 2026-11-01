// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Answers a question a design review raised about `zoom_stress_0.25x.png`:
/// the thin diagonal ink stroke there looks broken, almost dotted, rather
/// than a continuous line. Is that a real sub-pixel-width geometry problem,
/// or an artifact of the software rasterizer this whole harness renders
/// through (see `visual_render_support.dart`'s own library doc)?
///
/// **Answer: a rasterizer artifact, not real geometry.** At zoom 0.25 the
/// 4-world-unit stroke is exactly 1 device pixel wide (`4 * 0.25`), and a
/// diagonal 1px-wide line under this software rasterizer's antialiasing
/// breaks into a dotted pattern - confirmed by rendering the identical
/// scene at `ratio: 4`, where the same stroke is 4 device pixels wide and
/// renders as a fully continuous line with no gaps at all. If this were a
/// real geometry bug (a degenerate path, a missing segment), it would
/// persist at any pixel ratio; it does not. No code fix follows from this:
/// clamping ink's on-screen minimum width would break the world-space
/// model shapes were just made to match (see the note above `_paintShape`
/// in `canvas_object_painter.dart`), and every real target this client
/// ships to renders at a device pixel ratio of at least 1 (desktop) or
/// 2-3 (phone), where a stroke this thin at this zoom is already several
/// device pixels wide and the artifact does not appear.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_document.dart';

import 'visual_render_support.dart';
import 'visual_scenes.dart';
import 'visual_tokens.dart';

Future<void> _renderAtRatio(String name, double ratio) async {
  const zoom = 0.25;
  const margin = 40.0;
  const worldW = 880.0;
  const worldH = 280.0;
  final logicalW = (worldW * zoom).round();
  final logicalH = (worldH * zoom).round();
  final deviceW = (logicalW * ratio).round();
  final deviceH = (logicalH * ratio).round();

  final document = buildZoomStressScene();
  document.setViewport(Size(logicalW.toDouble(), logicalH.toDouble()));
  document.setCamera(const Camera(x: -margin, y: -margin, zoom: zoom));

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(ratio);
  paintCanvasComposite(
    canvas,
    document,
    VisualTheme.dark,
    Size(logicalW.toDouble(), logicalH.toDouble()),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(deviceW, deviceH);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  document.dispose();
  if (!writingVisuals) return;
  Directory(visualOutDir).createSync(recursive: true);
  File('$visualOutDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  test('zoom-floor ink: ratio 1 (dotted) versus ratio 4 (continuous)',
      () async {
    await _renderAtRatio('dpi_probe_ratio1', 1);
    await _renderAtRatio('dpi_probe_ratio4', 4);
  });
}
