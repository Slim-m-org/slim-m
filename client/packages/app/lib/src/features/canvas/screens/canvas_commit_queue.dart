// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one place a drawn stroke becomes rows on the server.
///
/// Serial by design: one request in flight, FIFO. Ordering is what `z_index`
/// is seeded from, so two strokes committed concurrently could land in either
/// order and re-layer overlapping ink differently for every viewer.
library;

import 'dart:async';

import 'package:slimm_api/api.dart' as api;

import 'canvas_forbidden_message.dart';

/// One queued placement.
class CanvasCommit {
  CanvasCommit({
    required this.id,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.props,
  });

  final String id;
  final double x;
  final double y;
  final double w;
  final double h;
  final Map<String, dynamic> props;
}

/// What undoing a placement named by an id this queue may or may not still
/// hold found.
enum UndoPlacementOutcome {
  /// Not yet sent: dropped from the queue outright, no round trip, since the
  /// server never saw it.
  cancelled,

  /// The commit currently in flight: issuing a removal now would 404 against
  /// an object that does not exist yet, so it is armed instead and
  /// [CanvasCommitQueue.onEraseOnConfirm] fires the moment it lands.
  armed,

  /// Neither pending nor in flight - already committed, or already failed
  /// for good. The caller tells those apart by asking the document, since
  /// this queue no longer tracks either once they leave it.
  unresolved,
}

/// Sends placements one at a time, retrying only what a retry can fix.
class CanvasCommitQueue {
  CanvasCommitQueue({
    required this.client,
    required this.channelId,
    required this.onPlaced,
    required this.onFailed,
    required this.onRemoved,
    required this.onEraseOnConfirm,
    required this.timedOutUntil,
  });

  final api.SlimmApi client;
  final String channelId;
  final void Function(api.CanvasObject object) onPlaced;

  /// The caller's own current timeout deadline, Unix milliseconds or null,
  /// read fresh on every refusal rather than captured once at construction -
  /// see [canvasDrawForbiddenMessage] for why.
  final int? Function() timedOutUntil;

  /// Called with the id and a sentence to show, once a commit is beyond
  /// retry and was never a real object server-side.
  final void Function(String id, String message) onFailed;

  /// Called instead of [onFailed] when a retried placement finds its own id
  /// already removed: the object was real and is gone, so the caller should
  /// drop it from view rather than mark it as never having landed.
  final void Function(String id) onRemoved;

  /// An id [undoPlacement] armed while in flight has now landed, so the
  /// removal an undo (or the eraser, catching its own still-unsent ink)
  /// could not issue up front happens the instant there is something to
  /// remove.
  final void Function(String id) onEraseOnConfirm;

  final List<CanvasCommit> _pending = <CanvasCommit>[];
  final Set<String> _armedForRemoval = <String>{};
  String? _inFlightId;
  bool _running = false;
  bool _closed = false;

  void add(CanvasCommit commit) {
    if (_closed) return;
    _pending.add(commit);
    unawaited(_drain());
  }

  void close() => _closed = true;

  /// See [UndoPlacementOutcome]. Named for its main caller, undo, but the
  /// eraser catching its own just-drawn ink resolves through the same path.
  UndoPlacementOutcome undoPlacement(String id) {
    final index = _pending.indexWhere((c) => c.id == id);
    if (index != -1) {
      _pending.removeAt(index);
      return UndoPlacementOutcome.cancelled;
    }
    if (_inFlightId == id) {
      _armedForRemoval.add(id);
      return UndoPlacementOutcome.armed;
    }
    return UndoPlacementOutcome.unresolved;
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending.isNotEmpty && !_closed) {
        final commit = _pending.removeAt(0);
        await _send(commit);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _send(CanvasCommit commit) async {
    _inFlightId = commit.id;
    try {
      // Three tries backing off: a 429 while somebody scribbles must not lose ink already on their own screen.
      var delay = const Duration(milliseconds: 250);
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final object = await client.placeCanvasObject(
            channelId,
            id: commit.id,
            kind: 'stroke',
            x: commit.x,
            y: commit.y,
            w: commit.w,
            h: commit.h,
            props: commit.props,
          );
          if (_closed) return;
          if (_armedForRemoval.remove(commit.id)) {
            onEraseOnConfirm(commit.id);
          } else {
            onPlaced(object);
          }
          return;
        } on api.ApiException catch (error) {
          if (_closed) return;
          if (!_retryable(error) || attempt == 2) {
            _armedForRemoval.remove(commit.id);
            if (_isRemovedConflict(error)) {
              onRemoved(commit.id);
            } else {
              onFailed(commit.id, _explain(error, timedOutUntil()));
            }
            return;
          }
          await Future<void>.delayed(delay);
          delay *= 2;
        }
      }
    } finally {
      if (_inFlightId == commit.id) _inFlightId = null;
    }
  }

  static bool _retryable(api.ApiException error) =>
      error is api.RateLimitedException ||
      error is api.UnavailableException ||
      error is api.TransportException;

  /// A retried placement's own id already names a removed object: the
  /// object was real and a moderator (or this same gesture's own undo) took
  /// it while the retry was in flight, distinct from [api.ConflictException]'s
  /// other two shapes (a taken id, a full canvas), which mean it never
  /// existed at all.
  static bool _isRemovedConflict(api.ApiException error) =>
      error is api.ConflictException && error.message == _removedMessage;

  static const _removedMessage = 'that object was removed';

  static String _explain(
    api.ApiException error,
    int? timedOutUntil,
  ) => switch (error) {
    // Covers a channel-wide refusal and a timeout freeze alike; canvasDrawForbiddenMessage tells them apart from the caller's own timeout deadline.
    api.ForbiddenException() => canvasDrawForbiddenMessage(timedOutUntil),
    // Matches canvas_quick_placement.dart and canvas_image_paste.dart's identical ConflictException wording: the id-collision half is an implementation detail nobody typed and cannot act on.
    api.ConflictException() => 'This canvas is full.',
    api.BadRequestException() => 'That stroke was refused as too large.',
    _ => 'That stroke could not be saved.',
  };
}
