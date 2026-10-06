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
    return CanvasObject.fromJson(json as Map<String, dynamic>);
  }

  /// Submits a canvas mutation - `remove`, `clear`, `restore`, `move`, or
  /// `reorder` - idempotent by [id] exactly as [placeCanvasObject] is: a
  /// replay answers with the stored op, `fresh: false`, and publishes
  /// nothing.
  ///
  /// Exactly one of [objectIds] (`remove`), [beforeSeq] (`clear`),
  /// [targetOp] (`restore`), [objectId] plus [x]/[y]/[w]/[h] (`move`), or
  /// [objectId] plus [zIndex] (`reorder`) is meaningful for a given [kind];
  /// the server rejects any other combination with a 400.
  Future<CanvasOpResult> submitCanvasOp(
    String channelId, {
    required String id,
    required String kind,
    List<String>? objectIds,
    int? beforeSeq,
    String? targetOp,
    String? objectId,
    double? x,
    double? y,
    double? w,
    double? h,
    int? zIndex,
  }) async {
    final json = await _send(
      'POST',
      '/channels/$channelId/canvas/ops',
      body: {
        'id': id,
        'kind': kind,
        if (objectIds != null) 'object_ids': objectIds,
        if (beforeSeq != null) 'before_seq': beforeSeq,
        if (targetOp != null) 'target_op': targetOp,
        if (objectId != null) 'object_id': objectId,
        if (x != null) 'x': x,
        if (y != null) 'y': y,
        if (w != null) 'w': w,
        if (h != null) 'h': h,
        if (zIndex != null) 'z_index': zIndex,
      },
    );
    return CanvasOpResult.fromJson(json as Map<String, dynamic>);
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
    return CanvasOpsPage.fromJson(json as Map<String, dynamic>);
  }

  /// Every media slot this channel's canvas currently remembers - a cold
  /// fetch to run once on opening the canvas, before live
  /// `canvas.media_slot.changed` frames keep the picture current.
  Future<CanvasMediaSlotPage> canvasMediaSlots(String channelId) async {
    final json = await _send('GET', '/channels/$channelId/canvas/media-slots');
    return CanvasMediaSlotPage.fromJson(json as Map<String, dynamic>);
  }

  /// Moves, resizes, locks or restacks one participant's camera or
  /// screen-share tile. [userId] names the participant the tile represents,
  /// never necessarily the caller: anyone who can draw on this canvas may
  /// rearrange anyone's tile, the same shared-editing trust this channel
  /// already grants over drawing. Every field is sent on every call; the
  /// stored row is replaced outright rather than merged.
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
    return CanvasMediaSlot.fromJson(json as Map<String, dynamic>);
  }
}
