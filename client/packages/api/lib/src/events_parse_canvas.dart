// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'events.dart';

/// Voice Canvas frames.
ServerEvent? _canvasFrame(Map<String, dynamic> decoded) =>
    _canvasObjectFrame(decoded) ??
    _canvasLiveFrame(decoded) ??
    _canvasEditFrame(decoded);

/// Canvas frames that place, remove, clear and restore objects.
ServerEvent? _canvasObjectFrame(Map<String, dynamic> decoded) {
  return switch (decoded['type']) {
    'canvas.object.placed'
        when decoded['channel_id'] is String &&
            decoded['object'] is Map<String, dynamic> =>
      CanvasObjectPlaced(
        channelId: decoded['channel_id'] as String,
        object: CanvasObject.fromJson(
          decoded['object'] as Map<String, dynamic>,
        ),
      ),
    'canvas.objects.removed'
        when decoded['channel_id'] is String &&
            decoded['seq'] is int &&
            decoded['op_id'] is String &&
            decoded['object_ids'] is List =>
      CanvasObjectsRemoved(
        channelId: decoded['channel_id'] as String,
        seq: decoded['seq'] as int,
        opId: decoded['op_id'] as String,
        objectIds: List<String>.from(decoded['object_ids'] as List<dynamic>),
      ),
    'canvas.cleared'
        when decoded['channel_id'] is String &&
            decoded['seq'] is int &&
            decoded['op_id'] is String &&
            decoded['before_seq'] is int =>
      CanvasCleared(
        channelId: decoded['channel_id'] as String,
        seq: decoded['seq'] as int,
        opId: decoded['op_id'] as String,
        beforeSeq: decoded['before_seq'] as int,
      ),
    'canvas.cleared_scoped'
        when decoded['channel_id'] is String &&
            decoded['seq'] is int &&
            decoded['op_id'] is String &&
            decoded['before_seq'] is int =>
      CanvasCleared(
        channelId: decoded['channel_id'] as String,
        seq: decoded['seq'] as int,
        opId: decoded['op_id'] as String,
        beforeSeq: decoded['before_seq'] as int,
        scope: CanvasClearScope.fromJson(decoded),
        sparedIds: decoded['spared_ids'] is List
            ? List<String>.from(decoded['spared_ids'] as List<dynamic>)
            : const [],
        sparedCount:
            decoded['spared_count'] is int ? decoded['spared_count'] as int : 0,
      ),
    'canvas.objects.restored'
        when decoded['channel_id'] is String &&
            decoded['seq'] is int &&
            decoded['op_id'] is String &&
            decoded['object_ids'] is List =>
      CanvasObjectsRestored(
        channelId: decoded['channel_id'] as String,
        seq: decoded['seq'] as int,
        opId: decoded['op_id'] as String,
        objectIds: List<String>.from(decoded['object_ids'] as List<dynamic>),
      ),
    _ => null,
  };
}

/// Canvas frames for cursors and live previews.
ServerEvent? _canvasLiveFrame(Map<String, dynamic> decoded) {
  return switch (decoded['type']) {
    'canvas.cursor.moved'
        when decoded['channel_id'] is String &&
            decoded['user_id'] is String &&
            decoded['x'] is num &&
            decoded['y'] is num =>
      CanvasCursorMoved(
        channelId: decoded['channel_id'] as String,
        userId: decoded['user_id'] as String,
        x: (decoded['x'] as num).toDouble(),
        y: (decoded['y'] as num).toDouble(),
        left: decoded['left'] == true,
      ),
    'canvas.stroke_preview.updated'
        when decoded['channel_id'] is String &&
            decoded['user_id'] is String &&
            decoded['object_id'] is String &&
            decoded['points'] is List &&
            decoded['ended'] is bool =>
      CanvasStrokePreview(
        channelId: decoded['channel_id'] as String,
        userId: decoded['user_id'] as String,
        objectId: decoded['object_id'] as String,
        points: (decoded['points'] as List<dynamic>)
            .map((p) => (p as num).toDouble())
            .toList(growable: false),
        ended: decoded['ended'] as bool,
        cancelled: decoded['cancelled'] as bool? ?? false,
        color: decoded['color'] is String ? decoded['color'] as String : null,
        width: decoded['width'] is num
            ? (decoded['width'] as num).toDouble()
            : null,
      ),
    'canvas.object_preview.updated'
        when decoded['channel_id'] is String &&
            decoded['user_id'] is String &&
            decoded['object_id'] is String &&
            decoded['x'] is num &&
            decoded['y'] is num &&
            decoded['w'] is num &&
            decoded['h'] is num &&
            decoded['ended'] is bool =>
      CanvasObjectPreview(
        channelId: decoded['channel_id'] as String,
        userId: decoded['user_id'] as String,
        objectId: decoded['object_id'] as String,
        x: (decoded['x'] as num).toDouble(),
        y: (decoded['y'] as num).toDouble(),
        w: (decoded['w'] as num).toDouble(),
        h: (decoded['h'] as num).toDouble(),
        ended: decoded['ended'] as bool,
      ),
    'canvas.media_slot_preview.updated'
        when decoded['channel_id'] is String &&
            decoded['user_id'] is String &&
            decoded['kind'] is String &&
            decoded['slot_user_id'] is String &&
            decoded['x'] is num &&
            decoded['y'] is num &&
            decoded['w'] is num &&
            decoded['h'] is num &&
            decoded['ended'] is bool =>
      CanvasMediaSlotPreview(
        channelId: decoded['channel_id'] as String,
        userId: decoded['user_id'] as String,
        kind: decoded['kind'] as String,
        slotUserId: decoded['slot_user_id'] as String,
        x: (decoded['x'] as num).toDouble(),
        y: (decoded['y'] as num).toDouble(),
        w: (decoded['w'] as num).toDouble(),
        h: (decoded['h'] as num).toDouble(),
        ended: decoded['ended'] as bool,
      ),
    'canvas.view.updated'
        when decoded['channel_id'] is String &&
            decoded['user_id'] is String &&
            decoded['x'] is num &&
            decoded['y'] is num &&
            decoded['w'] is num &&
            decoded['h'] is num &&
            decoded['summon'] is bool =>
      CanvasView(
        channelId: decoded['channel_id'] as String,
        userId: decoded['user_id'] as String,
        x: (decoded['x'] as num).toDouble(),
        y: (decoded['y'] as num).toDouble(),
        w: (decoded['w'] as num).toDouble(),
        h: (decoded['h'] as num).toDouble(),
        summon: decoded['summon'] as bool,
      ),
    _ => null,
  };
}

