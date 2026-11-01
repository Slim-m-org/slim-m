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
import 'canvas_retry.dart';

const Duration _attemptTimeout = Duration(seconds: 15);
const Duration _closeGrace = Duration(seconds: 30);
const Duration _unreadableReplyDelay = Duration(seconds: 1);
const int _maxUnreadableReplies = 3;
const int _attemptsBeforeRotating = 8;

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
    this.onUnsaved,
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

  /// Told when a stroke's save starts being retried, and again when it settles either way.
  final void Function(String id, {required bool unsaved})? onUnsaved;

  final List<CanvasCommit> _pending = <CanvasCommit>[];
  final Set<String> _armedForRemoval = <String>{};
  final Set<String> _attempted = <String>{};
  String? _inFlightId;
  var _unreadableReplies = 0;
  bool _running = false;
  bool _closed = false;
  bool _expired = false;
  Timer? _closeDeadline;

  /// True while the commit at the head is being retried, so what waits behind it is unsaved too.
  bool _retrying = false;

  void add(CanvasCommit commit) {
    if (_closed) return;
    if (_retrying) onUnsaved?.call(commit.id, unsaved: true);
    _pending.add(commit);
    unawaited(_drain());
  }

  /// Stops reporting, but keeps sending what is queued for [_closeGrace], so
  /// hanging up right after a scribble does not drop its tail for everyone.
  void close() {
    if (_closed) return;
    _closed = true;
    if (!_running) return;
    _closeDeadline = Timer(_closeGrace, () => _expired = true);
  }

  /// See [UndoPlacementOutcome]. Named for its main caller, undo, but the
  /// eraser catching its own just-drawn ink resolves through the same path.
  UndoPlacementOutcome undoPlacement(String id) {
    final index = _pending.indexWhere((c) => c.id == id);
    if (index != -1 && _attempted.contains(id)) {
      // An earlier try may have landed with its reply lost, so removal waits for the confirm.
      _armedForRemoval.add(id);
      return UndoPlacementOutcome.armed;
    }
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
      while (_pending.isNotEmpty && !_expired) {
        final commit = _pending.removeAt(0);
        await _send(commit);
      }
    } finally {
      _running = false;
      _closeDeadline?.cancel();
    }
  }

  /// Retries until the server accepts or definitively refuses: a blip or a
  /// deploy must not delete ink the drawer can still see on their screen.
  Future<void> _send(CanvasCommit commit) async {
    _inFlightId = commit.id;
    _unreadableReplies = 0;
    try {
      var finished = false;
      while (!finished) {
        finished = await _attempt(commit);
      }
    } finally {
      if (_inFlightId == commit.id) _inFlightId = null;
      if (!_pending.any((c) => c.id == commit.id)) _attempted.remove(commit.id);
    }
  }

  /// Whether the commit is settled; false asks for another try with the same id.
  Future<bool> _attempt(CanvasCommit commit) async {
    try {
      _attempted.add(commit.id);
      final object = await retryCanvasRequest(
        () => _place(commit),
        maxAttempts: _attemptsBeforeRotating,
        giveUp: () => _expired,
        onRetry: () => _markRetrying(commit),
      );
      _confirm(commit, object);
      return true;
    } on api.ApiException catch (error, stack) {
      api.reportFailure(api.LogTag.ui, 'send a canvas change', error, stack);
      if (isTransientCanvasFailure(error) && !_expired) {
        // A reply that never reads must not hold up every stroke behind it.
        if (_pending.isEmpty) return false;
        _pending.add(commit);
        return true;
      }
      _refuse(commit, error);
      return true;
    } on Object catch (error, stack) {
      // A reply that cannot be read may still mean the stroke landed, so ask again with the same id.
      api.reportFailure(api.LogTag.ui, 'read a canvas reply', error, stack);
      if (++_unreadableReplies >= _maxUnreadableReplies || _expired) {
        _refuse(commit, null);
        return true;
      }
      await Future<void>.delayed(_unreadableReplyDelay);
      return false;
    }
  }

  Future<api.CanvasObject> _place(CanvasCommit commit) => client
      .placeCanvasObject(
        channelId,
        id: commit.id,
        kind: 'stroke',
        x: commit.x,
        y: commit.y,
        w: commit.w,
        h: commit.h,
        props: commit.props,
      )
      .timeout(
        _attemptTimeout,
        onTimeout: () => throw const api.TransportException('timed out'),
      );

  void _markRetrying(CanvasCommit commit) {
    _retrying = true;
    onUnsaved?.call(commit.id, unsaved: true);
    for (final waiting in _pending) {
      onUnsaved?.call(waiting.id, unsaved: true);
    }
  }

  void _confirm(CanvasCommit commit, api.CanvasObject object) {
    _retrying = false;
    onUnsaved?.call(commit.id, unsaved: false);
    if (_closed) return;
    if (_armedForRemoval.remove(commit.id)) {
      onEraseOnConfirm(commit.id);
    } else {
      onPlaced(object);
    }
  }

  void _refuse(CanvasCommit commit, api.ApiException? error) {
    _retrying = false;
    onUnsaved?.call(commit.id, unsaved: false);
    if (_closed) return;
    _armedForRemoval.remove(commit.id);
    if (error != null && _isRemovedConflict(error)) {
      onRemoved(commit.id);
    } else {
      onFailed(commit.id, _explain(error, timedOutUntil()));
    }
  }

  /// A retried placement's own id already names a removed object: the
  /// object was real and a moderator (or this same gesture's own undo) took
  /// it while the retry was in flight, distinct from [api.ConflictException]'s
  /// other two shapes (a taken id, a full canvas), which mean it never
  /// existed at all.
  static bool _isRemovedConflict(api.ApiException error) =>
      error is api.ConflictException && error.message == _removedMessage;

  static const _removedMessage = 'that object was removed';

  static String _explain(
    api.ApiException? error,
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
