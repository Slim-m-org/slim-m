// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sending this device's own in-flight stroke, and turning everyone else's
/// into what `RemoteDraftPainter` paints.
///
/// The write half of the pair `canvas_cursor_relay.dart` already is for
/// pointer position: same throttle-and-buffer shape, same staleness prune,
/// extended for a frame that carries a growing list of points rather than
/// two numbers. Split out for the same reason that file was.
library;

import 'dart:async';
import 'dart:ui';

import 'package:clock/clock.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../ids.dart';
import 'canvas_cursor_relay.dart' show canvasParticipantColorIndex;

/// How often this device's own buffered draft points are flushed at most.
/// 20 frames a second so a stroke grows near real time; the server's
/// byte-rate budget (`Class::CanvasStrokePreview`) is sized against it.
const Duration strokePreviewSendInterval = Duration(milliseconds: 50);

/// How many points one flush may send. A well-behaved client never needs
/// this much in one 50ms window; it exists so a burst of very fast pointer
/// motion still produces a bounded frame rather than one that grows with
/// how long the pause since the last flush was. The oldest points in an
/// over-full buffer are dropped, not the newest: where the pen is *now*
/// matters more to a live preview than exactly how it got there.
const int maxStrokePreviewPointsPerFrame = 20;

/// How long a remote draft survives with no refresh before it is dropped -
/// the backstop for a mid-stroke disconnect, since the ordinary path is the
/// explicit `ended` signal [applyRemote] acts on immediately. Comfortably
/// longer than a real pause mid-gesture (someone holding the pen down while
/// deciding where to go next), short enough that an abandoned draft clears
/// within a few seconds.
const Duration strokePreviewStaleAfter = Duration(seconds: 6);

/// How often stale drafts are swept.
const Duration strokePreviewPruneInterval = Duration(seconds: 2);

/// The two halves of live stroke previews: buffering and throttling this
/// device's own in-flight points, and turning an incoming frame into what
/// [drafts] holds.
class CanvasStrokePreviewRelay {
  CanvasStrokePreviewRelay({
    required this.drafts,
    required this.paletteSize,
    required this.send,
    required this.isBlocked,
    required this.selfId,
  }) {
    _pruneTimer = Timer.periodic(
      strokePreviewPruneInterval,
      (_) => drafts.pruneOlderThan(strokePreviewStaleAfter, now: clock.now()),
    );
  }

  final RemoteStrokeDrafts drafts;

  /// The size of the caller's closed cursor-colour set, shared with
  /// [CanvasStrokePreviewRelay]'s own colour scheme so a participant's ink
  /// matches their cursor.
  final int paletteSize;

  /// Sends this device's own buffered points onward for [objectId], already
  /// throttled and capped by the time this is called.
  final void Function(String objectId, List<double> points, bool ended) send;

  final bool Function(String userId) isBlocked;

  /// The signed-in user's own id, read fresh on every call rather than
  /// captured once, matching `CanvasCursorRelay.selfId`'s own reasoning.
  final String? Function() selfId;

  Timer? _pruneTimer;
  Timer? _flushTimer;
  String? _activeObjectId;
  final List<Offset> _pending = <Offset>[];

  /// Call for every `DraftPointAdded` while this device draws: mints a new
  /// draft id on the first point of a gesture and starts the flush timer,
  /// or buffers onto the one already in progress.
  void reportLocalDraftPoint(Offset world) {
    _activeObjectId ??= newCanvasDraftId();
    _pending.add(world);
    _flushTimer ??= Timer.periodic(strokePreviewSendInterval, (_) => _flush());
  }

  /// Call once a local gesture ends, whether or not it went on to commit a
  /// real object. Flushes whatever is still buffered, marked `ended: true`
  /// so remote viewers drop the preview immediately rather than waiting out
  /// [strokePreviewStaleAfter].
  void endLocalDraft() {
    if (_activeObjectId == null) return;
    _flush(ended: true);
    _flushTimer?.cancel();
    _flushTimer = null;
    _activeObjectId = null;
  }

  void _flush({bool ended = false}) {
    final objectId = _activeObjectId;
    if (objectId == null) return;
    if (_pending.isEmpty && !ended) return;
    final points = _capped(_pending);
    _pending.clear();
    send(objectId, points, ended);
  }

  /// The flattened `[x0,y0,x1,y1,...]` for at most
  /// [maxStrokePreviewPointsPerFrame] of [points], keeping the most recent.
  List<double> _capped(List<Offset> points) {
    final kept = points.length > maxStrokePreviewPointsPerFrame
        ? points.sublist(points.length - maxStrokePreviewPointsPerFrame)
        : points;
    return [
      for (final p in kept) ...[p.dx, p.dy],
    ];
  }

  /// Call for every live stroke-preview frame naming this channel. Silently
  /// drops this device's own echo and a blocked author's ink, the same
  /// treatment `CanvasCursorRelay.applyRemote` already gives.
  void applyRemote(
    String userId,
    String objectId,
    List<double> points,
    bool ended,
  ) {
    if (userId == selfId() || isBlocked(userId)) return;
    if (ended) {
      drafts.finish(objectId, now: clock.now());
      return;
    }
    if (points.isEmpty) return;
    drafts.appendOrCreate(
      objectId: objectId,
      authorId: userId,
      points: points,
      colorIndex: canvasParticipantColorIndex(userId, paletteSize),
      now: clock.now(),
    );
  }

  void dispose() {
    endLocalDraft();
    _pruneTimer?.cancel();
    drafts.clear();
  }
}
