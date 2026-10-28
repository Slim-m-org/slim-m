// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// Reading a region of a channel's canvas and placing objects on it, the
/// `canvas` tag.
extension SlimmApiCanvas on SlimmApi {
  /// Every live object intersecting [region], in paint order.
  ///
  /// Always a cold fetch: catching up after a pan or a reconnect goes through
  /// the canvas op stream, which also carries removals.
  Future<CanvasViewport> canvasViewport(
    String channelId, {
    required CanvasRect region,
    int? limit,
  }) async {
    final query = <String, String>{
      'min_x': '${region.minX}',
      'min_y': '${region.minY}',
      'max_x': '${region.maxX}',
      'max_y': '${region.maxY}',
      if (limit != null) 'limit': '$limit',
    };
    final json = await _send(
      'GET',
      '/channels/$channelId/canvas/objects',
      query: query,
    );
    return _decodeShape(json, 'GET /channels/$channelId/canvas/objects',
        CanvasViewport.fromJson);
  }

  /// One page of [region] in seq order, oldest first, from [cursorSeq]
  /// (start at 0): load the visible area with [canvasViewport], then page the
  /// rest of a big board in with this until `nextCursor` is null.
  Future<CanvasViewport> canvasViewportPage(
    String channelId, {
    required CanvasRect region,
    required int cursorSeq,
    int? limit,
  }) async {
    final query = <String, String>{
      'min_x': '${region.minX}',
      'min_y': '${region.minY}',
      'max_x': '${region.maxX}',
      'max_y': '${region.maxY}',
      'cursor_seq': '$cursorSeq',
      if (limit != null) 'limit': '$limit',
    };
    final json = await _send(
      'GET',
      '/channels/$channelId/canvas/objects',
      query: query,
    );
    return CanvasViewport.fromJson(json as Map<String, dynamic>);
  }

  /// Places one object, idempotent by [id].
  ///
  /// [id] is a client-generated UUIDv7 and is the idempotency key, exactly as
  /// a message id is: replaying it answers with the stored row, its original
  /// seq intact, and broadcasts nothing, so a retry after a lost response is
  /// safe. [x] and [y] are the top-left corner in world coordinates and [w]
  /// and [h] the extents, neither over 8192.
  ///
  /// [props] is kind-specific and opaque to the server, capped at 4 KiB
  /// serialized. A stroke's `points` are relative to [x] and [y].
  Future<CanvasObject> placeCanvasObject(
    String channelId, {
    required String id,
    required String kind,
    required double x,
    required double y,
    required double w,
    required double h,
    required Map<String, dynamic> props,
  }) async {
    final json = await _send(
      'POST',
      '/channels/$channelId/canvas/objects',
      body: {
        'id': id,
        'kind': kind,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'props': props,
      },
    );
    return _decodeShape(json, 'POST /channels/$channelId/canvas/objects',
        CanvasObject.fromJson);
  }

  /// Submits a canvas mutation, idempotent by [id] like [placeCanvasObject]: a replay answers with the stored op
  /// (`fresh: false`) and publishes nothing. Only the fields that [kind] needs are read; the server 400s the rest.
  Future<CanvasOpResult> submitCanvasOp(
    String channelId, {
    required String id,
    required String kind,
    List<String>? objectIds,
    int? beforeSeq,
    CanvasClearScope? clearScope,
    String? targetOp,
    String? objectId,
    double? x,
    double? y,
    double? w,
    double? h,
    int? zIndex,
    Map<String, Object?>? props,
  }) async {
    final json = await _send(
      'POST',
      '/channels/$channelId/canvas/ops',
      body: {
        'id': id,
        'kind': kind,
        if (objectIds != null) 'object_ids': objectIds,
        if (beforeSeq != null) 'before_seq': beforeSeq,
        if (clearScope != null && clearScope.kinds.isNotEmpty)
          'kinds': clearScope.kinds,
        if (clearScope?.authorId != null) 'author_id': clearScope!.authorId,
        if (targetOp != null) 'target_op': targetOp,
        if (objectId != null) 'object_id': objectId,
        if (x != null) 'x': x,
        if (y != null) 'y': y,
        if (w != null) 'w': w,
        if (h != null) 'h': h,
        if (zIndex != null) 'z_index': zIndex,
        if (props != null) 'props': props,
      },
    );
    return _decodeShape(
        json, 'POST /channels/$channelId/canvas/ops', CanvasOpResult.fromJson);
  }

