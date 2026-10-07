// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'events.dart';

// The canvas half of the sealed `ServerEvent` frames, split from `events_frames.dart` for the line budget.

/// An object was placed on a channel's canvas.
///
/// Carries the whole row, so a live stroke needs no viewport read to render.
/// It reports arrivals only: nothing here can report a removal, because a soft
/// delete does not advance an object's seq (see [SlimmApiCanvas.canvasViewport]).
class CanvasObjectPlaced extends ServerEvent {
  const CanvasObjectPlaced({required this.channelId, required this.object});

  final String channelId;
  final CanvasObject object;

  /// The op stream's own seq for this placement: a `place` op and its object
  /// are written in the same transaction and asserted equal by the writer,
  /// so the object's own [CanvasObject.seq] already carries it.
  int get seq => object.seq;
}

/// Objects were removed from a channel's canvas.
///
/// Ids only, the shape [MessageDeleted] already uses: a removal publishes an
/// id rather than content, and the actor is deliberately absent so a
/// moderation act does not name its moderator to the whole channel.
class CanvasObjectsRemoved extends ServerEvent {
  const CanvasObjectsRemoved({
    required this.channelId,
    required this.seq,
    required this.opId,
    required this.objectIds,
  });

  final String channelId;
  final int seq;
  final String opId;
  final List<String> objectIds;
}

/// Every object placed at or below [beforeSeq] was cleared at once.
///
/// Carries no ids: a clear can cover a channel's whole live ceiling, and a
/// frame naming every one of them is exactly what the props ceiling exists
/// to stop one object doing.
class CanvasCleared extends ServerEvent {
  const CanvasCleared({
    required this.channelId,
    required this.seq,
    required this.opId,
    required this.beforeSeq,
  });

  final String channelId;
  final int seq;
  final String opId;
  final int beforeSeq;
}

/// A removal or a clear was undone.
///
/// Ids only; a receiver cannot resurrect them locally since the payload was
/// freed on removal, so it drops the tombstone and refetches instead.
class CanvasObjectsRestored extends ServerEvent {
  const CanvasObjectsRestored({
    required this.channelId,
    required this.seq,
    required this.opId,
    required this.objectIds,
  });

  final String channelId;
  final int seq;
  final String opId;
  final List<String> objectIds;
}

/// A live pointer position on a channel's canvas.
///
/// Never a fact about `canvas_objects` or `canvas_ops` and carries no `seq`:
/// it is a this-instant hint, not a change to reconcile, so a client that
/// missed one is not stale and needs no catch-up path for it. There is no
/// matching "stopped" event; a receiver ages a cursor out on its own after a
/// short silence, the deliberate difference from [TypingStarted]/
/// [TypingStopped].
class CanvasCursorMoved extends ServerEvent {
  const CanvasCursorMoved({
    required this.channelId,
    required this.userId,
    required this.x,
    required this.y,
  });

  final String channelId;
  final String userId;
  final double x;
  final double y;
}

/// A live in-flight stroke preview on a channel's canvas: ephemeral, never
/// persisted, carries no `seq`. `points` is a delta - only what was added
/// since the sender's last frame for this [objectId] - so a receiver
/// accumulates them locally rather than replacing what it has. [objectId]
/// never names a row the server stores: it only keys this preview session,
/// since the object(s) a finished stroke commits are decided later and one
/// stroke can split into several. [ended] marks the gesture's last frame,
/// whether or not it went on to commit a real object.
class CanvasStrokePreview extends ServerEvent {
  const CanvasStrokePreview({
    required this.channelId,
    required this.userId,
    required this.objectId,
    required this.points,
    required this.ended,
  });

  final String channelId;
  final String userId;
  final String objectId;
  final List<double> points;
  final bool ended;
}

/// A placed object was repositioned.
///
/// Carries the whole new box, so a receiver needs no refetch to draw it in
/// its new place. The actor is deliberately absent, the same shape
/// [CanvasObjectsRemoved] uses: moving another member's object needs
/// `MANAGE_CANVAS` and so can be a moderation act the same way a removal is.
class CanvasObjectMoved extends ServerEvent {
  const CanvasObjectMoved({
    required this.channelId,
    required this.seq,
    required this.opId,
    required this.objectId,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  final String channelId;
  final int seq;
  final String opId;
  final String objectId;
  final double x;
  final double y;
  final double w;
  final double h;
}

/// A participant's camera or screen-share tile was moved, resized, locked
/// or sent to the back or front - shared and persistent since decision
/// 0010's reversal, so this reaches every viewer, not only the one who
/// touched it. Carries the whole current row, so a receiver needs no
/// refetch. [userId] names the participant the tile represents, never who
/// moved it: anyone who can draw on this canvas may rearrange anyone's
/// tile. Carries no seq: a slot mutates in place rather than joining the
/// canvas op stream.
class CanvasMediaSlotChanged extends ServerEvent {
  const CanvasMediaSlotChanged({
    required this.channelId,
    required this.kind,
    required this.userId,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.locked,
    required this.sentToBack,
  });

  final String channelId;
  final String kind;
  final String userId;
  final double x;
  final double y;
  final double w;
  final double h;
  final bool locked;
  final bool sentToBack;
}

/// A placed object's paint order changed.
///
/// Carries the new [zIndex] outright, so a receiver needs no refetch to
/// repaint it in its new stacking position. The actor is deliberately
/// absent, matching [CanvasObjectMoved]: restacking another member's object
/// needs `MANAGE_CANVAS` and so can be a moderation act the same way a move
/// is.
class CanvasObjectReordered extends ServerEvent {
  const CanvasObjectReordered({
    required this.channelId,
    required this.seq,
    required this.opId,
    required this.objectId,
    required this.zIndex,
  });

  final String channelId;
  final int seq;
  final String opId;
  final String objectId;
  final int zIndex;
}
