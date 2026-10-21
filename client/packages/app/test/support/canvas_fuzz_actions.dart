// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What people do on the canvas for the engine fuzz: local gestures through the real engine API, remote people acting on the server, and remote drag previews.
/// A local gesture is a script run one step per world tick, so frames and replies land mid-drag.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_commit_queue.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_ops_controller.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_quick_placement.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_clear_scope.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_fuzz_server.dart';
import 'canvas_fuzz_world.dart';

const double boardW = 1920;
const double boardH = 1080;
const List<String> remoteUsers = ['ann', 'bob', 'mod'];

extension FuzzActions on FuzzWorld {
  double _pick(double lo, double hi) => lo + rng.nextDouble() * (hi - lo);

  Offset _point() => Offset(_pick(20, boardW - 20), _pick(20, boardH - 20));

  FuzzObject? _anyObject() {
    final all = server.objects.values.toList();
    return all.isEmpty ? null : all[rng.nextInt(all.length)];
  }

  FuzzObject? _liveObject() {
    final all = server.liveObjects.toList();
    return all.isEmpty ? null : all[rng.nextInt(all.length)];
  }

  /// A point a pointer would land on to touch [o].
  Offset anchorOf(FuzzObject o) {
    if (o.kind == 'stroke') {
      final pts = (o.props['points'] as List).cast<num>();
      return Offset(o.x + pts[0].toDouble(), o.y + pts[1].toDouble());
    }
    return Offset(o.x + o.w / 2, o.y + o.h / 2);
  }

  // --- local gestures ---

  void localAction() {
    final client = clients[rng.nextInt(clients.length)];
    if (client.script.isNotEmpty) {
      client.script.removeAt(0)();
      flush();
      return;
    }
    final roll = rng.nextInt(100);
    if (roll < 24) return _draw(client);
    if (roll < 36) return _erase(client);
    if (roll < 50) return _selectAndDrag(client);
    if (roll < 56) return _deleteSelected(client);
    if (roll < 62) return _reorderSelected(client);
    if (roll < 67) return _editNote(client);
    if (roll < 79) return _undoRedo(client);
    if (roll < 84) return _clear(client);
    if (roll < 90) return _place(client);
    if (roll < 94) return _lock(client);
    _resize(client);
  }

  void _draw(FuzzClient client) {
    final engine = client.engine;
    final start = _point();
    final points = [
      for (var i = 0; i < 2 + rng.nextInt(5); i++)
        start + Offset(_pick(-90, 90) * i, _pick(-60, 60) * i),
    ];
    final ids = <String>[];
    const width = 3.0;
    for (final segment in splitStroke(points)) {
      final id = client.newId();
      ids.add(id);
      engine.document.applyPlaced(
        CanvasStrokeInput(
          id: id,
          seq: 0,
          zIndex: provisionalLocalZIndex + rng.nextInt(1000),
          x: segment.x,
          y: segment.y,
          w: segment.w,
          h: segment.h,
          points: segment.points,
          width: width,
          colorKey: 'annotation',
          authorId: client.userId,
        ),
      );
      engine.commits.add(
        CanvasCommit(
          id: id,
          x: segment.x,
          y: segment.y,
          w: segment.w,
          h: segment.h,
          props: {
            'points': segment.points,
            'width': width,
            'color': 'annotation',
          },
        ),
      );
    }
    engine.document.refresh();
    engine.ops.recordDraw(ids);
    note('${client.userId} draws $ids');
    flush();
  }

  void _erase(FuzzClient client) {
    final target = _anyObject();
    final centre = target == null ? _point() : anchorOf(target);
    final steps = 1 + rng.nextInt(3);
    note('${client.userId} starts erasing near ${target?.id}');
    for (var i = 0; i < steps; i++) {
      client.script.add(
        () => client.engine.ops.onErasePoint(
          centre + Offset(_pick(-6, 6), _pick(-6, 6)),
          manageCanvas: client.moderator,
          selfId: client.userId,
        ),
      );
    }
    client.script.add(() {
      note('${client.userId} lifts the eraser');
      unawaited(client.engine.ops.endErase());
    });
    client.script.removeAt(0)();
    flush();
  }

