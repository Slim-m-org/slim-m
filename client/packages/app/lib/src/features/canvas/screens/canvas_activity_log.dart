// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas's text activity log: docs/ROADMAP.md's Phase 6 accessibility
/// fallback, closing the one surface in this product a `CustomPainter`
/// leaves with nothing for a screen reader.
///
/// Plain Dart, like `CanvasSync` and `CanvasOpsController`: recording an op
/// or a live event costs no Riverpod read, only the widget layer that later
/// resolves an actor id into a display name does. What an entry carries is
/// exactly what the wire already decided to disclose - never more.
///
/// **The withheld actor is trusted, not re-derived.** `GET /canvas/ops`
/// already nulls `actor_id` for a moderation act (remove, clear, restore,
/// move) unless the caller holds `MANAGE_CANVAS`, and a live socket frame
/// for those same kinds never carries an actor field at all - see
/// `Event::CanvasObjectsRemoved`'s own doc. This log never guesses a name
/// for a null actor and never treats "no actor on the wire" as "unknown
/// actor, ask again": both read the same way here, as nothing to say.
///
/// **Blocking matches the cursor precedent, not a new rule.**
/// `CanvasCursorRelay.applyRemote` drops a blocked author's pointer before it
/// ever reaches [CanvasCursors]; [CanvasActivityLog] drops a blocked
/// author's entry the same way, before it ever reaches the list a screen
/// reader can browse.
library;

import 'dart:async';
import 'dart:collection';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:slimm_api/api.dart' as api;

/// What happened to the canvas. `resynced` is not a wire kind at all - it
/// marks the one honest gap this log can report: a hard reset skips
/// whatever happened between the old cursor and the fresh snapshot's head,
/// and saying nothing would read as nothing having happened rather than as
/// a known hole.
enum CanvasActivityKind {
  placed,
  moved,
  reordered,
  removed,
  cleared,
  restored,
  resynced,
}

/// One line of canvas history, already filtered for blocking and already
/// carrying whatever attribution the wire disclosed - a widget only ever
/// resolves [actorId] into a name, never decides whether to show one.
@immutable
class CanvasActivityEntry {
  const CanvasActivityEntry({
    required this.id,
    required this.kind,
    required this.actorId,
    this.objectKind,
    this.detail,
    this.count = 1,
    required this.at,
  });

  /// The op or object id this entry reports on, for a widget key - not
  /// asserted unique across entries, since a resync carries no op of its own.
  final String id;
  final CanvasActivityKind kind;

  /// Null when the server withheld it (a moderation act, read by a viewer
  /// without `MANAGE_CANVAS`) or a live frame that structurally never
  /// carries one, or the author's account has since been anonymized. All
  /// three read the same way to this log: nothing to attribute.
  final String? actorId;

  /// `'stroke'` or `'image'`, only ever known for [CanvasActivityKind.placed]
  /// - the wire's `move` op names no kind, and a removal or a clear may
  /// cover a mix.
  final String? objectKind;

  /// A note's own text, truncated - the one kind whose content is worth
  /// naming here rather than just its kind. Null for every other
  /// [CanvasActivityKind.placed] entry, and always null for every other
  /// kind: a stroke's ink, an image's bytes and a shape's outline have
  /// nothing a sentence could usefully say about them.
  final String? detail;

  /// How many objects this entry covers. A real count for `removed` and
  /// `restored`; always 1 for `placed` and `moved`; ignored by the sentence
  /// builder for `cleared` and `resynced`, which carry none on the wire.
  final int count;
  final DateTime at;
}

/// Records canvas activity for the accessibility panel and a throttled live
/// announcement, bounded so an old, busy channel cannot grow this without
/// limit for as long as one pane stays open.
class CanvasActivityLog extends ChangeNotifier {
  CanvasActivityLog({
    required this.isBlocked,
    this.capacity = 200,
    this.announceDelay = const Duration(seconds: 2),
  });

  /// The same predicate `CanvasCursorRelay.isBlocked` already takes - this
  /// log invents no second way to ask.
  final bool Function(String userId) isBlocked;
  final int capacity;

  /// A burst of quick changes (a multi-segment stroke, an erase drag over
  /// several strokes) flushes as one announcement rather than one per
  /// change, which would read as noise rather than news.
  final Duration announceDelay;

