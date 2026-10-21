// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An independent reference model of what a [CanvasDocument] should hold, for
/// `canvas_document_fuzz_test.dart`.
///
/// It is written from the documented contract of the document (dedupe by id,
/// tombstones, scoped clear, restore, kill) and never calls into the document
/// or the spatial grid, so a bug shared by both could not make them agree.
library;

import 'dart:ui';

import 'package:slimm_voice_canvas/voice_canvas.dart';

class ModelObject {
  ModelObject({
    required this.id,
    required this.kind,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.z,
    required this.seq,
    required this.author,
    required this.width,
    required this.rel,
    this.text,
  });

  final String id;
  final CanvasObjectKind kind;
  double x;
  double y;
  double w;
  double h;
  int z;
  int seq;
  final String? author;
  final double width;
  final List<double> rel;
  String? text;
  bool alive = true;

  Rect get box => Rect.fromLTWH(x, y, w, h);

  /// Absolute points, the way a hit test sees them.
  List<Offset> get absolutePoints => [
        for (var i = 0; i + 1 < rel.length; i += 2)
          Offset(x + rel[i], y + rel[i + 1]),
      ];
}

/// What the document should answer after every step.
class DocumentModel {
  /// Every id the document still holds a slot for: alive, or killed.
  final Map<String, ModelObject> known = {};

  /// Ids told to drop that no restore has lifted.
  final Set<String> tombstones = {};

  Iterable<ModelObject> get alive => known.values.where((o) => o.alive);
  int get killedCount => known.values.where((o) => !o.alive).length;

  /// Whether a placement of [input] is accepted.
  bool place(CanvasStrokeInput input) {
    if (tombstones.contains(input.id)) return false;
    final existing = known[input.id];
    if (existing != null) {
      existing.alive = true;
      // A repeated reply must not undo a reorder that landed after the original.
      if (input.seq == 0 || input.seq > existing.seq) {
        existing
          ..z = input.zIndex
          ..seq = input.seq;
      }
      return true;
    }
    known[input.id] = ModelObject(
      id: input.id,
      kind: input.kind,
      x: input.x,
      y: input.y,
      w: input.w,
      h: input.h,
      z: input.zIndex,
      seq: input.seq,
      author: input.authorId,
      width: input.width,
      rel: List<double>.of(input.points),
      text: input.text,
    );
    return true;
  }

  bool move(String id, double x, double y, double w, double h) {
    final o = known[id];
    if (o == null || !o.alive) return false;
    o
      ..x = x
      ..y = y
      ..w = w
      ..h = h;
    return true;
  }

  bool setZ(String id, int z) {
    final o = known[id];
    if (o == null || !o.alive) return false;
    o.z = z;
    return true;
  }

  bool setText(String id, String text) {
    final o = known[id];
    if (o == null || !o.alive || o.kind != CanvasObjectKind.note) return false;
    o.text = text;
    return true;
  }

  void remove(String id) {
    tombstones.add(id);
    known.remove(id);
  }

  void clearBelow(
    int beforeSeq,
    Set<CanvasObjectKind> kinds,
    String? authorId,
  ) {
    final doomed = [
      for (final o in known.values)
        if (o.seq > 0 &&
            o.seq <= beforeSeq &&
            (kinds.isEmpty || kinds.contains(o.kind)) &&
            (authorId == null || o.author == authorId))
          o.id,
    ];
    doomed.forEach(remove);
  }

  /// A restore lifts the tombstone and leaves anything still live exactly as it was.
  void forgetRemoved(Iterable<String> ids) {
    tombstones.removeAll(ids);
  }

  void kill(String id) {
    final o = known[id];
    if (o != null) o.alive = false;
  }

  void reset() {
    known.clear();
    tombstones.clear();
  }

  /// Ids a board of [board] cannot hold whole, by the document's stated rule.
  Set<String> outsideBoard(Rect? board) {
    if (board == null) return {};
    final padded = board.inflate(0.5);
    return {
      for (final o in alive)
        if (!boardHoldsBox(padded, o.box) &&
            (o.kind != CanvasObjectKind.stroke ||
                (o.w <= padded.width && o.h <= padded.height)))
          o.id,
    };
  }

  /// The paint order (z, then seq) both sides promise; slot breaks the rest.
  static int byPaint(ModelObject a, ModelObject b) {
    final z = a.z.compareTo(b.z);
    return z != 0 ? z : a.seq.compareTo(b.seq);
  }
}