  void _selectAndDrag(FuzzClient client) {
    final target = _liveObject();
    if (target == null) return;
    final at = anchorOf(target);
    final ops = client.engine.ops;
    note('${client.userId} grabs ${target.id}');
    ops.beginSelect(at, manageCanvas: client.moderator, selfId: client.userId);
    final steps = 1 + rng.nextInt(4);
    var cursor = at;
    for (var i = 0; i < steps; i++) {
      cursor += Offset(_pick(-120, 120), _pick(-90, 90));
      final next = cursor;
      client.script.add(
        () => ops.dragSelect(next, lockAspect: true, snap: rng.nextBool()),
      );
    }
    client.script.add(() {
      note('${client.userId} drops');
      unawaited(ops.endSelect());
    });
    flush();
  }

  void _resize(FuzzClient client) {
    final id = client.engine.document.selectedObjectId.value;
    final bounds = id == null ? null : client.engine.document.objectBounds(id);
    if (bounds == null) return;
    final corner = Offset(bounds.x + bounds.w, bounds.y + bounds.h);
    final ops = client.engine.ops;
    note('${client.userId} resizes $id');
    ops.beginSelect(
      corner,
      manageCanvas: client.moderator,
      selfId: client.userId,
    );
    client.script.add(
      () => ops.dragSelect(
        corner + Offset(_pick(-40, 80), _pick(-30, 60)),
        lockAspect: false,
      ),
    );
    client.script.add(() => unawaited(ops.endSelect()));
  }

  void _deleteSelected(FuzzClient client) {
    final id = client.engine.document.selectedObjectId.value;
    if (id == null) return;
    if (!config.allows('deleteLocked') && server.locked.contains(id)) return;
    note('${client.userId} presses Delete on $id');
    unawaited(client.engine.ops.deleteSelected(id));
    flush();
  }

  void _reorderSelected(FuzzClient client) {
    final id = client.engine.document.selectedObjectId.value;
    if (id == null) return;
    final front = rng.nextBool();
    note('${client.userId} sends $id to ${front ? 'front' : 'back'}');
    unawaited(
      front
          ? client.engine.ops.bringToFront(id)
          : client.engine.ops.sendToBack(id),
    );
    flush();
  }

  void _editNote(FuzzClient client) {
    final notes = client.engine.document.visibleIds.where(
      (id) =>
          client.engine.document.kindOf(id) == CanvasObjectKind.note &&
          (config.allows('foreignEdit') ||
              client.moderator ||
              client.engine.document.authorIdOf(id) == client.userId),
    );
    if (notes.isEmpty) return;
    final id = notes.elementAt(rng.nextInt(notes.length));
    note('${client.userId} edits $id');
    unawaited(client.engine.ops.editNote(id, 'edited ${rng.nextInt(1000)}'));
    flush();
  }

  void _undoRedo(FuzzClient client) {
    final redo = rng.nextInt(3) == 0;
    note('${client.userId} presses ${redo ? 'redo' : 'undo'}');
    unawaited(redo ? client.engine.ops.redo() : client.engine.ops.undo());
    flush();
  }

  void _clear(FuzzClient client) {
    if (!client.moderator) return;
    final scope = switch (rng.nextInt(3)) {
      0 => api.CanvasClearScope.everything,
      1 => api.CanvasClearScope(
        kinds: [CanvasClearTarget.values[rng.nextInt(3)].kinds.first],
      ),
      _ => api.CanvasClearScope(
        authorId: ['me', 'ann', 'peer1'][rng.nextInt(3)],
      ),
    };
    note('${client.userId} clears ${scope.kinds} ${scope.authorId}');
    final engine = client.engine;
    unawaited(() async {
      await engine.sync.catchUp();
      final fence = engine.sync.asOfSeq;
      if (fence != null) await engine.ops.clear(fence, scope: scope);
    }());
    flush();
  }

