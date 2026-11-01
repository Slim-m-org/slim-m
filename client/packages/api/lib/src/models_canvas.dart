// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Canvas objects, as a viewport read returns them. The op stream that reads
/// back removals, clears and restores is a sibling file, `models_canvas_ops.dart`.
library;

/// One object on a channel's canvas.
class CanvasObject {
  const CanvasObject({
    required this.id,
    required this.kind,
    required this.zIndex,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.props,
    required this.authorId,
    required this.seq,
    required this.createdAt,
  });

  final String id;

  /// `stroke`, `image`, `note` or `shape`. A String so a client too old to know a kind skips the object
  /// instead of failing the region; there is no `window` kind (decision 0004).
  final String kind;

  final int zIndex;
  final double x;
  final double y;
  final double w;
  final double h;

  /// Kind-specific payload, opaque here.
  final Map<String, dynamic> props;

  /// Null once the author's account has been deleted.
  final String? authorId;

  /// Per-channel order key, and the cursor for a delta read.
  final int seq;
  final int createdAt;

  factory CanvasObject.fromJson(Map<String, dynamic> json) => CanvasObject(
        id: json['id'] as String,
        kind: json['kind'] as String,
        zIndex: json['z_index'] as int,
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        w: (json['w'] as num).toDouble(),
        h: (json['h'] as num).toDouble(),
        props: (json['props'] as Map<String, dynamic>?) ?? const {},
        authorId: json['author_id'] as String?,
        seq: json['seq'] as int,
        createdAt: json['created_at'] as int,
      );
}

/// The answer to one viewport read.
class CanvasViewport {
  const CanvasViewport({
    required this.objects,
    required this.hasMore,
    required this.latestSeq,
    this.nextCursor,
    this.totalObjects,
  });

  final List<CanvasObject> objects;

  /// More objects intersect the region than the limit allowed. There is no
  /// stable cursor across a region query, so the answer is a smaller region
  /// rather than a next page.
  final bool hasMore;

  /// The channel's highest assigned canvas seq, a valid `after_seq` cursor for
  /// the canvas op stream.
  final int latestSeq;

  /// A paged read with more to come: the `cursorSeq` of the next page.
  final int? nextCursor;

  /// A paged read: how many live objects the whole channel holds.
  final int? totalObjects;

  factory CanvasViewport.fromJson(Map<String, dynamic> json) => CanvasViewport(
        objects: (json['objects'] as List<dynamic>)
            .map((o) => CanvasObject.fromJson(o as Map<String, dynamic>))
            .toList(),
        hasMore: json['has_more'] as bool,
        latestSeq: json['latest_seq'] as int,
        nextCursor: json['next_cursor'] as int?,
        totalObjects: json['total_objects'] as int?,
      );
}

/// Where a call participant's camera or screen-share tile sits on a
/// channel's canvas - shared by every viewer and remembered whether or not
/// that participant is on a call right now. See decision 0010's reversal:
/// this used to be a purely local, per-viewer arrangement.
class CanvasMediaSlot {
  const CanvasMediaSlot({
    required this.kind,
    required this.userId,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.locked,
    required this.sentToBack,
    required this.updatedAt,
  });

  /// `camera` or `screen`.
  final String kind;

  /// The participant this tile represents, never necessarily who last moved it.
  final String userId;
  final double x;
  final double y;
  final double w;
  final double h;

  /// Shared, not personal: a locked tile stops intercepting the pointer for
  /// every viewer, protecting an arrangement everyone relies on.
  final bool locked;
  final bool sentToBack;
  final int updatedAt;

  factory CanvasMediaSlot.fromJson(Map<String, dynamic> json) =>
      CanvasMediaSlot(
        kind: json['kind'] as String,
        userId: json['user_id'] as String,
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        w: (json['w'] as num).toDouble(),
        h: (json['h'] as num).toDouble(),
        locked: json['locked'] as bool,
        sentToBack: json['sent_to_back'] as bool,
        updatedAt: json['updated_at'] as int,
      );
}

/// Every media slot a channel's canvas currently remembers.
class CanvasMediaSlotPage {
  const CanvasMediaSlotPage({required this.slots, this.version = 0});

  final List<CanvasMediaSlot> slots;

  /// The state version the list was read at; 0 from a server that sends none.
  final int version;

  factory CanvasMediaSlotPage.fromJson(Map<String, dynamic> json) =>
      CanvasMediaSlotPage(
        slots: (json['slots'] as List<dynamic>)
            .map((s) => CanvasMediaSlot.fromJson(s as Map<String, dynamic>))
            .toList(),
        version: (json['version'] as num?)?.toInt() ?? 0,
      );
}

/// The objects locked in place, with the state version they were read at.
class CanvasObjectLockPage {
  const CanvasObjectLockPage({required this.objectIds, this.version = 0});

  final Set<String> objectIds;

  /// 0 from a server that sends none.
  final int version;

  factory CanvasObjectLockPage.fromJson(Map<String, dynamic> json) =>
      CanvasObjectLockPage(
        objectIds: (json['object_ids'] as List<dynamic>).cast<String>().toSet(),
        version: (json['version'] as num?)?.toInt() ?? 0,
      );
}

/// A rectangle in world coordinates.
class CanvasRect {
  const CanvasRect({
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
  });

  final double minX;
  final double minY;
  final double maxX;
  final double maxY;
}
