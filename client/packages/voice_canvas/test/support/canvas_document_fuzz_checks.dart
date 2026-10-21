// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_document_fuzz_run.dart';

/// What [DocumentFuzzRun] holds the document to after every step.
extension DocumentFuzzChecks on DocumentFuzzRun {
  void _checkFields(List<ModelObject> alive) {
    for (final o in model.known.values) {
      if (document.knows(o.id) != true) {
        violate('knows', 'knows(${o.id}) is false for a held object');
      }
      if (document.isAlive(o.id) != o.alive) {
        violate(
          'isAlive',
          'isAlive(${o.id})=${document.isAlive(o.id)}, expected ${o.alive}',
        );
        continue;
      }
      if (!o.alive) continue;
      final b = document.objectBounds(o.id);
      if (b == null ||
          (b.x - o.x).abs() > 1e-9 ||
          (b.y - o.y).abs() > 1e-9 ||
          (b.w - o.w).abs() > 1e-9 ||
          (b.h - o.h).abs() > 1e-9) {
        violate('objectBounds', 'objectBounds(${o.id})=$b, expected ${o.box}');
      }
      if (document.zIndexOf(o.id) != o.z) {
        violate('zIndexOf',
            'zIndexOf(${o.id})=${document.zIndexOf(o.id)}, expected ${o.z}');
      }
      if (document.kindOf(o.id) != o.kind) {
        violate('kindOf', 'kindOf(${o.id}) disagrees');
      }
      if (document.authorIdOf(o.id) != o.author) {
        violate('authorIdOf', 'authorIdOf(${o.id}) disagrees');
      }
      if (o.kind == CanvasObjectKind.note &&
          document.noteTextOf(o.id) != o.text) {
        violate('noteTextOf', 'noteTextOf(${o.id}) disagrees');
      }
    }
    for (final id in model.tombstones) {
      if (document.isAlive(id) && !model.known.containsKey(id)) {
        violate('tombstone alive', 'removed id $id reads as alive');
      }
    }
  }

  void _checkGrid(List<ModelObject> alive) {
    final out = CullResult();
    document.scene.queryRect(-1e9, -1e9, 1e9, 1e9, out);
    final seen = <String>[];
    for (final slot in out.slots) {
      final stroke = document.strokeIfAlive(slot);
      if (stroke != null) seen.add(stroke.id);
    }
    final want = alive.map((o) => o.id).toSet();
    if (seen.length != seen.toSet().length) {
      violate('grid duplicates', 'the grid returned one id twice: $seen');
    }
    if (seen.toSet().length != want.length || !seen.toSet().containsAll(want)) {
      violate(
        'grid finds live objects',
        'grid found ${seen.toSet()} but live objects are $want',
      );
    }
    final inGrid = document.scene.objectCount;
    final expectedInGrid = alive.length + model.killedCount;
    if (inGrid != expectedInGrid) {
      violate(
        'grid slot leak',
        'grid holds $inGrid slots, live=${alive.length} killed=${model.killedCount}',
      );
    }
  }

  Rect _view() {
    final view = document.worldView;
    final board = document.board;
    return board == null ? view : view.intersect(board);
  }

  bool _visible(ModelObject o, Rect view) =>
      o.x <= view.right &&
      o.x + o.w >= view.left &&
      o.y <= view.bottom &&
      o.y + o.h >= view.top;

  void _checkPaintOrder(List<ModelObject> alive) {
    final view = _view().inflate(model.cullPad);
    final slots = document.paintOrder.toList();
    final ids = <String>[];
    for (final slot in slots) {
      final stroke = document.strokeIfAlive(slot);
      if (stroke == null) {
        violate('painted dead slot', 'paint order holds a dead slot $slot');
        continue;
      }
      ids.add(stroke.id);
    }
    final want = {
      for (final o in alive)
        if (_visible(o, view)) o.id
    };
    if (ids.length != ids.toSet().length) {
      violate('paint order duplicates', 'paint order repeats an id: $ids');
    }
    if (ids.toSet().length != want.length || !ids.toSet().containsAll(want)) {
      violate(
        'paint order is the live visible set',
        'painted ${ids.toSet()}, live and visible are $want',
      );
    }
    for (var i = 1; i < ids.length; i++) {
      final a = model.known[ids[i - 1]];
      final b = model.known[ids[i]];
      if (a == null || b == null) {
        violate('painted removed id',
            'painted ${a == null ? ids[i - 1] : ids[i]} which is not held');
        continue;
      }
      if (DocumentModel.byPaint(a, b) > 0) {
        violate(
          'paint order sorted',
          '${a.id}(z=${a.z},seq=${a.seq}) painted before ${b.id}(z=${b.z},seq=${b.seq})',
        );
      }
    }
    final visibleIds = document.visibleIds;
    if (visibleIds.length != want.length || !visibleIds.containsAll(want)) {
      violate('visibleIds', 'visibleIds=$visibleIds, expected $want');
    }
  }

  double _distance(Offset p, List<Offset> pts) {
    if (pts.isEmpty) return double.infinity;
    if (pts.length == 1) return (p - pts.first).distance;
    var best = double.infinity;
    for (var i = 0; i + 1 < pts.length; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      final ab = b - a;
      final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
      final t = len2 == 0
          ? 0.0
          : (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2)
              .clamp(0.0, 1.0);
      final d = (p - Offset(a.dx + t * ab.dx, a.dy + t * ab.dy)).distance;
      best = math.min(best, d);
    }
    return best;
  }