  void _place(FuzzClient client) {
    final engine = client.engine;
    final placement = CanvasQuickPlacement(
      client: client.container.read(apiProvider),
      channelId: fuzzChannel,
      document: engine.document,
      timedOutUntil: () => null,
      authorId: () => client.userId,
      clearedSincePlacement: engine.sync.clearedSincePlacement,
    );
    final at = _point();
    if (rng.nextBool()) {
      note('${client.userId} places a note');
      unawaited(
        placement.placeNote(at, 'note ${rng.nextInt(99)}', onError: (_) {}),
      );
    } else {
      note('${client.userId} places a shape');
      unawaited(
        placement.placeShape(
          at,
          CanvasShapeKind.values[rng.nextInt(4)],
          draggedSize: Size(_pick(30, 300), _pick(30, 200)),
          onError: (_) {},
        ),
      );
    }
    flush();
  }

  void _lock(FuzzClient client) {
    if (!config.allows('locks')) return;
    final target = _liveObject();
    if (target == null) return;
    final value = !server.locked.contains(target.id);
    note('${client.userId} ${value ? 'locks' : 'unlocks'} ${target.id}');
    unawaited(client.engine.objectLocks.setLocked(target.id, value));
    flush();
  }

  void cameraAction() {
    final client = clients[rng.nextInt(clients.length)];
    final document = client.engine.document;
    final zoom = [0.5, 0.5, 1.0, 2.0, 4.0][rng.nextInt(5)];
    note('${client.userId} camera zoom=$zoom');
    document.setCamera(
      Camera(x: _pick(0, boardW), y: _pick(0, boardH), zoom: zoom),
    );
    flush();
  }

  /// A read of the whole board, as a pan out of the fetched region makes.
  void refetchAction() {
    final client = clients[rng.nextInt(clients.length)];
    note('${client.userId} re-reads the board');
    unawaited(client.engine.fetch());
    flush();
  }

  // --- remote people ---

  void remoteAction() {
    final actor = remoteUsers[rng.nextInt(remoteUsers.length)];
    final roll = rng.nextInt(100);
    if (roll < 30) return _remotePlace(actor);
    if (roll < 48) return _remoteMove(actor);
    if (roll < 56) return _remoteReorder(actor);
    if (roll < 62) return _remoteEdit(actor);
    if (roll < 74) return _remoteRemove(actor);
    if (roll < 80) return _remoteClear();
    if (roll < 90) return _remoteRestore();
    if (roll < 95 || !config.allows('previews')) return _remoteLock();
    _remotePreview(actor);
  }

  void _submitAs(String actor, Map<String, dynamic> body, String what) {
    try {
      final result = server.submit(actor, body);
      note('$actor $what -> seq=${result.seq} affected=${result.affected}');
    } on FuzzRefusal catch (refusal) {
      note('$actor $what refused ${refusal.status}');
    }
  }

  void _remotePlace(String actor) {
    final kind = ['stroke', 'stroke', 'note', 'shape'][rng.nextInt(4)];
    final w = kind == 'stroke' ? _pick(5, 200) : _pick(40, 300);
    final h = kind == 'stroke' ? _pick(5, 150) : _pick(30, 200);
    final x = _pick(0, boardW - w);
    final y = _pick(0, boardH - h);
    final props = switch (kind) {
      'stroke' => {
        'points': [0.0, 0.0, w / 2, h, w, 0.0],
        'width': 3.0,
        'color': 'annotation',
      },
      'note' => {'text': 'hello ${rng.nextInt(99)}'},
      _ => {
        'shape': ['rectangle', 'ellipse', 'line', 'arrow'][rng.nextInt(4)],
      },
    };
    final id = '$actor-o${server.ops.length}-${rng.nextInt(9999)}';
    server.place(actor, id, kind, x, y, w, h, props);
    note('$actor places $kind $id');
  }

  void _remoteMove(String actor) {
    final target = _liveObject();
    if (target == null) return;
    final box = target.kind == 'stroke'
        ? (w: target.w, h: target.h)
        : (w: _pick(20, 400), h: _pick(20, 300));
    _submitAs(actor, {
      'id': newOpId(actor),
      'kind': 'move',
      'object_id': target.id,
      'x': _pick(0, boardW - box.w),
      'y': _pick(0, boardH - box.h),
      'w': box.w,
      'h': box.h,
    }, 'moves ${target.id}');
  }

  void _remoteReorder(String actor) {
    final target = _liveObject();
    if (target == null) return;
    _submitAs(actor, {
      'id': newOpId(actor),
      'kind': 'reorder',
      'object_id': target.id,
      'z_index': server.ops.length + rng.nextInt(20) - 10,
    }, 'reorders ${target.id}');
  }

