// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reconciles a channel's canvas op stream against the local document, which has no durable state: a closed pane and an offline client both recover by a cold viewport read.
/// One sequenced reducer applies live frames, catch-up pages and viewport pages: ops at or below the cursor are skipped, the next applies, later ones buffer while a catch-up fills the gap.
/// Plain Dart with no `Ref` or `BuildContext`, so a live frame applies inside the frame that produced it.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:ui' show Rect;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../widgets/canvas_clear_scope.dart' show clearDocumentScope;
import '../providers/canvas_object_inputs.dart';
import 'canvas_op_log.dart';

export '../providers/canvas_object_inputs.dart';

part 'canvas_sync_pages.dart';

/// Past this many pages, replaying the feed costs no less than a cold
/// viewport re-read, and the re-read is strictly better: it also drops
/// everything outside the caller's own region.
@visibleForTesting
const int maxCatchUpPages = 25;

/// A request that never answers (a half-open socket after a deploy) would
/// otherwise hold the single catch-up slot forever and drop every later gap.
@visibleForTesting
const Duration catchUpDeadline = Duration(seconds: 15);

/// A failed catch-up re-arms itself this many times, backing off from two seconds.
@visibleForTesting
const int maxCatchUpRetries = 6;

/// A hard reset costs one viewport read; without a floor, a server emitting
/// an op kind this client cannot parse turns every stale client into a
/// refetch loop.
@visibleForTesting
const Duration hardResetFloor = Duration(seconds: 5);

/// The ops page size; the server's own default of 100 doubles the requests.
const int catchUpPageSize = 200;

/// Frames held for a gap to close; past this the feed is the only source.
const int maxBufferedFrames = 512;

/// What a viewport page did to the document.
enum CanvasPageOutcome {
  /// Applied; the caller should catch up from the cursor.
  applied,

  /// Older than anything the op log can bring forward: read the region again.
  stale,
}

/// How one pass over the feed ended.
enum _PassEnd {
  /// Read to the head.
  done,

  /// Gave up; a retry timer or the next trigger tries again.
  failed,

  /// The document was reset under it; a cold read re-seeds the cursor.
  restarted,
}

class _Buffered {
  const _Buffered(this.apply, this.replay);

  final void Function() apply;
  final api.CanvasOp? replay;
}

/// Reconciles [document] against one channel's canvas op stream.
class CanvasSync {
  CanvasSync({
    required this.channelId,
    required this.client,
    required this.document,
    required this.coldFetch,
    required this.forgetFetchedRegion,
    this.onObjectPlaced,
    this.onOpApplied,
    this.onHardReset,
    this.settleObjectPreview,
    this.isShownOffPlace,
  });

  final String channelId;
  final api.SlimmApi client;
  final CanvasDocument document;

  /// Fires for every object a catch-up `place` op actually applies, so the
  /// pane's image hydrator sees an arrival off this path exactly as it does
  /// a viewport page or a live frame.
  final void Function(api.CanvasObject object)? onObjectPlaced;

  /// Fires for every op the catch-up feed actually applies, so the
  /// accessibility activity log sees the history a reconnect or a gap replays.
  final void Function(api.CanvasOp op)? onOpApplied;

  /// Fires when a hard reset discards local state for a fresh snapshot.
  final VoidCallback? onHardReset;

  /// A committed move reached the document by any path; the drag preview of
  /// that object has nothing left to say.
  final void Function(String objectId)? settleObjectPreview;

  /// Whether an object is drawn somewhere other than where the server has it
  /// (a drag in progress), so its box says nothing about a snapshot.
  final bool Function(String objectId)? isShownOffPlace;

  /// The pane's own cold viewport fetch: it alone knows the padded region and
  /// owns the fetched-region cache. A restored object's payload was freed on
  /// removal, so only a read brings it back.
  final Future<void> Function() coldFetch;

  /// Drops the pane's fetched-region cache, so the next camera move refetches.
  final VoidCallback forgetFetchedRegion;

  int? _cursor;

  int? get _asOfSeq => _cursor;

  set _asOfSeq(int? seq) {
    _cursor = seq;
    document.reflectedSeq = seq;
  }

  Timer? _retryTimer;
  Timer? _resetTimer;
  int _retries = 0;
  Stopwatch? _sinceReset;
  bool _catchingUp = false;
  bool _rerun = false;
  bool _disposed = false;
  int _epoch = 0;
  final SplayTreeMap<int, _Buffered> _early = SplayTreeMap<int, _Buffered>();
  final CanvasOpLog _log = CanvasOpLog();