  /// Pages the canvas op stream from [afterSeq] (exclusive): the catch-up
  /// feed a client reconciling after a drop or a reconnect reads, rather
  /// than a full viewport re-read.
  Future<CanvasOpsPage> canvasOps(
    String channelId, {
    required int afterSeq,
    int? limit,
  }) async {
    final query = <String, String>{
      'after_seq': '$afterSeq',
      if (limit != null) 'limit': '$limit',
    };
    final json = await _send(
      'GET',
      '/channels/$channelId/canvas/ops',
      query: query,
    );
    return _decodeShape(
        json, 'GET /channels/$channelId/canvas/ops', CanvasOpsPage.fromJson);
  }

  /// Every media slot this channel's canvas currently remembers - a cold
  /// fetch to run once on opening the canvas, before live
  /// `canvas.media_slot.changed` frames keep the picture current.
  Future<CanvasMediaSlotPage> canvasMediaSlots(String channelId) async {
    final json = await _send('GET', '/channels/$channelId/canvas/media-slots');
    return _decodeShape(json, 'GET /channels/$channelId/canvas/media-slots',
        CanvasMediaSlotPage.fromJson);
  }

  /// Moves, resizes, locks or restacks one participant's tile; [userId] is the participant it represents, not the caller.
  /// Any member who can draw may rearrange any tile, and every field is sent each call because the row is replaced, not merged.
  Future<CanvasMediaSlot> putCanvasMediaSlot(
    String channelId, {
    required String kind,
    required String userId,
    required double x,
    required double y,
    required double w,
    required double h,
    required bool locked,
    required bool sentToBack,
  }) async {
    final json = await _send(
      'PUT',
      '/channels/$channelId/canvas/media-slots/$kind/$userId',
      body: {
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'locked': locked,
        'sent_to_back': sentToBack,
      },
    );
    return _decodeShape(
        json,
        'PUT /channels/$channelId/canvas/media-slots/$kind/$userId',
        CanvasMediaSlot.fromJson);
  }

  /// The ids of this channel's live objects locked in place, with the state version they were read at.
  Future<CanvasObjectLockPage> canvasObjectLocks(String channelId) async {
    final json = await _send('GET', '/channels/$channelId/canvas/object-locks');
    return _decodeShape(
      json,
      'GET /channels/$channelId/canvas/object-locks',
      CanvasObjectLockPage.fromJson,
    );
  }

  /// Locks [objectId] in place: nobody moves, restacks or erases it until it
  /// is unlocked. Its author or a canvas moderator may.
  Future<void> lockCanvasObject(String channelId, String objectId) =>
      _send('PUT', '/channels/$channelId/canvas/objects/$objectId/lock');

  /// Unlocks [objectId]; the same rule as [lockCanvasObject].
  Future<void> unlockCanvasObject(String channelId, String objectId) =>
      _send('DELETE', '/channels/$channelId/canvas/objects/$objectId/lock');

  /// Deletes [objectId] for good: its author or a canvas moderator may.
  /// Answers the row as it was, so the caller can place it again to undo.
  Future<CanvasObject> purgeCanvasObject(
    String channelId,
    String objectId,
  ) async {
    final json = await _send(
      'DELETE',
      '/channels/$channelId/canvas/objects/$objectId',
    );
    return _decodeShape(
      json,
      'DELETE /channels/$channelId/canvas/objects/$objectId',
      CanvasObject.fromJson,
    );
  }
}