  void _remoteEdit(String actor) {
    final notes = server.liveObjects.where((o) => o.kind == 'note').toList();
    if (notes.isEmpty) return;
    final target = notes[rng.nextInt(notes.length)];
    _submitAs(actor, {
      'id': newOpId(actor),
      'kind': 'edit',
      'object_id': target.id,
      'props': {'text': 'remote edit ${rng.nextInt(99)}'},
    }, 'edits ${target.id}');
  }

  void _remoteRemove(String actor) {
    final live = server.liveObjects.toList()..shuffle(rng);
    final ids = [for (final o in live.take(1 + rng.nextInt(3))) o.id];
    if (ids.isEmpty) return;
    _submitAs(actor, {
      'id': newOpId(actor),
      'kind': 'remove',
      'object_ids': ids,
    }, 'removes $ids');
  }

  void _remoteClear() {
    final scoped = rng.nextBool();
    _submitAs('mod', {
      'id': newOpId('mod'),
      'kind': scoped ? 'clear_scoped' : 'clear',
      'before_seq': rng.nextInt(server.head + 1),
      if (scoped && rng.nextBool())
        'kinds': [
          ['stroke', 'note', 'shape'][rng.nextInt(3)],
        ],
      if (scoped) 'author_id': ['ann', 'bob', 'me'][rng.nextInt(3)],
    }, 'clears');
  }

  void _remoteRestore() {
    final targets = server.ops
        .where((o) => o.kind == 'remove' || o.kind == 'clear')
        .toList();
    if (targets.isEmpty) return;
    final target = targets[rng.nextInt(targets.length)];
    _submitAs(rng.nextBool() ? target.actor : 'mod', {
      'id': newOpId('re'),
      'kind': 'restore',
      'target_op': target.id,
    }, 'restores ${target.id}');
  }

  void _remoteLock() {
    if (!config.allows('locks')) return;
    final target = _liveObject();
    if (target == null) return;
    server.setLocked(target.id, !server.locked.contains(target.id));
    note(
      'remote ${server.locked.contains(target.id) ? 'locks' : 'unlocks'} ${target.id}',
    );
  }

  /// A drag seen only through its previews, which may or may not commit, and
  /// whose commit may reach a client late or only through a catch-up.
  void _remotePreview(String actor) {
    final target = _liveObject();
    if (target == null) return;
    final to = (x: _pick(0, boardW - target.w), y: _pick(0, boardH - target.h));
    note('$actor drags ${target.id}');
    for (var i = 1; i <= 3; i++) {
      final t = i / 3;
      publishEphemeral(
        api.CanvasObjectPreview(
          channelId: fuzzChannel,
          userId: actor,
          objectId: target.id,
          x: target.x + (to.x - target.x) * t,
          y: target.y + (to.y - target.y) * t,
          w: target.w,
          h: target.h,
          ended: i == 3,
        ),
      );
    }
    if (rng.nextInt(3) == 0) return;
    deferred.add((
      tickNo + rng.nextInt(6),
      () => _submitAs(actor, {
        'id': newOpId(actor),
        'kind': 'move',
        'object_id': target.id,
        'x': to.x,
        'y': to.y,
        'w': target.w,
        'h': target.h,
      }, 'commits the drag of ${target.id}'),
    ));
  }
}

extension FuzzTick on FuzzWorld {
  void tick() {
    tickNo++;
    final roll = rng.nextInt(100);
    if (roll < 22) {
      deliverFrame();
    } else if (roll < 38) {
      arrive();
    } else if (roll < 52) {
      deliverResponse();
    } else if (roll < 70) {
      localAction();
    } else if (roll < 86) {
      remoteAction();
    } else if (roll < 90) {
      config.camera ? cameraAction() : refetchAction();
    } else if (roll < 92) {
      flap();
    } else if (roll < 97) {
      elapse(rng.nextInt(40) == 0 ? 4000 + rng.nextInt(12000) : null);
    } else {
      runDeferred();
    }
    flush();
  }
}

double distanceBetween(Offset a, Offset b) =>
    math.sqrt(math.pow(a.dx - b.dx, 2) + math.pow(a.dy - b.dy, 2));