  final Queue<CanvasActivityEntry> _entries = Queue<CanvasActivityEntry>();
  List<CanvasActivityEntry> get entries => _entries.toList(growable: false);

  final List<CanvasActivityEntry> _pending = [];
  Timer? _timer;

  /// Bumped every time a throttled batch is ready to announce. A widget
  /// listens for this changing, not for a specific value: two batches that
  /// happen to summarize identically must still both fire, which a
  /// `ValueNotifier`'s equality-gated `==` check would silently swallow.
  int announcementTick = 0;

  /// Records one op read off `GET /canvas/ops`, during catch-up. `actorId`
  /// on the op is already the server's own disclosure decision.
  void recordOp(api.CanvasOp op) {
    switch (op) {
      case api.CanvasPlaceOp(:final object):
        if (object != null) _recordPlace(op.id, object);
      case api.CanvasRemoveOp(:final actorId, :final objectIds):
        _add(
          _entry(op.id, CanvasActivityKind.removed, actorId, objectIds.length),
        );
      case api.CanvasClearOp(:final actorId):
        _add(_entry(op.id, CanvasActivityKind.cleared, actorId, 1));
      case api.CanvasRestoreOp(:final actorId, :final objectIds):
        _add(
          _entry(op.id, CanvasActivityKind.restored, actorId, objectIds.length),
        );
      case api.CanvasMoveOp(:final actorId):
        _add(_entry(op.id, CanvasActivityKind.moved, actorId, 1));
      case api.CanvasReorderOp(:final actorId):
        _add(_entry(op.id, CanvasActivityKind.reordered, actorId, 1));
      case api.CanvasUnknownOp():
        break;
    }
  }

  /// A live placement: the one live event that ever carries a real actor,
  /// since placing is not a moderation act - see `CanvasObjectPlaced`'s own
  /// wire shape.
  void recordPlacedLive(api.CanvasObject object) =>
      _recordPlace(object.id, object);

  /// A live `CanvasObjectsRemoved` frame: no actor field to read at all,
  /// unlike the durable feed row the same removal also produced.
  void recordRemovedLive(String opId, List<String> objectIds) =>
      _add(_entry(opId, CanvasActivityKind.removed, null, objectIds.length));

  void recordClearedLive(String opId) =>
      _add(_entry(opId, CanvasActivityKind.cleared, null, 1));

  void recordRestoredLive(String opId, int count) =>
      _add(_entry(opId, CanvasActivityKind.restored, null, count));

  void recordMovedLive(String opId) =>
      _add(_entry(opId, CanvasActivityKind.moved, null, 1));

  /// A live `CanvasObjectReordered` frame: restacking another member's
  /// object needs `MANAGE_CANVAS`, the same moderation-capable shape a move
  /// carries, so this live frame has no actor field either - see
  /// `CanvasObjectReordered`'s own wire doc.
  void recordReorderedLive(String opId) =>
      _add(_entry(opId, CanvasActivityKind.reordered, null, 1));

  /// A hard reset happened: whatever changed between the old cursor and the
  /// fresh snapshot's head is unrecoverable, and this is the one line that
  /// says so rather than leaving a silent gap in the history.
  void recordResync() => _add(
    CanvasActivityEntry(
      id: 'resync-${_now().microsecondsSinceEpoch}',
      kind: CanvasActivityKind.resynced,
      actorId: null,
      at: _now(),
    ),
  );

  void _recordPlace(String id, api.CanvasObject object) => _add(
    CanvasActivityEntry(
      id: id,
      kind: CanvasActivityKind.placed,
      actorId: object.authorId,
      objectKind: object.kind,
      detail: _noteDetail(object),
      at: _now(),
    ),
  );

  /// A note's own text, truncated to a length worth reading aloud in a
  /// throttled announcement rather than reciting a note in full. Null for
  /// every other kind, and for a note whose `props.text` this client cannot
  /// read - the same "unparseable" case `canvasStrokeInputFrom` already
  /// treats as nothing rather than guessing.
  static String? _noteDetail(api.CanvasObject object) {
    if (object.kind != 'note') return null;
    final text = object.props['text'];
    if (text is! String || text.isEmpty) return null;
    const limit = 80;
    return text.length > limit ? '${text.substring(0, limit)}…' : text;
  }

