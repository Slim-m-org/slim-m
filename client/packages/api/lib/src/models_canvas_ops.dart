// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas op stream: the single ordering authority every mutation -
/// place, remove, clear, restore, move, reorder, edit - writes into, and the paged
/// catch-up feed a client reconciling after a drop reads it back through. A
/// sibling of `models_canvas.dart`, which holds the object and
/// viewport-read shapes.
library;

import 'models_canvas.dart';

/// One row of the canvas op stream. Unlike a viewport read, this cursor is
/// stable and paging is correct, since every op has its own seq value and
/// there are no ties.
sealed class CanvasOp {
  const CanvasOp({
    required this.seq,
    required this.id,
    required this.actorId,
    required this.createdAt,
  });

  final int seq;
  final String id;

  /// Null once the actor's account has been anonymized.
  final String? actorId;
  final int createdAt;

  factory CanvasOp.fromJson(Map<String, dynamic> json) {
    final seq = json['seq'] as int;
    final id = json['id'] as String;
    final actorId = json['actor_id'] as String?;
    final createdAt = json['created_at'] as int;
    return switch (json['kind']) {
      'place' => CanvasPlaceOp(
          seq: seq,
          id: id,
          actorId: actorId,
          createdAt: createdAt,
          object: json['object'] == null
              ? null
              : CanvasObject.fromJson(json['object'] as Map<String, dynamic>),
        ),
      'remove' => CanvasRemoveOp(
          seq: seq,
          id: id,
          actorId: actorId,
          createdAt: createdAt,
          objectIds: _stringList(json['object_ids']),
        ),
      'clear' => CanvasClearOp(
          seq: seq,
          id: id,
          actorId: actorId,
          createdAt: createdAt,
          beforeSeq: json['before_seq'] as int,
        ),
      'clear_scoped' => CanvasClearOp(
          seq: seq,
          id: id,
          actorId: actorId,
          createdAt: createdAt,
          beforeSeq: json['before_seq'] as int,
          scope: CanvasClearScope.fromJson(json),
          sparedIds: _stringList(json['spared_ids']),
        ),
      'restore' => CanvasRestoreOp(
          seq: seq,
          id: id,
          actorId: actorId,
          createdAt: createdAt,
          targetOp: json['target_op'] as String,
          objectIds: _stringList(json['object_ids']),
        ),
      'move' => CanvasMoveOp(
          seq: seq,
          id: id,
          actorId: actorId,
          createdAt: createdAt,
          objectId: json['object_id'] as String,
          x: (json['x'] as num).toDouble(),
          y: (json['y'] as num).toDouble(),
          w: (json['w'] as num).toDouble(),
          h: (json['h'] as num).toDouble(),
        ),
      'reorder' => CanvasReorderOp(
          seq: seq,
          id: id,
          actorId: actorId,
          createdAt: createdAt,
          objectId: json['object_id'] as String,
          zIndex: json['z_index'] as int,
        ),
      'edit' => CanvasEditOp(
          seq: seq,
          id: id,
          actorId: actorId,
          createdAt: createdAt,
          objectId: json['object_id'] as String,
          props: (json['props'] as Map<String, dynamic>?) ??
              const <String, dynamic>{},
        ),
      _ => CanvasUnknownOp(
          seq: seq,
          id: id,
          actorId: actorId,
          createdAt: createdAt,
        ),
    };
  }
}

List<String> _stringList(Object? raw) =>
    (raw as List<dynamic>? ?? const <dynamic>[]).cast<String>();

/// An object was placed. [object] is null once it has since been removed - a
/// client should not paint an object the server no longer holds live.
class CanvasPlaceOp extends CanvasOp {
  const CanvasPlaceOp({
    required super.seq,
    required super.id,
    required super.actorId,
    required super.createdAt,
    required this.object,
  });

  final CanvasObject? object;
}

/// One or more objects were removed.
class CanvasRemoveOp extends CanvasOp {
  const CanvasRemoveOp({
    required super.seq,
    required super.id,
    required super.actorId,
    required super.createdAt,
    required this.objectIds,
  });

  final List<String> objectIds;
}

/// Narrows a clear to some object kinds and/or one author; empty clears everything.
class CanvasClearScope {
  const CanvasClearScope({this.kinds = const [], this.authorId});

  factory CanvasClearScope.fromJson(Map<String, dynamic> json) =>
      CanvasClearScope(
        kinds: _stringList(json['kinds']),
        authorId: json['author_id'] as String?,
      );

  static const everything = CanvasClearScope();

  /// Wire names of the object kinds; empty means every kind.
  final List<String> kinds;
  final String? authorId;

  bool get isEverything => kinds.isEmpty && authorId == null;
}

