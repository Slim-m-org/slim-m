// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading and writing the shared, persistent half of a media tile's state
/// - position, size, lock and depth - which the server remembers per
/// channel now (decision 0010's reversal). `hidden` never passes through
/// here: it stays the one field `CanvasPresenceTileOverrides` keeps purely
/// local, exactly as it always has.
///
/// A cold fetch on opening the canvas and again on every reconnect
/// (`CanvasPane`'s own `SyncStatus.live` listener calls both this and
/// `CanvasSync.catchUp` on the same transition), with live
/// `canvas.media_slot.changed` frames keeping the picture current in
/// between - a slot carries no seq, so a reconnect has no gap-detector of
/// its own the way the canvas op stream does, and a missed live frame
/// during a disconnect would otherwise never be corrected.
library;

import 'dart:ui';

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_presence_geometry.dart'
    show presenceTileIdentity, presenceTileKeyForSlot, presenceTileKind;

class CanvasMediaSlotSync {
  CanvasMediaSlotSync({
    required this.channelId,
    required this.client,
    required this.overrides,
  });

  final String channelId;
  final api.SlimmApi client;
  final CanvasPresenceTileOverrides overrides;

  /// Every slot this channel's canvas currently remembers, applied once.
  /// Failures are silent and leave every tile at its default arrangement -
  /// the same degrade a lost viewport read already falls back to, rather
  /// than blocking the canvas on this one read.
  Future<void> fetch() async {
    final api.CanvasMediaSlotPage page;
    try {
      page = await client.canvasMediaSlots(channelId);
    } on api.ApiException {
      return;
    }
    for (final slot in page.slots) {
      overrides.applyServer(
        presenceTileKeyForSlot(slot.kind, slot.userId),
        rect: Rect.fromLTWH(slot.x, slot.y, slot.w, slot.h),
        locked: slot.locked,
        sentToBack: slot.sentToBack,
      );
    }
  }

  /// Sends [key]'s now-settled [rect], plus whatever `overrides.stateFor(key)`
  /// currently says about lock and depth, to the server. Best-effort and
  /// fire-and-forget, the same shape `VoiceController.leave()`'s own
  /// heartbeat call already uses: a failed write leaves the caller's own
  /// optimistic local update standing, with nowhere better to report a
  /// canvas drag's own failure than a `SnackBar` nobody asked for.
  Future<void> commit(String key, Rect rect) async {
    final state = overrides.stateFor(key);
    try {
      await client.putCanvasMediaSlot(
        channelId,
        kind: presenceTileKind(key),
        userId: presenceTileIdentity(key),
        x: rect.left,
        y: rect.top,
        w: rect.width,
        h: rect.height,
        locked: state.locked,
        sentToBack: state.sentToBack,
      );
    } on api.ApiException {
      // Best-effort; see this method's own doc.
    }
  }

  /// Applies a live `canvas.media_slot.changed` frame naming this channel.
  void applyRemote(api.CanvasMediaSlotChanged event) {
    if (event.channelId != channelId) return;
    overrides.applyServer(
      presenceTileKeyForSlot(event.kind, event.userId),
      rect: Rect.fromLTWH(event.x, event.y, event.w, event.h),
      locked: event.locked,
      sentToBack: event.sentToBack,
    );
  }
}