  CanvasActivityEntry _entry(
    String id,
    CanvasActivityKind kind,
    String? actorId,
    int count,
  ) => CanvasActivityEntry(
    id: id,
    kind: kind,
    actorId: actorId,
    count: count,
    at: _now(),
  );

  DateTime _now() => clock.now();

  void _add(CanvasActivityEntry entry) {
    final actor = entry.actorId;
    if (actor != null && isBlocked(actor)) return;
    _entries.addLast(entry);
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
    _pending.add(entry);
    _timer?.cancel();
    _timer = Timer(announceDelay, _flush);
    notifyListeners();
  }

  void _flush() {
    if (_pending.isEmpty) return;
    announcementTick++;
    notifyListeners();
  }

  /// The entries the just-bumped [announcementTick] covers, clearing the
  /// pending batch. Idempotent-shaped: calling this without a new flush in
  /// between answers empty rather than replaying the same batch twice.
  List<CanvasActivityEntry> takeAnnouncementBatch() {
    final batch = List<CanvasActivityEntry>.unmodifiable(_pending);
    _pending.clear();
    return batch;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// One sentence summarizing a batch flushed together, so a burst of quick
/// changes announces once rather than once per change. [nameFor] resolves
/// an actor id into a display name; null (or a null return) renders as no
/// attribution at all, never as "someone" for a withheld moderation act.
String summarizeCanvasActivity(
  List<CanvasActivityEntry> batch, {
  String? Function(String userId)? nameFor,
}) {
  if (batch.isEmpty) return '';
  if (batch.length == 1) {
    return describeCanvasActivityEntry(batch.single, nameFor: nameFor);
  }

  final totals = <CanvasActivityKind, int>{};
  for (final entry in batch) {
    totals[entry.kind] = (totals[entry.kind] ?? 0) + entry.count;
  }
  final parts = totals.entries
      .map((e) => '${e.value} ${_kindLabel(e.key)}')
      .join(', ');
  return 'Canvas activity: $parts.';
}

/// One sentence for a single entry - what [summarizeCanvasActivity] falls
/// back to for a batch of one, and what a full activity list renders per
/// row, so the two surfaces cannot describe the same entry two ways.
String describeCanvasActivityEntry(
  CanvasActivityEntry entry, {
  String? Function(String userId)? nameFor,
}) {
  final who = entry.actorId == null ? null : nameFor?.call(entry.actorId!);
  switch (entry.kind) {
    case CanvasActivityKind.placed:
      final what = switch (entry.objectKind) {
        'image' => 'an image',
        'note' => 'a note',
        'shape' => 'a shape',
        _ => 'a stroke',
      };
      final detail = entry.detail == null ? '' : ': ${entry.detail}';
      return who == null
          ? 'Someone placed $what$detail.'
          : '$who placed $what$detail.';
    case CanvasActivityKind.moved:
      return who == null ? 'An object was moved.' : '$who moved an object.';
    case CanvasActivityKind.reordered:
      return who == null
          ? "An object's stacking order changed."
          : "$who changed an object's stacking order.";
    case CanvasActivityKind.removed:
      final what = entry.count == 1 ? 'An object' : '${entry.count} objects';
      final verb = entry.count == 1 ? 'was' : 'were';
      return who == null
          ? '$what $verb removed.'
          : '$who removed ${what.toLowerCase()}.';
    case CanvasActivityKind.cleared:
      return who == null
          ? 'The canvas was cleared.'
          : '$who cleared the canvas.';
    case CanvasActivityKind.restored:
      final what = entry.count == 1 ? 'An object' : '${entry.count} objects';
      final verb = entry.count == 1 ? 'was' : 'were';
      return who == null
          ? '$what $verb restored.'
          : '$who restored ${what.toLowerCase()}.';
    case CanvasActivityKind.resynced:
      return 'The canvas reloaded from the server.';
  }
}

String _kindLabel(CanvasActivityKind kind) => switch (kind) {
  CanvasActivityKind.placed => 'placed',
  CanvasActivityKind.moved => 'moved',
  CanvasActivityKind.reordered => 'reordered',
  CanvasActivityKind.removed => 'removed',
  CanvasActivityKind.cleared => 'cleared',
  CanvasActivityKind.restored => 'restored',
  CanvasActivityKind.resynced => 'reloaded',
};
