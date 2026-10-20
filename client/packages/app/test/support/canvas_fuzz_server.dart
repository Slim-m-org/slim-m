// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An in-memory model of the server's canvas, written from
/// `crates/slimm-server/src/store/canvas/` and `.../http/canvas/`, for
/// `canvas_engine_fuzz_test.dart`: the same op stream, the same dense seq, the
/// same "an op row exists only for a real state transition" rule, the same
/// soft delete and restore fence, the same locked-object skip and the same
/// feed that joins a place op to the object's current row.
///
/// It answers in the server's wire JSON and publishes the server's frames, so
/// the real `CanvasEngine` is driven end to end.
library;

import 'package:slimm_api/api.dart' as api;

import 'canvas_fuzz_model.dart';

export 'canvas_fuzz_model.dart';

class FuzzServer {
  FuzzServer({required this.channelId, required this.publish});

  final String channelId;
  final void Function(api.ServerEvent event) publish;

  final Map<String, FuzzObject> objects = {};
  final List<FuzzOp> ops = [];
  final Map<String, FuzzOp> opById = {};
  final Set<String> locked = {};
  final Set<String> moderators = {};
  int _clock = 0;

  int get head => ops.length;

  Iterable<FuzzObject> get liveObjects => objects.values.where((o) => o.live);

  FuzzOp _record(String id, String kind, String actor) {
    final op = FuzzOp(
      seq: ops.length + 1,
      id: id,
      kind: kind,
      actor: actor,
      createdAt: ++_clock,
    );
    ops.add(op);
    opById[id] = op;
    return op;
  }

  // --- place ---

  ({FuzzObject object, bool fresh}) place(
    String actor,
    String id,
    String kind,
    double x,
    double y,
    double w,
    double h,
    Map<String, dynamic> props,
  ) {
    final existing = objects[id];
    if (existing != null) {
      if (!existing.live) {
        throw const FuzzRefusal(409, 'that object was removed');
      }
      return (object: existing, fresh: false);
    }
    final op = _record('place-${ops.length + 1}', 'place', actor);
    final object = FuzzObject(
      id: id,
      kind: kind,
      x: x,
      y: y,
      w: w,
      h: h,
      z: op.seq,
      seq: op.seq,
      author: actor,
      props: props,
    );
    op.objectId = id;
    objects[id] = object;
    publish(
      api.CanvasObjectPlaced(
        channelId: channelId,
        object: api.CanvasObject.fromJson(object.toJson()),
      ),
    );
    return (object: object, fresh: true);
  }

  // --- ops ---

  FuzzSubmit submit(String actor, Map<String, dynamic> body) {
    final opId = body['id'] as String;
    final replay = opById[opId];
    if (replay != null) {
      final replayed = FuzzSubmit(replay, _affectedOf(replay), false)
        ..seq = replay.seq
        ..kind = replay.kind
        ..id = replay.id
        ..createdAt = replay.createdAt;
      return replayed;
    }
    final may = moderators.contains(actor);
    final kind = body['kind'] as String;
    final result = switch (kind) {
      'remove' => _remove(actor, may, opId, body),
      'clear' || 'clear_scoped' => _clear(actor, may, opId, body),
      'restore' => _restore(actor, may, opId, body),
      'move' => _move(actor, may, opId, body),
      'reorder' => _reorder(actor, may, opId, body),
      'edit' => _edit(actor, may, opId, body),
      _ => throw const FuzzRefusal(400, 'unknown canvas op kind'),
    };
    return result;
  }

  int _affectedOf(FuzzOp op) {
    if (op.kind == 'clear') {
      return objects.values.where((o) => o.deletedAt == op.createdAt).length;
    }
    if (op.kind == 'remove' || op.kind == 'restore') return op.targets.length;
    return 1;
  }

  FuzzSubmit _zero(String opId, String kind) => FuzzSubmit(null, 0, true)
    ..seq = head
    ..kind = kind
    ..id = opId
    ..createdAt = ++_clock;

  FuzzSubmit _done(FuzzOp op, int affected) => FuzzSubmit(op, affected, true)
    ..seq = op.seq
    ..kind = op.kind == 'clear' && op.kinds.isNotEmpty
        ? 'clear_scoped'
        : op.kind
    ..id = op.id
    ..createdAt = op.createdAt;

  FuzzSubmit _remove(
    String actor,
    bool may,
    String opId,
    Map<String, dynamic> body,
  ) {
    final ids = (body['object_ids'] as List).cast<String>();
    if (ids.isEmpty || ids.length > 64) {
      throw const FuzzRefusal(400, 'object_ids must hold between 1 and 64 ids');
    }
    final toRemove = <String>[];
    for (final id in ids) {
      final found = objects[id];
      if (found == null) {
        throw const FuzzRefusal(404, 'that id is not in this channel');
      }
      if (!may && found.author != actor) {
        throw const FuzzRefusal(403, 'forbidden');
      }
      if (found.live) toRemove.add(id);
    }
    toRemove.removeWhere(locked.contains);
    if (toRemove.isEmpty) return _zero(opId, 'remove');
    final op = _record(opId, 'remove', actor);
    for (final id in toRemove) {
      objects[id]!.deletedAt = op.createdAt;
    }
    op.targets = toRemove;
    publish(
      api.CanvasObjectsRemoved(
        channelId: channelId,
        seq: op.seq,
        opId: opId,
        objectIds: toRemove,
      ),
    );
    return _done(op, toRemove.length);
  }

