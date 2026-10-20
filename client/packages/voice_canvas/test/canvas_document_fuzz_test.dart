// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Seeded random op streams against [CanvasDocument], checked after every
/// step against an independent reference model
/// (`support/canvas_document_model.dart`).
///
/// Every violation is collected by category with the seed, the step and the
/// tail of the op trace that produced it, and the test fails once at the end
/// listing all of them, so one run names every distinct way the document
/// disagrees with the contract it documents.
///
/// Invariants: the object count, every per-object field, the grid finding
/// exactly the live objects, paint order being a sorted permutation of the
/// live visible ids, no removed or killed id being hit-testable, the
/// selection never naming a removed object, and the board bookkeeping.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'support/canvas_document_model.dart';

const int _seeds = 300;
const int _steps = 160;

/// A small pool so placements collide with live, killed and removed ids.
const int _idPool = 12;

const List<String?> _authors = ['ann', 'bob', 'cy', null];

class _Violation {
  _Violation(this.seed, this.step, this.detail, this.trace);

  final int seed;
  final int step;
  final String detail;
  final List<String> trace;
}

class _Run {
  _Run(this.seed, this.violations) : rng = math.Random(seed) {
    document.setViewport(const Size(900, 600));
  }

  final int seed;
  final Map<String, _Violation> violations;
  final math.Random rng;
  final CanvasDocument document = CanvasDocument();
  final DocumentModel model = DocumentModel();
  final List<String> trace = [];
  int step = 0;
  int nextSeq = 1;

  void violate(String category, String detail) {
    violations.putIfAbsent(
      category,
      () => _Violation(
        seed,
        step,
        detail,
        trace.length > 14 ? trace.sublist(trace.length - 14) : [...trace],
      ),
    );
  }

  String _id() => 'p${rng.nextInt(_idPool)}';

  double _coord() {
    final roll = rng.nextInt(20);
    if (roll == 0) return (rng.nextBool() ? 1 : -1) * 4900000.0;
    if (roll < 4) return rng.nextDouble() * 2400 - 200;
    return rng.nextDouble() * 6000 - 3000;
  }

  CanvasStrokeInput _input(String id) {
    final kind = CanvasObjectKind.values[rng.nextInt(4)];
    final local = rng.nextInt(6) == 0;
    final seq = local ? 0 : nextSeq++;
    final z = local ? provisionalLocalZIndex : seq;
    final author = _authors[rng.nextInt(_authors.length)];
    final x = _coord();
    final y = _coord();
    if (kind == CanvasObjectKind.stroke) {
      final count = 1 + rng.nextInt(6);
      final points = <double>[];
      var w = 0.0;
      var h = 0.0;
      for (var i = 0; i < count; i++) {
        final px = rng.nextDouble() * 300;
        final py = rng.nextDouble() * 300;
        points
          ..add(px)
          ..add(py);
        w = math.max(w, px);
        h = math.max(h, py);
      }
      return CanvasStrokeInput(
        id: id,
        seq: seq,
        zIndex: z,
        x: x,
        y: y,
        w: w,
        h: h,
        points: points,
        width: 1 + rng.nextInt(40).toDouble(),
        colorKey: 'annotation',
        authorId: author,
      );
    }
    return CanvasStrokeInput(
      id: id,
      seq: seq,
      zIndex: z,
      x: x,
      y: y,
      w: rng.nextInt(8) == 0 ? 0 : 10 + rng.nextDouble() * 600,
      h: rng.nextInt(8) == 0 ? 0 : 10 + rng.nextDouble() * 400,
      points: const [],
      width: 0,
      colorKey: kind.name,
      authorId: author,
      kind: kind,
      attachmentId: kind == CanvasObjectKind.image ? 'att' : null,
      text: kind == CanvasObjectKind.note ? 'n${rng.nextInt(99)}' : null,
      shapeKind: kind == CanvasObjectKind.shape
          ? CanvasShapeKind.values[rng.nextInt(4)]
          : null,
    );
  }

  void run() {
    for (step = 0; step < _steps; step++) {
      _act();
      _check();
    }
  }

  void _act() {
    final roll = rng.nextInt(100);
    if (roll < 26) return _place(_id());
    if (roll < 34) return _placeKnownAgain();
    if (roll < 46) return _move();
    if (roll < 54) return _reorder();
    if (roll < 63) return _remove();
    if (roll < 67) return _clear();
    if (roll < 74) return _forget();
    if (roll < 78) return _kill();
    if (roll < 81) return _editNote();
    if (roll < 87) return _select();
    if (roll < 89) return _elevate();
    if (roll < 95) return _camera();
    if (roll < 97) return _board();
    if (roll < 98) return _reset();
    return document.refresh();
  }

