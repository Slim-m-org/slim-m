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

import 'dart:async';
import 'dart:ui';

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_cursor_relay.dart' show cursorSendInterval;
import 'canvas_forbidden_message.dart' show canvasDrawForbiddenMessage;
import 'canvas_retry.dart';
import 'canvas_presence_geometry.dart'
    show presenceTileIdentity, presenceTileKeyForSlot, presenceTileKind;

class CanvasMediaSlotSync {
  CanvasMediaSlotSync({
    required this.channelId,
    required this.client,
    required this.overrides,
    this.onError,
    this.sendPreview,
    this.selfId,
    this.isBlocked,
    this.timedOutUntil,
  }) {
    overrides.onSharedRectDragged = (key, rect) => reportDrag(key, rect);
  }

  final String channelId;
  final api.SlimmApi client;
  final CanvasPresenceTileOverrides overrides;

  /// Told when a tile change could not be saved and was put back.
  final void Function(String message)? onError;

  /// Streams a tile's box mid-drag; null leaves tile drags visible to others only on commit.
  final void Function(String key, Rect rect, {required bool ended})?
  sendPreview;
  final String? Function()? selfId;
  final bool Function(String userId)? isBlocked;

  /// The caller's current timeout deadline in Unix milliseconds, or null.
  final int? Function()? timedOutUntil;

  bool get _isTimedOut {
    final until = timedOutUntil?.call();
    return until != null &&
        DateTime.fromMillisecondsSinceEpoch(until).isAfter(DateTime.now());
  }

  final Map<String, Future<void>> _tails = {};
  final Map<String, Timer> _abandon = {};
  DateTime? _lastPreview;

  /// How long a stream may go quiet without a commit before the drag counts as abandoned.
  static const _abandonAfter = Duration(seconds: 3);

  /// Call on every shared-view drag step; throttled like the other ephemeral previews.
  void reportDrag(String key, Rect rect, {DateTime? now}) {
    if (_isTimedOut) return;
    final send = sendPreview;
    if (send == null) return;
    final at = now ?? DateTime.now();
    _abandon[key]?.cancel();
    _abandon[key] = Timer(_abandonAfter, () => _endPreview(key, rect));
    final last = _lastPreview;
    if (last != null &&
        at.isAfter(last) &&
        at.difference(last) < cursorSendInterval) {
      return;
    }
    _lastPreview = at;
    send(key, rect, ended: false);
  }

  void _endPreview(String key, Rect rect) {
    if (_abandon.remove(key) == null) return;
    _abandon[key]?.cancel();
    sendPreview?.call(key, rect, ended: true);
  }

  /// Drops pending abandon timers; the pane calls this when it goes away.
  void dispose() {
    for (final timer in _abandon.values) {
      timer.cancel();
    }
    _abandon.clear();
    overrides.onSharedRectDragged = null;
  }

  /// Shows another member's streamed tile drag; a locked tile, a blocked sender and this device's own frames are ignored.
  void applyRemotePreview(api.CanvasMediaSlotPreview event) {
    if (event.channelId != channelId) return;
    if (event.userId == selfId?.call()) return;
    if (isBlocked?.call(event.userId) ?? false) return;
    final key = presenceTileKeyForSlot(event.kind, event.slotUserId);
    if (event.ended) {
      overrides.revertToServer(key);
      return;
    }
    overrides.showRemoteRect(
      key,
      Rect.fromLTWH(event.x, event.y, event.w, event.h),
    );
  }

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
    _abandon.remove(key)?.cancel();
    final until = timedOutUntil?.call();
    if (until != null &&
        DateTime.fromMillisecondsSinceEpoch(until).isAfter(DateTime.now())) {
      overrides.revertToServer(key);
      sendPreview?.call(key, overrides.stateFor(key).rect ?? rect, ended: true);
      onError?.call(canvasDrawForbiddenMessage(until));
      return Future.value();
    }
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
      sendPreview?.call(key, overrides.stateFor(key).rect ?? rect, ended: true);
      onError?.call(_explain(error, timedOutUntil?.call()));
    }
  }

  static String _explain(api.ApiException error, [int? timedOutUntil]) =>
      switch (error) {
        api.ConflictException() => 'That tile is locked in place.',
        api.ForbiddenException() =>
          timedOutUntil != null &&
                  DateTime.fromMillisecondsSinceEpoch(
                    timedOutUntil,
                  ).isAfter(DateTime.now())
              ? canvasDrawForbiddenMessage(timedOutUntil)
              : 'You cannot move tiles in this channel right now.',
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
