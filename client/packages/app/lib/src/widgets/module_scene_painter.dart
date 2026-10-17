// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Paints a [ModuleScene] and answers "what did a tap land on", the two
/// halves of rendering a module's scene. Both scale the scene's logical
/// coordinates to whatever box the widget is given, and both resolve named
/// colours against the viewer's theme so a module's drawing is native to
/// light and dark without the module choosing either.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'module_scene.dart';
import 'module_scene_path.dart';
import 'module_scene_sweep.dart';

class ModuleScenePainter extends CustomPainter {
  const ModuleScenePainter({
    required this.scene,
    required this.tokens,
    this.images = const {},
    this.time,
  }) : super(repaint: time);

  final ModuleScene scene;
  final AppTokens tokens;

  /// The decoded images available this frame, keyed by [ImageOp.key]. An image
  /// still decoding is simply absent, and its op draws nothing until a later
  /// frame has it - which is what lets an image take its place in the op order
  /// instead of being layered over the canvas.
  final Map<int, ui.Image> images;

  /// Seconds into the scene's `sweep` motion, or null to draw the end state.
  final Animation<double>? time;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = scene.viewWidth == 0 ? 1.0 : size.width / scene.viewWidth;
    final sy = scene.viewHeight == 0 ? 1.0 : size.height / scene.viewHeight;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = _resolve(scene.background, tokens.surfaceRaised),
    );
    canvas.translate(-scene.viewLeft * sx, -scene.viewTop * sy);
    final seconds = time?.value ?? double.infinity;
    for (final op in scene.ops) {
      _paintOp(canvas, applySweep(op, seconds), sx, sy);
    }
  }

  void _paintOp(Canvas canvas, SceneOp op, double sx, double sy) {
    switch (op) {
      case CellsOp():
        _paintCells(canvas, op, sx, sy);
      case RectOp():
        final rect = Rect.fromLTWH(op.x * sx, op.y * sy, op.w * sx, op.h * sy);
        final rrect = RRect.fromRectAndRadius(
          rect,
          Radius.circular(op.radius * sx),
        );
        if (op.gradient case final gradient?) {
          canvas.drawRRect(rrect, _gradientPaint(gradient, rect));
        } else if (op.fill != null) {
          canvas.drawRRect(
            rrect,
            Paint()..color = _resolve(op.fill, tokens.accent),
          );
        }
        _stroke(
          canvas,
          op.stroke,
          op.strokeWidth * sx,
          (p) => canvas.drawRRect(rrect, p),
        );
      case CircleOp():
        final center = Offset(op.cx * sx, op.cy * sy);
        final radius = op.r * ((sx + sy) / 2);
        if (op.gradient case final gradient?) {
          canvas.drawCircle(
            center,
            radius,
            _gradientPaint(
              gradient,
              Rect.fromCircle(center: center, radius: radius),
            ),
          );
        } else if (op.fill != null) {
          canvas.drawCircle(
            center,
            radius,
            Paint()..color = _resolve(op.fill, tokens.accent),
          );
        }
        _stroke(
          canvas,
          op.stroke,
          op.strokeWidth * sx,
          (p) => canvas.drawCircle(center, radius, p),
        );
      case LineOp():
        _stroke(
          canvas,
          op.stroke ?? 'muted',
          op.strokeWidth * sx,
          (p) => canvas.drawLine(
            Offset(op.x1 * sx, op.y1 * sy),
            Offset(op.x2 * sx, op.y2 * sy),
            p,
          ),
        );
      case PathOp():
        final path = buildScenePath(op.steps, sx, sy);
        if (op.fill != null) {
          canvas.drawPath(
            path,
            Paint()..color = _resolve(op.fill, tokens.accent),
          );
        }
        _stroke(
          canvas,
          op.stroke,
          op.strokeWidth * sx,
          (paint) => canvas.drawPath(path, paint),
        );
      case TextOp():
        _paintText(canvas, op, sx, sy);
      case ImageOp():
        final image = images[op.key];
        if (image == null) break;
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Rect.fromLTWH(op.x * sx, op.y * sy, op.w * sx, op.h * sy),
          Paint()..filterQuality = FilterQuality.medium,
        );
      case InputOp():
        // A real text field, not paint; ModuleSceneView overlays it.
        break;
      case NotesOp():
        // Sound, not drawing; ModuleSceneView plays it, this painter never does.
        break;
    }
  }

  void _paintCells(Canvas canvas, CellsOp op, double sx, double sy) {
    if (op.cols <= 0 || op.rows <= 0 || op.palette.isEmpty) return;
    final grid = cellsGridRect(op, scene, sx, sy);
    final cellW = grid.width / op.cols;
    final cellH = grid.height / op.rows;
    final inset = op.gap * (cellW < cellH ? cellW : cellH) / 2;
    // One Paint per palette entry, not per cell: a ticking board repaints cols*rows a second.
    final brushes = op.palette
        .map((name) => Paint()..color = _resolve(name, tokens.surfaceSunken))
        .toList(growable: false);
    for (var i = 0; i < op.data.length && i < op.cols * op.rows; i++) {
      final index = op.data.codeUnitAt(i) - 0x30;
      if (index < 0 || index >= brushes.length) continue;
      final col = i % op.cols;
      final row = i ~/ op.cols;
      final rect = Rect.fromLTWH(
        grid.left + col * cellW + inset,
        grid.top + row * cellH + inset,
        cellW - inset * 2,
        cellH - inset * 2,
      );
      canvas.drawRect(rect, brushes[index]);
    }
  }

  void _paintText(Canvas canvas, TextOp op, double sx, double sy) {
    final painter = TextPainter(
      text: TextSpan(
        text: op.text,
        style: TextStyle(
          color: _resolve(op.fill, tokens.textPrimary),
          fontSize: op.size * sy,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = switch (op.align) {
      'center' => op.x * sx - painter.width / 2,
      'right' => op.x * sx - painter.width,
      _ => op.x * sx,
    };
    painter.paint(canvas, Offset(dx, op.y * sy - painter.height / 2));
  }

  /// A two-stop linear gradient across [bounds].
  ///
  /// The shader is built per paint rather than cached: it depends on the shape's
  /// own rectangle, which changes with every resize, so a cache keyed on
  /// anything less than that would be wrong more often than it helped.
  Paint _gradientPaint(SceneGradient gradient, Rect bounds) {
    final (begin, end) = switch (gradient.direction) {
      'h' => (Alignment.centerLeft, Alignment.centerRight),
      'd' => (Alignment.topLeft, Alignment.bottomRight),
      _ => (Alignment.topCenter, Alignment.bottomCenter),
    };
    return Paint()
      ..shader = LinearGradient(
        begin: begin,
        end: end,
        colors: [
          _resolve(gradient.from, tokens.accent),
          _resolve(gradient.to, tokens.surfaceSunken),
        ],
      ).createShader(bounds);
  }

  void _stroke(
    Canvas canvas,
    String? color,
    double width,
    void Function(Paint) draw,
  ) {
    if (color == null) return;
    draw(
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width <= 0 ? 1 : width
        ..color = _resolve(color, tokens.borderSubtle),
    );
  }

  Color _resolve(String? name, Color fallback) =>
      resolveSceneColor(name, tokens, fallback);

  @override
  bool shouldRepaint(ModuleScenePainter old) =>
      !identical(old.scene, scene) ||
      old.tokens != tokens ||
      !identical(old.images, images) ||
      old.time != time;
}

/// Maps a scene colour name to a real colour: a `#rgb`/`#rrggbb`/`#aarrggbb`
/// literal is parsed as written; a theme-token name resolves against [tokens];
/// anything unrecognised falls back to [fallback].
Color resolveSceneColor(String? name, AppTokens tokens, Color fallback) {
  if (name == null || name.isEmpty) return fallback;
  if (name.startsWith('#')) return _parseHex(name) ?? fallback;
  return switch (name) {
    'bg' => tokens.surfaceBase,
    'surface' => tokens.surfaceRaised,
    'sunken' => tokens.surfaceSunken,
    'accent' => tokens.accent,
    'accent-soft' => tokens.accentSoft,
    'muted' => tokens.textSecondary,
    'text' => tokens.textPrimary,
    'border' => tokens.borderSubtle,
    'danger' => tokens.dangerText,
    _ => fallback,
  };
}

Color? _parseHex(String value) {
  var hex = value.substring(1);
  if (hex.length == 3) {
    hex = hex.split('').map((c) => '$c$c').join();
  }
  if (hex.length == 6) hex = 'ff$hex';
  if (hex.length != 8) return null;
  final parsed = int.tryParse(hex, radix: 16);
  return parsed == null ? null : Color(parsed);
}

/// The action a tap at [local] within a [size]-sized box lands on, or null if
/// it hit nothing interactive. Ops are tested topmost-first. A tap on a
/// [CellsOp] reports the specific cell as `"$tap:row,col"`; a tap on a [RectOp]
/// or [CircleOp] reports its bare `tap`.
/// Whether [action] came from a cells op that reads a `;`-separated list, so
/// several of them may be sent as one call. False for anything else, including
/// a scene from a module that has never heard of batching.
bool sceneAllowsTapBatch(ModuleScene scene, String action) {
  final prefix = action.split(':').first;
  for (final op in scene.ops) {
    if (op is CellsOp && op.tap == prefix) return op.tapBatch;
  }
  return false;
}

/// The painted box a grid occupies, in widget pixels.
///
/// Shared by the painter and the hit test on purpose: they disagreed about a
/// boxed grid the moment either one was written alone, and a grid whose cells
/// are drawn somewhere its taps are not read is the exact bug that is hardest
/// to see in a screenshot.
Rect cellsGridRect(CellsOp op, ModuleScene scene, double sx, double sy) {
  final box = op.box;
  return Rect.fromLTWH(
    (box?.x ?? 0) * sx,
    (box?.y ?? 0) * sy,
    (box?.w ?? scene.width) * sx,
    (box?.h ?? scene.height) * sy,
  );
}

String? sceneTapAction(ModuleScene scene, Offset tapped, Size size) {
  final sx = scene.viewWidth == 0 ? 1.0 : size.width / scene.viewWidth;
  final sy = scene.viewHeight == 0 ? 1.0 : size.height / scene.viewHeight;
  final local = tapped.translate(scene.viewLeft * sx, scene.viewTop * sy);
  for (final op in scene.ops.reversed) {
    switch (op) {
      case CellsOp() when op.tap != null && op.cols > 0 && op.rows > 0:
        final grid = cellsGridRect(op, scene, sx, sy);
        final col = ((local.dx - grid.left) / (grid.width / op.cols)).floor();
        final row = ((local.dy - grid.top) / (grid.height / op.rows)).floor();
        if (col >= 0 && col < op.cols && row >= 0 && row < op.rows) {
          return '${op.tap}:$row,$col';
        }
      case RectOp() when op.tap != null:
        final rect = Rect.fromLTWH(op.x * sx, op.y * sy, op.w * sx, op.h * sy);
        if (rect.contains(local)) return op.tap;
      case CircleOp() when op.tap != null:
        final center = Offset(op.cx * sx, op.cy * sy);
        if ((local - center).distance <= op.r * ((sx + sy) / 2)) return op.tap;
      case ImageOp() when op.tap != null:
        final rect = Rect.fromLTWH(op.x * sx, op.y * sy, op.w * sx, op.h * sy);
        if (rect.contains(local)) return op.tap;
      case PathOp() when op.tap != null:
        if (buildScenePath(op.steps, sx, sy).contains(local)) return op.tap;
      default:
        break;
    }
  }
  return null;
}