  void _place(String id) {
    final input = _input(id);
    trace.add(
      'place $id ${input.kind.name} seq=${input.seq} z=${input.zIndex} '
      'at (${input.x.toStringAsFixed(0)}, ${input.y.toStringAsFixed(0)})',
    );
    final accepted = document.applyPlaced(input) != null;
    final expected = model.place(input);
    if (accepted != expected) {
      violate(
        'applyPlaced accept/refuse',
        'applyPlaced($id) accepted=$accepted but the contract says $expected',
      );
    }
  }

  void _placeKnownAgain() {
    final ids = [...model.known.keys, ...model.tombstones];
    if (ids.isEmpty) return _place(_id());
    _place(ids[rng.nextInt(ids.length)]);
  }

  String? _alivePick() {
    final ids = model.alive.map((o) => o.id).toList();
    return ids.isEmpty ? null : ids[rng.nextInt(ids.length)];
  }

  void _move() {
    final id = rng.nextInt(5) == 0 ? _id() : _alivePick() ?? _id();
    final x = _coord();
    final y = _coord();
    // A stroke's ink cannot be resized, so the app only ever moves it whole.
    final held = model.known[id];
    final fixed = held != null && held.kind == CanvasObjectKind.stroke;
    final w = fixed ? held.w : rng.nextDouble() * 500;
    final h = fixed ? held.h : rng.nextDouble() * 400;
    trace.add('move $id to (${x.toStringAsFixed(0)}, ${y.toStringAsFixed(0)})');
    final moved = document.moveObject(id, x, y, w, h);
    final expected = model.move(id, x, y, w, h);
    if (moved != expected) {
      violate('moveObject result', 'moveObject($id)=$moved, expected $expected');
    }
  }

  void _reorder() {
    final id = rng.nextInt(5) == 0 ? _id() : _alivePick() ?? _id();
    final z = rng.nextInt(60) - 10;
    trace.add('reorder $id z=$z');
    final done = document.setZIndex(id, z);
    final expected = model.setZ(id, z);
    if (done != expected) {
      violate('setZIndex result', 'setZIndex($id)=$done, expected $expected');
    }
  }

  void _remove() {
    final id = rng.nextInt(4) == 0 ? _id() : _alivePick() ?? _id();
    trace.add('remove $id');
    document.removeObject(id);
    model.remove(id);
  }

  void _clear() {
    final before = rng.nextInt(math.max(2, nextSeq + 2));
    final kinds = <CanvasObjectKind>{
      if (rng.nextInt(3) == 0)
        for (final k in CanvasObjectKind.values)
          if (rng.nextBool()) k,
    };
    final author = rng.nextInt(4) == 0
        ? _authors[rng.nextInt(_authors.length - 1)]
        : null;
    trace.add(
      'clearBelow $before kinds=${kinds.map((k) => k.name).toList()} '
      'author=$author',
    );
    document.clearBelow(before, kinds: kinds, authorId: author);
    model.clearBelow(before, kinds, author);
  }

  // Only ids the document no longer holds: a restore names removed objects.
  // A restore of a live one is exercised by its own test below.
  void _forget() {
    final ids = <String>{
      for (var i = 0; i < 1 + rng.nextInt(3); i++) _id(),
    }..removeWhere(model.known.containsKey);
    trace.add('forgetRemoved ${ids.toList()}');
    document.forgetRemoved(ids);
    model.forgetRemoved(ids);
  }

  void _kill() {
    final id = _alivePick() ?? _id();
    trace.add('kill $id');
    document.kill(id);
    model.kill(id);
  }

  void _editNote() {
    final id = _alivePick() ?? _id();
    final text = 'edit${rng.nextInt(99)}';
    trace.add('setNoteText $id');
    final done = document.setNoteText(id, text);
    final expected = model.setText(id, text);
    if (done != expected) {
      violate('setNoteText result', 'setNoteText($id)=$done, expected $expected');
    }
  }

  void _select() {
    final id = _alivePick();
    trace.add('select $id');
    document.selectedObjectId.value = id;
  }

  void _elevate() {
    final id = _alivePick();
    trace.add('elevate $id');
    document.elevatedObjectId.value = id;
  }

  void _camera() {
    final size = Size(200 + rng.nextInt(1800).toDouble(), 200 + rng.nextInt(900).toDouble());
    trace.add('viewport ${size.width.toInt()}x${size.height.toInt()}');
    document.setViewport(size);
    final zoom = 0.25 + rng.nextDouble() * 3.75;
    document.setCamera(Camera(x: _coord(), y: _coord(), zoom: zoom));
    trace.add('camera zoom=${zoom.toStringAsFixed(2)}');
  }

  void _board() {
    final on = rng.nextBool();
    trace.add('board ${on ? 'on' : 'off'}');
    document.setBoard(on ? canvasBoard : null);
  }

