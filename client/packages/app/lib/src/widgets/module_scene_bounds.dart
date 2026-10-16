// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The part of a scene's declared canvas that actually has something in it.
///
/// Modules declare a logical canvas and then draw wherever they like inside
/// it; word-guess declares 100x100 and draws a 60x88 board with a gap on every
/// side. Painting the declared canvas turned that gap into a wide empty fill
/// inside the card, so the frame shows only the drawn content plus a small
/// margin. Done once here for every module, rather than asking each to
/// declare a tight canvas.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'module_scene.dart';
import 'module_scene_path.dart';
import 'module_scene_sweep.dart';

/// Margin kept around the content, as a share of its longer side.
const sceneCropMargin = 0.03;

/// Room reserved under an input's top edge, as a share of the declared
/// canvas's longer side, because a field is a widget with a pixel height.
const sceneInputReserve = 0.12;

/// Glyph advance and line height as multiples of the font size, generous so a
/// label is never cut by the crop.
const _glyphAdvance = 0.62;
const _lineHeight = 1.3;

/// The rect to show, in scene units, or null to show the declared canvas.
///
/// Null whenever the answer would be a guess: a moving op, a canvas with
/// nothing drawn, or content so elongated that the aspect clamp would have to
/// stretch it again.
Rect? sceneContentBounds(ModuleScene scene) {
  final canvas = Rect.fromLTWH(0, 0, scene.width, scene.height);
  if (scene.width <= 0 || scene.height <= 0) return null;
  Rect? union;
  for (final op in scene.ops) {
    if (sweepOf(op) != null) return null;
    final bounds = _opBounds(op, scene);
    if (bounds == null) continue;
    union = union == null ? bounds : union.expandToInclude(bounds);
  }
  if (union == null) return null;
  final margin = math.max(union.width, union.height) * sceneCropMargin;
  final view = union.inflate(margin).intersect(canvas);
  if (view.isEmpty) return null;
  final ratio = view.width / view.height;
  if (ratio > ModuleScene.maxAspect || ratio < 1 / ModuleScene.maxAspect) {
    return null;
  }
  return view;
}

Rect? _opBounds(SceneOp op, ModuleScene scene) {
  switch (op) {
    case CellsOp():
      final box = op.box;
      if (box == null) return Rect.fromLTWH(0, 0, scene.width, scene.height);
      return Rect.fromLTWH(box.x, box.y, box.w, box.h);
    case RectOp():
      return Rect.fromLTWH(op.x, op.y, op.w, op.h).inflate(op.strokeWidth / 2);
    case CircleOp():
      return Rect.fromCircle(
        center: Offset(op.cx, op.cy),
        radius: op.r + op.strokeWidth / 2,
      );
    case LineOp():
      return Rect.fromPoints(
        Offset(op.x1, op.y1),
        Offset(op.x2, op.y2),
      ).inflate(op.strokeWidth / 2);
    case PathOp():
      final path = buildScenePath(op.steps, 1, 1).getBounds();
      return path.isEmpty && path.width == 0 && path.height == 0
          ? null
          : path.inflate(op.strokeWidth / 2);
    case TextOp():
      final width = op.text.length * op.size * _glyphAdvance;
      final left = switch (op.align) {
        'center' => op.x - width / 2,
        'right' => op.x - width,
        _ => op.x,
      };
      final height = op.size * _lineHeight;
      return Rect.fromLTWH(left, op.y - height / 2, width, height);
    case ImageOp():
      return Rect.fromLTWH(op.x, op.y, op.w, op.h);
    case InputOp():
      final reserve = math.max(scene.width, scene.height) * sceneInputReserve;
      return Rect.fromLTWH(op.x, op.y, op.w, reserve);
    case NotesOp():
      return null;
  }
}
