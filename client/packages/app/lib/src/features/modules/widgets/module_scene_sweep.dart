// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Motion a scene declares for one op, played by the client: decision 0043.
///
/// The module states where an op ends up and how long it takes; the client
/// interpolates. No further module call is made, so what a viewer pays is
/// fixed by the numbers here, not by anything the module does afterwards.
library;

import 'module_scene.dart';

/// A linear move from an op's declared geometry to that geometry plus the
/// deltas, once, then it holds. `dw` grows a rect's width or a circle's radius.
class SceneSweep {
  const SceneSweep({
    required this.secs,
    this.delay = 0,
    this.dx = 0,
    this.dy = 0,
    this.dw = 0,
    this.dh = 0,
  });

  /// Animated ops per scene; later ones draw still. Mirrored by the server.
  static const maxPerScene = 8;

  /// The longest a scene may keep moving, delay included.
  static const maxTimelineSeconds = 10.0;
  static const minSeconds = 0.1;
  static const maxDelta = 10000.0;

  final double secs;
  final double delay;
  final double dx;
  final double dy;
  final double dw;
  final double dh;

  double get end => delay + secs;

  /// How far along the move is at [seconds] into the scene, 0 to 1.
  double progress(double seconds) => ((seconds - delay) / secs).clamp(0.0, 1.0);

  /// Reads a module's `sweep` object, or null if it is not one. Every number
  /// is clamped rather than refused, like the rest of the scene contract.
  static SceneSweep? parse(Object? raw) {
    if (raw is! Map) return null;
    double number(String key) {
      final value = raw[key];
      return value is num && value.isFinite ? value.toDouble() : 0;
    }

    double delta(String key) => number(key).clamp(-maxDelta, maxDelta);
    final delay = number('delay').clamp(0.0, maxTimelineSeconds - minSeconds);
    // 10.0 - 9.9 is a hair under 0.1 in floating point, and clamp throws when its bounds cross.
    final longest = (maxTimelineSeconds - delay).clamp(
      minSeconds,
      maxTimelineSeconds,
    );
    return SceneSweep(
      delay: delay,
      secs: number('secs').clamp(minSeconds, longest),
      dx: delta('dx'),
      dy: delta('dy'),
      dw: delta('dw'),
      dh: delta('dh'),
    );
  }
}

/// The sweep an op carries, or null for an op that cannot be animated.
SceneSweep? sweepOf(SceneOp op) => switch (op) {
  RectOp() => op.sweep,
  CircleOp() => op.sweep,
  LineOp() => op.sweep,
  TextOp() => op.sweep,
  _ => null,
};

/// How long a scene keeps moving: zero for a still one.
double sceneTimelineSeconds(ModuleScene scene) {
  var end = 0.0;
  for (final op in scene.ops) {
    final sweep = sweepOf(op);
    if (sweep != null && sweep.end > end) end = sweep.end;
  }
  return end;
}

/// [op] as it should be drawn [seconds] into the scene.
SceneOp applySweep(SceneOp op, double seconds) {
  final sweep = sweepOf(op);
  if (sweep == null) return op;
  final p = sweep.progress(seconds);
  double grown(double base, double delta) => (base + delta * p).clamp(0, 1e9);
  return switch (op) {
    RectOp() => RectOp(
      x: op.x + sweep.dx * p,
      y: op.y + sweep.dy * p,
      w: grown(op.w, sweep.dw),
      h: grown(op.h, sweep.dh),
      fill: op.fill,
      gradient: op.gradient,
      stroke: op.stroke,
      strokeWidth: op.strokeWidth,
      radius: op.radius,
      tap: op.tap,
    ),
    CircleOp() => CircleOp(
      cx: op.cx + sweep.dx * p,
      cy: op.cy + sweep.dy * p,
      r: grown(op.r, sweep.dw),
      fill: op.fill,
      gradient: op.gradient,
      stroke: op.stroke,
      strokeWidth: op.strokeWidth,
      tap: op.tap,
    ),
    LineOp() => LineOp(
      x1: op.x1 + sweep.dx * p,
      y1: op.y1 + sweep.dy * p,
      x2: op.x2 + sweep.dx * p,
      y2: op.y2 + sweep.dy * p,
      stroke: op.stroke,
      strokeWidth: op.strokeWidth,
    ),
    TextOp() => TextOp(
      x: op.x + sweep.dx * p,
      y: op.y + sweep.dy * p,
      text: op.text,
      fill: op.fill,
      size: op.size,
      align: op.align,
    ),
    _ => op,
  };
}
