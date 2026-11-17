// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the overlay window paints and which relayed marks it may paint.
library;

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart' show resolveCanvasInk;
import 'package:slimm_platform/platform.dart';

import '../../canvas/providers/canvas_pen_style.dart';
import 'screen_annotation_board.dart';
import 'screen_annotation_call.dart';
import 'stamp_content.dart';

/// Stroke width on the sharer's screen, in logical pixels.
const overlayInkWidth = 4.0;

/// The paint list for [marks] at [now]; a mark with too few points to draw is left out, and so is a stamp whose picture the runner does not hold, which [heldImage] names.
List<OverlayShape> overlayShapesFor(
  List<ScreenAnnotation> marks,
  DateTime now, {
  String? Function(StampContent content)? heldImage,
  bool reduceMotion = false,
}) {
  final shapes = <OverlayShape>[];
  for (final mark in marks) {
    final alpha = mark.alphaAt(now);
    if (alpha <= 0) continue;
    final ink = resolveCanvasInk(
      canvasPenInkByKey,
      mark.colorKey,
      AppCanvasColors.annotation,
    );
    final p = mark.points;
    switch (mark.kind) {
      case ScreenAnnotationKind.stroke when p.length >= 4:
        shapes.add(
          OverlayStroke(
            points: List.of(p),
            color: ink,
            alpha: alpha,
            width: overlayInkWidth,
          ),
        );
      case ScreenAnnotationKind.shape when p.length == 4:
        shapes.add(
          OverlayEllipse(
            x0: p[0],
            y0: p[1],
            x1: p[2],
            y1: p[3],
            color: ink,
            alpha: alpha,
            width: overlayInkWidth,
          ),
        );
      case ScreenAnnotationKind.note when p.length == 2 && mark.text != null:
        shapes.add(
          OverlayNote(
            x: p[0],
            y: p[1],
            text: mark.text!,
            color: AppCanvasColors.note,
            alpha: alpha,
          ),
        );
      case ScreenAnnotationKind.stamp when p.length == 2:
        final content = mark.stamp;
        final key = content == null ? null : heldImage?.call(content);
        if (key == null) break;
        shapes.add(
          OverlayStamp(
            image: key,
            x: p[0],
            y: p[1],
            size: mark.size,
            scale: mark.scaleAt(now, reduceMotion: reduceMotion),
            alpha: alpha,
          ),
        );
      default:
        break;
    }
  }
  return shapes;
}

/// Whether the sharer's own client shows [frame] on their screen.
///
/// This is the gate that matters: the overlay lives on the sharer's machine and
/// only paints what the sharer allowed, drawn in the call they are in.
bool overlayAccepts(
  api.CanvasScreenAnnotation frame, {
  required bool overlayActive,
  required String? selfId,
  required String? callChannelId,
}) =>
    overlayActive &&
    frame.kind != 'consent' &&
    selfId != null &&
    frame.targetUserId == selfId &&
    markInCall(frame, callChannelId: callChannelId);
