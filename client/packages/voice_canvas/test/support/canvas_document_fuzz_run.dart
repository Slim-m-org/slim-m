// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One seeded random op stream against a [CanvasDocument], checked after every
/// step against the reference model; see `canvas_document_fuzz_test.dart`.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_document_model.dart';

part 'canvas_document_fuzz_checks.dart';

const List<String?> _authors = ['ann', 'bob', 'cy', null];

class DocumentFuzzViolation {
  DocumentFuzzViolation(this.seed, this.step, this.detail, this.trace);

  final int seed;
  final int step;
  final String detail;
  final List<String> trace;
}

class DocumentFuzzRun {
  DocumentFuzzRun(this.seed, this.violations,
      {this.steps = 160, this.idPool = 12})
      : rng = math.Random(seed) {
    document.setViewport(const Size(900, 600));
  }

  final int seed;
  final Map<String, DocumentFuzzViolation> violations;
  final math.Random rng;
  final CanvasDocument document = CanvasDocument();
  final DocumentModel model = DocumentModel();
  final List<String> trace = [];
  final int steps;
  final int idPool;
  int step = 0;
  int nextSeq = 1;

  void violate(String category, String detail) {
    violations.putIfAbsent(
      category,
      () => DocumentFuzzViolation(
        seed,
        step,
        detail,
        trace.length > 14 ? trace.sublist(trace.length - 14) : [...trace],
      ),
    );
  }

  String _id() => 'p${rng.nextInt(idPool)}';

  double _coord() {
    final roll = rng.nextInt(24);
    if (roll == 0) return (rng.nextBool() ? 1 : -1) * 4900000.0;
    // On, just before and just after a grid cell edge, where floor() decides the bucket.
    if (roll < 4) {
      return (rng.nextInt(9) - 4) * 1024.0 +
          [0.0, 1e-9, -1e-9, 0.5, -0.5][rng.nextInt(5)];
    }
    if (roll < 8) return rng.nextDouble() * 2400 - 200;
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
    for (step = 0; step < steps; step++) {
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
      violate(
          'moveObject result', 'moveObject($id)=$moved, expected $expected');
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
    final author =
        rng.nextInt(4) == 0 ? _authors[rng.nextInt(_authors.length - 1)] : null;
    trace.add(
      'clearBelow $before kinds=${kinds.map((k) => k.name).toList()} '
      'author=$author',
    );
    document.clearBelow(before, kinds: kinds, authorId: author);
    model.clearBelow(before, kinds, author);
  }

  // A restore names removed objects; one naming a live object has its own test.
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
      violate(
          'setNoteText result', 'setNoteText($id)=$done, expected $expected');
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
    final size = Size(
        200 + rng.nextInt(1800).toDouble(), 200 + rng.nextInt(900).toDouble());
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

  final Map<String, Offset> _graveyard = {};
}