/// Canvas frames that change an object that is already there.
ServerEvent? _canvasEditFrame(Map<String, dynamic> decoded) {
  return switch (decoded['type']) {
    'canvas.object.moved'
        when decoded['channel_id'] is String &&
            decoded['seq'] is int &&
            decoded['op_id'] is String &&
            decoded['object_id'] is String &&
            decoded['x'] is num &&
            decoded['y'] is num &&
            decoded['w'] is num &&
            decoded['h'] is num =>
      CanvasObjectMoved(
        channelId: decoded['channel_id'] as String,
        seq: decoded['seq'] as int,
        opId: decoded['op_id'] as String,
        objectId: decoded['object_id'] as String,
        x: (decoded['x'] as num).toDouble(),
        y: (decoded['y'] as num).toDouble(),
        w: (decoded['w'] as num).toDouble(),
        h: (decoded['h'] as num).toDouble(),
      ),
    'canvas.object.edited'
        when decoded['channel_id'] is String &&
            decoded['seq'] is int &&
            decoded['op_id'] is String &&
            decoded['object_id'] is String &&
            decoded['props'] is Map<String, dynamic> =>
      CanvasObjectEdited(
        channelId: decoded['channel_id'] as String,
        seq: decoded['seq'] as int,
        opId: decoded['op_id'] as String,
        objectId: decoded['object_id'] as String,
        props: decoded['props'] as Map<String, dynamic>,
      ),
    'canvas.object.reordered'
        when decoded['channel_id'] is String &&
            decoded['seq'] is int &&
            decoded['op_id'] is String &&
            decoded['object_id'] is String &&
            decoded['z_index'] is int =>
      CanvasObjectReordered(
        channelId: decoded['channel_id'] as String,
        seq: decoded['seq'] as int,
        opId: decoded['op_id'] as String,
        objectId: decoded['object_id'] as String,
        zIndex: decoded['z_index'] as int,
      ),
    'canvas.media_slot.changed'
        when decoded['channel_id'] is String &&
            decoded['kind'] is String &&
            decoded['user_id'] is String &&
            decoded['x'] is num &&
            decoded['y'] is num &&
            decoded['w'] is num &&
            decoded['h'] is num &&
            decoded['locked'] is bool &&
            decoded['sent_to_back'] is bool =>
      CanvasMediaSlotChanged(
        channelId: decoded['channel_id'] as String,
        kind: decoded['kind'] as String,
        userId: decoded['user_id'] as String,
        x: (decoded['x'] as num).toDouble(),
        y: (decoded['y'] as num).toDouble(),
        w: (decoded['w'] as num).toDouble(),
        h: (decoded['h'] as num).toDouble(),
        locked: decoded['locked'] as bool,
        sentToBack: decoded['sent_to_back'] as bool,
      ),
    'canvas.object.lock_changed'
        when decoded['channel_id'] is String &&
            decoded['object_id'] is String &&
            decoded['locked'] is bool =>
      CanvasObjectLockChanged(
        channelId: decoded['channel_id'] as String,
        objectId: decoded['object_id'] as String,
        locked: decoded['locked'] as bool,
      ),
    _ => null,
  };
}