  void _reset() {
    trace.add('reset');
    document.reset();
    model.reset();
  }

  void _check() {
    document.refresh();
    final alive = model.alive.toList();
    if (document.objectCount.value != alive.length) {
      violate(
        'objectCount',
        'objectCount=${document.objectCount.value}, live objects=${alive.length}',
      );
    }
    _checkFields(alive);
    _checkGrid(alive);
    _checkPaintOrder(alive);
    _checkHitTests(alive);
    _checkSelection();
    _checkBoard();
    _checkAggregates(alive);
  }

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
        violate('zIndexOf', 'zIndexOf(${o.id})=${document.zIndexOf(o.id)}, expected ${o.z}');
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
    final view = _view();
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
    final want = {for (final o in alive) if (_visible(o, view)) o.id};
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
        violate('painted removed id', 'painted ${a == null ? ids[i - 1] : ids[i]} which is not held');
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
          : (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2).clamp(0.0, 1.0);
      final d = (p - Offset(a.dx + t * ab.dx, a.dy + t * ab.dy)).distance;
      best = math.min(best, d);
    }
    return best;
  }

  void _checkHitTests(List<ModelObject> alive) {
    final zoom = document.camera.zoom;
    for (final o in alive) {
      final probe = o.kind == CanvasObjectKind.stroke
          ? (o.absolutePoints.isEmpty ? null : o.absolutePoints.first)
          : o.box.center;
      if (probe == null) continue;
      final hitId = o.kind == CanvasObjectKind.stroke
          ? hitTestStroke(document, probe)
          : hitTestBoxAt(document, probe);
      if (hitId == null) {
        violate('hit test misses a live object', 'nothing hit at the ${o.kind.name} ${o.id} itself');
        continue;
      }
      final hit = model.known[hitId];
      if (hit == null || !hit.alive) {
        violate('hit test returns a dead id', 'hit test returned $hitId which is not live');
        continue;
      }
      _checkTopmost(o, hit, probe, zoom);
    }
    for (final id in model.tombstones) {
      final stale = _graveyard[id];
      if (stale == null) continue;
      final hitId = hitTestStroke(document, stale) ?? hitTestBoxAt(document, stale);
      if (hitId == id) {
        violate('removed id hit-testable', 'removed id $id is still hit at $stale');
      }
    }
    for (final o in alive) {
      _graveyard[o.id] = o.kind == CanvasObjectKind.stroke
          ? (o.absolutePoints.isEmpty ? o.box.center : o.absolutePoints.first)
          : o.box.center;
    }
  }

  final Map<String, Offset> _graveyard = {};

  void _checkTopmost(ModelObject target, ModelObject hit, Offset probe, double zoom) {
    final isStrokeProbe = target.kind == CanvasObjectKind.stroke;
    ModelObject? best;
    for (final c in model.alive) {
      final sure = isStrokeProbe
          ? c.kind == CanvasObjectKind.stroke &&
              _distance(probe, c.absolutePoints) <= c.width / 2 + 4 / zoom - 1
          : c.kind != CanvasObjectKind.stroke &&
              c.box.contains(probe) &&
              probe.dx > c.x &&
              probe.dx < c.x + c.w &&
              probe.dy > c.y &&
              probe.dy < c.y + c.h;
      if (sure && (best == null || DocumentModel.byPaint(c, best) > 0)) best = c;
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
    final authors = {for (final o in alive) if (o.author != null) o.author!};
    if (!document.authorIds().containsAll(authors) ||
        document.authorIds().length != authors.length) {
      violate('authorIds', 'authorIds()=${document.authorIds()}, expected $authors');
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
    final wantRange = zs.isEmpty
        ? null
        : (zs.reduce(math.min), zs.reduce(math.max));
    if (range != wantRange) {
      violate('zIndexRange', 'zIndexRange=$range, expected $wantRange');
    }
  }
}

void main() {
  test(
    'random op streams keep the document consistent with the model '
    '($_seeds seeds x $_steps steps)',
    timeout: const Timeout(Duration(minutes: 5)),
    () {
      final violations = <String, _Violation>{};
      for (var seed = 0; seed < _seeds; seed++) {
        _Run(seed, violations).run();
      }
      if (violations.isEmpty) return;
      final report = StringBuffer(
        '${violations.length} distinct violation(s):\n',
      );
      for (final entry in violations.entries) {
        final v = entry.value;
        report
          ..writeln('\n[${entry.key}] seed=${v.seed} step=${v.step}')
          ..writeln('  ${v.detail}')
          ..writeln('  trace tail:');
        for (final line in v.trace) {
          report.writeln('    $line');
        }
      }
      fail(report.toString());
    },
  );
}