  FuzzSubmit _clear(
    String actor,
    bool may,
    String opId,
    Map<String, dynamic> body,
  ) {
    if (!may) throw const FuzzRefusal(403, 'forbidden');
    final before = body['before_seq'] as int;
    final kinds = ((body['kinds'] as List?) ?? const []).cast<String>();
    final scopeAuthor = body['author_id'] as String?;
    final now = ++_clock;
    final touched = [
      for (final o in objects.values)
        if (o.live &&
            o.seq <= before &&
            (kinds.isEmpty || kinds.contains(o.kind)) &&
            (scopeAuthor == null || o.author == scopeAuthor))
          o,
    ];
    if (touched.isEmpty) return _zero(opId, 'clear');
    final op =
        FuzzOp(
            seq: ops.length + 1,
            id: opId,
            kind: 'clear',
            actor: actor,
            createdAt: now,
          )
          ..beforeSeq = before
          ..kinds = kinds
          ..scopeAuthor = scopeAuthor;
    ops.add(op);
    opById[opId] = op;
    for (final o in touched) {
      o.deletedAt = now;
    }
    publish(
      api.CanvasCleared(
        channelId: channelId,
        seq: op.seq,
        opId: opId,
        beforeSeq: before,
        scope: api.CanvasClearScope(kinds: kinds, authorId: scopeAuthor),
      ),
    );
    return _done(op, touched.length);
  }

  FuzzSubmit _restore(
    String actor,
    bool may,
    String opId,
    Map<String, dynamic> body,
  ) {
    final target = opById[body['target_op'] as String];
    if (target == null || (target.kind != 'remove' && target.kind != 'clear')) {
      throw const FuzzRefusal(404, 'that id is not in this channel');
    }
    if (!may && (target.kind == 'clear' || target.actor != actor)) {
      throw const FuzzRefusal(403, 'forbidden');
    }
    final dead = <String>[];
    if (target.kind == 'clear') {
      for (final o in objects.values) {
        if (o.seq <= target.beforeSeq! && o.deletedAt == target.createdAt) {
          dead.add(o.id);
        }
      }
    } else {
      for (final id in target.targets) {
        final o = objects[id];
        if (!may && o?.author != actor) {
          throw const FuzzRefusal(403, 'forbidden');
        }
        if (o != null && o.deletedAt == target.createdAt) dead.add(id);
      }
    }
    if (dead.isEmpty) return _zero(opId, 'restore');
    final op = _record(opId, 'restore', actor)
      ..targetOp = target.id
      ..targets = dead;
    for (final id in dead) {
      objects[id]!.deletedAt = null;
    }
    publish(
      api.CanvasObjectsRestored(
        channelId: channelId,
        seq: op.seq,
        opId: opId,
        objectIds: dead.length > 64 ? const [] : dead,
      ),
    );
    return _done(op, dead.length);
  }

  FuzzObject _target(String actor, bool may, Map<String, dynamic> body) {
    final id = body['object_id'] as String;
    final found = objects[id];
    if (found == null) {
      throw const FuzzRefusal(404, 'that id is not in this channel');
    }
    if (!may && found.author != actor) {
      throw const FuzzRefusal(403, 'forbidden');
    }
    if (locked.contains(id)) {
      throw const FuzzRefusal(409, 'that object is locked in place');
    }
    return found;
  }

  FuzzSubmit _move(
    String actor,
    bool may,
    String opId,
    Map<String, dynamic> body,
  ) {
    final found = _target(actor, may, body);
    final x = (body['x'] as num).toDouble();
    final y = (body['y'] as num).toDouble();
    final w = (body['w'] as num).toDouble();
    final h = (body['h'] as num).toDouble();
    if (!found.live) return _zero(opId, 'move');
    if (w < 0 || h < 0 || w > 8192 || h > 8192) {
      throw const FuzzRefusal(
        400,
        'the object is outside the world or too large',
      );
    }
    found
      ..x = x
      ..y = y
      ..w = w
      ..h = h;
    final op = _record(opId, 'move', actor)
      ..objectId = found.id
      ..targets = [found.id]
      ..x = x
      ..y = y
      ..w = w
      ..h = h;
    publish(
      api.CanvasObjectMoved(
        channelId: channelId,
        seq: op.seq,
        opId: opId,
        objectId: found.id,
        x: x,
        y: y,
        w: w,
        h: h,
      ),
    );
    return _done(op, 1);
  }

