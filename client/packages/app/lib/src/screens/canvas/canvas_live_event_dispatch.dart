// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The live-event dispatch switch `CanvasPane` reads off the socket, split
/// out of `canvas_pane.dart` because it sat at the file budget's hard
/// ceiling. A pure function over explicit callbacks rather than a class:
/// nothing here holds state between calls, everything it touches belongs to
/// whoever calls it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_activity_log.dart';
import 'canvas_cursor_relay.dart';
import 'canvas_media_slot_sync.dart';
import 'canvas_object_locks.dart';
import 'canvas_stroke_preview_relay.dart';
import 'canvas_sync.dart';

/// Applies one server event to [document] if it names [paneChannelId], the
/// exact switch `CanvasPane._onEvent` used to carry directly.
///
/// [relay] is a closure rather than a value so the caller's own lazy getter
/// stays lazy: a remote cursor object is only ever constructed the first
/// time an actual [api.CanvasCursorMoved] for this channel arrives, never on
/// an unrelated placement or removal.
///
/// [activityLog] is recorded inline, per case, rather than through a second
/// switch elsewhere: every other kind's live frame structurally carries no
/// actor at all (see `Event::CanvasObjectsRemoved`'s own doc), which is why
/// only the `CanvasObjectPlaced` case ever passes one through.
void dispatchCanvasLiveEvent(
  api.ServerEvent event, {
  required String paneChannelId,
  required CanvasSync sync,
  required CanvasDocument document,
  required CanvasCursorRelay Function() relay,
  required CanvasStrokePreviewRelay Function() strokePreviewRelay,
  required void Function(api.CanvasObject object) applyPlacedObject,
  required VoidCallback forgetFetchedRegion,
  required CanvasMediaSlotSync mediaSlotSync,
  required CanvasObjectLocks objectLocks,
  CanvasActivityLog? activityLog,
}) {
  switch (event) {
    case api.CanvasObjectPlaced(:final channelId, :final object)
        when channelId == paneChannelId:
      sync.applyLive(event.seq, () {
        applyPlacedObject(object);
        activityLog?.recordPlacedLive(object);
      });
    case api.CanvasObjectsRemoved(
          :final channelId,
          :final seq,
          :final opId,
          :final objectIds,
        )
        when channelId == paneChannelId:
      sync.applyLive(seq, () {
        for (final id in objectIds) {
          document.removeObject(id);
        }
        document.refresh();
        activityLog?.recordRemovedLive(opId, objectIds);
      });
    case api.CanvasCleared(
          :final channelId,
          :final seq,
          :final opId,
          :final beforeSeq,
        )
        when channelId == paneChannelId:
      sync.applyLive(seq, () {
        document.clearBelow(beforeSeq);
        document.refresh();
        activityLog?.recordClearedLive(opId);
      });
    case api.CanvasObjectsRestored(
          :final channelId,
          :final seq,
          :final opId,
          :final objectIds,
        )
        when channelId == paneChannelId:

      /// An empty list never means "nothing was restored": the server only
      /// publishes this frame when it restored at least one object, and
      /// empties the list rather than exceed the frame bound a `remove`
      /// already sets. Applying it would clear no tombstone while advancing
      /// the cursor past the one op that could, so the objects stay
      /// invisible on this client for good. The feed carries the full list,
      /// so this defers to it instead.
      if (objectIds.isEmpty) {
        sync.deferToFeed();
        return;
      }
      sync.applyLive(seq, () {
        document.forgetRemoved(objectIds);
        forgetFetchedRegion();
        activityLog?.recordRestoredLive(opId, objectIds.length);
      });
      // A restored object's payload was freed on removal and the camera-move guard only checks on an actual pan, so nothing repaints it without this - see CanvasSync.coldFetch's own doc.
      unawaited(sync.coldFetch());
    case api.CanvasCursorMoved(
          :final channelId,
          :final userId,
          :final x,
          :final y,
        )
        when channelId == paneChannelId:
      // Never through sync.applyLive: a cursor carries no seq to catch up on.
      relay().applyRemote(userId, x, y);
    case api.CanvasStrokePreview(
          :final channelId,
          :final userId,
          :final objectId,
          :final points,
          :final ended,
        )
        when channelId == paneChannelId:
      // Never through sync.applyLive, the same reason a cursor is not: no seq.
      strokePreviewRelay().applyRemote(userId, objectId, points, ended);
    case api.CanvasObjectMoved(
          :final channelId,
          :final seq,
          :final opId,
          :final objectId,
          :final x,
          :final y,
          :final w,
          :final h,
        )
        when channelId == paneChannelId:
      sync.applyLive(seq, () {
        document.moveObject(objectId, x, y, w, h);
        document.refresh();
        activityLog?.recordMovedLive(opId);
      });
    case api.CanvasObjectReordered(
          :final channelId,
          :final seq,
          :final opId,
          :final objectId,
          :final zIndex,
        )
        when channelId == paneChannelId:
      sync.applyLive(seq, () {
        document.setZIndex(objectId, zIndex);
        document.refresh();
        activityLog?.recordReorderedLive(opId);
      });
    case api.CanvasMediaSlotChanged(:final channelId)
        when channelId == paneChannelId:
      // Never through sync.applyLive: a slot carries no seq, the same reason a cursor does not.
      mediaSlotSync.applyRemote(event);
    case api.CanvasObjectLockChanged(:final channelId)
        when channelId == paneChannelId:
      objectLocks.applyRemote(event);
    default:
      break;
  }
}