  /// The highest op this document reflects, or null before the first viewport read.
  /// Also the clear control's fencing token: sent as `before_seq` it means "clear what I have seen", so a retried clear cannot wipe ink drawn while it was in flight.
  int? get asOfSeq => _asOfSeq;

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _resetTimer?.cancel();
    _early.clear();
  }

  /// Seeds the cursor from a viewport read's `latestSeq`, only the first time.
  /// A later region refetch must not advance it, or the cursor could pass the op that removed another region's object.
  void seedFromViewport(int latestSeq) {
    if (_asOfSeq != null) return;
    _asOfSeq = latestSeq;
    _log.reset(latestSeq);
  }

  /// A live frame named [seq] arrived; [apply] materializes its payload and [replay] is what a later, older viewport page re-applies.
  /// Ignored before the first read seeds the cursor or when already reflected; applied if exactly next, otherwise buffered while a catch-up fetches the gap.
  void applyLive(int? seq, void Function() apply, {api.CanvasOp? replay}) {
    if (seq == null) {
      _guarded(apply);
      return;
    }
    final cursor = _asOfSeq;
    if (cursor == null || seq <= cursor) return;
    if (seq == cursor + 1) {
      _advance(seq, apply, replay);
      _drainBuffered();
      return;
    }
    if (_early.length < maxBufferedFrames) {
      _early[seq] = _Buffered(apply, replay);
    }
    unawaited(catchUp());
  }

  /// Reconciles an op the live frame could not carry without advancing the cursor past it (a restore frame with no ids).
  /// Not [applyLive] with an empty apply, which would skip the only op able to clear those tombstones.
  void deferToFeed() => unawaited(catchUp());

  bool _guarded(void Function() apply) {
    try {
      apply();
      return true;
    } on Object catch (error, stack) {
      api.reportFailure(api.LogTag.ui, 'apply a canvas change', error, stack);
      return false;
    }
  }

  void _advance(int seq, void Function() apply, api.CanvasOp? replay) {
    // Left unmoved on failure, so the feed replays this op instead of the cursor wedging behind it.
    if (!_guarded(apply)) {
      unawaited(catchUp());
      return;
    }
    _asOfSeq = seq;
    if (replay != null) _log.add(replay);
  }

  void _drainBuffered() {
    while (true) {
      final cursor = _asOfSeq;
      if (cursor == null) return;
      _early.removeWhere((seq, _) => seq <= cursor);
      final next = _early.remove(cursor + 1);
      if (next == null) return;
      _advance(cursor + 1, next.apply, next.replay);
      if (_asOfSeq == cursor) return;
    }
  }

  /// Pages the ops feed from the cursor, applying every op in order; a request during a run sets a flag for one more pass, and a failed pass leaves its own retry timer.
  Future<void> catchUp() async {
    if (_disposed || _asOfSeq == null) return;
    if (_catchingUp) {
      _rerun = true;
      return;
    }
    _catchingUp = true;
    try {
      do {
        _rerun = false;
        if (await _catchUpPages() == _PassEnd.failed) break;
      } while (_rerun && !_disposed);
    } finally {
      _catchingUp = false;
    }
  }

  /// The newest op this client can name, for a control that must not leave
  /// later ink standing: caught up first when there is a cursor, and read off
  /// the feed without applying anything when the first read never landed.
  Future<int?> fenceHead() async {
    if (_asOfSeq == null) return (await _fetchPage(0))?.latestSeq;
    await catchUp();
    return _asOfSeq;
  }

  void _scheduleRetry() {
    if (_disposed || _retries >= maxCatchUpRetries) return;
    _retryTimer?.cancel();
    final delay = Duration(seconds: 2 << _retries++);
    _retryTimer = Timer(delay, () => unawaited(catchUp()));
  }

  _PassEnd _finishCatchUp(int latestSeq) {
    _retries = 0;
    _retryTimer?.cancel();
    _commitHead(latestSeq);
    _drainBuffered();
    return _PassEnd.done;
  }

  Future<_PassEnd> _catchUpPages() async {
    final epoch = _epoch;
    for (var page = 0; page < maxCatchUpPages; page++) {
      final cursor = _asOfSeq;
      if (cursor == null) return _PassEnd.restarted;
      final result = await _fetchPage(cursor);
      final end = await _unusablePage(result, epoch);
      if (end != null) return end;
      if (!result!.hasMore) return _finishCatchUp(result.latestSeq);
      // A page that claims more and carries nothing cannot be paged past.
      if (result.ops.isEmpty) break;
    }
    await _hardReset();
    return _PassEnd.restarted;
  }

  Future<_PassEnd?> _unusablePage(api.CanvasOpsPage? result, int epoch) async {
    if (_disposed) return _PassEnd.failed;
    if (epoch != _epoch) return _PassEnd.restarted;
    if (result == null) {
      _scheduleRetry();
      return _PassEnd.failed;
    }
    if (result.reset || !_applyOps(result.ops)) {
      await _hardReset();
      return _PassEnd.restarted;
    }
    return null;
  }

  /// Applies the ops above the cursor in order, moving it as each lands, so a
  /// live frame arriving between pages is judged against the real position.
  bool _applyOps(List<api.CanvasOp> ops) {
    for (final op in ops) {
      final cursor = _asOfSeq;
      if (cursor == null) return false;
      if (op.seq <= cursor) continue;
      try {
        if (!_applyOp(op)) return false;
      } on Object catch (error, stack) {
        // An op this client cannot apply is the same as one it cannot parse: resync.
        api.reportFailure(api.LogTag.ui, 'apply a canvas change', error, stack);
        return false;
      }
      _asOfSeq = op.seq;
      _log.add(op);
    }
    return true;
  }

  void _commitHead(int latestSeq) {
    final committed = _asOfSeq;
    _asOfSeq = committed == null || latestSeq > committed
        ? latestSeq
        : committed;
    document.refresh();
  }

  /// Applies one op read off the catch-up feed. Returns false for a kind
  /// this client does not recognise, so the caller resets rather than
  /// skips it - skipping could mean leaving ink on screen the server has
  /// removed, which is the one failure this whole surface exists to avoid.
  bool _applyOp(api.CanvasOp op) {
    switch (op) {
      case api.CanvasPlaceOp(:final object):
        if (object != null) _applyPlaced(object);
      case api.CanvasRestoreOp(:final objectIds):
        document.forgetRemoved(objectIds);
        forgetFetchedRegion();
        // A restored object's payload was freed on removal, so nothing shows it again without this read.
        unawaited(coldFetch());
      case api.CanvasUnknownOp():
        return false;
      case api.CanvasMoveOp(:final objectId):
        settleObjectPreview?.call(objectId);
        _reapply(op);
      case api.CanvasRemoveOp() ||
          api.CanvasClearOp() ||
          api.CanvasReorderOp() ||
          api.CanvasEditOp():
        _reapply(op);
    }
    onOpApplied?.call(op);
    return true;
  }

  /// The document change an op makes, without any of the notifications.
  void _reapply(api.CanvasOp op) {
    switch (op) {
      case api.CanvasRemoveOp(:final objectIds):
        for (final id in objectIds) {
          document.removeObject(id, seq: op.seq);
        }
      case api.CanvasClearOp(:final beforeSeq, :final scope, :final sparedIds):
        clearDocumentScope(
          document,
          beforeSeq,
          scope,
          opSeq: op.seq,
          spared: sparedIds.toSet(),
        );
      case api.CanvasMoveOp(
        :final objectId,
        :final x,
        :final y,
        :final w,
        :final h,
      ):
        document.moveObject(objectId, x, y, w, h);
      case api.CanvasReorderOp(:final objectId, :final zIndex):
        document.setZIndex(objectId, zIndex);
      case api.CanvasEditOp(:final objectId, :final props):
        applyEditedProps(document, objectId, props);
      default:
        break;
    }
  }

  void _applyPlaced(api.CanvasObject object) {
    final input = canvasStrokeInputFrom(object);
    if (input == null) return;
    document.applyPlaced(input);
    onObjectPlaced?.call(object);
  }

  /// Fetches one page, retrying a rate limit with backoff so a 429 never becomes a document wipe.
  /// Null means retries were spent or another failure occurred; the caller abandons the attempt and a later gap or reconnect retries.
  Future<api.CanvasOpsPage?> _fetchPage(int afterSeq) async {
    var delay = const Duration(milliseconds: 250);
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_disposed) return null;
      try {
        return await client
            .canvasOps(channelId, afterSeq: afterSeq, limit: catchUpPageSize)
            .timeout(catchUpDeadline);
      } on api.RateLimitedException catch (error, stack) {
        api.reportFailure(api.LogTag.ui, 'load canvas changes', error, stack);
        if (attempt == 2) return null;
        await Future<void>.delayed(delay);
        delay *= 2;
      } on Object catch (error, stack) {
        api.reportFailure(api.LogTag.ui, 'load canvas changes', error, stack);
        return null;
      }
    }
    return null;
  }

  /// Empties the document, drops the cursor and cold-fetches.
  /// A second reset inside the floor is postponed to its end rather than dropped, so an unknown op kind cannot loop and a stale client is never left stale.
  Future<void> _hardReset() async {
    final since = _sinceReset;
    if (since != null && since.elapsed < hardResetFloor) {
      _resetTimer ??= Timer(hardResetFloor - since.elapsed, () {
        _resetTimer = null;
        if (!_disposed) unawaited(_hardReset());
      });
      return;
    }
    _sinceReset = clock.stopwatch()..start();
    _epoch++;
    document.reset();
    forgetFetchedRegion();
    _asOfSeq = null;
    _early.clear();
    _log.reset(0);
    onHardReset?.call();
    if (_disposed) return;
    await coldFetch();
  }
}
