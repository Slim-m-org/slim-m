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

import 'canvas_retry.dart';
import 'canvas_presence_geometry.dart'
    show presenceTileIdentity, presenceTileKeyForSlot, presenceTileKind;

class CanvasMediaSlotSync {
  CanvasMediaSlotSync({
    required this.channelId,
    required this.client,
    required this.overrides,
    this.onError,
  });

  final String channelId;
  final api.SlimmApi client;
  final CanvasPresenceTileOverrides overrides;

  /// Told when a tile change could not be saved and was put back.
  final void Function(String message)? onError;

  final Map<String, Future<void>> _tails = {};

  /// Every slot this channel's canvas currently remembers, applied once.
  /// A failure after the retries leaves every tile at its default
  /// arrangement; the next reconnect fetches again.
  Future<void> fetch() async {
    final api.CanvasMediaSlotPage page;
    try {
      page = await retryCanvasRequest(() => client.canvasMediaSlots(channelId));
    } on api.ApiException catch (error, stack) {
      api.reportFailure(api.LogTag.ui, 'load canvas media slots', error, stack);
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

  /// Sends [key]'s settled [rect] with its lock and depth; writes for one key run in order, and a refused or lost write puts the tile back where the server has it.
  Future<void> commit(String key, Rect rect) {
    // A personal-view move is this viewer's alone, so nothing is sent.
    if (overrides.personal) return Future.value();
    final previous = _tails[key] ?? Future<void>.value();
    final next = previous.then((_) => _put(key, rect));
    _tails[key] = next;
    return next;
  }

  Future<void> _put(String key, Rect rect) async {
    final state = overrides.stateFor(key);
    try {
      await retryCanvasRequest(
        () => client.putCanvasMediaSlot(
          channelId,
          kind: presenceTileKind(key),
          userId: presenceTileIdentity(key),
          x: rect.left,
          y: rect.top,
          w: rect.width,
          h: rect.height,
          locked: state.locked,
          sentToBack: state.sentToBack,
        ),
      );
      overrides.confirm(key);
    } on api.ApiException catch (error, stack) {
      api.reportFailure(
        api.LogTag.ui,
        'save a canvas media slot',
        error,
        stack,
      );
      overrides.revertToServer(key);
      onError?.call(_explain(error));
    }
  }

  static String _explain(api.ApiException error) => switch (error) {
    api.ForbiddenException() =>
      'That tile is locked or you cannot move it now.',
    _ => 'That tile change could not be saved.',
  };

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
