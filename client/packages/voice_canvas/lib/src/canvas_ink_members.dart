// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the ink texture holds, object by object, so a change to a few objects redraws only where they are.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'canvas_document.dart';
import 'canvas_object_painter.dart'
    show
        arrowheadLength,
        minArrowheadScreenPx,
        minInkScreenPx,
        shapeOutlineWorld;

/// One object drawn into the texture, as it was when drawn.
class InkMember {
  InkMember(this.stroke, this.bounds)
      : version = stroke.paintVersion,
        zIndex = stroke.zIndex,
        seq = stroke.seq;

  final CanvasStroke stroke;

  /// Where its ink reached in the world, padded for line width and antialiasing.
  final ui.Rect bounds;
  final int version;
  int zIndex;
  int seq;
}

/// Whether [stroke] belongs in the texture: a dragged, previewed or unconfirmed object paints live over it.
bool inkCacheable(
  CanvasDocument document,
  CanvasStroke stroke,
  String? elevated,
) =>
    stroke.alive &&
    stroke.seq != 0 &&
    stroke.id != elevated &&
    !document.isHeldLive(stroke.id);

/// The world box [stroke]'s pixels can reach at [zoom].
ui.Rect inkReach(CanvasStroke stroke, double zoom) =>
    ui.Rect.fromLTWH(stroke.x, stroke.y, stroke.w, stroke.h)
        .inflate(_reachPast(stroke, zoom));

/// How far past its box [stroke]'s pixels reach: half its line, an arrowhead's wings, and the antialiased edge.
double _reachPast(CanvasStroke stroke, double zoom) {
  if (stroke.kind != CanvasObjectKind.shape) {
    return _lineReach(stroke.width, zoom);
  }
  final outline = _lineReach(shapeOutlineWorld, zoom);
  return stroke.shapeKind == CanvasShapeKind.arrow
      ? outline + _arrowheadReach(zoom)
      : outline;
}

double _lineReach(double width, double zoom) =>
    math.max(width, minInkScreenPx / zoom) / 2 + 2 / zoom;

double _arrowheadReach(double zoom) =>
    math.max(arrowheadLength, minArrowheadScreenPx / zoom);

/// The farthest any object on [document] reaches past its box at [zoom], so a lookup padded by it finds every one whose ink lands in a box.
double widestInkReach(CanvasDocument document, double zoom) => math.max(
      _lineReach(document.maxInkReach * 2, zoom),
      _lineReach(shapeOutlineWorld, zoom) + _arrowheadReach(zoom),
    );

/// The live object in [slot], or null once it is gone.
CanvasStroke? inkSlotStroke(CanvasDocument document, int slot) =>
    slot < document.scene.slotCount ? document.strokeIfAlive(slot) : null;

/// The members whose pixels changed or that left since they were drawn, and those only renumbered in paint order.
({List<int> stale, List<int> renumbered}) changedInkMembers(
  CanvasDocument document,
  Map<int, InkMember> members,
  String? elevated,
) {
  final stale = <int>[];
  final renumbered = <int>[];
  members.forEach((slot, member) {
    final now = inkSlotStroke(document, slot);
    if (now == null ||
        !identical(now, member.stroke) ||
        now.paintVersion != member.version ||
        !inkCacheable(document, now, elevated)) {
      stale.add(slot);
    } else if (now.zIndex != member.zIndex || now.seq != member.seq) {
      renumbered.add(slot);
    }
  });
  return (stale: stale, renumbered: renumbered);
}

/// Whether [members] bar [skip] stack now as they did when drawn; a placement reply renumbers a stroke without moving it.
bool inkStackKept(Map<int, InkMember> members, List<int> skip) {
  final skipped = skip.toSet();
  final slots = [
    for (final slot in members.keys)
      if (!skipped.contains(slot)) slot,
  ];
  int compare(int a, int b, {required bool drawn}) {
    final ma = members[a]!;
    final mb = members[b]!;
    final za = drawn ? ma.zIndex : ma.stroke.zIndex;
    final zb = drawn ? mb.zIndex : mb.stroke.zIndex;
    if (za != zb) return za.compareTo(zb);
    final sa = drawn ? ma.seq : ma.stroke.seq;
    final sb = drawn ? mb.seq : mb.stroke.seq;
    return sa != sb ? sa.compareTo(sb) : a.compareTo(b);
  }

  final before = [...slots]..sort((a, b) => compare(a, b, drawn: true));
  final after = [...slots]..sort((a, b) => compare(a, b, drawn: false));
  for (var i = 0; i < before.length; i++) {
    if (before[i] != after[i]) return false;
  }
  return true;
}
