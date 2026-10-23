// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A small, pre-blurred picture of a voice channel's canvas board, painted
/// once per read so the call view can hint at what is on the canvas without
/// keeping the canvas engine alive.
library;

import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../providers/providers.dart';
import '../../canvas/providers/canvas_object_inputs.dart';
import '../../canvas/providers/canvas_pen_style.dart';

/// How big the snapshot is drawn before it is stretched behind the call: the blur hides the low resolution.
const loungeGlowSize = Size(480, 270);

/// The blurred shared area for [channelId], read each time a call view opens; null when it is empty or cannot be read.
final loungeCanvasGlowProvider = FutureProvider.autoDispose
    .family<ui.Image?, String>((ref, channelId) async {
      final client = ref.read(apiProvider);
      final api.CanvasViewport page;
      try {
        page = await client.canvasViewport(
          channelId,
          region: api.CanvasRect(
            minX: canvasSharedArea.left,
            minY: canvasSharedArea.top,
            maxX: canvasSharedArea.right,
            maxY: canvasSharedArea.bottom,
          ),
          limit: 500,
        );
      } on Object {
        return null;
      }
      final document = CanvasDocument();
      try {
        document.setBoard(canvasBoard, sharedArea: canvasSharedArea);
        for (final object in page.objects) {
          final input = canvasStrokeInputFrom(object);
          if (input != null) document.applyPlaced(input, overwrite: true);
        }
        if (document.objectCount.value == 0) return null;
        return await paintLoungeGlow(document);
      } finally {
        document.dispose();
      }
    });

/// Paints [document]'s board through a blur, so the call view never blurs per frame.
Future<ui.Image> paintLoungeGlow(CanvasDocument document) {
  document.setViewport(loungeGlowSize);
  document.fitBoard();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & loungeGlowSize);
  canvas.saveLayer(
    Offset.zero & loungeGlowSize,
    Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
  );
  StrokePainter(
    document: document,
    ink: AppCanvasColors.annotation,
    inkColors: canvasPenInkByKey,
    noteColor: AppCanvasColors.note,
    shapeColor: AppCanvasColors.shape,
  ).paint(canvas, loungeGlowSize);
  canvas.restore();
  return recorder.endRecording().toImage(
    loungeGlowSize.width.toInt(),
    loungeGlowSize.height.toInt(),
  );
}