/// Every object placed at or below [beforeSeq] was removed at once, limited to [scope].
class CanvasClearOp extends CanvasOp {
  const CanvasClearOp({
    required super.seq,
    required super.id,
    required super.actorId,
    required super.createdAt,
    required this.beforeSeq,
    this.scope = CanvasClearScope.everything,
    this.sparedIds = const [],
  });

  final int beforeSeq;
  final CanvasClearScope scope;

  /// The locked objects the clear left standing; a replay keeps them.
  final List<String> sparedIds;
}

/// A removal or a clear named by [targetOp] was undone.
class CanvasRestoreOp extends CanvasOp {
  const CanvasRestoreOp({
    required super.seq,
    required super.id,
    required super.actorId,
    required super.createdAt,
    required this.targetOp,
    required this.objectIds,
  });

  final String targetOp;
  final List<String> objectIds;
}

/// An object was repositioned to `(x, y, w, h)`, without touching its
/// z-index.
class CanvasMoveOp extends CanvasOp {
  const CanvasMoveOp({
    required super.seq,
    required super.id,
    required super.actorId,
    required super.createdAt,
    required this.objectId,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  final String objectId;
  final double x;
  final double y;
  final double w;
  final double h;
}

/// An object's paint order was set to [zIndex], without touching its bounds.
class CanvasReorderOp extends CanvasOp {
  const CanvasReorderOp({
    required super.seq,
    required super.id,
    required super.actorId,
    required super.createdAt,
    required this.objectId,
    required this.zIndex,
  });

  final String objectId;
  final int zIndex;
}

/// A note's props were replaced by [props], without touching its bounds.
class CanvasEditOp extends CanvasOp {
  const CanvasEditOp({
    required super.seq,
    required super.id,
    required super.actorId,
    required super.createdAt,
    required this.objectId,
    required this.props,
  });

  final String objectId;
  final Map<String, dynamic> props;
}

/// A kind this client does not recognise. Never skipped by a catch-up:
/// silently ignoring an unknown kind could mean leaving ink on screen the
/// server has since removed, so a caller resets rather than skips it.
class CanvasUnknownOp extends CanvasOp {
  const CanvasUnknownOp({
    required super.seq,
    required super.id,
    required super.actorId,
    required super.createdAt,
  });
}

/// One page of the canvas op stream, from `GET .../canvas/ops`.
class CanvasOpsPage {
  const CanvasOpsPage({
    required this.ops,
    required this.latestSeq,
    required this.hasMore,
    required this.reset,
  });

  /// Ascending by seq, with no ties: a page boundary is never ambiguous.
  final List<CanvasOp> ops;

  /// The channel's highest assigned canvas op seq at read time.
  final int latestSeq;

  final bool hasMore;

  /// The cursor was too far behind, below the retained floor, or ahead of
  /// [latestSeq] (which happens after a restore from backup). [ops] is
  /// always empty alongside this: discard local state and cold-fetch rather
  /// than trust a partial answer.
  final bool reset;

  factory CanvasOpsPage.fromJson(Map<String, dynamic> json) => CanvasOpsPage(
        ops: (json['ops'] as List<dynamic>)
            .map((o) => CanvasOp.fromJson(o as Map<String, dynamic>))
            .toList(),
        latestSeq: json['latest_seq'] as int,
        hasMore: json['has_more'] as bool,
        reset: json['reset'] as bool,
      );
}

/// The answer to submitting one canvas op (`remove`, `clear`, `restore`,
/// `move`, `reorder`, or `edit`).
class CanvasOpResult {
  const CanvasOpResult({required this.op, required this.fresh});

  final CanvasOpSummary op;

  /// False for a replay of a known op id: the stored op is returned and
  /// nothing was published a second time.
  final bool fresh;

  factory CanvasOpResult.fromJson(Map<String, dynamic> json) => CanvasOpResult(
        op: CanvasOpSummary.fromJson(json['op'] as Map<String, dynamic>),
        fresh: json['fresh'] as bool,
      );
}

/// The op a submission produced or replayed. Distinct from [CanvasOp]: this
/// is a write's own confirmation, carrying an `affected` count rather than a
/// body, not a feed row.
class CanvasOpSummary {
  const CanvasOpSummary({
    required this.id,
    required this.seq,
    required this.kind,
    required this.affected,
    required this.createdAt,
  });

  final String id;
  final int seq;
  final String kind;

  /// How many objects this op actually changed. Zero is possible (every
  /// named id was already gone) and writes no op row server-side.
  final int affected;
  final int createdAt;

  factory CanvasOpSummary.fromJson(Map<String, dynamic> json) =>
      CanvasOpSummary(
        id: json['id'] as String,
        seq: json['seq'] as int,
        kind: json['kind'] as String,
        affected: json['affected'] as int,
        createdAt: json['created_at'] as int,
      );
}