  FuzzSubmit _reorder(
    String actor,
    bool may,
    String opId,
    Map<String, dynamic> body,
  ) {
    final found = _target(actor, may, body);
    final z = body['z_index'] as int;
    if (!found.live) return _zero(opId, 'reorder');
    found.z = z;
    final op = _record(opId, 'reorder', actor)
      ..objectId = found.id
      ..targets = [found.id]
      ..z = z;
    publish(
      api.CanvasObjectReordered(
        channelId: channelId,
        seq: op.seq,
        opId: opId,
        objectId: found.id,
        zIndex: z,
      ),
    );
    return _done(op, 1);
  }

  FuzzSubmit _edit(
    String actor,
    bool may,
    String opId,
    Map<String, dynamic> body,
  ) {
    final found = _target(actor, may, body);
    if (found.kind != 'note') {
      throw const FuzzRefusal(400, 'only a note can be edited');
    }
    final props = Map<String, dynamic>.from(body['props'] as Map);
    if (!found.live) return _zero(opId, 'edit');
    found.props = props;
    final op = _record(opId, 'edit', actor)
      ..objectId = found.id
      ..targets = [found.id]
      ..props = props;
    publish(
      api.CanvasObjectEdited(
        channelId: channelId,
        seq: op.seq,
        opId: opId,
        objectId: found.id,
        props: props,
      ),
    );
    return _done(op, 1);
  }

  // --- locks ---

  void setLocked(String objectId, bool value) {
    final changed = value ? locked.add(objectId) : locked.remove(objectId);
    if (!changed) return;
    publish(
      api.CanvasObjectLockChanged(
        channelId: channelId,
        objectId: objectId,
        locked: value,
      ),
    );
  }

  // --- reads ---

  Map<String, dynamic> viewport(Map<String, String> q) {
    final minX = double.parse(q['min_x']!);
    final minY = double.parse(q['min_y']!);
    final maxX = double.parse(q['max_x']!);
    final maxY = double.parse(q['max_y']!);
    final limit = (int.tryParse(q['limit'] ?? '') ?? 500).clamp(1, 2000);
    final inside =
        [
          for (final o in liveObjects)
            if (o.x <= maxX &&
                o.x + o.w >= minX &&
                o.y <= maxY &&
                o.y + o.h >= minY)
              o,
        ]..sort((a, b) {
          final z = b.z.compareTo(a.z);
          return z != 0 ? z : b.seq.compareTo(a.seq);
        });
    final hasMore = inside.length > limit;
    final page = inside.take(limit).toList().reversed.toList();
    return {
      'objects': [for (final o in page) o.toJson()],
      'has_more': hasMore,
      'latest_seq': head,
    };
  }

  /// How far behind a cursor may be before the feed answers `reset`.
  int resetGap = 2000;

  Map<String, dynamic> feed(int afterSeq, int limit) {
    final reset = afterSeq > head || head - afterSeq > resetGap;
    if (reset) {
      return {
        'ops': <Object>[],
        'latest_seq': head,
        'has_more': false,
        'reset': true,
      };
    }
    final page = ops.where((o) => o.seq > afterSeq).take(limit + 1).toList();
    final hasMore = page.length > limit;
    final shown = hasMore ? page.sublist(0, limit) : page;
    return {
      'ops': [for (final op in shown) _opJson(op)],
      'latest_seq': head,
      'has_more': hasMore,
      'reset': false,
    };
  }

  Map<String, dynamic> _opJson(FuzzOp op) {
    final base = <String, dynamic>{
      'seq': op.seq,
      'id': op.id,
      'actor_id': op.actor,
      'created_at': op.createdAt,
    };
    switch (op.kind) {
      case 'place':
        final object = objects[op.objectId];
        return {
          ...base,
          'kind': 'place',
          'object': object != null && object.live ? object.toJson() : null,
        };
      case 'remove':
        return {...base, 'kind': 'remove', 'object_ids': op.targets};
      case 'clear':
        return {
          ...base,
          'kind': op.kinds.isEmpty && op.scopeAuthor == null
              ? 'clear'
              : 'clear_scoped',
          'before_seq': op.beforeSeq,
          if (op.kinds.isNotEmpty) 'kinds': op.kinds,
          if (op.scopeAuthor != null) 'author_id': op.scopeAuthor,
        };
      case 'restore':
        return {
          ...base,
          'kind': 'restore',
          'target_op': op.targetOp,
          'object_ids': op.targets,
        };
      case 'move':
        return {
          ...base,
          'kind': 'move',
          'object_id': op.objectId,
          'x': op.x,
          'y': op.y,
          'w': op.w,
          'h': op.h,
        };
      case 'reorder':
        return {
          ...base,
          'kind': 'reorder',
          'object_id': op.objectId,
          'z_index': op.z,
        };
      default:
        return {
          ...base,
          'kind': 'edit',
          'object_id': op.objectId,
          'props': op.props,
        };
    }
  }

  Map<String, dynamic> opResultJson(FuzzSubmit s) => {
    'op': {
      'id': s.id,
      'seq': s.seq,
      'kind': s.kind,
      'affected': s.affected,
      'created_at': s.createdAt,
    },
    'fresh': s.fresh,
  };
}