  void _checkHitTests(List<ModelObject> alive) {
    final zoom = document.camera.zoom;
    for (final o in alive) {
      if (o.kind == CanvasObjectKind.stroke && o.rel.isEmpty) continue;
      final probe = o.hitProbe;
      final hitId = o.kind == CanvasObjectKind.stroke
          ? hitTestStroke(document, probe)
          : hitTestBoxAt(document, probe);
      // The board's clip hides everything past its edge, so nothing there is hit.
      if (hitId == null && !(document.board?.contains(probe) ?? true)) continue;
      if (hitId == null) {
        violate('hit test misses a live object',
            'nothing hit at the ${o.kind.name} ${o.id} itself');
        continue;
      }
      final hit = model.known[hitId];
      if (hit == null || !hit.alive) {
        violate('hit test returns a dead id',
            'hit test returned $hitId which is not live');
        continue;
      }
      _checkTopmost(o, hit, probe, zoom);
    }
    for (final id in model.tombstones) {
      final stale = _graveyard[id];
      if (stale == null) continue;
      final hitId =
          hitTestStroke(document, stale) ?? hitTestBoxAt(document, stale);
      if (hitId == id) {
        violate(
            'removed id hit-testable', 'removed id $id is still hit at $stale');
      }
    }
    for (final o in alive) {
      _graveyard[o.id] = o.hitProbe;
    }
  }

  void _checkTopmost(
      ModelObject target, ModelObject hit, Offset probe, double zoom) {
    final isStrokeProbe = target.kind == CanvasObjectKind.stroke;
    ModelObject? best;
    for (final c in model.alive) {
      final sure = isStrokeProbe
          ? c.kind == CanvasObjectKind.stroke &&
              _distance(probe, c.absolutePoints) <= c.width / 2 + 4 / zoom - 1
          : c.kind != CanvasObjectKind.stroke &&
              c.kind != CanvasObjectKind.shape &&
              c.box.contains(probe) &&
              probe.dx > c.x &&
              probe.dx < c.x + c.w &&
              probe.dy > c.y &&
              probe.dy < c.y + c.h;
      if (sure && (best == null || DocumentModel.byPaint(c, best) > 0)) {
        best = c;
      }
    }
    if (best != null && DocumentModel.byPaint(hit, best) < 0) {
      violate(
        'hit test is not topmost',
        'hit ${hit.id}(z=${hit.z},seq=${hit.seq}) but ${best.id}(z=${best.z},seq=${best.seq}) is above it at $probe',
      );
    }
  }

  void _checkSelection() {
    for (final entry in {
      'selectedObjectId': document.selectedObjectId.value,
      'elevatedObjectId': document.elevatedObjectId.value,
    }.entries) {
      final id = entry.value;
      if (id != null && !(model.known[id]?.alive ?? false)) {
        violate(
          '${entry.key} names a removed object',
          '${entry.key} is still "$id" but that object is not live',
        );
      }
    }
  }

  void _checkBoard() {
    final outside = model.outsideBoard(document.board).toSet();
    final got = document.idsOutsideBoard.toSet();
    if (got.length != outside.length || !got.containsAll(outside)) {
      violate('idsOutsideBoard', 'idsOutsideBoard=$got, expected $outside');
    }
    if (document.outsideBoardCount.value != got.length) {
      violate(
        'outsideBoardCount',
        'outsideBoardCount=${document.outsideBoardCount.value}, ids=${got.length}',
      );
    }
  }

  void _checkAggregates(List<ModelObject> alive) {
    final counts = document.liveCountsByKind;
    int of(CanvasObjectKind k) => alive.where((o) => o.kind == k).length;
    if (counts.strokes != of(CanvasObjectKind.stroke) ||
        counts.images != of(CanvasObjectKind.image) ||
        counts.notes != of(CanvasObjectKind.note) ||
        counts.shapes != of(CanvasObjectKind.shape)) {
      violate('liveCountsByKind', 'counts=$counts, live=${alive.length}');
    }
    final authors = {
      for (final o in alive)
        if (o.author != null) o.author!
    };
    if (!document.authorIds().containsAll(authors) ||
        document.authorIds().length != authors.length) {
      violate('authorIds',
          'authorIds()=${document.authorIds()}, expected $authors');
    }
    Rect? union;
    for (final o in alive) {
      union = union?.expandToInclude(o.box) ?? o.box;
    }
    final got = document.contentBounds;
    if ((union == null) != (got == null) ||
        (union != null &&
            (union.left - got!.left).abs() +
                    (union.top - got.top).abs() +
                    (union.right - got.right).abs() +
                    (union.bottom - got.bottom).abs() >
                1e-6)) {
      violate('contentBounds', 'contentBounds=$got, expected $union');
    }
    final zs = [
      for (final o in alive)
        if (o.z != provisionalLocalZIndex) o.z,
    ];
    final range = document.zIndexRange;
    final wantRange =
        zs.isEmpty ? null : (zs.reduce(math.min), zs.reduce(math.max));
    if (range != wantRange) {
      violate('zIndexRange', 'zIndexRange=$range, expected $wantRange');
    }
  }
}
